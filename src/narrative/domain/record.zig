//! Canonical narrative records exposed as stable human document projections.

const std = @import("std");

pub const Record = struct {
    id: []const u8,
    story_id: []const u8,
    parent_id: ?[]const u8,
    record_type: []const u8,
    lifecycle: []const u8,
    truth_class: []const u8,
    value_json: []const u8,
    provenance_json: []const u8,
    revision: i64,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.story_id);
        if (self.parent_id) |value| allocator.free(value);
        allocator.free(self.record_type);
        allocator.free(self.lifecycle);
        allocator.free(self.truth_class);
        allocator.free(self.value_json);
        allocator.free(self.provenance_json);
        self.* = undefined;
    }
};

/// The package is deterministic: every story gets these logical documents.
/// Empty values mean "not decided yet", never permission for a model to invent
/// a replacement document type.
pub const required_story_record_types = [_][]const u8{
    "StoryIdentity",
    "StoryIntentProfile",
    "StoryContract",
    "StoryStructureRoot",
    "NarratorContract",
    "StyleContract",
    "InformationDeliveryContract",
    "ComedyContract",
    "RelationalTextureContract",
    "QualityGateContract",
    "EntityRegistry",
    "WorldRuleRegistry",
    "MasterTimeline",
    "InformationRegistry",
    "ArcRegistry",
    "PromiseLedger",
    "AuthorDecisionRegistry",
    "SourceRegistry",
    "BranchRegistry",
};
