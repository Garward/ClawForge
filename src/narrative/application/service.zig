//! Public command/query façade for Narrative Studio.

const std = @import("std");
const storage = @import("storage");
const inference = @import("inference");
const documentation_extractor = @import("documentation_extractor.zig");
const narrative_embedding = @import("../embedding_gateway.zig");
const domain = @import("../domain/root.zig");
const StoryStore = @import("../storage/story_store.zig").StoryStore;
const RecordStore = @import("../storage/record_store.zig").RecordStore;
const NodeStore = @import("../storage/node_store.zig").NodeStore;
const ProseStore = @import("../storage/prose_store.zig").ProseStore;
const AuthorStore = @import("../storage/author_store.zig").AuthorStore;
const JobStore = @import("../storage/job_store.zig").JobStore;
const ProposalStore = @import("../storage/proposal_store.zig").ProposalStore;
const import_storage = @import("../storage/import_store.zig");
const ImportStore = import_storage.ImportStore;

pub const Service = struct {
    allocator: std.mem.Allocator,
    conn: *storage.Connection,
    daemon_default_model: []const u8,
    inference_gateway: ?inference.Gateway = null,
    embedding_gateway: ?narrative_embedding.Gateway = null,

    pub fn setInferenceGateway(self: *Service, gateway: inference.Gateway) void {
        self.inference_gateway = gateway;
    }

    pub fn setEmbeddingGateway(self: *Service, gateway: narrative_embedding.Gateway) void {
        self.embedding_gateway = gateway;
    }

    pub fn createStory(self: *Service, input: domain.CreateStory) !domain.Story {
        var store = StoryStore.init(self.allocator, self.conn);
        return store.create(input, self.daemon_default_model);
    }

    pub fn getStory(self: *Service, id: []const u8) !?domain.Story {
        var store = StoryStore.init(self.allocator, self.conn);
        return store.get(id);
    }

    pub fn listStories(self: *Service) ![]domain.Story {
        var store = StoryStore.init(self.allocator, self.conn);
        return store.list();
    }

    pub fn getModelProfile(self: *Service, story_id: []const u8) !?domain.ModelProfile {
        var store = StoryStore.init(self.allocator, self.conn);
        return store.getModelProfile(story_id);
    }

    pub fn updateModelProfile(
        self: *Service,
        story_id: []const u8,
        default_model: ?[]const u8,
        role_overrides_json: []const u8,
        expected_revision: i64,
    ) !domain.ModelProfile {
        var store = StoryStore.init(self.allocator, self.conn);
        return store.updateModelProfile(
            story_id,
            default_model,
            role_overrides_json,
            expected_revision,
        );
    }

    pub fn listRecords(self: *Service, story_id: []const u8) ![]domain.Record {
        var store = RecordStore.init(self.allocator, self.conn);
        return store.listForStory(story_id);
    }

    pub fn updateRecord(
        self: *Service,
        story_id: []const u8,
        record_id: []const u8,
        value_json: []const u8,
        lifecycle: []const u8,
        expected_revision: i64,
    ) !domain.Record {
        var store = RecordStore.init(self.allocator, self.conn);
        return store.update(
            story_id,
            record_id,
            value_json,
            lifecycle,
            expected_revision,
        );
    }

    pub fn appendDerivedRecord(
        self: *Service,
        story_id: []const u8,
        parent_id: ?[]const u8,
        record_type: []const u8,
        value_json: []const u8,
        provenance_json: []const u8,
    ) !domain.Record {
        var store = RecordStore.init(self.allocator, self.conn);
        return store.appendDerived(
            story_id,
            parent_id,
            record_type,
            value_json,
            provenance_json,
        );
    }

    pub fn createNode(self: *Service, story_id: []const u8, input: domain.CreateNode) !domain.Node {
        var store = NodeStore.init(self.allocator, self.conn);
        return store.create(story_id, input);
    }

    pub fn listNodes(self: *Service, story_id: []const u8) ![]domain.Node {
        var store = NodeStore.init(self.allocator, self.conn);
        return store.list(story_id);
    }

    pub fn updateNode(
        self: *Service,
        story_id: []const u8,
        node_id: []const u8,
        title: []const u8,
        purpose: ?[]const u8,
        synopsis: ?[]const u8,
        lifecycle: []const u8,
        expected_revision: i64,
    ) !domain.Node {
        var store = NodeStore.init(self.allocator, self.conn);
        return store.update(
            story_id,
            node_id,
            title,
            purpose,
            synopsis,
            lifecycle,
            expected_revision,
        );
    }

    pub fn getProse(self: *Service, story_id: []const u8, node_id: []const u8) !domain.ProseDocument {
        var store = ProseStore.init(self.allocator, self.conn);
        return store.latest(story_id, node_id);
    }

    pub fn applyProsePatch(
        self: *Service,
        story_id: []const u8,
        node_id: []const u8,
        patch: domain.ProsePatch,
    ) !domain.ProseDocument {
        var store = ProseStore.init(self.allocator, self.conn);
        return store.applyPatch(story_id, node_id, patch);
    }

    pub fn listAuthorMessages(self: *Service, story_id: []const u8) ![]domain.AuthorMessage {
        var store = AuthorStore.init(self.allocator, self.conn);
        const thread_id = try store.ensureThread(story_id, "author_room");
        defer self.allocator.free(thread_id);
        return store.listMessages(thread_id, 100);
    }

    pub fn authorTurn(
        self: *Service,
        story_id: []const u8,
        user_text: []const u8,
        model_override: ?[]const u8,
    ) !domain.AuthorMessage {
        const gateway = self.inference_gateway orelse return error.InferenceUnavailable;
        var story = (try self.getStory(story_id)) orelse return error.StoryNotFound;
        defer story.deinit(self.allocator);
        var profile = (try self.getModelProfile(story_id)) orelse return error.ModelProfileNotFound;
        defer profile.deinit(self.allocator);
        const model = model_override orelse profile.default_model orelse self.daemon_default_model;

        var author_store = AuthorStore.init(self.allocator, self.conn);
        const thread_id = try author_store.ensureThread(story_id, "author_room");
        defer self.allocator.free(thread_id);
        var persisted_user = try author_store.addMessage(thread_id, "user", user_text, null);
        persisted_user.deinit(self.allocator);

        const messages = try author_store.listMessages(thread_id, 12);
        defer {
            for (messages) |*message| message.deinit(self.allocator);
            self.allocator.free(messages);
        }
        const records = try self.listRecords(story_id);
        defer {
            for (records) |*record| record.deinit(self.allocator);
            self.allocator.free(records);
        }
        const prompt = try buildAuthorPrompt(self.allocator, &story, records, messages);
        defer self.allocator.free(prompt);
        var response = try gateway.invoke(.{
            .model = model,
            .system = author_room_system,
            .prompt = prompt,
            .max_tokens = 4096,
        });
        defer response.deinit(self.allocator);
        return author_store.addMessage(thread_id, "assistant", response.text, response.model);
    }

    pub fn listDiscoveryMessages(self: *Service, story_id: []const u8) ![]domain.AuthorMessage {
        var store = AuthorStore.init(self.allocator, self.conn);
        const thread_id = try store.ensureThread(story_id, "discovery");
        defer self.allocator.free(thread_id);
        return store.listMessages(thread_id, 100);
    }

    pub fn listDiscoveryProposals(self: *Service, story_id: []const u8) ![]domain.DecisionProposal {
        var store = ProposalStore.init(self.allocator, self.conn);
        return store.listDiscovery(story_id);
    }

    pub fn listDiscoveryDocumentChanges(self: *Service, story_id: []const u8) ![]domain.DocumentChange {
        var store = ProposalStore.init(self.allocator, self.conn);
        return store.listDocumentChanges(story_id);
    }

    pub fn analyzeImportedSources(
        self: *Service,
        story_id: []const u8,
        source_bundle: []const u8,
    ) !domain.DecisionProposal {
        const gateway = self.inference_gateway orelse return error.InferenceUnavailable;
        if (std.mem.trim(u8, source_bundle, " \t\r\n").len == 0) return error.EmptyImport;
        if (source_bundle.len > 2 * 1024 * 1024) return error.ImportTooLarge;
        const import_job_id = try self.indexImportedSources(story_id, source_bundle);
        defer self.allocator.free(import_job_id);
        var story = (try self.getStory(story_id)) orelse return error.StoryNotFound;
        defer story.deinit(self.allocator);
        var profile = (try self.getModelProfile(story_id)) orelse return error.ModelProfileNotFound;
        defer profile.deinit(self.allocator);
        const model = profile.default_model orelse self.daemon_default_model;
        const records = try self.listRecords(story_id);
        defer {
            for (records) |*record| record.deinit(self.allocator);
            self.allocator.free(records);
        }
        const prompt = try buildImportPrompt(self.allocator, &story, records, source_bundle);
        defer self.allocator.free(prompt);
        var response = try gateway.invoke(.{
            .model = model,
            .system = import_system,
            .prompt = prompt,
            .max_tokens = 12_000,
            .tools = &.{finish_discovery_turn_tool},
        });
        defer response.deinit(self.allocator);
        if (response.tool_name == null or
            !std.mem.eql(u8, response.tool_name.?, "finish_discovery_turn") or
            response.tool_input_json == null) return error.ImportContractViolation;

        var finish = std.json.parseFromSlice(DiscoveryFinish, self.allocator, response.tool_input_json.?, .{
            .ignore_unknown_fields = true,
        }) catch return error.ImportContractViolation;
        defer finish.deinit();
        if (finish.value.questions.len > 8) return error.ImportContractViolation;
        if (finish.value.record_patches.len == 0) return error.ImportContractViolation;
        for (finish.value.record_patches) |patch| {
            if (!isDiscoveryRecordType(patch.record_type)) return error.InvalidDiscoveryRecordType;
            var value = std.json.parseFromSlice(std.json.Value, self.allocator, patch.value_json, .{}) catch
                return error.InvalidRecordValue;
            defer value.deinit();
            if (value.value != .object) return error.InvalidRecordValue;
        }

        var author_store = AuthorStore.init(self.allocator, self.conn);
        const thread_id = try author_store.ensureThread(story_id, "discovery");
        defer self.allocator.free(thread_id);
        var proposal_store = ProposalStore.init(self.allocator, self.conn);
        return proposal_store.create(
            story_id,
            thread_id,
            "Imported source reconstruction",
            finish.value.assistant_message,
            response.tool_input_json.?,
        );
    }

    pub fn indexImportedSources(
        self: *Service,
        story_id: []const u8,
        source_bundle: []const u8,
    ) ![]u8 {
        var story = (try self.getStory(story_id)) orelse return error.StoryNotFound;
        defer story.deinit(self.allocator);
        if (source_bundle.len > 2 * 1024 * 1024) return error.ImportTooLarge;
        var store = ImportStore.init(self.allocator, self.conn);
        const job_id = try store.indexBundle(story_id, source_bundle);
        errdefer self.allocator.free(job_id);
        if (self.embedding_gateway) |semantic_gateway| {
            const chunks = try store.listJobChunks(job_id);
            defer {
                for (chunks) |*chunk| chunk.deinit(self.allocator);
                self.allocator.free(chunks);
            }
            const source_type = try narrativeEmbeddingSourceType(
                self.allocator,
                story_id,
                job_id,
            );
            defer self.allocator.free(source_type);
            for (chunks) |chunk| {
                semantic_gateway.enqueue(
                    source_type,
                    chunk.id,
                    chunk.text,
                    chunk.context_header,
                );
            }
        }
        return job_id;
    }

    pub fn listImportSources(self: *Service, story_id: []const u8) ![]import_storage.SourceSummary {
        var store = ImportStore.init(self.allocator, self.conn);
        return store.listLatestSources(story_id);
    }

    pub fn discoveryTurn(
        self: *Service,
        story_id: []const u8,
        user_text: []const u8,
    ) !domain.AuthorMessage {
        const gateway = self.inference_gateway orelse return error.InferenceUnavailable;
        var story = (try self.getStory(story_id)) orelse return error.StoryNotFound;
        defer story.deinit(self.allocator);
        var profile = (try self.getModelProfile(story_id)) orelse return error.ModelProfileNotFound;
        defer profile.deinit(self.allocator);
        const model = profile.default_model orelse self.daemon_default_model;

        var author_store = AuthorStore.init(self.allocator, self.conn);
        const thread_id = try author_store.ensureThread(story_id, "discovery");
        defer self.allocator.free(thread_id);
        var persisted_user = try author_store.addMessage(thread_id, "user", user_text, null);
        persisted_user.deinit(self.allocator);
        const messages = try author_store.listMessages(thread_id, 16);
        defer {
            for (messages) |*message| message.deinit(self.allocator);
            self.allocator.free(messages);
        }
        const records = try self.listRecords(story_id);
        defer {
            for (records) |*record| record.deinit(self.allocator);
            self.allocator.free(records);
        }
        const proposals = try self.listDiscoveryDocumentChanges(story_id);
        defer {
            for (proposals) |*proposal| proposal.deinit(self.allocator);
            self.allocator.free(proposals);
        }
        var retrieval_query: std.ArrayList(u8) = .empty;
        defer retrieval_query.deinit(self.allocator);
        const retrieval_start = if (messages.len > 2) messages.len - 2 else 0;
        for (messages[retrieval_start..]) |message| {
            try retrieval_query.appendSlice(self.allocator, message.content);
            try retrieval_query.append(self.allocator, '\n');
        }
        var import_store = ImportStore.init(self.allocator, self.conn);
        const lexical_evidence = try import_store.relevantEvidence(
            story_id,
            retrieval_query.items,
            14 * 1024,
        );
        defer self.allocator.free(lexical_evidence);
        var source_evidence: std.ArrayList(u8) = .empty;
        defer source_evidence.deinit(self.allocator);
        if (self.embedding_gateway) |semantic_gateway| {
            const latest_job_id = try import_store.latestJobId(story_id);
            defer if (latest_job_id) |job_id| self.allocator.free(job_id);
            if (latest_job_id) |job_id| {
                const source_type = try narrativeEmbeddingSourceType(
                    self.allocator,
                    story_id,
                    job_id,
                );
                defer self.allocator.free(source_type);
                const semantic_results = semantic_gateway.search(
                    self.allocator,
                    source_type,
                    retrieval_query.items,
                    10,
                ) catch try self.allocator.alloc(narrative_embedding.SemanticResult, 0);
                defer {
                    for (semantic_results) |*result| result.deinit(self.allocator);
                    self.allocator.free(semantic_results);
                }
                for (semantic_results) |result| {
                    try source_evidence.print(
                        self.allocator,
                        "\n[SEMANTIC SOURCE; cosine {d:.3}]\n{s}\n",
                        .{ result.score, result.text },
                    );
                }
            }
        }
        try source_evidence.appendSlice(self.allocator, lexical_evidence);
        const prompt = try buildDiscoveryPrompt(
            self.allocator,
            &story,
            records,
            proposals,
            source_evidence.items,
            messages,
        );
        defer self.allocator.free(prompt);
        var response = try gateway.invoke(.{
            .model = model,
            .system = discovery_system,
            .prompt = prompt,
            .max_tokens = 4096,
            .tools = &.{finish_discovery_turn_tool},
        });
        defer response.deinit(self.allocator);
        if (response.tool_name == null or
            !std.mem.eql(u8, response.tool_name.?, "finish_discovery_turn") or
            response.tool_input_json == null) return error.DiscoveryContractViolation;

        var finish = std.json.parseFromSlice(DiscoveryFinish, self.allocator, response.tool_input_json.?, .{
            .ignore_unknown_fields = true,
        }) catch return error.DiscoveryContractViolation;
        defer finish.deinit();
        if (finish.value.questions.len == 0 or finish.value.questions.len > 6)
            return error.DiscoveryContractViolation;
        for (finish.value.record_patches) |patch| {
            if (!isDiscoveryRecordType(patch.record_type)) return error.InvalidDiscoveryRecordType;
            var value = std.json.parseFromSlice(std.json.Value, self.allocator, patch.value_json, .{}) catch
                return error.InvalidRecordValue;
            defer value.deinit();
            if (value.value != .object) return error.InvalidRecordValue;
        }
        const visible_message = try buildVisibleDiscoveryMessage(
            self.allocator,
            finish.value.assistant_message,
            finish.value.questions,
        );
        defer self.allocator.free(visible_message);

        var assistant = try author_store.addMessage(
            thread_id,
            "assistant",
            visible_message,
            response.model,
        );
        errdefer assistant.deinit(self.allocator);
        if (finish.value.record_patches.len > 0) {
            var proposal_store = ProposalStore.init(self.allocator, self.conn);
            var proposal = try proposal_store.create(
                story_id,
                thread_id,
                "Discovery document updates",
                visible_message,
                response.tool_input_json.?,
            );
            proposal.deinit(self.allocator);
        }
        return assistant;
    }

    pub fn quickstartArchitect(
        self: *Service,
        story_id: []const u8,
        premise: []const u8,
    ) !domain.AuthorMessage {
        const gateway = self.inference_gateway orelse return error.InferenceUnavailable;
        const trimmed = std.mem.trim(u8, premise, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyPremise;
        if (trimmed.len > 16 * 1024) return error.PremiseTooLarge;
        var story = (try self.getStory(story_id)) orelse return error.StoryNotFound;
        defer story.deinit(self.allocator);
        var profile = (try self.getModelProfile(story_id)) orelse return error.ModelProfileNotFound;
        defer profile.deinit(self.allocator);
        const model = profile.default_model orelse self.daemon_default_model;
        var author_store = AuthorStore.init(self.allocator, self.conn);
        const thread_id = try author_store.ensureThread(story_id, "discovery");
        defer self.allocator.free(thread_id);
        const user_message = try std.fmt.allocPrint(
            self.allocator,
            "Quickstart premise: {s}\n\nDesign a complete provisional story foundation without requiring me to answer the full interview first.",
            .{trimmed},
        );
        defer self.allocator.free(user_message);
        var persisted_user = try author_store.addMessage(thread_id, "user", user_message, null);
        persisted_user.deinit(self.allocator);
        const prompt = try std.fmt.allocPrint(
            self.allocator,
            "STORY TITLE\n{s}\n\nBASIC PREMISE\n{s}\n\nProduce the complete 19-document provisional foundation now.",
            .{ story.title, trimmed },
        );
        defer self.allocator.free(prompt);
        var response = try gateway.invoke(.{
            .model = model,
            .system = quickstart_architect_system,
            .prompt = prompt,
            .max_tokens = 16000,
            .tools = &.{finish_discovery_turn_tool},
        });
        defer response.deinit(self.allocator);
        if (response.tool_name == null or
            !std.mem.eql(u8, response.tool_name.?, "finish_discovery_turn") or
            response.tool_input_json == null) return error.QuickstartContractViolation;
        var finish = std.json.parseFromSlice(DiscoveryFinish, self.allocator, response.tool_input_json.?, .{
            .ignore_unknown_fields = true,
        }) catch return error.QuickstartContractViolation;
        defer finish.deinit();
        if (finish.value.record_patches.len != domain.required_story_record_types.len)
            return error.QuickstartContractViolation;
        for (domain.required_story_record_types) |required_type| {
            var found = false;
            for (finish.value.record_patches) |patch| {
                if (std.mem.eql(u8, patch.record_type, required_type)) found = true;
            }
            if (!found) return error.QuickstartContractViolation;
        }
        if (!try validateQuickstartFoundationDepth(self.allocator, finish.value.record_patches))
            return error.QuickstartContractViolation;
        const visible_message = try buildVisibleDiscoveryMessage(
            self.allocator,
            finish.value.assistant_message,
            finish.value.questions,
        );
        defer self.allocator.free(visible_message);
        var assistant = try author_store.addMessage(
            thread_id,
            "assistant",
            visible_message,
            response.model,
        );
        errdefer assistant.deinit(self.allocator);
        var proposal_store = ProposalStore.init(self.allocator, self.conn);
        var proposal = try proposal_store.create(
            story_id,
            thread_id,
            "Quickstart story foundation",
            visible_message,
            response.tool_input_json.?,
        );
        proposal.deinit(self.allocator);
        return assistant;
    }

    pub const QuickstartApproval = struct {
        accepted_count: usize,
        chapter_id: []const u8,

        pub fn deinit(self: *QuickstartApproval, allocator: std.mem.Allocator) void {
            allocator.free(self.chapter_id);
            self.* = undefined;
        }
    };

    pub fn acceptQuickstartFoundation(self: *Service, story_id: []const u8) !QuickstartApproval {
        const changes = try self.listDiscoveryDocumentChanges(story_id);
        defer {
            for (changes) |*change| change.deinit(self.allocator);
            self.allocator.free(changes);
        }
        var accepted_count: usize = 0;
        for (changes) |change| {
            if (!std.mem.eql(u8, change.status, "pending")) continue;
            var accepted = try self.decideDiscoveryDocumentChange(story_id, change.id, true);
            accepted.deinit(self.allocator);
            accepted_count += 1;
        }
        const chapter_id = try self.ensureQuickstartScaffold(story_id);
        return .{ .accepted_count = accepted_count, .chapter_id = chapter_id };
    }

    fn ensureQuickstartScaffold(self: *Service, story_id: []const u8) ![]u8 {
        const existing = try self.listNodes(story_id);
        defer {
            for (existing) |*node| node.deinit(self.allocator);
            self.allocator.free(existing);
        }
        for (existing) |node| {
            if (std.mem.eql(u8, node.node_type, "chapter"))
                return self.allocator.dupe(u8, node.id);
        }
        const records = try self.listRecords(story_id);
        defer {
            for (records) |*record| record.deinit(self.allocator);
            self.allocator.free(records);
        }
        for (records) |record| {
            if (!std.mem.eql(u8, record.record_type, "StoryStructureRoot")) continue;
            const PlanNode = struct {
                title: ?[]const u8 = null,
                purpose: ?[]const u8 = null,
                synopsis: ?[]const u8 = null,
            };
            const StructurePlan = struct {
                volume_title: ?PlanNode = null,
                opening_arc: ?PlanNode = null,
                opening_chapter: ?PlanNode = null,
            };
            var parsed = std.json.parseFromSlice(StructurePlan, self.allocator, record.value_json, .{
                .ignore_unknown_fields = true,
            }) catch break;
            defer parsed.deinit();
            const volume_plan = parsed.value.volume_title orelse PlanNode{};
            const arc_plan = parsed.value.opening_arc orelse PlanNode{};
            const chapter_plan = parsed.value.opening_chapter orelse PlanNode{};
            return self.createQuickstartScaffold(
                story_id,
                volume_plan.title orelse "Volume One",
                volume_plan.purpose orelse "Deliver the accepted opening-volume story contract.",
                volume_plan.synopsis,
                arc_plan.title orelse "Opening Arc",
                arc_plan.purpose orelse "Establish the protagonist, dramatic engine, world rules, and first active mystery.",
                arc_plan.synopsis,
                chapter_plan.title orelse "Chapter One",
                chapter_plan.purpose orelse "Open with a concrete demonstration of the premise while creating the first story obligation.",
                chapter_plan.synopsis orelse "Introduce the protagonist through action and environmental consequence; reveal rules through behavior rather than exposition.",
            );
        }
        return self.createQuickstartScaffold(
            story_id,
            "Volume One",
            "Deliver the accepted opening-volume story contract.",
            null,
            "Opening Arc",
            "Establish the protagonist, dramatic engine, world rules, and first active mystery.",
            null,
            "Chapter One",
            "Open with a concrete demonstration of the premise while creating the first story obligation.",
            "Introduce the protagonist through action and environmental consequence; reveal rules through behavior rather than exposition.",
        );
    }

    fn createQuickstartScaffold(
        self: *Service,
        story_id: []const u8,
        volume_title: []const u8,
        volume_purpose: []const u8,
        volume_synopsis: ?[]const u8,
        arc_title: []const u8,
        arc_purpose: []const u8,
        arc_synopsis: ?[]const u8,
        chapter_title: []const u8,
        chapter_purpose: []const u8,
        chapter_synopsis: []const u8,
    ) ![]u8 {
        var volume = try self.createNode(story_id, .{
            .node_type = "volume",
            .title = volume_title,
            .purpose = volume_purpose,
            .synopsis = volume_synopsis,
        });
        defer volume.deinit(self.allocator);
        var arc = try self.createNode(story_id, .{
            .parent_id = volume.id,
            .node_type = "arc",
            .title = arc_title,
            .purpose = arc_purpose,
            .synopsis = arc_synopsis,
        });
        defer arc.deinit(self.allocator);
        var chapter = try self.createNode(story_id, .{
            .parent_id = arc.id,
            .node_type = "chapter",
            .title = chapter_title,
            .purpose = chapter_purpose,
            .synopsis = chapter_synopsis,
        });
        defer chapter.deinit(self.allocator);
        return self.allocator.dupe(u8, chapter.id);
    }

    pub fn decideDiscoveryProposal(
        self: *Service,
        story_id: []const u8,
        proposal_id: []const u8,
        accept: bool,
    ) !domain.DecisionProposal {
        var proposal_store = ProposalStore.init(self.allocator, self.conn);
        var proposal = (try proposal_store.get(story_id, proposal_id)) orelse
            return error.ProposalNotFound;
        defer proposal.deinit(self.allocator);
        if (!std.mem.eql(u8, proposal.status, "pending")) return error.ProposalNotPending;
        if (!accept) return proposal_store.setStatus(story_id, proposal_id, "rejected");

        var finish = std.json.parseFromSlice(DiscoveryFinish, self.allocator, proposal.proposal_json, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidProposal;
        defer finish.deinit();
        const records = try self.listRecords(story_id);
        defer {
            for (records) |*record| record.deinit(self.allocator);
            self.allocator.free(records);
        }

        try self.conn.execSimple("BEGIN IMMEDIATE");
        errdefer self.conn.execSimple("ROLLBACK") catch {};
        for (finish.value.record_patches) |patch| {
            const target = blk: {
                for (records) |*record| {
                    if (std.mem.eql(u8, record.record_type, patch.record_type)) break :blk record;
                }
                return error.RecordNotFound;
            };
            var updated = try self.updateRecord(
                story_id,
                target.id,
                patch.value_json,
                "accepted",
                target.revision,
            );
            updated.deinit(self.allocator);
        }
        const accepted = try proposal_store.setStatus(story_id, proposal_id, "accepted");
        try self.conn.execSimple("COMMIT");
        return accepted;
    }

    pub fn decideDiscoveryDocumentChange(
        self: *Service,
        story_id: []const u8,
        change_id: []const u8,
        accept: bool,
    ) !domain.DocumentChange {
        var proposal_store = ProposalStore.init(self.allocator, self.conn);
        var change = (try proposal_store.getDocumentChange(story_id, change_id)) orelse
            return error.ProposalNotFound;
        defer change.deinit(self.allocator);
        if (!std.mem.eql(u8, change.status, "pending")) return error.ProposalNotPending;
        if (!accept)
            return proposal_store.setDocumentChangeStatus(story_id, change_id, "rejected");

        const records = try self.listRecords(story_id);
        defer {
            for (records) |*record| record.deinit(self.allocator);
            self.allocator.free(records);
        }
        const target = blk: {
            for (records) |*record| {
                if (std.mem.eql(u8, record.record_type, change.record_type)) break :blk record;
            }
            return error.RecordNotFound;
        };
        try self.conn.execSimple("BEGIN IMMEDIATE");
        errdefer self.conn.execSimple("ROLLBACK") catch {};
        var updated = try self.updateRecord(
            story_id,
            target.id,
            change.value_json,
            "accepted",
            target.revision,
        );
        updated.deinit(self.allocator);
        const accepted = try proposal_store.setDocumentChangeStatus(story_id, change_id, "accepted");
        try self.conn.execSimple("COMMIT");
        return accepted;
    }

    pub fn createWriterJob(
        self: *Service,
        story_id: []const u8,
        node_id: []const u8,
        mode: []const u8,
        revision_instruction: []const u8,
    ) !domain.Job {
        var profile = (try self.getModelProfile(story_id)) orelse return error.ModelProfileNotFound;
        defer profile.deinit(self.allocator);
        const model = profile.default_model orelse self.daemon_default_model;
        var store = JobStore.init(self.allocator, self.conn);
        return store.createWriterJob(story_id, node_id, model, mode, revision_instruction);
    }

    pub fn listJobs(self: *Service, story_id: []const u8) ![]domain.Job {
        var store = JobStore.init(self.allocator, self.conn);
        return store.list(story_id);
    }

    pub fn syncChapterDocumentation(self: *Service, story_id: []const u8, node_id: []const u8) !void {
        const gateway = self.inference_gateway orelse return error.InferenceUnavailable;
        var profile = (try self.getModelProfile(story_id)) orelse
            return error.ModelProfileNotFound;
        defer profile.deinit(self.allocator);
        const model = profile.default_model orelse self.daemon_default_model;
        var story = (try self.getStory(story_id)) orelse return error.StoryNotFound;
        defer story.deinit(self.allocator);
        const nodes = try self.listNodes(story_id);
        defer {
            for (nodes) |*node| node.deinit(self.allocator);
            self.allocator.free(nodes);
        }
        const selected_node = blk: {
            for (nodes) |*node| {
                if (std.mem.eql(u8, node.id, node_id)) break :blk node;
            }
            return error.NodeNotFound;
        };
        const records = try self.listRecords(story_id);
        defer {
            for (records) |*record| record.deinit(self.allocator);
            self.allocator.free(records);
        }
        var prose = try self.getProse(story_id, node_id);
        defer prose.deinit(self.allocator);
        if (prose.blocks.len == 0) return error.EmptyProse;
        try self.extractChapterDocumentation(
            gateway,
            model,
            &story,
            selected_node,
            records,
            &prose,
        );
    }

    fn extractChapterDocumentation(
        self: *Service,
        gateway: inference.Gateway,
        model: []const u8,
        story: *const domain.Story,
        node: *const domain.Node,
        records: []const domain.Record,
        prose: *const domain.ProseDocument,
    ) !void {
        const prompt = try documentation_extractor.buildPrompt(
            self.allocator,
            story,
            node,
            records,
            prose,
        );
        defer self.allocator.free(prompt);
        var response = try gateway.invoke(.{
            .model = model,
            .system = documentation_extractor.system,
            .prompt = prompt,
            .max_tokens = 8192,
            .tools = &.{documentation_extractor.finish_tool},
        });
        defer response.deinit(self.allocator);
        if (response.tool_name == null or
            !std.mem.eql(u8, response.tool_name.?, documentation_extractor.finish_tool.name) or
            response.tool_input_json == null)
            return error.DocumentationExtractionContractViolation;

        var finish = std.json.parseFromSlice(
            documentation_extractor.Finish,
            self.allocator,
            response.tool_input_json.?,
            .{ .ignore_unknown_fields = true },
        ) catch return error.DocumentationExtractionContractViolation;
        defer finish.deinit();

        for (finish.value.record_patches) |patch| {
            if (!documentation_extractor.isMutableRecordType(patch.record_type) or
                !documentation_extractor.evidenceBelongsToProse(
                    patch.evidence_block_ids,
                    prose,
                ))
                return error.DocumentationExtractionContractViolation;
            const existing = blk: {
                for (records) |*record| {
                    if (std.mem.eql(u8, record.record_type, patch.record_type))
                        break :blk record;
                }
                return error.DocumentationExtractionContractViolation;
            };
            if (existing.revision != patch.expected_revision)
                return error.StaleRevision;
            var updated = try self.updateRecord(
                story.id,
                existing.id,
                patch.value_json,
                existing.lifecycle,
                patch.expected_revision,
            );
            updated.deinit(self.allocator);
        }
        for (finish.value.beat_evidence) |evidence| {
            if ((!std.mem.eql(u8, evidence.status, "satisfied") and
                !std.mem.eql(u8, evidence.status, "partial") and
                !std.mem.eql(u8, evidence.status, "contradicted")) or
                !documentation_extractor.evidenceBelongsToProse(
                    evidence.evidence_block_ids,
                    prose,
                ))
                return error.DocumentationExtractionContractViolation;
        }

        var provenance_ids: std.ArrayList([]const u8) = .empty;
        defer provenance_ids.deinit(self.allocator);
        for (prose.blocks) |block| try provenance_ids.append(self.allocator, block.id);
        const provenance_json = try std.json.Stringify.valueAlloc(
            self.allocator,
            provenance_ids.items,
            .{},
        );
        defer self.allocator.free(provenance_json);
        const update_json = try std.json.Stringify.valueAlloc(self.allocator, .{
            .node_id = node.id,
            .prose_revision_id = prose.revision_id,
            .summary = finish.value.summary,
            .record_patches = finish.value.record_patches,
            .beat_evidence = finish.value.beat_evidence,
            .extraction_status = "complete",
        }, .{});
        defer self.allocator.free(update_json);
        var update_record = try self.appendDerivedRecord(
            story.id,
            node.id,
            "ChapterDocumentationUpdate",
            update_json,
            provenance_json,
        );
        update_record.deinit(self.allocator);
    }

    pub fn runWriterPass(self: *Service, job_id: []const u8) !domain.Job {
        const gateway = self.inference_gateway orelse return error.InferenceUnavailable;
        var job_store = JobStore.init(self.allocator, self.conn);
        var job = (try job_store.get(job_id)) orelse return error.JobNotFound;
        defer job.deinit(self.allocator);
        if (std.mem.eql(u8, job.status, "complete")) return try job_store.get(job_id) orelse error.JobNotFound;
        if (!std.mem.eql(u8, job.status, "queued") and !std.mem.eql(u8, job.status, "paused"))
            return error.JobNotRunnable;

        const WriterState = struct {
            node_id: []const u8,
            pass: u32,
            continue_context: []const u8,
            rewrite_existing: bool = false,
            mode: []const u8 = "continue",
            revision_instruction: []const u8 = "",
            revision_cursor: usize = 0,
            remaining_original_blocks: ?usize = null,
            postprocess_pending: bool = false,
        };
        var state = try std.json.parseFromSlice(WriterState, self.allocator, job.state_json, .{});
        defer state.deinit();
        if (state.value.pass >= 80) {
            try job_store.setStatus(job_id, "paused");
            return error.PassLimitReached;
        }
        const ModelSnapshot = struct { passage_writer: []const u8 };
        var snapshot = try std.json.parseFromSlice(ModelSnapshot, self.allocator, job.model_snapshot_json, .{});
        defer snapshot.deinit();

        var story = (try self.getStory(job.story_id)) orelse return error.StoryNotFound;
        defer story.deinit(self.allocator);
        const nodes = try self.listNodes(job.story_id);
        defer {
            for (nodes) |*node| node.deinit(self.allocator);
            self.allocator.free(nodes);
        }
        const selected_node = blk: {
            for (nodes) |*node| {
                if (std.mem.eql(u8, node.id, state.value.node_id)) break :blk node;
            }
            return error.NodeNotFound;
        };
        const records = try self.listRecords(job.story_id);
        defer {
            for (records) |*record| record.deinit(self.allocator);
            self.allocator.free(records);
        }
        var prose = try self.getProse(job.story_id, state.value.node_id);
        defer prose.deinit(self.allocator);
        if (state.value.postprocess_pending) {
            try job_store.setStatus(job_id, "running");
            try job_store.addEvent(job_id, "documentation_extraction_started", "{}");
            self.extractChapterDocumentation(
                gateway,
                snapshot.value.passage_writer,
                &story,
                selected_node,
                records,
                &prose,
            ) catch |err| {
                try job_store.setStatus(job_id, "paused");
                try job_store.addEvent(job_id, "documentation_extraction_failed", "{}");
                return err;
            };
            try job_store.addEvent(job_id, "documentation_extraction_completed", "{}");
            const recovered_state = try std.json.Stringify.valueAlloc(self.allocator, .{
                .node_id = state.value.node_id,
                .pass = state.value.pass,
                .continue_context = state.value.continue_context,
                .mode = state.value.mode,
                .revision_instruction = state.value.revision_instruction,
                .revision_cursor = state.value.revision_cursor,
                .remaining_original_blocks = state.value.remaining_original_blocks,
                .postprocess_pending = false,
            }, .{});
            defer self.allocator.free(recovered_state);
            return job_store.finishPass(job_id, recovered_state, "complete");
        }
        const is_rewrite = state.value.rewrite_existing or
            std.mem.eql(u8, state.value.mode, "rewrite");
        const is_revision = std.mem.eql(u8, state.value.mode, "revise");
        const revision_remaining = state.value.remaining_original_blocks orelse prose.blocks.len;
        if (is_revision and revision_remaining == 0)
            return job_store.finishPass(job_id, job.state_json, "complete");
        const prompt = if (is_revision)
            try buildRevisionPrompt(
                self.allocator,
                &story,
                selected_node,
                records,
                &prose,
                state.value.revision_cursor,
                @min(@as(usize, 4), revision_remaining),
                state.value.revision_instruction,
            )
        else
            try buildWriterPrompt(
                self.allocator,
                &story,
                selected_node,
                records,
                &prose,
                state.value.pass,
                state.value.continue_context,
                is_rewrite,
            );
        defer self.allocator.free(prompt);

        try job_store.setStatus(job_id, "running");
        try job_store.addEvent(job_id, "writer_pass_started", "{}");
        var response = gateway.invoke(.{
            .model = snapshot.value.passage_writer,
            .system = if (is_revision) passage_revision_system else passage_writer_system,
            .prompt = prompt,
            .max_tokens = 4096,
            .tools = &.{finish_writer_pass_tool},
        }) catch |err| {
            try job_store.setStatus(job_id, "paused");
            try job_store.addEvent(job_id, "provider_error", "{}");
            return err;
        };
        defer response.deinit(self.allocator);
        if (response.tool_name == null or
            !std.mem.eql(u8, response.tool_name.?, "finish_writer_pass") or
            response.tool_input_json == null)
        {
            try job_store.setStatus(job_id, "paused");
            try job_store.addEvent(job_id, "writer_contract_violation", "{}");
            return error.WriterContractViolation;
        }

        const Finish = struct {
            paragraphs: []const []const u8,
            continue_context: []const u8,
            section_complete: bool,
            quality_checks: struct {
                dialogue_speakers_separated: bool,
                clarity_before_ornament: bool,
                voice_boundaries_preserved: bool,
                story_state_advanced: bool,
            },
        };
        var finish = std.json.parseFromSlice(Finish, self.allocator, response.tool_input_json.?, .{
            .ignore_unknown_fields = true,
        }) catch {
            try job_store.setStatus(job_id, "paused");
            return error.WriterContractViolation;
        };
        defer finish.deinit();
        const quality_violation = validateWriterFinish(finish.value.paragraphs, .{
            finish.value.quality_checks.dialogue_speakers_separated,
            finish.value.quality_checks.clarity_before_ornament,
            finish.value.quality_checks.voice_boundaries_preserved,
            if (is_revision) true else finish.value.quality_checks.story_state_advanced,
        });
        if (finish.value.continue_context.len > 6_000) {
            try job_store.setStatus(job_id, "paused");
            return error.WriterPatchTooLarge;
        }
        if (quality_violation) |violation| {
            try job_store.setStatus(job_id, "paused");
            const payload = try std.json.Stringify.valueAlloc(
                self.allocator,
                .{ .reason = violation },
                .{},
            );
            defer self.allocator.free(payload);
            try job_store.addEvent(job_id, "writer_quality_violation", payload);
            return error.WriterQualityViolation;
        }
        const passage_text = try joinParagraphs(self.allocator, finish.value.paragraphs);
        defer self.allocator.free(passage_text);
        const revision_target_count = if (is_revision)
            @min(@as(usize, 4), revision_remaining)
        else
            0;
        const revision_start = state.value.revision_cursor;
        if (is_revision and revision_start + revision_target_count > prose.blocks.len)
            return error.WriterContractViolation;

        var updated_prose = try self.applyProsePatch(job.story_id, state.value.node_id, .{
            .base_revision_id = prose.revision_id,
            .operation = if (is_revision)
                "replace_range"
            else if (is_rewrite and state.value.pass == 0)
                "replace_all"
            else
                "append",
            .anchor_block_id = if (is_revision) prose.blocks[revision_start].id else null,
            .end_anchor_block_id = if (is_revision)
                prose.blocks[revision_start + revision_target_count - 1].id
            else
                null,
            .text = passage_text,
            .author_source = "passage_writer",
        });
        defer updated_prose.deinit(self.allocator);

        const added_count = @min(finish.value.paragraphs.len, updated_prose.blocks.len);
        const added_start = if (is_revision)
            revision_start
        else if (is_rewrite and state.value.pass == 0)
            0
        else
            updated_prose.blocks.len - added_count;
        var block_ids: std.ArrayList([]const u8) = .empty;
        defer block_ids.deinit(self.allocator);
        for (updated_prose.blocks[added_start .. added_start + added_count]) |block| {
            try block_ids.append(self.allocator, block.id);
        }
        const provenance_json = try std.json.Stringify.valueAlloc(
            self.allocator,
            block_ids.items,
            .{},
        );
        defer self.allocator.free(provenance_json);
        const next_pass = state.value.pass + 1;
        const remaining_after = if (is_revision)
            revision_remaining - revision_target_count
        else
            0;
        const extraction_required = if (is_revision)
            remaining_after == 0
        else
            finish.value.section_complete;
        if (extraction_required) {
            try job_store.addEvent(job_id, "documentation_extraction_started", "{}");
            self.extractChapterDocumentation(
                gateway,
                snapshot.value.passage_writer,
                &story,
                selected_node,
                records,
                &updated_prose,
            ) catch |err| {
                const pending_state = try std.json.Stringify.valueAlloc(self.allocator, .{
                    .node_id = state.value.node_id,
                    .pass = next_pass,
                    .continue_context = finish.value.continue_context,
                    .mode = state.value.mode,
                    .revision_instruction = state.value.revision_instruction,
                    .revision_cursor = if (is_revision)
                        revision_start + finish.value.paragraphs.len
                    else
                        state.value.revision_cursor,
                    .remaining_original_blocks = if (is_revision)
                        remaining_after
                    else
                        state.value.remaining_original_blocks,
                    .postprocess_pending = true,
                }, .{});
                defer self.allocator.free(pending_state);
                var paused_job = try job_store.finishPass(job_id, pending_state, "paused");
                paused_job.deinit(self.allocator);
                try job_store.addEvent(job_id, "documentation_extraction_failed", "{}");
                return err;
            };
            try job_store.addEvent(job_id, "documentation_extraction_completed", "{}");
        }
        const change_set_json = try std.json.Stringify.valueAlloc(self.allocator, .{
            .node_id = state.value.node_id,
            .prose_revision_id = updated_prose.revision_id.?,
            .block_ids = block_ids.items,
            .continue_context = finish.value.continue_context,
            .extraction_status = if (extraction_required)
                "complete"
            else
                "deferred_until_section_complete",
        }, .{});
        defer self.allocator.free(change_set_json);
        var change_set = try self.appendDerivedRecord(
            job.story_id,
            state.value.node_id,
            "PassChangeSet",
            change_set_json,
            provenance_json,
        );
        change_set.deinit(self.allocator);
        const capsule_json = try std.json.Stringify.valueAlloc(self.allocator, .{
            .node_id = state.value.node_id,
            .after_revision_id = updated_prose.revision_id.?,
            .handoff = finish.value.continue_context,
        }, .{});
        defer self.allocator.free(capsule_json);
        var capsule = try self.appendDerivedRecord(
            job.story_id,
            state.value.node_id,
            "ContinuationCapsule",
            capsule_json,
            provenance_json,
        );
        capsule.deinit(self.allocator);

        const next_status: []const u8 = if (is_revision and remaining_after == 0)
            "complete"
        else if (!is_revision and finish.value.section_complete)
            "complete"
        else if (next_pass >= 80)
            "paused"
        else
            "queued";
        const next_state = try std.json.Stringify.valueAlloc(self.allocator, .{
            .node_id = state.value.node_id,
            .pass = next_pass,
            .continue_context = finish.value.continue_context,
            .mode = state.value.mode,
            .revision_instruction = state.value.revision_instruction,
            .revision_cursor = if (is_revision)
                revision_start + finish.value.paragraphs.len
            else
                state.value.revision_cursor,
            .remaining_original_blocks = if (is_revision)
                remaining_after
            else
                state.value.remaining_original_blocks,
            .postprocess_pending = false,
        }, .{});
        defer self.allocator.free(next_state);
        return job_store.finishPass(job_id, next_state, next_status);
    }
};

const author_room_system =
    \\You are ClawForge Narrative Studio's Author Room collaborator.
    \\Discuss the user's story like an experienced co-author and developmental editor.
    \\Treat accepted records as established authorial decisions. Label draft or candidate
    \\material as tentative. Never pretend conversation alone changed canon, plans, prose,
    \\or documentation. Explain proposed decisions clearly so the user can review them.
    \\Do not write a full chapter in chat. Keep story voices separate from your own
    \\out-of-character collaboration voice. Use only the supplied story context.
;

const DiscoveryPatch = struct {
    record_type: []const u8,
    value_json: []const u8,
    rationale: []const u8,
};

const DiscoveryFinish = struct {
    assistant_message: []const u8,
    questions: []const []const u8,
    record_patches: []const DiscoveryPatch,
};

const discovery_system =
    \\You are ClawForge Narrative Studio's guided story-discovery director.
    \\Help the author discover what they actually want before drafting. Ask two to
    \\five focused questions per turn, adapting to their answers instead of dumping
    \\a generic questionnaire. Explain useful craft tradeoffs when they matter.
    \\When the author says a decision is difficult, asks for help deciding, or is
    \\not ready to lock an answer, switch into a decision workshop. Work on at most
    \\two current decisions. For each, offer two to four story-specific directions,
    \\give a compact illustrative scene or beat example, explain the likely effects
    \\on plot, character arcs, tone, pacing, and future promises, then recommend the
    \\best fit for the supplied intent and evidence. Explicitly distinguish sourced
    \\facts, your recommendations, provisional preferences, and accepted decisions.
    \\Let the author reject options, combine them, mark a preference provisional, or
    \\keep a mystery intentionally unresolved. End a workshop with the smallest useful
    \\comparative question, such as which direction feels closer and what feels wrong;
    \\do not demand a complete volume-level answer in one turn. Do not create record
    \\patches for choices the author has not actually made.
    \\Build from volume destination, reader experience, dramatic engine, character
    \\relationships, information delivery, narrator/voice, comedy, romance texture,
    \\tone, pacing, prohibitions, and protected moments.
    \\Keep one fiction_declaration object in StoryIdentity rather than repeating a
    \\disclaimer across records. It should identify the work as fiction, state that
    \\characters and events are imaginary unless the author explicitly identifies a
    \\source, and clarify that depicting flawed or immoral behavior is not endorsement.
    \\Character records are working dossiers, not name indexes. When creating or updating
    \\a significant character, preserve demographics, physical presence, background,
    \\public/private personality, wants, needs, fears, contradictions, capabilities,
    \\strengths, one or two concrete flaws, limitations, daily life, key relationships,
    \\recognition anchors, attraction/flirting behavior when relevant, and a distinct
    \\spoken-voice profile with short illustrative dialogue. A flaw must alter choices or
    \\relationships and impose a real cost; disguised virtues such as "cares too much" do
    \\not qualify. Recognition anchors should make the character identifiable through
    \\behavior without reducing them to a repeated prop, catchphrase, diagnosis, or gimmick.
    \\Dialogue exemplars must be understandable without an unstated scene diagram or
    \\specialized workplace jargon. Reveal voice through syntax, priorities, evasion,
    \\and attitude—not by forcing worldbuilding keywords into otherwise unnatural lines.
    \\When proposing chapter or scene beats, decide interaction posture before prose:
    \\who addresses whom, their relationship state, immediate goal, emotional posture,
    \\openness, what may be expressed, what must remain withheld, prohibited social moves,
    \\the expected relational shift, and whether the decision is locked, strongly implied,
    \\or provisional. Cite the character, relationship, prior-event, or author-decision
    \\evidence that makes the planned behavior believable.
    \\Do not inject generic therapy, safety-policy, or consent vocabulary into relationship
    \\documents. Ordinary flirting, teasing, attraction, and attempted courtship do not
    \\require prior formal permission. Show interest, disinterest, awkwardness, persistence,
    \\or withdrawal through character behavior. Discuss consent, coercion, or power dynamics
    \\only when the author's intent or the actual relationship makes them materially relevant.
    \\Before asking any question, search the supplied pending evidence and imported
    \\record proposals for an answer. Do not ask the author to repeat sourced facts.
    \\When sources disagree, state the competing evidence and ask only for the decision
    \\needed to resolve it. Treat the author's latest answer as higher authority than
    \\older plans, while preserving an explicit note that a prior source differed.
    \\Normalize an isolated spelling variant to the consistently sourced character,
    \\place, or term name and mention the normalization briefly. Do not manufacture a
    \\canon conflict from one likely typo unless the author explicitly announces a rename
    \\or two authoritative sources consistently support different names.
    \\If a pending import proposal exists, update the relevant imported record shapes
    \\instead of inventing a disconnected parallel schema.
    \\Never silently change story documentation. When an answer is clear enough,
    \\propose complete typed document objects through finish_discovery_turn.
    \\Your assistant_message must include the questions in readable numbered form.
    \\End exclusively with finish_discovery_turn.
;

const quickstart_architect_system =
    \\You are ClawForge Narrative Studio's Quickstart Story Architect.
    \\Turn one basic premise into a coherent, immediately usable story foundation for
    \\a casual author who wants to approve or lightly adjust the design and begin writing.
    \\Invent confidently, but never disguise inventions as user facts. Every major choice
    \\must be marked inside its document as premise_fact, provisional_default,
    \\load_bearing_assumption, open_question, or protected_choice.
    \\Produce exactly one complete compact JSON object for every one of the 19 allowed
    \\record types. Use stable IDs. Make the documents agree with one another.
    \\Design a satisfying opening volume rather than an endless encyclopedia: protagonist,
    \\ability rules and costs, cast, relationship texture, antagonist pressure, volume
    \\destination, arcs, promises, information delivery, POV, tone, comedy/romance defaults,
    \\timeline, continuity gates, and an opening chapter plan must all be actionable.
    \\EntityRegistry MUST be a usable cast bible. Every significant character entry must
    \\include: id, type, name, gender, pronouns, age_at_opening, role, appearance, background,
    \\public_persona, private_self, traits, want, need, fear, misbelief_or_wound, skills,
    \\strengths, flaws, limitations, daily_life, key_relationships, recognition_anchors,
    \\and voice. strengths states what the character reliably does well beyond a job title.
    \\flaws must contain exactly one or two objects with trait, behavior, and cost. Keep
    \\mechanical inability in limitations; flaws are recurring choices or reactions that
    \\create trouble even when the character has better options.
    \\recognition_anchors must include baseline_habit, under_stress, relational_shift,
    \\variation, and restraint. The same anchor should change with context: for example, a
    \\chronically stressed smoker may reach for a cigarette when trouble starts, forget to
    \\light it while frightened, or stop reaching for one when unexpectedly at ease. restraint
    \\states how often to show it so the behavior remains characterization rather than a tic.
    \\The voice object must include
    \\register, rhythm, word_choice, humor, emotional_expression, evasions, physical_tells,
    \\and at least three short dialogue_samples showing different pressures. Samples are
    \\illustrative voice exemplars, not promised quotations. Non-character entities stay compact.
    \\Every sample must have an obvious meaning on first read. Do not rely on invisible spatial
    \\layout, unexplained trade shorthand, therapy-speak, thematic keyword stuffing, or a clever
    \\line that no person would choose in that immediate situation. In danger, prioritize the
    \\shortest actionable warning a listener could obey.
    \\StoryIdentity MUST contain one fiction_declaration object with classification,
    \\notice, and depiction_principle. Treat it as story-level metadata; do not echo its
    \\language into character, relationship, world, arc, or scene records.
    \\RelationalTextureContract MUST use a relationships array with concrete pair entries:
    \\participants, starting_dynamic, each_side, warmth, friction, public_behavior,
    \\private_behavior, progression, and scene_opportunities. Include a romance_profile with
    \\the selected prominence, plausible pairing(s), attraction basis, each participant's
    \\flirting style, pacing, and exclusions—or explicitly state that romance is absent.
    \\Do not fill documents with generic therapy, safety-policy, or consent language. Ordinary
    \\flirting and courtship require no pre-negotiated consent ritual. Character responses make
    \\reciprocity, rejection, embarrassment, escalation, or retreat legible. Mention consent,
    \\coercion, or power imbalance only when materially relevant to the chosen story.
    \\StoryStructureRoot must include volume_title, opening_arc, and opening_chapter objects,
    \\each with title, purpose, and synopsis. opening_chapter.beats must be an ordered array
    \\of beat objects, not summary strings. Every beat needs id, purpose, entry_state,
    \\exit_change, completion_test, participants, and interaction_contracts. When two or more
    \\characters interact, interaction_contracts must specify each planned speaking posture:
    \\speaker, listener, relationship_state_at_entry, speaker_goal, emotional_posture,
    \\openness, speech_mode, may_express, must_withhold, prohibited_moves, expected_shift,
    \\certainty, and evidence. certainty is locked, strongly_implied, or provisional and must
    \\follow the cited accepted records or prior beats. Decide social behavior here; do not
    \\leave the passage writer to invent whether a character would confide, threaten, flirt,
    \\joke, evade, or use unusual familiarity. Prefer show-not-tell information delivery.
    \\Do not write prose. In assistant_message provide a readable pitch, a section titled
    \\"What I invented", the five most consequential assumptions, and three high-leverage
    \\adjustment questions. The author may accept the complete foundation or revise any
    \\document individually. End exclusively with finish_discovery_turn.
;

const import_system =
    \\You are ClawForge Narrative Studio's source reconstruction specialist.
    \\Convert an existing story bible and manuscript evidence into concise, machine-readable
    \\typed story records. Preserve the author's actual decisions; do not improve, retcon, or
    \\silently reconcile contradictions. Put uncertainty and contradictions in the record data
    \\and explain them in assistant_message. Prefer compact registries with stable entity, arc,
    \\promise, rule, and milestone identifiers over copied prose. Treat future plans as planned,
    \\not as facts that have already occurred. Use chapter prose as evidence of demonstrated
    \\voice, characterization, world rules, and reader knowledge. Propose every record type for
    \\which the supplied sources contain meaningful evidence. Ask only high-value questions that
    \\the source material cannot answer. End exclusively with finish_discovery_turn.
    \\For significant characters, extract a full dossier and dialogue exemplars when evidence
    \\exists. Mark demographics or voice fields unknown rather than inferring them from names.
    \\For an evidently fictional work, keep one fiction_declaration in StoryIdentity. Preserve
    \\the source's declaration when present; otherwise propose a compact default. Never assert
    \\that real people or events are fictional if the source explicitly identifies them as real.
    \\Do not add generic consent or boundary language absent from the source.
;

const finish_discovery_turn_tool = inference.ToolDefinition{
    .name = "finish_discovery_turn",
    .description = "Finish one guided-discovery exchange with focused questions and approval-gated typed document proposals.",
    .input_schema_json =
    \\{"type":"object","additionalProperties":false,"required":["assistant_message","questions","record_patches"],"properties":{"assistant_message":{"type":"string"},"questions":{"type":"array","maxItems":8,"items":{"type":"string"}},"record_patches":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["record_type","value_json","rationale"],"properties":{"record_type":{"type":"string","enum":["StoryIdentity","StoryIntentProfile","StoryContract","StoryStructureRoot","NarratorContract","StyleContract","InformationDeliveryContract","ComedyContract","RelationalTextureContract","QualityGateContract","EntityRegistry","WorldRuleRegistry","MasterTimeline","InformationRegistry","ArcRegistry","PromiseLedger","AuthorDecisionRegistry","SourceRegistry","BranchRegistry"]},"value_json":{"type":"string","description":"A complete JSON object encoded as a string."},"rationale":{"type":"string"}}}}}}
    ,
};

const passage_writer_system =
    \\You are the bounded passage writer inside ClawForge Narrative Studio.
    \\Continue only the selected chapter or scene. Produce one coherent passage of
    \\one to six paragraph blocks, never a full chapter. Each array item is exactly one
    \\publishable fiction paragraph with no embedded blank line.
    \\Dialogue must be obvious on first read. A character says what the immediate situation
    \\calls for; they do not force in occupational, magical, thematic, or relationship
    \\vocabulary merely to demonstrate that it exists in the story bible. Do not use
    \\unstaged directional shorthand or private scene geometry the reader cannot visualize.
    \\Use character recognition anchors sparingly and contextually. An anchor should change
    \\under stress, trust, concealment, or relief; never repeat a habit merely to remind the
    \\reader who entered the scene. If the behavior adds nothing in this passage, omit it.
    \\Let strengths solve some problems and flaws create or worsen others. Do not announce
    \\either in narration; demonstrate them through decisions, consequences, and reactions.
    \\Accepted beat-level interaction contracts are authoritative for who addresses whom,
    \\with what goal, familiarity, openness, and disclosure boundary. Realize that posture
    \\naturally; do not upgrade guardedness into intimacy, turn suspicion into banter, reveal
    \\withheld knowledge, or invent a different social move because it makes a sharper line.
    \\
    \\FICTION TYPOGRAPHY IS A HARD CONTRACT:
    \\- Start a new paragraph every time the speaker changes.
    \\- A paragraph may contain one speaker's dialogue plus that same speaker's action
    \\  beat. Never put an answer from a second speaker in that paragraph.
    \\- Give important reactions and changes of focus breathing room. Do not compress a
    \\  whole exchange into one large paragraph merely to stay within the passage limit.
    \\
    \\UNIVERSAL PROSE FLOOR:
    \\- Clarity, natural rhythm, and character specificity come before ornament.
    \\- Most sentences should state concrete action, perception, or thought plainly.
    \\- Across the entire passage, use at most one conspicuous metaphor or simile unless
    \\  the accepted style explicitly requires more. Motifs are options, not quotas.
    \\- Do not personify ordinary objects merely to sound literary. Avoid stacked images,
    \\  clever synonyms for simple actions, aphoristic narration, and explanatory echoes.
    \\- Name concrete things concretely. Never replace people, bodies, tools, or physical
    \\  sensations with vague poetic abstractions such as "living complexity," "a geometry
    \\  of grief," or similar language that no viewpoint character would naturally think.
    \\- Never invent a magical sensation, capability, visual effect, or bodily feedback to
    \\  decorate a moment. If it is absent from the supplied world rules, it does not happen.
    \\- Give each sentence one primary physical image, action, or thought. Split sentences
    \\  that stack spatial description, a dangling action phrase, and a comparison through
    \\  comma-heavy modifier chains. Read every sentence literally before keeping a simile.
    \\- Vary paragraph length. Under pressure, prefer shorter sentences and clean beats.
    \\
    \\Preserve narrator/character voice boundaries, advance at least one active story
    \\track, and prioritize an enjoyable read. Exposition must follow the supplied
    \\information-delivery contract.
    \\Emphasize a detail only when the paragraph makes its immediate relevance legible:
    \\why the viewpoint notices it now and what pressure, choice, evidence, or reaction it
    \\creates. A future story-bible obligation alone does not justify confusing emphasis.
    \\Prefer visible causal chains—action, evidence, reaction—over abstract interpretation.
    \\End exclusively by calling finish_writer_pass. Put anything the next
    \\pass must remember in continue_context; do not rely on hidden conversation history.
;

const passage_revision_system =
    \\You are the bounded prose reviser inside ClawForge Narrative Studio.
    \\Revise only the TARGET BLOCKS supplied by the user prompt. Preserve their events,
    \\facts, intentions, viewpoint, chronology, and unresolved implications. Do not advance
    \\the story, add a new beat, remove a necessary beat, or imitate weaknesses in the
    \\surrounding context. Return polished replacement paragraphs in the same reading order.
    \\
    \\Apply the user's revision instruction. By default, improve clarity, natural cadence,
    \\dialogue typography, concrete physical logic, and character-specific voice. Start a
    \\new paragraph whenever the speaker changes. Each returned array item must contain at
    \\most one speaking character. Give each sentence one primary image, action, or thought.
    \\Split comma-heavy modifier chains. Remove stacked metaphors, decorative personification,
    \\redundant interpretation, and lines that advertise the prose instead of serving the scene.
    \\Retain a striking image only when it is precise and earns its emphasis.
    \\Name concrete things concretely. Replace vague poetic abstractions with the actual
    \\person, object, action, or sensation. Never invent a magical sense or effect while
    \\revising; world rules are authoritative and silence is not permission to embellish.
    \\For every retained detail, make its local causal role legible: why the viewpoint notices
    \\it now and what pressure, evidence, decision, or reaction follows. Story documentation
    \\saying a detail matters is not enough. Prefer action, evidence, reaction.
    \\
    \\End exclusively by calling finish_writer_pass. Set section_complete false; the runtime,
    \\not you, decides when all source blocks have been revised.
;

const finish_writer_pass_tool = inference.ToolDefinition{
    .name = "finish_writer_pass",
    .description = "Commit one bounded forward-writing passage and its explicit handoff to the next pass.",
    .input_schema_json =
    \\{"type":"object","additionalProperties":false,"required":["paragraphs","continue_context","section_complete","quality_checks"],"properties":{"paragraphs":{"type":"array","minItems":1,"maxItems":6,"description":"Publishable fiction paragraphs in reading order. One speaking character maximum per item.","items":{"type":"string","minLength":1,"maxLength":1600}},"continue_context":{"type":"string","description":"Only details that must be injected into the next pass for local coherence, including exact protected wording if needed."},"section_complete":{"type":"boolean","description":"True only when the selected scene or chapter is actually complete."},"quality_checks":{"type":"object","additionalProperties":false,"required":["dialogue_speakers_separated","clarity_before_ornament","voice_boundaries_preserved","story_state_advanced"],"properties":{"dialogue_speakers_separated":{"type":"boolean"},"clarity_before_ornament":{"type":"boolean"},"voice_boundaries_preserved":{"type":"boolean"},"story_state_advanced":{"type":"boolean"}}}}}
    ,
};

fn buildAuthorPrompt(
    allocator: std.mem.Allocator,
    story: *const domain.Story,
    records: []const domain.Record,
    messages: []const domain.AuthorMessage,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.print(
        allocator,
        "STORY\nTitle: {s}\nGenre: {s}\nPremise: {s}\n\nCANONICAL DOCUMENT PROJECTIONS\n",
        .{ story.title, story.genre orelse "undecided", story.premise orelse "undecided" },
    );
    const document_ceiling: usize = 40 * 1024;
    for (records) |record| {
        if (output.items.len >= document_ceiling) break;
        const remaining = document_ceiling - output.items.len;
        const value = record.value_json[0..@min(record.value_json.len, @min(remaining, 2400))];
        try output.print(
            allocator,
            "\n[{s}; {s}; revision {d}]\n{s}\n",
            .{ record.record_type, record.lifecycle, record.revision, value },
        );
    }
    try output.appendSlice(allocator, "\nRECENT AUTHOR ROOM CONVERSATION\n");
    for (messages) |message| {
        try output.print(allocator, "\n{s}: {s}\n", .{ message.role, message.content });
    }
    try output.appendSlice(
        allocator,
        "\nRespond to the latest user message. Keep any suggested documentation changes explicitly proposed, not silently accepted.",
    );
    return try output.toOwnedSlice(allocator);
}

fn buildDiscoveryPrompt(
    allocator: std.mem.Allocator,
    story: *const domain.Story,
    records: []const domain.Record,
    proposals: []const domain.DocumentChange,
    source_evidence: []const u8,
    messages: []const domain.AuthorMessage,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.print(
        allocator,
        "STORY WORKSPACE\nTitle: {s}\nGenre: {s}\nPremise: {s}\n\nCURRENT DESIGN DOCUMENTS\n",
        .{ story.title, story.genre orelse "undecided", story.premise orelse "undecided" },
    );
    for (records) |record| {
        if (!isDiscoveryRecordType(record.record_type)) continue;
        const value = record.value_json[0..@min(record.value_json.len, 3200)];
        try output.print(
            allocator,
            "\n[{s}; {s}; revision {d}]\n{s}\n",
            .{ record.record_type, record.lifecycle, record.revision, value },
        );
    }
    try output.appendSlice(
        allocator,
        "\nPENDING EVIDENCE AND DOCUMENT PROPOSALS\nThese are not accepted canon, but they are required evidence. Consult them before asking the author for information already reconstructed from imported sources.\n",
    );
    var included_proposals: usize = 0;
    for (proposals) |proposal| {
        if (included_proposals >= 19) break;
        if (!std.mem.eql(u8, proposal.status, "pending")) continue;
        const value = proposal.value_json[0..@min(proposal.value_json.len, 12 * 1024)];
        try output.print(
            allocator,
            "\n[{s}; pending revision {d}]\nRationale: {s}\n{s}\n",
            .{ proposal.record_type, proposal.revision, proposal.rationale, value },
        );
        included_proposals += 1;
    }
    try output.appendSlice(
        allocator,
        "\nRETRIEVED RAW SOURCE EXCERPTS\nThese excerpts come directly from durable imported files. Prefer them over asking the author to repeat established source facts.\n",
    );
    if (source_evidence.len == 0)
        try output.appendSlice(allocator, "No relevant raw-source excerpt was retrieved for this turn.\n")
    else
        try output.appendSlice(allocator, source_evidence);
    try output.appendSlice(allocator, "\nDISCOVERY CONVERSATION\n");
    for (messages) |message| {
        try output.print(allocator, "\n{s}: {s}\n", .{ message.role, message.content });
    }
    try output.appendSlice(
        allocator,
        "\nRespond to the latest answer, summarize what it clarified, then ask the next highest-value focused questions. If the author requested help deciding, run the decision-workshop procedure instead of merely restating the questions. Propose document patches only for decisions supported by the author's answers.",
    );
    return try output.toOwnedSlice(allocator);
}

fn buildImportPrompt(
    allocator: std.mem.Allocator,
    story: *const domain.Story,
    records: []const domain.Record,
    source_bundle: []const u8,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.print(
        allocator,
        "IMPORT TARGET\nTitle: {s}\nGenre: {s}\nPremise: {s}\n\nEXISTING RECORD STATUS\n",
        .{ story.title, story.genre orelse "undecided", story.premise orelse "undecided" },
    );
    for (records) |record| {
        try output.print(
            allocator,
            "{s}: {s}, revision {d}\n",
            .{ record.record_type, record.lifecycle, record.revision },
        );
    }
    try output.appendSlice(
        allocator,
        "\nSOURCE BUNDLE\nEach source begins with a clearly marked filename. Reconstruct typed records with source filenames and evidence notes embedded where useful.\n\n",
    );
    try output.appendSlice(allocator, source_bundle);
    return try output.toOwnedSlice(allocator);
}

fn buildVisibleDiscoveryMessage(
    allocator: std.mem.Allocator,
    summary: []const u8,
    questions: []const []const u8,
) ![]u8 {
    if (questions.len > 0 and
        std.mem.indexOf(u8, summary, "1.") != null and
        std.mem.count(u8, summary, "?") >= questions.len)
        return try allocator.dupe(u8, summary);

    var missing_count: usize = 0;
    for (questions) |question| {
        if (std.mem.indexOf(u8, summary, question) == null) missing_count += 1;
    }
    if (missing_count == 0) return try allocator.dupe(u8, summary);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, summary);
    try output.appendSlice(allocator, "\n\nQuestions to answer:");
    var visible_index: usize = 1;
    for (questions) |question| {
        if (std.mem.indexOf(u8, summary, question) != null) continue;
        try output.print(allocator, "\n{d}. {s}", .{ visible_index, question });
        visible_index += 1;
    }
    return try output.toOwnedSlice(allocator);
}

fn isDiscoveryRecordType(record_type: []const u8) bool {
    const allowed = [_][]const u8{
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
    for (allowed) |candidate| {
        if (std.mem.eql(u8, record_type, candidate)) return true;
    }
    return false;
}

fn buildWriterPrompt(
    allocator: std.mem.Allocator,
    story: *const domain.Story,
    node: *const domain.Node,
    records: []const domain.Record,
    prose: *const domain.ProseDocument,
    pass: u32,
    continue_context: []const u8,
    rewrite_existing: bool,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.print(
        allocator,
        "AUTHORING POSITION\nStory: {s}\nGenre: {s}\nSection: {s} ({s})\nPurpose: {s}\nSynopsis: {s}\nPass: {d}\nMode: {s}\n\n",
        .{
            story.title,
            story.genre orelse "undecided",
            node.title,
            node.node_type,
            node.purpose orelse "not specified",
            node.synopsis orelse "not specified",
            pass,
            if (rewrite_existing) "rewrite from a clean opening; prior prose is evidence only, not a style sample" else "continue accepted prose",
        },
    );
    try output.appendSlice(allocator, "REQUIRED CONTRACTS AND ACTIVE REGISTRIES\n");
    const record_types = [_][]const u8{
        "StoryContract",             "StoryStructureRoot",          "NarratorContract",
        "StyleContract",             "InformationDeliveryContract", "ComedyContract",
        "RelationalTextureContract", "QualityGateContract",         "EntityRegistry",
        "WorldRuleRegistry",         "InformationRegistry",         "ArcRegistry",
        "PromiseLedger",
    };
    for (records) |record| {
        var relevant = false;
        for (record_types) |record_type| {
            if (std.mem.eql(u8, record.record_type, record_type)) {
                relevant = true;
                break;
            }
        }
        if (!relevant) continue;
        const limit: usize = if (std.mem.eql(u8, record.record_type, "EntityRegistry") or
            std.mem.eql(u8, record.record_type, "StoryStructureRoot"))
            8_000
        else
            2_600;
        const value = record.value_json[0..@min(record.value_json.len, limit)];
        try output.print(
            allocator,
            "\n[{s}; {s}; r{d}]\n{s}\n",
            .{ record.record_type, record.lifecycle, record.revision, value },
        );
    }
    if (!rewrite_existing or pass > 0) {
        try output.appendSlice(allocator, "\nRECENT PROSE WINDOW\n");
        const start = if (prose.blocks.len > 8) prose.blocks.len - 8 else 0;
        for (prose.blocks[start..]) |block| {
            try output.print(allocator, "\n[block {s}]\n{s}\n", .{ block.id, block.text });
        }
    } else {
        try output.appendSlice(
            allocator,
            "\nPRIOR PROSE WINDOW\nOmitted intentionally. Establish a cleaner opening from the accepted plans.\n",
        );
    }
    try output.print(
        allocator,
        "\nEXPLICIT CONTINUATION HANDOFF\n{s}\n\n" ++ "Before committing, read the passage once as a reader. Separate every speaker, " ++ "remove decorative language that does not improve comprehension or character, " ++ "and confirm that something changed. Write the next bounded passage now.",
        .{if (continue_context.len > 0) continue_context else "No additional handoff; infer only from the supplied position, records, and prose window."},
    );
    return try output.toOwnedSlice(allocator);
}

fn buildRevisionPrompt(
    allocator: std.mem.Allocator,
    story: *const domain.Story,
    node: *const domain.Node,
    records: []const domain.Record,
    prose: *const domain.ProseDocument,
    start: usize,
    count: usize,
    instruction: []const u8,
) ![]u8 {
    if (count == 0 or start + count > prose.blocks.len) return error.InvalidRevisionRange;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.print(
        allocator,
        "REVISION POSITION\nStory: {s}\nGenre: {s}\nSection: {s} ({s})\n" ++ "Purpose: {s}\nSynopsis: {s}\n\nUSER REVISION INSTRUCTION\n{s}\n\n",
        .{
            story.title,
            story.genre orelse "undecided",
            node.title,
            node.node_type,
            node.purpose orelse "not specified",
            node.synopsis orelse "not specified",
            if (std.mem.trim(u8, instruction, " \t\r\n").len > 0)
                instruction
            else
                "Make the prose clear, natural, readable, and properly paragraphed while preserving its story content.",
        },
    );
    try output.appendSlice(allocator, "RELEVANT ACCEPTED CONTRACTS\n");
    const record_types = [_][]const u8{
        "NarratorContract",
        "StyleContract",
        "InformationDeliveryContract",
        "QualityGateContract",
        "WorldRuleRegistry",
    };
    for (records) |record| {
        for (record_types) |record_type| {
            if (!std.mem.eql(u8, record.record_type, record_type)) continue;
            const value = record.value_json[0..@min(record.value_json.len, 2200)];
            try output.print(allocator, "\n[{s}; {s}]\n{s}\n", .{
                record.record_type,
                record.lifecycle,
                value,
            });
            break;
        }
    }
    try output.appendSlice(allocator, "\nSURROUNDING CONTEXT — DO NOT RETURN THESE BLOCKS\n");
    const context_start = start -| 2;
    for (prose.blocks[context_start..start]) |block| {
        try output.print(allocator, "[before] {s}\n", .{block.text});
    }
    const target_end = start + count;
    for (prose.blocks[target_end..@min(prose.blocks.len, target_end + 2)]) |block| {
        try output.print(allocator, "[after] {s}\n", .{block.text});
    }
    try output.appendSlice(allocator, "\nTARGET BLOCKS — RETURN REPLACEMENTS ONLY\n");
    for (prose.blocks[start..target_end], 0..) |block, index| {
        try output.print(allocator, "\n[target {d}; block {s}]\n{s}\n", .{
            index + 1,
            block.id,
            block.text,
        });
    }
    try output.appendSlice(
        allocator,
        "\nPreserve the complete information and dramatic function of these targets. " ++ "You may split or combine paragraphs when readability requires it. " ++ "Return only their revised replacements through finish_writer_pass.",
    );
    return output.toOwnedSlice(allocator);
}

fn validateWriterFinish(
    paragraphs: []const []const u8,
    checks: [4]bool,
) ?[]const u8 {
    if (paragraphs.len == 0 or paragraphs.len > 6) return "passage must contain one to six paragraphs";
    for (checks) |passed| {
        if (!passed) return "writer self-check reported an unresolved prose problem";
    }
    var total_bytes: usize = 0;
    for (paragraphs) |paragraph| {
        const trimmed = std.mem.trim(u8, paragraph, " \t\r\n");
        if (trimmed.len == 0) return "empty paragraph";
        if (std.mem.indexOf(u8, trimmed, "\n\n") != null) return "paragraph item contains an embedded paragraph break";
        if (writerWordCount(trimmed) > 130) return "paragraph exceeds the 130-word readability ceiling";
        total_bytes += trimmed.len;
    }
    if (total_bytes > 9_000) return "passage exceeds the bounded patch size";
    return null;
}

fn validateQuickstartFoundationDepth(
    allocator: std.mem.Allocator,
    patches: []const DiscoveryPatch,
) !bool {
    var identity_json: ?[]const u8 = null;
    var structure_json: ?[]const u8 = null;
    var entity_json: ?[]const u8 = null;
    var relationship_json: ?[]const u8 = null;
    for (patches) |patch| {
        if (std.mem.eql(u8, patch.record_type, "StoryIdentity"))
            identity_json = patch.value_json;
        if (std.mem.eql(u8, patch.record_type, "StoryStructureRoot"))
            structure_json = patch.value_json;
        if (std.mem.eql(u8, patch.record_type, "EntityRegistry"))
            entity_json = patch.value_json;
        if (std.mem.eql(u8, patch.record_type, "RelationalTextureContract"))
            relationship_json = patch.value_json;
    }
    if (identity_json == null or structure_json == null or entity_json == null or
        relationship_json == null)
        return false;

    var identity = std.json.parseFromSlice(std.json.Value, allocator, identity_json.?, .{}) catch
        return false;
    defer identity.deinit();
    if (identity.value != .object) return false;
    const declaration = identity.value.object.get("fiction_declaration") orelse return false;
    if (declaration != .object) return false;
    const declaration_fields = [_][]const u8{
        "classification",
        "notice",
        "depiction_principle",
    };
    for (declaration_fields) |field| {
        if (!hasMeaningfulJsonField(declaration.object.get(field))) return false;
    }

    var structure = std.json.parseFromSlice(std.json.Value, allocator, structure_json.?, .{}) catch
        return false;
    defer structure.deinit();
    if (structure.value != .object) return false;
    const opening_chapter = structure.value.object.get("opening_chapter") orelse return false;
    if (opening_chapter != .object) return false;
    const beats = opening_chapter.object.get("beats") orelse return false;
    if (beats != .array or beats.array.items.len == 0) return false;
    for (beats.array.items) |beat| {
        if (beat != .object) return false;
        const beat_fields = [_][]const u8{
            "id",
            "purpose",
            "entry_state",
            "exit_change",
            "completion_test",
            "participants",
        };
        for (beat_fields) |field| {
            if (!hasMeaningfulJsonField(beat.object.get(field))) return false;
        }
        const entry_state = beat.object.get("entry_state") orelse return false;
        if (entry_state != .object or entry_state.object.count() == 0) return false;
        const participants = beat.object.get("participants") orelse return false;
        if (participants != .array or participants.array.items.len == 0) return false;
        const contracts = beat.object.get("interaction_contracts") orelse return false;
        if (contracts != .array) return false;
        if (participants.array.items.len > 1 and contracts.array.items.len == 0)
            return false;
        for (contracts.array.items) |contract| {
            if (contract != .object) return false;
            const contract_fields = [_][]const u8{
                "speaker",
                "listener",
                "relationship_state_at_entry",
                "speaker_goal",
                "emotional_posture",
                "openness",
                "speech_mode",
                "may_express",
                "expected_shift",
                "certainty",
                "evidence",
            };
            for (contract_fields) |field| {
                if (!hasMeaningfulJsonField(contract.object.get(field))) return false;
            }
            const must_withhold = contract.object.get("must_withhold") orelse return false;
            const prohibited = contract.object.get("prohibited_moves") orelse return false;
            if (must_withhold != .array or prohibited != .array) return false;
            const certainty = contract.object.get("certainty") orelse return false;
            if (certainty != .string or
                (!std.mem.eql(u8, certainty.string, "locked") and
                    !std.mem.eql(u8, certainty.string, "strongly_implied") and
                    !std.mem.eql(u8, certainty.string, "provisional")))
                return false;
        }
    }

    var entities = std.json.parseFromSlice(std.json.Value, allocator, entity_json.?, .{}) catch
        return false;
    defer entities.deinit();
    if (entities.value != .object) return false;
    const entity_list = entities.value.object.get("entities") orelse return false;
    if (entity_list != .array) return false;
    var character_count: usize = 0;
    for (entity_list.array.items) |entity| {
        if (entity != .object) continue;
        const entity_type = entity.object.get("type") orelse continue;
        if (entity_type != .string or !std.mem.eql(u8, entity_type.string, "character"))
            continue;
        character_count += 1;
        const required_fields = [_][]const u8{
            "id",           "name",              "gender",
            "pronouns",     "age_at_opening",    "role",
            "appearance",   "background",        "public_persona",
            "private_self", "traits",            "want",
            "need",         "fear",              "misbelief_or_wound",
            "skills",       "strengths",         "limitations",
            "daily_life",   "key_relationships", "recognition_anchors",
        };
        for (required_fields) |field| {
            if (!hasMeaningfulJsonField(entity.object.get(field))) return false;
        }
        const flaws = entity.object.get("flaws") orelse return false;
        if (flaws != .array or flaws.array.items.len < 1 or flaws.array.items.len > 2)
            return false;
        for (flaws.array.items) |flaw| {
            if (flaw != .object) return false;
            const flaw_fields = [_][]const u8{ "trait", "behavior", "cost" };
            for (flaw_fields) |field| {
                if (!hasMeaningfulJsonField(flaw.object.get(field))) return false;
            }
        }
        const anchors = entity.object.get("recognition_anchors") orelse return false;
        if (anchors != .object) return false;
        const anchor_fields = [_][]const u8{
            "baseline_habit",
            "under_stress",
            "relational_shift",
            "variation",
            "restraint",
        };
        for (anchor_fields) |field| {
            if (!hasMeaningfulJsonField(anchors.object.get(field))) return false;
        }
        const voice = entity.object.get("voice") orelse return false;
        if (voice != .object) return false;
        const voice_fields = [_][]const u8{
            "register",       "rhythm",               "word_choice",
            "humor",          "emotional_expression", "evasions",
            "physical_tells",
        };
        for (voice_fields) |field| {
            if (!hasMeaningfulJsonField(voice.object.get(field))) return false;
        }
        const samples = voice.object.get("dialogue_samples") orelse return false;
        if (samples != .array or samples.array.items.len < 3) return false;
    }
    if (character_count == 0) return false;

    var relationships = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        relationship_json.?,
        .{},
    ) catch return false;
    defer relationships.deinit();
    if (relationships.value != .object) return false;
    const pairs = relationships.value.object.get("relationships") orelse return false;
    if (pairs != .array or pairs.array.items.len == 0) return false;
    const romance_profile = relationships.value.object.get("romance_profile") orelse
        return false;
    return romance_profile == .object;
}

fn hasMeaningfulJsonField(value: ?std.json.Value) bool {
    const field = value orelse return false;
    return switch (field) {
        .null => false,
        .string => |text| std.mem.trim(u8, text, " \t\r\n").len > 0,
        .array => |items| items.items.len > 0,
        else => true,
    };
}

fn joinParagraphs(allocator: std.mem.Allocator, paragraphs: []const []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (paragraphs, 0..) |paragraph, index| {
        if (index > 0) try output.appendSlice(allocator, "\n\n");
        try output.appendSlice(allocator, std.mem.trim(u8, paragraph, " \t\r\n"));
    }
    return output.toOwnedSlice(allocator);
}

fn writerWordCount(text: []const u8) usize {
    var count: usize = 0;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next() != null) count += 1;
    return count;
}

fn narrativeEmbeddingSourceType(
    allocator: std.mem.Allocator,
    story_id: []const u8,
    import_job_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "narrative_source:{s}:{s}",
        .{ story_id, import_job_id },
    );
}

test "visible discovery message does not duplicate questions already in summary" {
    const allocator = std.testing.allocator;
    const questions = [_][]const u8{
        "Where should volume one leave the protagonist?",
        "What feeling should linger after the ending?",
    };
    const summary =
        "We should establish the destination first.\n\n" ++
        "1. Where should volume one leave the protagonist?\n" ++
        "2. What feeling should linger after the ending?";

    const visible = try buildVisibleDiscoveryMessage(allocator, summary, &questions);
    defer allocator.free(visible);

    try std.testing.expectEqualStrings(summary, visible);
}

test "visible discovery message appends structured questions omitted from summary" {
    const allocator = std.testing.allocator;
    const questions = [_][]const u8{"What changes by the end of the volume?"};

    const visible = try buildVisibleDiscoveryMessage(
        allocator,
        "The volume destination is still undecided.",
        &questions,
    );
    defer allocator.free(visible);

    try std.testing.expect(std.mem.indexOf(u8, visible, "Questions to answer:") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, questions[0]) != null);
}

test "writer quality gate rejects an unresolved dialogue layout self-check" {
    const paragraphs = [_][]const u8{
        "“The pin failed,” Arin said. “Before I arrived.” “Then explain the frost,” Mira said.",
    };
    try std.testing.expectEqualStrings(
        "writer self-check reported an unresolved prose problem",
        validateWriterFinish(&paragraphs, .{ false, true, true, true }).?,
    );
}

test "writer quality gate permits multiple utterances from one speaker" {
    const paragraphs = [_][]const u8{
        "“The pin failed,” Arin said. He looked at the glove. “It failed before I arrived.”",
    };
    try std.testing.expect(validateWriterFinish(&paragraphs, .{ true, true, true, true }) == null);
}

test "quickstart foundation requires fiction declaration character depth and relationships" {
    const patches = [_]DiscoveryPatch{
        .{
            .record_type = "StoryIdentity",
            .value_json =
            \\{"fiction_declaration":{"classification":"fiction","notice":"Characters and events are imaginary.","depiction_principle":"Depiction is not endorsement."}}
            ,
            .rationale = "test",
        },
        .{
            .record_type = "StoryStructureRoot",
            .value_json =
            \\{"opening_chapter":{"title":"One","purpose":"Open","synopsis":"A test.","beats":[{"id":"beat.one","purpose":"Change trust","entry_state":{"relationship":"wary"},"exit_change":"They cooperate once.","completion_test":"One accepts the other's warning.","participants":["One","Two"],"interaction_contracts":[{"speaker":"One","listener":"Two","relationship_state_at_entry":"wary rivals","speaker_goal":"get immediate cooperation","emotional_posture":"controlled urgency","openness":"guarded","speech_mode":"plain and direct","may_express":["the immediate danger"],"must_withhold":["the private cause"],"prohibited_moves":["confession","flirtation"],"expected_shift":"Two treats the warning as credible","certainty":"strongly_implied","evidence":["EntityRegistry:One","RelationalTextureContract:One-Two"]}]}]}}
            ,
            .rationale = "test",
        },
        .{
            .record_type = "EntityRegistry",
            .value_json =
            \\{"entities":[{"id":"char.one","type":"character","name":"One","gender":"woman","pronouns":"she/her","age_at_opening":30,"role":"lead","appearance":"distinct","background":"history","public_persona":"calm","private_self":"restless","traits":["precise"],"want":"solve it","need":"trust others","fear":"failure","misbelief_or_wound":"control prevents loss","skills":["analysis"],"strengths":["patient observation"],"flaws":[{"trait":"controlling","behavior":"withholds choices","cost":"alienates allies"}],"limitations":["impatient"],"daily_life":"repairs clocks","key_relationships":{"Two":"rival"},"recognition_anchors":{"baseline_habit":"winds a broken watch","under_stress":"winds it faster","relational_shift":"hands it to trusted people","variation":"forgets it when absorbed","restraint":"show only at pressure changes"},"voice":{"register":"plain","rhythm":"measured","word_choice":"concrete","humor":"dry","emotional_expression":"indirect","evasions":"answers narrowly","physical_tells":"folds sleeves","dialogue_samples":["one","two","three"]}}]}
            ,
            .rationale = "test",
        },
        .{
            .record_type = "RelationalTextureContract",
            .value_json =
            \\{"relationships":[{"participants":["One","Two"]}],"romance_profile":{"prominence":"none"}}
            ,
            .rationale = "test",
        },
    };
    try std.testing.expect(try validateQuickstartFoundationDepth(std.testing.allocator, &patches));
}

test "quickstart foundation rejects cast indexes without voice dossiers" {
    const patches = [_]DiscoveryPatch{
        .{
            .record_type = "StoryIdentity",
            .value_json =
            \\{"fiction_declaration":{"classification":"fiction","notice":"Characters and events are imaginary.","depiction_principle":"Depiction is not endorsement."}}
            ,
            .rationale = "test",
        },
        .{
            .record_type = "StoryStructureRoot",
            .value_json =
            \\{"opening_chapter":{"title":"One","purpose":"Open","synopsis":"A test.","beats":[{"id":"beat.one","purpose":"Change trust","entry_state":{"relationship":"wary"},"exit_change":"They cooperate once.","completion_test":"One accepts the other's warning.","participants":["One","Two"],"interaction_contracts":[{"speaker":"One","listener":"Two","relationship_state_at_entry":"wary rivals","speaker_goal":"get immediate cooperation","emotional_posture":"controlled urgency","openness":"guarded","speech_mode":"plain and direct","may_express":["the immediate danger"],"must_withhold":["the private cause"],"prohibited_moves":["confession","flirtation"],"expected_shift":"Two treats the warning as credible","certainty":"strongly_implied","evidence":["EntityRegistry:One","RelationalTextureContract:One-Two"]}]}]}}
            ,
            .rationale = "test",
        },
        .{
            .record_type = "EntityRegistry",
            .value_json =
            \\{"entities":[{"id":"char.one","type":"character","name":"One","role":"lead"}]}
            ,
            .rationale = "test",
        },
        .{
            .record_type = "RelationalTextureContract",
            .value_json =
            \\{"relationships":[{"participants":["One","Two"]}],"romance_profile":{"prominence":"none"}}
            ,
            .rationale = "test",
        },
    };
    try std.testing.expect(!try validateQuickstartFoundationDepth(std.testing.allocator, &patches));
}
