//! Immutable prose revisions composed of addressable paragraph-sized blocks.

const std = @import("std");

pub const ProseBlock = struct {
    id: []const u8,
    ordinal: i64,
    block_type: []const u8,
    text: []const u8,
    content_hash: []const u8,

    pub fn deinit(self: *ProseBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.block_type);
        allocator.free(self.text);
        allocator.free(self.content_hash);
        self.* = undefined;
    }
};

pub const ProseDocument = struct {
    node_id: []const u8,
    revision_id: ?[]const u8,
    parent_revision_id: ?[]const u8,
    lifecycle: []const u8,
    author_source: []const u8,
    word_count: i64,
    created_at: ?i64,
    blocks: []ProseBlock,

    pub fn deinit(self: *ProseDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        if (self.revision_id) |value| allocator.free(value);
        if (self.parent_revision_id) |value| allocator.free(value);
        allocator.free(self.lifecycle);
        allocator.free(self.author_source);
        for (self.blocks) |*block| block.deinit(allocator);
        allocator.free(self.blocks);
        self.* = undefined;
    }
};

pub const ProsePatch = struct {
    base_revision_id: ?[]const u8 = null,
    operation: []const u8,
    anchor_block_id: ?[]const u8 = null,
    end_anchor_block_id: ?[]const u8 = null,
    text: ?[]const u8 = null,
    block_type: []const u8 = "paragraph",
    author_source: []const u8 = "user",
};
