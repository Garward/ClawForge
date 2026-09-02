//! Persistent Author Room conversation types.

const std = @import("std");

pub const AuthorMessage = struct {
    id: []const u8,
    thread_id: []const u8,
    sequence: i64,
    role: []const u8,
    content: []const u8,
    model_used: ?[]const u8,
    created_at: i64,

    pub fn deinit(self: *AuthorMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.thread_id);
        allocator.free(self.role);
        allocator.free(self.content);
        if (self.model_used) |value| allocator.free(value);
        self.* = undefined;
    }
};
