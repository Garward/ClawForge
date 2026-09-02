//! Narrative subsystem composition and lifecycle.

const std = @import("std");
const storage = @import("storage");
const inference = @import("inference");
const migrations = @import("storage/migrations.zig");
const Service = @import("application/service.zig").Service;

pub const Runtime = struct {
    service_instance: Service,

    pub fn init(
        allocator: std.mem.Allocator,
        conn: *storage.Connection,
        daemon_default_model: []const u8,
    ) !Runtime {
        try migrations.run(conn);
        return .{
            .service_instance = .{
                .allocator = allocator,
                .conn = conn,
                .daemon_default_model = daemon_default_model,
                .inference_gateway = null,
            },
        };
    }

    pub fn service(self: *Runtime) *Service {
        return &self.service_instance;
    }

    pub fn setInferenceGateway(self: *Runtime, gateway: inference.Gateway) void {
        self.service_instance.setInferenceGateway(gateway);
    }

    pub fn setEmbeddingGateway(
        self: *Runtime,
        gateway: @import("embedding_gateway.zig").Gateway,
    ) void {
        self.service_instance.setEmbeddingGateway(gateway);
    }

    pub fn start(_: *Runtime) !void {}
    pub fn stop(_: *Runtime) void {}
    pub fn deinit(_: *Runtime) void {}
};

test "story documents storyboard and prose revisions form one workspace" {
    const allocator = std.testing.allocator;
    var conn = try storage.Connection.open(":memory:");
    defer conn.close();
    try conn.execSimple("PRAGMA foreign_keys=ON");

    var runtime = try Runtime.init(allocator, &conn, "test:model");
    defer runtime.deinit();
    const service_instance = runtime.service();

    var story = try service_instance.createStory(.{
        .title = "Test Story",
        .premise = "A persistent narrative workspace.",
        .genre = "Fantasy",
    });
    defer story.deinit(allocator);

    const records = try service_instance.listRecords(story.id);
    defer {
        for (records) |*record| record.deinit(allocator);
        allocator.free(records);
    }
    try std.testing.expectEqual(@as(usize, 19), records.len);

    var chapter = try service_instance.createNode(story.id, .{
        .node_type = "chapter",
        .title = "Chapter One",
        .purpose = "Begin the story.",
    });
    defer chapter.deinit(allocator);

    var first = try service_instance.applyProsePatch(story.id, chapter.id, .{
        .operation = "append",
        .text = "The first paragraph remembers where it belongs.",
    });
    defer first.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), first.blocks.len);
    try std.testing.expectEqual(@as(i64, 7), first.word_count);

    var second = try service_instance.applyProsePatch(story.id, chapter.id, .{
        .base_revision_id = first.revision_id,
        .operation = "replace",
        .anchor_block_id = first.blocks[0].id,
        .text = "The revised paragraph still remembers where it belongs.",
    });
    defer second.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, first.revision_id.?, second.revision_id.?));
    try std.testing.expectEqualStrings(
        "The revised paragraph still remembers where it belongs.",
        second.blocks[0].text,
    );

    const FakeGateway = struct {
        allocator: std.mem.Allocator,
        saw_source_evidence: bool = false,
        saw_semantic_evidence: bool = false,

        fn invoke(ptr: *anyopaque, request: inference.InferenceRequest) anyerror!inference.InferenceResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const is_discovery = request.tools != null and
                request.tools.?.len > 0 and
                std.mem.eql(u8, request.tools.?[0].name, "finish_discovery_turn");
            const is_documentation_extraction = request.tools != null and
                request.tools.?.len > 0 and
                std.mem.eql(
                    u8,
                    request.tools.?[0].name,
                    "finish_documentation_extraction",
                );
            if (is_discovery and
                std.mem.indexOf(u8, request.prompt, "Rorann is twenty-one in chapter one") != null)
                self.saw_source_evidence = true;
            if (is_discovery and
                std.mem.indexOf(u8, request.prompt, "Semantic evidence: Lyra is his assigned partner") != null)
                self.saw_semantic_evidence = true;
            return .{
                .text = try self.allocator.dupe(u8, ""),
                .model = try self.allocator.dupe(u8, "test:model"),
                .input_tokens = 100,
                .output_tokens = 30,
                .tool_name = try self.allocator.dupe(
                    u8,
                    if (is_discovery)
                        "finish_discovery_turn"
                    else if (is_documentation_extraction)
                        "finish_documentation_extraction"
                    else
                        "finish_writer_pass",
                ),
                .tool_input_json = try self.allocator.dupe(
                    u8,
                    if (is_discovery)
                        "{\"assistant_message\":\"That establishes the desired experience.\\n\\n1. What should the reader feel at the end of volume one?\\n2. Which relationship should change most?\",\"questions\":[\"What should the reader feel at the end of volume one?\",\"Which relationship should change most?\"],\"record_patches\":[{\"record_type\":\"StoryIntentProfile\",\"value_json\":\"{\\\"reader_experience\\\":\\\"tense wonder\\\"}\",\"rationale\":\"The author established the intended experience.\"}]}"
                    else if (is_documentation_extraction)
                        "{\"summary\":\"No maintained story document changed in the test passage.\",\"record_patches\":[],\"beat_evidence\":[]}"
                    else
                        "{\"paragraphs\":[\"A bounded new paragraph.\",\"A second paragraph follows.\"],\"continue_context\":\"Carry the immediate physical position.\",\"section_complete\":true,\"quality_checks\":{\"dialogue_speakers_separated\":true,\"clarity_before_ornament\":true,\"voice_boundaries_preserved\":true,\"story_state_advanced\":true}}",
                ),
            };
        }
    };
    var fake = FakeGateway{ .allocator = allocator };
    runtime.setInferenceGateway(.{ .ptr = &fake, .invoke_fn = FakeGateway.invoke });
    const FakeEmbeddingGateway = struct {
        fn enqueue(
            _: *anyopaque,
            _: []const u8,
            _: i64,
            _: []const u8,
            _: ?[]const u8,
        ) void {}

        fn search(
            _: *anyopaque,
            result_allocator: std.mem.Allocator,
            _: []const u8,
            _: []const u8,
            _: usize,
        ) anyerror![]@import("embedding_gateway.zig").SemanticResult {
            const results = try result_allocator.alloc(
                @import("embedding_gateway.zig").SemanticResult,
                1,
            );
            results[0] = .{
                .text = try result_allocator.dupe(
                    u8,
                    "Semantic evidence: Lyra is his assigned partner.",
                ),
                .score = 0.91,
            };
            return results;
        }
    };
    var fake_embedding_context: u8 = 0;
    runtime.setEmbeddingGateway(.{
        .ptr = &fake_embedding_context,
        .enqueue_fn = FakeEmbeddingGateway.enqueue,
        .search_fn = FakeEmbeddingGateway.search,
    });
    var job = try service_instance.createWriterJob(story.id, chapter.id, "continue", "");
    defer job.deinit(allocator);
    var finished_job = try service_instance.runWriterPass(job.id);
    defer finished_job.deinit(allocator);
    try std.testing.expectEqualStrings("complete", finished_job.status);

    var final_prose = try service_instance.getProse(story.id, chapter.id);
    defer final_prose.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), final_prose.blocks.len);

    const updated_records = try service_instance.listRecords(story.id);
    defer {
        for (updated_records) |*record| record.deinit(allocator);
        allocator.free(updated_records);
    }
    try std.testing.expectEqual(@as(usize, 21), updated_records.len);

    const import_job_id = try service_instance.indexImportedSources(
        story.id,
        "===== SOURCE: character_notes.md =====\n\nRorann is twenty-one in chapter one.",
    );
    defer allocator.free(import_job_id);
    var discovery_message = try service_instance.discoveryTurn(
        story.id,
        "I want Rorann's chapter one age and the reader experience established.",
    );
    defer discovery_message.deinit(allocator);
    try std.testing.expect(fake.saw_source_evidence);
    try std.testing.expect(fake.saw_semantic_evidence);
    try std.testing.expect(std.mem.indexOf(u8, discovery_message.content, "volume one") != null);
    const proposals = try service_instance.listDiscoveryProposals(story.id);
    defer {
        for (proposals) |*proposal| proposal.deinit(allocator);
        allocator.free(proposals);
    }
    try std.testing.expectEqual(@as(usize, 1), proposals.len);
    var revised_message = try service_instance.discoveryTurn(
        story.id,
        "Refine that same document with my latest preference.",
    );
    revised_message.deinit(allocator);
    const changes = try service_instance.listDiscoveryDocumentChanges(story.id);
    defer {
        for (changes) |*change| change.deinit(allocator);
        allocator.free(changes);
    }
    try std.testing.expectEqual(@as(usize, 2), changes.len);
    try std.testing.expectEqualStrings("pending", changes[0].status);
    try std.testing.expectEqualStrings("superseded", changes[1].status);
    var accepted = try service_instance.decideDiscoveryDocumentChange(
        story.id,
        changes[0].id,
        true,
    );
    defer accepted.deinit(allocator);
    try std.testing.expectEqualStrings("accepted", accepted.status);
}
