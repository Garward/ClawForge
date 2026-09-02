//! Typed storyboard nodes. The hierarchy is data, not a directory convention.

const std = @import("std");

pub const Node = struct {
    id: []const u8,
    story_id: []const u8,
    branch_id: ?[]const u8,
    parent_id: ?[]const u8,
    node_type: []const u8,
    title: []const u8,
    ordinal: i64,
    lifecycle: []const u8,
    purpose: ?[]const u8,
    synopsis: ?[]const u8,
    metadata_json: []const u8,
    revision: i64,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.story_id);
        if (self.branch_id) |value| allocator.free(value);
        if (self.parent_id) |value| allocator.free(value);
        allocator.free(self.node_type);
        allocator.free(self.title);
        allocator.free(self.lifecycle);
        if (self.purpose) |value| allocator.free(value);
        if (self.synopsis) |value| allocator.free(value);
        allocator.free(self.metadata_json);
        self.* = undefined;
    }
};

pub const CreateNode = struct {
    parent_id: ?[]const u8 = null,
    node_type: []const u8,
    title: []const u8,
    purpose: ?[]const u8 = null,
    synopsis: ?[]const u8 = null,
};
