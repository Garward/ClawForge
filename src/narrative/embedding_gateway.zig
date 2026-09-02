//! Narrow semantic-index interface used by Narrative Studio.

const std = @import("std");

pub const SemanticResult = struct {
    text: []u8,
    score: f32,

    pub fn deinit(self: *SemanticResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const Gateway = struct {
    ptr: *anyopaque,
    enqueue_fn: *const fn (
        ptr: *anyopaque,
        source_type: []const u8,
        source_id: i64,
        text: []const u8,
        context_header: ?[]const u8,
    ) void,
    search_fn: *const fn (
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        source_type: []const u8,
        query: []const u8,
        limit: usize,
    ) anyerror![]SemanticResult,

    pub fn enqueue(
        self: Gateway,
        source_type: []const u8,
        source_id: i64,
        text: []const u8,
        context_header: ?[]const u8,
    ) void {
        self.enqueue_fn(self.ptr, source_type, source_id, text, context_header);
    }

    pub fn search(
        self: Gateway,
        allocator: std.mem.Allocator,
        source_type: []const u8,
        query: []const u8,
        limit: usize,
    ) ![]SemanticResult {
        return self.search_fn(self.ptr, allocator, source_type, query, limit);
    }
};
