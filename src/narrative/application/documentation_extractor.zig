//! Chapter-boundary extraction of observed prose into canonical story records.

const std = @import("std");
const domain = @import("../domain/root.zig");
const inference = @import("inference");

pub const Patch = struct {
    record_type: []const u8,
    expected_revision: i64,
    value_json: []const u8,
    rationale: []const u8,
    evidence_block_ids: []const []const u8,
};

pub const BeatEvidence = struct {
    beat_id: []const u8,
    status: []const u8,
    summary: []const u8,
    evidence_block_ids: []const []const u8,
};

pub const Finish = struct {
    summary: []const u8,
    record_patches: []const Patch,
    beat_evidence: []const BeatEvidence,
};

pub const system =
    \\You are ClawForge Narrative Studio's chapter documentation extractor.
    \\The prose is already accepted canon. Update only the supplied mutable story records
    \\whose demonstrated facts, current state, relationship progression, reader knowledge,
    \\timeline, arcs, promises, or world rules actually changed in this chapter.
    \\
    \\Return complete replacement JSON objects, never fragments. Preserve every unaffected
    \\field, stable ID, author decision, future plan, uncertainty marker, and provenance note.
    \\Do not convert planned future events into occurred facts. Do not improve the story,
    \\retcon awkward prose, infer demographics from names, invent off-page events, or add
    \\generic therapy, consent, safety, romance, or moral language.
    \\
    \\Every patch needs one or more exact prose block IDs as evidence. If a record did not
    \\materially change, omit it. Separately report evidence for each planned beat as
    \\satisfied, partial, or contradicted. Beat evidence does not rewrite the plan.
    \\End exclusively with finish_documentation_extraction.
;

pub const finish_tool = inference.ToolDefinition{
    .name = "finish_documentation_extraction",
    .description = "Finish chapter-boundary canon extraction with complete record replacements and beat evidence.",
    .input_schema_json =
    \\{"type":"object","additionalProperties":false,"required":["summary","record_patches","beat_evidence"],"properties":{"summary":{"type":"string"},"record_patches":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["record_type","expected_revision","value_json","rationale","evidence_block_ids"],"properties":{"record_type":{"type":"string","enum":["EntityRegistry","RelationalTextureContract","WorldRuleRegistry","MasterTimeline","InformationRegistry","ArcRegistry","PromiseLedger"]},"expected_revision":{"type":"integer"},"value_json":{"type":"string","description":"The complete replacement JSON object encoded as a string."},"rationale":{"type":"string"},"evidence_block_ids":{"type":"array","minItems":1,"items":{"type":"string"}}}}},"beat_evidence":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["beat_id","status","summary","evidence_block_ids"],"properties":{"beat_id":{"type":"string"},"status":{"type":"string","enum":["satisfied","partial","contradicted"]},"summary":{"type":"string"},"evidence_block_ids":{"type":"array","minItems":1,"items":{"type":"string"}}}}}}}
    ,
};

pub fn isMutableRecordType(record_type: []const u8) bool {
    const allowed = [_][]const u8{
        "EntityRegistry",
        "RelationalTextureContract",
        "WorldRuleRegistry",
        "MasterTimeline",
        "InformationRegistry",
        "ArcRegistry",
        "PromiseLedger",
    };
    for (allowed) |candidate| {
        if (std.mem.eql(u8, candidate, record_type)) return true;
    }
    return false;
}

pub fn buildPrompt(
    allocator: std.mem.Allocator,
    story: *const domain.Story,
    node: *const domain.Node,
    records: []const domain.Record,
    prose: *const domain.ProseDocument,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.print(
        allocator,
        "CHAPTER BOUNDARY\nStory: {s}\nSection: {s}\nPurpose: {s}\nSynopsis: {s}\n\n",
        .{
            story.title,
            node.title,
            node.purpose orelse "not specified",
            node.synopsis orelse "not specified",
        },
    );
    try output.appendSlice(allocator, "ACTIVE BEAT PLAN AND MUTABLE RECORDS\n");
    var record_bytes: usize = 0;
    for (records) |record| {
        if (!isMutableRecordType(record.record_type) and
            !std.mem.eql(u8, record.record_type, "StoryStructureRoot")) continue;
        if (record_bytes >= 80_000) break;
        const per_record_limit: usize = if (std.mem.eql(u8, record.record_type, "EntityRegistry"))
            20_000
        else if (std.mem.eql(u8, record.record_type, "StoryStructureRoot"))
            16_000
        else
            8_000;
        const remaining = 80_000 - record_bytes;
        const value = record.value_json[0..@min(record.value_json.len, @min(per_record_limit, remaining))];
        try output.print(
            allocator,
            "\n[{s}; id={s}; revision={d}; lifecycle={s}]\n{s}\n",
            .{ record.record_type, record.id, record.revision, record.lifecycle, value },
        );
        record_bytes += value.len;
    }
    try output.appendSlice(allocator, "\nACCEPTED CHAPTER PROSE\n");
    var prose_bytes: usize = 0;
    for (prose.blocks) |block| {
        if (prose_bytes >= 80_000) break;
        const remaining = 80_000 - prose_bytes;
        const text = block.text[0..@min(block.text.len, remaining)];
        try output.print(allocator, "\n[block {s}]\n{s}\n", .{ block.id, text });
        prose_bytes += text.len;
    }
    try output.appendSlice(
        allocator,
        "\nExtract demonstrated changes now. Empty record_patches is correct when the chapter changed no maintained record.",
    );
    return output.toOwnedSlice(allocator);
}

pub fn evidenceBelongsToProse(
    evidence: []const []const u8,
    prose: *const domain.ProseDocument,
) bool {
    if (evidence.len == 0) return false;
    for (evidence) |block_id| {
        var found = false;
        for (prose.blocks) |block| {
            if (std.mem.eql(u8, block.id, block_id)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}
