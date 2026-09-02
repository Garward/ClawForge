//! Approval-gated story decision and document patch proposal.

const std = @import("std");

pub const DecisionProposal = struct {
    id: []const u8,
    story_id: []const u8,
    thread_id: ?[]const u8,
    status: []const u8,
    title: []const u8,
    decision: []const u8,
    proposal_json: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *DecisionProposal, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.story_id);
        if (self.thread_id) |value| allocator.free(value);
        allocator.free(self.status);
        allocator.free(self.title);
        allocator.free(self.decision);
        allocator.free(self.proposal_json);
        self.* = undefined;
    }
};

pub const DocumentChange = struct {
    id: []const u8,
    story_id: []const u8,
    thread_id: ?[]const u8,
    source_proposal_id: []const u8,
    record_type: []const u8,
    status: []const u8,
    revision: i64,
    value_json: []const u8,
    rationale: []const u8,
    supersedes_id: ?[]const u8,
    accepted_value_json: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *DocumentChange, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.story_id);
        if (self.thread_id) |value| allocator.free(value);
        allocator.free(self.source_proposal_id);
        allocator.free(self.record_type);
        allocator.free(self.status);
        allocator.free(self.value_json);
        allocator.free(self.rationale);
        if (self.supersedes_id) |value| allocator.free(value);
        allocator.free(self.accepted_value_json);
        self.* = undefined;
    }
};
