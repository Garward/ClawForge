const std = @import("std");
const common = @import("common");

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,

    pub fn connect(allocator: std.mem.Allocator, socket_path: []const u8) !Connection {
        const io = common.config.runtimeIo();
        const address = try std.Io.net.UnixAddress.init(socket_path);
        const stream = try address.connect(io);

        return .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.io);
    }

    fn writeAll(self: *Connection, data: []const u8) !void {
        var stream_writer = self.stream.writer(self.io, &.{});
        try stream_writer.interface.writeAll(data);
    }

    fn readExact(self: *Connection, buf: []u8) !void {
        var stream_reader = self.stream.reader(self.io, &.{});
        try stream_reader.interface.readSliceAll(buf);
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
        const io = common.config.runtimeIo();
        const stdin = std.Io.File.stdin();
        var buf: [16]u8 = undefined;
        var stdin_reader = stdin.reader(io, &.{});
        const n = stdin_reader.interface.readSliceShort(&buf) catch return false;
        if (n == 0) return false;
        const input = std.mem.trimEnd(u8, buf[0..n], "\r\n \t");
        return input.len > 0 and (input[0] == 'y' or input[0] == 'Y');
    }
};
