const std = @import("std");
const posix = std.posix;
const common = @import("common");

pub const Connection = struct {
    allocator: std.mem.Allocator,
    socket_fd: posix.socket_t,

    pub fn connect(allocator: std.mem.Allocator, socket_path: []const u8) !Connection {
        const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(socket_fd);

        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        if (socket_path.len >= addr.path.len) {
            return error.NameTooLong;
        }

        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);

        try posix.connect(socket_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        return .{
            .allocator = allocator,
            .socket_fd = socket_fd,
        };
    }

    pub fn deinit(self: *Connection) void {
        posix.close(self.socket_fd);
    }

    fn writeAll(self: *Connection, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += posix.write(self.socket_fd, data[written..]) catch |err| {
                return err;
            };
        }
    }

    fn readExact(self: *Connection, buf: []u8) !void {
        var read_total: usize = 0;
        while (read_total < buf.len) {
            const n = posix.read(self.socket_fd, buf[read_total..]) catch |err| {
                return err;
            };
            if (n == 0) return error.EndOfStream;
            read_total += n;
        }
    }

    pub fn send(self: *Connection, request: common.Request) !void {
        const data = try request.serialize(self.allocator);
        defer self.allocator.free(data);

        // Write length prefix (4 bytes big-endian)
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
        try self.writeAll(&len_buf);
        try self.writeAll(data);
    }

    pub fn receive(self: *Connection) !common.protocol.Response.ParsedResponse {
        // Read length prefix
        var len_buf: [4]u8 = undefined;
        try self.readExact(&len_buf);
        const len = std.mem.readInt(u32, &len_buf, .big);

        if (len > 10 * 1024 * 1024) {
            return error.MessageTooLarge;
        }

        const data = try self.allocator.alloc(u8, len);
        defer self.allocator.free(data);
        try self.readExact(data);

        return try common.Response.deserialize(self.allocator, data);
    }

    pub fn receiveStreaming(self: *Connection, display: *@import("display.zig").Display) !void {
        while (true) {
            var parsed = self.receive() catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            defer parsed.deinit();

            try display.handleResponse(parsed.value);

            switch (parsed.value) {
                // Tool confirmation — read user input and send response back
                .tool_confirm_request => |confirm_req| {
                    const approved = readUserConfirmation();
                    const response: common.Request = .{ .tool_confirm = .{
                        .tool_id = confirm_req.tool_id,
                        .approved = approved,
                    } };
                    try self.send(response);
                },
                // Streaming responses — continue reading
                .stream_start, .stream_text, .stream_tool_use, .stream_tool_result => {},
                // Everything else is a terminal response — stop reading
                else => break,
            }
        }
    }

    /// Read y/N from stdin for tool confirmation.
    fn readUserConfirmation() bool {
        const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        var buf: [16]u8 = undefined;
        const n = stdin.read(&buf) catch return false;
        if (n == 0) return false;
        const input = std.mem.trimRight(u8, buf[0..n], "\r\n \t");
        return input.len > 0 and (input[0] == 'y' or input[0] == 'Y');
    }
};
