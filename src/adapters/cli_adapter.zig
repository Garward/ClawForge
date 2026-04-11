const std = @import("std");
const posix = std.posix;
const common = @import("common");
const core = @import("core");
const adapter_mod = @import("adapter.zig");

/// CLI adapter: Unix socket server for the clawforge CLI client.
/// Receives length-prefixed JSON requests, delegates to engine, sends responses.
pub const CliAdapter = struct {
    allocator: std.mem.Allocator,
    config: *const common.Config,
    engine: *core.Engine,
    socket_fd: ?posix.socket_t,
    socket_path: []const u8,
    running: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const common.Config,
        engine_ptr: *core.Engine,
        socket_path: []const u8,
    ) CliAdapter {
        return .{
            .allocator = allocator,
            .config = config,
            .engine = engine_ptr,
            .socket_fd = null,
            .socket_path = socket_path,
            .running = false,
        };
    }

    pub fn deinit(self: *CliAdapter) void {
        if (self.socket_fd) |fd| posix.close(fd);
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
    }

    pub fn adapter(self: *CliAdapter) adapter_mod.Adapter {
        return .{
            .name = "cli",
            .display_name = "CLI Socket",
            .version = "0.2.0",
            .ptr = @ptrCast(self),
            .vtable = &.{
                .start = start,
                .run = run,
                .stop = stop,
            },
        };
    }

    fn start(ptr: *anyopaque) !void {
        const self: *CliAdapter = @ptrCast(@alignCast(ptr));

        // Remove existing socket file
        std.fs.deleteFileAbsolute(self.socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Ensure parent directory
        if (std.fs.path.dirname(self.socket_path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(socket_fd);

        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        if (self.socket_path.len >= addr.path.len) return error.NameTooLong;

        @memset(&addr.path, 0);
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);

        try posix.bind(socket_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(socket_fd, 5);

        self.socket_fd = socket_fd;
        self.running = true;

        std.log.info("CLI adapter listening on {s}", .{self.socket_path});
    }

    fn run(ptr: *anyopaque) void {
        const self: *CliAdapter = @ptrCast(@alignCast(ptr));
        const socket_fd = self.socket_fd orelse return;

        while (self.running) {
            var client_addr: posix.sockaddr.un = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un);

            const client_fd = posix.accept(socket_fd, @ptrCast(&client_addr), &addr_len, 0) catch |err| {
                if (!self.running) break;
                std.log.err("Accept failed: {}", .{err});
                continue;
            };

            std.log.debug("Client connected", .{});
            self.handleClient(client_fd) catch |err| {
                std.log.err("Error handling client: {}", .{err});
            };
            posix.close(client_fd);
            std.log.debug("Client disconnected", .{});
        }
    }

    fn stop(ptr: *anyopaque) void {
        const self: *CliAdapter = @ptrCast(@alignCast(ptr));
        self.running = false;
    }

    // -- Internal: client handling (moved from server.zig + handler.zig) --

    fn handleClient(self: *CliAdapter, client_fd: posix.socket_t) !void {
        while (self.running) {
            // Read length prefix
            var len_buf: [4]u8 = undefined;
            readExact(client_fd, &len_buf) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            const len = std.mem.readInt(u32, &len_buf, .big);

            if (len > 10 * 1024 * 1024) {
                try sendResponse(self.allocator, client_fd, .{ .error_resp = .{
                    .code = "MESSAGE_TOO_LARGE",
                    .message = "Request too large",
                } });
                continue;
            }

            // Read request data
            const request_data = try self.allocator.alloc(u8, len);
            defer self.allocator.free(request_data);
            try readExact(client_fd, request_data);

            // Parse request
            const request = common.Request.deserialize(self.allocator, request_data) catch {
                try sendResponse(self.allocator, client_fd, .{ .error_resp = .{
                    .code = "PARSE_ERROR",
                    .message = "Failed to parse request",
                } });
                continue;
            };

            // Check for stop
            if (request == .stop) {
                self.running = false;
                try sendResponse(self.allocator, client_fd, .{ .ok = {} });
                break;
            }

            // Process through engine with streaming + tool confirmation
            if (request == .chat) {
                var ac = AdapterContext{ .allocator = self.allocator, .fd = client_fd };
                const emitter = core.Engine.StreamEmitter{
                    .ctx = @ptrCast(&ac),
                    .emitFn = emitToSocket,
                };
                const confirmer = core.Engine.ToolConfirmCallback{
                    .ctx = @ptrCast(&ac),
                    .confirmFn = confirmTool,
                };

                const result = self.engine.process(request, emitter, confirmer);
                switch (result) {
                    .chat => |chat| {
                        try sendResponse(self.allocator, client_fd, .{ .stream_end = .{
                            .stop_reason = chat.stop_reason,
                            .model = chat.model,
                            .input_tokens = chat.input_tokens,
                            .output_tokens = chat.output_tokens,
                        } });
                    },
                    .response => |resp| try sendResponse(self.allocator, client_fd, resp),
                }
            } else {
                const result = self.engine.process(request, null, null);
                switch (result) {
                    .response => |resp| try sendResponse(self.allocator, client_fd, resp),
                    .chat => unreachable,
                }
            }
        }
    }

    const AdapterContext = struct {
        allocator: std.mem.Allocator,
        fd: posix.fd_t,
    };

    fn emitToSocket(ctx: *anyopaque, response: common.Response) void {
        const ac: *AdapterContext = @ptrCast(@alignCast(ctx));
        sendResponse(ac.allocator, ac.fd, response) catch |err| {
            std.log.err("Failed to emit stream chunk: {}", .{err});
        };
    }

    fn confirmTool(ctx: *anyopaque, tool_name: []const u8, tool_id: []const u8, input_preview: []const u8) bool {
        const ac: *AdapterContext = @ptrCast(@alignCast(ctx));

        sendResponse(ac.allocator, ac.fd, .{ .tool_confirm_request = .{
            .tool_id = tool_id,
            .tool_name = tool_name,
            .input_preview = input_preview,
        } }) catch return false;

        var len_buf: [4]u8 = undefined;
        readExact(ac.fd, &len_buf) catch return false;
        const len = std.mem.readInt(u32, &len_buf, .big);
        if (len > 1024 * 1024) return false;

        const data = ac.allocator.alloc(u8, len) catch return false;
        defer ac.allocator.free(data);
        readExact(ac.fd, data) catch return false;

        const request = common.Request.deserialize(ac.allocator, data) catch return false;
        if (request == .tool_confirm) return request.tool_confirm.approved;
        return false;
    }

    fn sendResponse(allocator: std.mem.Allocator, fd: posix.fd_t, response: common.Response) !void {
        const data = try response.serialize(allocator);
        defer allocator.free(data);
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
        try writeAll(fd, &len_buf);
        try writeAll(fd, data);
    }

    fn writeAll(fd: posix.fd_t, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += posix.write(fd, data[written..]) catch |err| return err;
        }
    }

    fn readExact(fd: posix.fd_t, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = posix.read(fd, buf[total..]) catch |err| return err;
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }
};
