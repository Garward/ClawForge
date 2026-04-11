const std = @import("std");
const posix = std.posix;
const common = @import("common");
const handler = @import("handler.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    socket_fd: posix.socket_t,
    socket_path: []const u8,
    running: bool,
    request_handler: *handler.Handler,

    pub fn init(
        allocator: std.mem.Allocator,
        socket_path: []const u8,
        request_handler: *handler.Handler,
    ) !Server {
        // Remove existing socket file if present
        std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Ensure parent directory exists
        if (std.fs.path.dirname(socket_path)) |dir| {
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

        if (socket_path.len >= addr.path.len) {
            return error.NameTooLong;
        }

        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);

        try posix.bind(socket_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(socket_fd, 5);

        std.log.info("Server listening on {s}", .{socket_path});

        return .{
            .allocator = allocator,
            .socket_fd = socket_fd,
            .socket_path = socket_path,
            .running = true,
            .request_handler = request_handler,
        };
    }

    pub fn deinit(self: *Server) void {
        posix.close(self.socket_fd);
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
        std.log.info("Server shut down", .{});
    }

    pub fn run(self: *Server) !void {
        while (self.running) {
            var client_addr: posix.sockaddr.un = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un);

            const client_fd = posix.accept(self.socket_fd, @ptrCast(&client_addr), &addr_len, 0) catch |err| {
                if (!self.running) break;
                std.log.err("Accept failed: {}", .{err});
                continue;
            };

            std.log.debug("Client connected", .{});

            // Handle client in the same thread for simplicity
            self.handleClient(client_fd) catch |err| {
                std.log.err("Error handling client: {}", .{err});
            };

            posix.close(client_fd);
            std.log.debug("Client disconnected", .{});
        }
    }

    fn writeAll(fd: posix.fd_t, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += posix.write(fd, data[written..]) catch |err| {
                return err;
            };
        }
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

    fn handleClient(self: *Server, client_fd: posix.socket_t) !void {
        while (self.running) {
            // Read length prefix
            var len_buf: [4]u8 = undefined;
            readExact(client_fd, &len_buf) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            const len = std.mem.readInt(u32, &len_buf, .big);

            if (len > 10 * 1024 * 1024) {
                const err_resp = common.Response{ .error_resp = .{
                    .code = "MESSAGE_TOO_LARGE",
                    .message = "Request too large",
                } };
                const resp_data = try err_resp.serialize(self.allocator);
                defer self.allocator.free(resp_data);
                var resp_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &resp_len_buf, @intCast(resp_data.len), .big);
                try writeAll(client_fd, &resp_len_buf);
                try writeAll(client_fd, resp_data);
                continue;
            }

            // Read request data
            const request_data = try self.allocator.alloc(u8, len);
            defer self.allocator.free(request_data);
            try readExact(client_fd, request_data);

            // Parse request
            const request = common.Request.deserialize(self.allocator, request_data) catch {
                const err_resp = common.Response{ .error_resp = .{
                    .code = "PARSE_ERROR",
                    .message = "Failed to parse request",
                } };
                const resp_data = try err_resp.serialize(self.allocator);
                defer self.allocator.free(resp_data);
                var resp_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &resp_len_buf, @intCast(resp_data.len), .big);
                try writeAll(client_fd, &resp_len_buf);
                try writeAll(client_fd, resp_data);
                continue;
            };

            // Check for stop request
            if (request == .stop) {
                self.running = false;
                const ok_resp = common.Response{ .ok = {} };
                const resp_data = try ok_resp.serialize(self.allocator);
                defer self.allocator.free(resp_data);
                var resp_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &resp_len_buf, @intCast(resp_data.len), .big);
                try writeAll(client_fd, &resp_len_buf);
                try writeAll(client_fd, resp_data);
                break;
            }

            // Handle request
            try self.request_handler.handle(request, client_fd);
        }
    }

    pub fn stop(self: *Server) void {
        self.running = false;
    }
};
