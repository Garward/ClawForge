//! Small stream adapter preserving ClawForge's synchronous transport interface.

const std = @import("std");
const config = @import("config.zig");

pub const Stream = struct {
    inner: std.Io.net.Stream,
    handle: std.Io.net.Socket.Handle,

    pub fn init(inner: std.Io.net.Stream) Stream {
        return .{ .inner = inner, .handle = inner.socket.handle };
    }

    pub fn close(self: Stream) void {
        self.inner.close(config.runtimeIo());
    }

    pub fn read(self: Stream, buffer: []u8) !usize {
        const io = config.runtimeIo();
        var data: [1][]u8 = .{buffer};
        return io.vtable.netRead(io.userdata, self.handle, &data);
    }

    pub fn write(self: Stream, data: []const u8) !usize {
        var writer = self.inner.writer(config.runtimeIo(), &.{});
        return writer.interface.write(data);
    }

    pub fn writeAll(self: Stream, data: []const u8) !void {
        var writer = self.inner.writer(config.runtimeIo(), &.{});
        return writer.interface.writeAll(data);
    }
};

pub const Server = struct {
    inner: std.Io.net.Server,
    stream: ListenerStream,

    pub const ListenerStream = struct {
        handle: std.Io.net.Socket.Handle,
    };

    pub const Connection = struct {
        stream: Stream,
    };

    pub fn init(inner: std.Io.net.Server) Server {
        return .{
            .stream = .{ .handle = inner.socket.handle },
            .inner = inner,
        };
    }

    pub fn accept(self: *Server) !Connection {
        return .{ .stream = .init(try self.inner.accept(config.runtimeIo())) };
    }

    pub fn deinit(self: *Server) void {
        self.inner.deinit(config.runtimeIo());
        self.* = undefined;
    }
};

pub const Address = struct {
    inner: std.Io.net.IpAddress,

    pub fn parseIp4(host: []const u8, port: u16) !Address {
        return .{ .inner = try std.Io.net.IpAddress.parseIp4(host, port) };
    }

    pub fn listen(self: Address, options: std.Io.net.IpAddress.ListenOptions) !Server {
        return .init(try self.inner.listen(config.runtimeIo(), options));
    }
};
