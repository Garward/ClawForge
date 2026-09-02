const std = @import("std");
const common = @import("common");
const core = @import("core");
const adapter_mod = @import("adapter.zig");

/// CLI adapter: Unix socket server for the clawforge CLI client.
/// Receives length-prefixed JSON requests, delegates to engine, sends responses.
pub const CliAdapter = struct {
    allocator: std.mem.Allocator,
    config: *const common.Config,
    engine: *core.Engine,
    server: ?std.Io.net.Server,
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
            .server = null,
            .socket_path = socket_path,
            .running = false,
        };
    }

    pub fn deinit(self: *CliAdapter) void {
        if (self.server) |*server| server.deinit(common.config.runtimeIo());
        std.Io.Dir.deleteFileAbsolute(common.config.runtimeIo(), self.socket_path) catch {};
    }

    pub fn adapter(self: *CliAdapter) adapter_mod.Adapter {
        return .{
            .name = "cli",
            .display_name = "CLI Socket",
            .version = common.version.current,
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
        const io = common.config.runtimeIo();
        std.Io.Dir.deleteFileAbsolute(io, self.socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Ensure parent directory
        if (std.fs.path.dirname(self.socket_path)) |dir| {
            try std.Io.Dir.cwd().createDirPath(io, dir);
        }

        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        self.server = try address.listen(io, .{ .kernel_backlog = 5 });
        self.running = true;

        std.log.info("CLI adapter listening on {s}", .{self.socket_path});
    }

    fn run(ptr: *anyopaque) void {
        const self: *CliAdapter = @ptrCast(@alignCast(ptr));
        const server = if (self.server) |*value| value else return;

        while (self.running) {
            // Poll with timeout so SIGTERM can break us out within 500ms
            // (posix.accept retries internally on EINTR, so we can't rely on signal alone)
            var pfds = [_]std.posix.pollfd{.{
                .fd = server.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&pfds, 500) catch |err| {
                if (!self.running) break;
                std.log.err("Poll failed: {}", .{err});
                continue;
            };
            if (ready == 0) continue;

            const client_stream = server.accept(common.config.runtimeIo()) catch |err| {
                if (!self.running) break;
                std.log.err("Accept failed: {}", .{err});
                continue;
            };

            std.log.debug("Client connected", .{});
            const stream = common.net.Stream.init(client_stream);
            self.handleClient(stream) catch |err| {
                std.log.err("Error handling client: {}", .{err});
            };
            stream.close();
            std.log.debug("Client disconnected", .{});
        }
    }

    fn stop(ptr: *anyopaque) void {
        const self: *CliAdapter = @ptrCast(@alignCast(ptr));
        self.running = false;
    }

    // -- Internal: client handling (moved from server.zig + handler.zig) --

    fn handleClient(self: *CliAdapter, stream: common.net.Stream) !void {
        while (self.running) {
            // Wait for incoming data with timeout, so SIGTERM can break us
            // out of an idle keep-alive client (e.g. discord bridge connected
            // but not sending). Bare readExact would block indefinitely.
            var pfds = [_]std.posix.pollfd{.{
                .fd = stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&pfds, 500) catch |err| {
                if (!self.running) break;
                return err;
            };
            if (ready == 0) continue;

            // Read length prefix
            var len_buf: [4]u8 = undefined;
            readExact(stream, &len_buf) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            const len = std.mem.readInt(u32, &len_buf, .big);

            if (len > 10 * 1024 * 1024) {
                try sendResponse(self.allocator, stream, .{ .error_resp = .{
                    .code = "MESSAGE_TOO_LARGE",
                    .message = "Request too large",
                } });
                continue;
            }

            // Read request data
            const request_data = try self.allocator.alloc(u8, len);
            defer self.allocator.free(request_data);
            try readExact(stream, request_data);

            // Parse request
            const request = common.Request.deserialize(self.allocator, request_data) catch {
                try sendResponse(self.allocator, stream, .{ .error_resp = .{
                    .code = "PARSE_ERROR",
                    .message = "Failed to parse request",
                } });
                continue;
            };

            // Check for stop
            if (request == .stop) {
                self.running = false;
                try sendResponse(self.allocator, stream, .{ .ok = {} });
                break;
            }

            // Process through engine with streaming + tool confirmation
            if (request == .chat) {
                var ac = AdapterContext{ .allocator = self.allocator, .stream = stream };
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
                        try sendResponse(self.allocator, stream, .{ .stream_end = .{
                            .stop_reason = chat.stop_reason,
                            .model = chat.model,
                            .input_tokens = chat.input_tokens,
                            .output_tokens = chat.output_tokens,
                        } });
                    },
                    .response => |resp| try sendResponse(self.allocator, stream, resp),
                }
            } else {
                const result = self.engine.process(request, null, null);
                switch (result) {
                    .response => |resp| try sendResponse(self.allocator, stream, resp),
                    .chat => unreachable,
                }
            }
        }
    }

    const AdapterContext = struct {
        allocator: std.mem.Allocator,
        stream: common.net.Stream,
    };

    fn emitToSocket(ctx: *anyopaque, response: common.Response) void {
        const ac: *AdapterContext = @ptrCast(@alignCast(ctx));
        sendResponse(ac.allocator, ac.stream, response) catch |err| {
            std.log.err("Failed to emit stream chunk: {}", .{err});
        };
    }

    fn confirmTool(ctx: *anyopaque, tool_name: []const u8, tool_id: []const u8, input_preview: []const u8) bool {
        const ac: *AdapterContext = @ptrCast(@alignCast(ctx));

        sendResponse(ac.allocator, ac.stream, .{ .tool_confirm_request = .{
            .tool_id = tool_id,
            .tool_name = tool_name,
            .input_preview = input_preview,
        } }) catch return false;

        var len_buf: [4]u8 = undefined;
        readExact(ac.stream, &len_buf) catch return false;
        const len = std.mem.readInt(u32, &len_buf, .big);
        if (len > 1024 * 1024) return false;

        const data = ac.allocator.alloc(u8, len) catch return false;
        defer ac.allocator.free(data);
        readExact(ac.stream, data) catch return false;

        const request = common.Request.deserialize(ac.allocator, data) catch return false;
        if (request == .tool_confirm) return request.tool_confirm.approved;
        return false;
    }

    fn sendResponse(allocator: std.mem.Allocator, stream: common.net.Stream, response: common.Response) !void {
        const data = try response.serialize(allocator);
        defer allocator.free(data);
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
        try stream.writeAll(&len_buf);
        try stream.writeAll(data);
    }

    fn readExact(stream: common.net.Stream, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = stream.read(buf[total..]) catch |err| return err;
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }
};
