//! Provider-neutral model catalog and resolved-selection types.

const std = @import("std");

pub const ModelCapabilities = struct {
    context_window: ?u32 = null,
    supports_tools: ?bool = null,
    supports_structured_output: ?bool = null,
    supports_streaming: ?bool = null,
};

pub const ModelCatalogEntry = struct {
    id: []const u8,
    provider: []const u8,
    display_name: []const u8,
    input_cost: ?[]const u8 = null,
    output_cost: ?[]const u8 = null,
    capabilities: ModelCapabilities = .{},

    pub fn providerFromId(id: []const u8) []const u8 {
        const separator = std.mem.indexOfScalar(u8, id, ':') orelse return "";
        return id[0..separator];
    }
};

pub const ModelSelection = struct {
    model_id: []const u8,
    source: Source,
    capabilities: ModelCapabilities = .{},

    pub const Source = enum {
        operation_override,
        job_role_override,
        story_role_override,
        story_default,
        narrative_default,
        daemon_default,
    };
};

test "provider is parsed from prefixed model id" {
    try std.testing.expectEqualStrings(
        "anthropic",
        ModelCatalogEntry.providerFromId("anthropic:claude-sonnet-4-6"),
    );
    try std.testing.expectEqualStrings("", ModelCatalogEntry.providerFromId("bare-model"));
}
