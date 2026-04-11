const std = @import("std");
const posix = std.posix;
const common = @import("common");
const core = @import("core");

/// Thin adapter: receives requests from Unix socket, delegates to Engine,
/// serializes and writes responses back to the client fd.
pub const Handler = struct {
    allocator: std.mem.Allocator,
    engine: *core.Engine,

    pub fn init(allocator: std.mem.Allocator, engine_ptr: *core.Engine) Handler {
        return .{
            .allocator = allocator,
            .engine = engine_ptr,
        };
    }

    fn writeAll(fd: posix.fd_t, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += posix.write(fd, data[written..]) catch |err| {
                return err;
            };
        }
    }

    fn sendResponse(self: *Handler, fd: posix.fd_t, response: common.Response) !void {
        const data = try response.serialize(self.allocator);
        defer self.allocator.free(data);
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
        try writeAll(fd, &len_buf);
        try writeAll(fd, data);
    }

    /// Context for callbacks — carries handler and fd.
    const AdapterContext = struct {
        handler: *Handler,
        fd: posix.fd_t,
    };

    fn emitToSocket(ctx: *anyopaque, response: common.Response) void {
        const ac: *AdapterContext = @ptrCast(@alignCast(ctx));
        ac.handler.sendResponse(ac.fd, response) catch |err| {
            std.log.err("Failed to emit stream chunk: {}", .{err});
        };
    }

    /// Tool confirmation callback. Sends ToolConfirmRequest to client,
    /// reads ToolConfirmResponse back. Blocks until the user responds.
    fn confirmTool(ctx: *anyopaque, tool_name: []const u8, tool_id: []const u8, input_preview: []const u8) bool {
        const ac: *AdapterContext = @ptrCast(@alignCast(ctx));

        // Send confirmation request to client
        ac.handler.sendResponse(ac.fd, .{ .tool_confirm_request = .{
            .tool_id = tool_id,
            .tool_name = tool_name,
            .input_preview = input_preview,
        } }) catch return false;

        // Read confirmation response from client
        var len_buf: [4]u8 = undefined;
        readExact(ac.fd, &len_buf) catch return false;
        const len = std.mem.readInt(u32, &len_buf, .big);
        if (len > 1024 * 1024) return false;

        const data = ac.handler.allocator.alloc(u8, len) catch return false;
        defer ac.handler.allocator.free(data);
        readExact(ac.fd, data) catch return false;

        const request = common.Request.deserialize(ac.handler.allocator, data) catch return false;
        if (request == .tool_confirm) {
            return request.tool_confirm.approved;
        }
        return false;
    }

    fn readExact(fd: posix.fd_t, buf: []u8) !void {
        var read_total: usize = 0;
        while (read_total < buf.len) {
            const n = posix.read(fd, buf[read_total..]) catch |err| {
                return err;
            };
            if (n == 0) return error.EndOfStream;
            read_total += n;
        }
    }

    pub fn handle(self: *Handler, request: common.Request, fd: posix.fd_t) !void {
        // For chat requests, provide streaming emitter and tool confirmer
        if (request == .chat) {
            var ac = AdapterContext{ .handler = self, .fd = fd };
            const emitter = core.Engine.StreamEmitter{
                .ctx = @ptrCast(&ac),
                .emitFn = emitToSocket,
            };
            const confirm = core.Engine.ToolConfirmCallback{
                .ctx = @ptrCast(&ac),
                .confirmFn = confirmTool,
            };

            const result = self.engine.process(request, emitter, confirm);

            switch (result) {
                .chat => |chat| {
                    // stream_text chunks already sent via emitter.
                    // Send the final metadata footer.
                    try self.sendResponse(fd, .{ .stream_end = .{
                        .stop_reason = chat.stop_reason,
                        .model = chat.model,
                        .input_tokens = chat.input_tokens,
                        .output_tokens = chat.output_tokens,
                    } });
                },
                .response => |resp| {
                    try self.sendResponse(fd, resp);
                },
            }
        } else {
            // Non-chat requests: no streaming or confirmation needed
            const result = self.engine.process(request, null, null);
            switch (result) {
                .response => |resp| try self.sendResponse(fd, resp),
                .chat => unreachable,
            }
        }
    }
};
