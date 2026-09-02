//! Writer-shaped adapter for Zig 0.16's unmanaged byte ArrayList.

const std = @import("std");

pub const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: ListWriter, data: []const u8) !void {
        try self.list.appendSlice(self.allocator, data);
    }

    pub fn writeByte(self: ListWriter, byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }

    pub fn print(self: ListWriter, comptime format: []const u8, args: anytype) !void {
        try self.list.print(self.allocator, format, args);
    }
};

pub fn init(list: *std.ArrayList(u8), allocator: std.mem.Allocator) ListWriter {
    return .{ .list = list, .allocator = allocator };
}
