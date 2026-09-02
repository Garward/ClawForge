//! Story workspace and model-profile domain types.

const std = @import("std");

pub const Story = struct {
    id: []const u8,
    title: []const u8,
    premise: ?[]const u8,
    genre: ?[]const u8,
    status: []const u8,
    active_branch_id: ?[]const u8,
    active_version: i64,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *Story, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        if (self.premise) |value| allocator.free(value);
        if (self.genre) |value| allocator.free(value);
        allocator.free(self.status);
        if (self.active_branch_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const CreateStory = struct {
    title: []const u8,
    premise: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
};

pub const ModelProfile = struct {
    story_id: []const u8,
    default_model: ?[]const u8,
    role_overrides_json: []const u8,
    revision: i64,
    updated_at: i64,

    pub fn deinit(self: *ModelProfile, allocator: std.mem.Allocator) void {
        allocator.free(self.story_id);
        if (self.default_model) |value| allocator.free(value);
        allocator.free(self.role_overrides_json);
        self.* = undefined;
    }
};
