//! Durable narrative authoring job state exposed to the UI.

const std = @import("std");

pub const Job = struct {
    id: []const u8,
    story_id: []const u8,
    branch_id: ?[]const u8,
    job_type: []const u8,
    status: []const u8,
    state_json: []const u8,
    model_snapshot_json: []const u8,
    base_story_version: i64,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.story_id);
        if (self.branch_id) |value| allocator.free(value);
        allocator.free(self.job_type);
        allocator.free(self.status);
        allocator.free(self.state_json);
        allocator.free(self.model_snapshot_json);
        self.* = undefined;
    }
};
