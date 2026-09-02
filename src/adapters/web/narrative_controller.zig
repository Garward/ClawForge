//! Thin HTTP/JSON transport for the public NarrativeService API.

const std = @import("std");
const common = @import("common");
const narrative = @import("narrative");

pub const Controller = struct {
    allocator: std.mem.Allocator,
    service: *narrative.Service,

    pub fn handles(path: []const u8) bool {
        return std.mem.eql(u8, path, "/narrative") or
            std.mem.eql(u8, path, "/narrative/") or
            std.mem.startsWith(u8, path, "/narrative/story/") or
            std.mem.startsWith(u8, path, "/api/narrative/");
    }

    pub fn handle(
        self: *Controller,
        stream: common.net.Stream,
        method: []const u8,
        raw_path: []const u8,
        body: []const u8,
    ) !void {
        const path = if (std.mem.indexOfScalar(u8, raw_path, '?')) |index|
            raw_path[0..index]
        else
            raw_path;

        if (std.mem.eql(u8, method, "OPTIONS")) {
            return send(stream, "204 No Content", "text/plain", "");
        }
        if (std.mem.startsWith(u8, path, "/narrative")) {
            const html = @embedFile("narrative/index.html");
            return send(stream, "200 OK", "text/html; charset=utf-8", html);
        }
        if (std.mem.eql(u8, path, "/api/narrative/v1/health")) {
            return sendJson(stream, "200 OK", "{\"ok\":true,\"subsystem\":\"narrative\",\"version\":1}");
        }
        if (std.mem.eql(u8, path, "/api/narrative/v1/stories")) {
            if (std.mem.eql(u8, method, "GET")) return self.listStories(stream);
            if (std.mem.eql(u8, method, "POST")) return self.createStory(stream, body);
            return methodNotAllowed(stream);
        }
        const job_prefix = "/api/narrative/v1/jobs/";
        if (std.mem.startsWith(u8, path, job_prefix) and std.mem.endsWith(u8, path, "/step")) {
            const job_id = path[job_prefix.len .. path.len - "/step".len];
            if (!isUuid(job_id)) return badRequest(stream, "Invalid job ID");
            if (std.mem.eql(u8, method, "POST")) return self.runWriterPass(stream, job_id);
            return methodNotAllowed(stream);
        }

        const prefix = "/api/narrative/v1/stories/";
        if (std.mem.startsWith(u8, path, prefix)) {
            const remainder = path[prefix.len..];
            if (std.mem.endsWith(u8, remainder, "/discovery/messages")) {
                const story_id = remainder[0 .. remainder.len - "/discovery/messages".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "GET"))
                    return self.listDiscoveryMessages(stream, story_id);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/discovery/proposals")) {
                const story_id = remainder[0 .. remainder.len - "/discovery/proposals".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "GET"))
                    return self.listDiscoveryProposals(stream, story_id);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/discovery/changes")) {
                const story_id = remainder[0 .. remainder.len - "/discovery/changes".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "GET"))
                    return self.listDiscoveryDocumentChanges(stream, story_id);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/discovery/turn")) {
                const story_id = remainder[0 .. remainder.len - "/discovery/turn".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "POST"))
                    return self.discoveryTurn(stream, story_id, body);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/quickstart/design")) {
                const story_id = remainder[0 .. remainder.len - "/quickstart/design".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "POST"))
                    return self.quickstartArchitect(stream, story_id, body);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/quickstart/accept")) {
                const story_id = remainder[0 .. remainder.len - "/quickstart/accept".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "POST"))
                    return self.acceptQuickstartFoundation(stream, story_id);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/imports/analyze")) {
                const story_id = remainder[0 .. remainder.len - "/imports/analyze".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "POST"))
                    return self.analyzeImportedSources(stream, story_id, body);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/imports/index")) {
                const story_id = remainder[0 .. remainder.len - "/imports/index".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "POST"))
                    return self.indexImportedSources(stream, story_id, body);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/imports")) {
                const story_id = remainder[0 .. remainder.len - "/imports".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "GET"))
                    return self.listImportSources(stream, story_id);
                return methodNotAllowed(stream);
            }
            if (std.mem.indexOf(u8, remainder, "/discovery/proposals/")) |separator| {
                const story_id = remainder[0..separator];
                const action_path = remainder[separator + "/discovery/proposals/".len ..];
                const action_separator = std.mem.lastIndexOfScalar(u8, action_path, '/') orelse
                    return badRequest(stream, "Missing proposal action");
                const proposal_id = action_path[0..action_separator];
                const action = action_path[action_separator + 1 ..];
                if (!isUuid(story_id) or !isUuid(proposal_id))
                    return badRequest(stream, "Invalid story or proposal ID");
                if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed(stream);
                if (std.mem.eql(u8, action, "accept"))
                    return self.decideDiscoveryProposal(stream, story_id, proposal_id, true);
                if (std.mem.eql(u8, action, "reject"))
                    return self.decideDiscoveryProposal(stream, story_id, proposal_id, false);
                return badRequest(stream, "Invalid proposal action");
            }
            if (std.mem.indexOf(u8, remainder, "/discovery/changes/")) |separator| {
                const story_id = remainder[0..separator];
                const action_path = remainder[separator + "/discovery/changes/".len ..];
                const action_separator = std.mem.lastIndexOfScalar(u8, action_path, '/') orelse
                    return badRequest(stream, "Missing document change action");
                const change_id = action_path[0..action_separator];
                const action = action_path[action_separator + 1 ..];
                if (!isUuid(story_id) or !isUuid(change_id))
                    return badRequest(stream, "Invalid story or document change ID");
                if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed(stream);
                if (std.mem.eql(u8, action, "accept"))
                    return self.decideDiscoveryDocumentChange(stream, story_id, change_id, true);
                if (std.mem.eql(u8, action, "reject"))
                    return self.decideDiscoveryDocumentChange(stream, story_id, change_id, false);
                return badRequest(stream, "Invalid document change action");
            }
            if (std.mem.endsWith(u8, remainder, "/jobs")) {
                const story_id = remainder[0 .. remainder.len - "/jobs".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "GET")) return self.listJobs(stream, story_id);
                if (std.mem.eql(u8, method, "POST")) return self.createWriterJob(stream, story_id, body);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/author-room/messages")) {
                const story_id = remainder[0 .. remainder.len - "/author-room/messages".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "GET"))
                    return self.listAuthorMessages(stream, story_id);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/author-room/turn")) {
                const story_id = remainder[0 .. remainder.len - "/author-room/turn".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "POST"))
                    return self.authorTurn(stream, story_id, body);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/nodes")) {
                const story_id = remainder[0 .. remainder.len - "/nodes".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "GET")) return self.listNodes(stream, story_id);
                if (std.mem.eql(u8, method, "POST")) return self.createNode(stream, story_id, body);
                return methodNotAllowed(stream);
            }
            if (std.mem.indexOf(u8, remainder, "/nodes/")) |separator| {
                const story_id = remainder[0..separator];
                const node_path = remainder[separator + "/nodes/".len ..];
                if (std.mem.endsWith(u8, node_path, "/prose")) {
                    const node_id = node_path[0 .. node_path.len - "/prose".len];
                    if (!isUuid(story_id) or !isUuid(node_id))
                        return badRequest(stream, "Invalid story or node ID");
                    if (std.mem.eql(u8, method, "GET"))
                        return self.getProse(stream, story_id, node_id);
                    if (std.mem.eql(u8, method, "PATCH"))
                        return self.applyProsePatch(stream, story_id, node_id, body);
                    return methodNotAllowed(stream);
                }
                if (std.mem.endsWith(u8, node_path, "/documentation-sync")) {
                    const node_id = node_path[0 .. node_path.len - "/documentation-sync".len];
                    if (!isUuid(story_id) or !isUuid(node_id))
                        return badRequest(stream, "Invalid story or node ID");
                    if (std.mem.eql(u8, method, "POST"))
                        return self.syncChapterDocumentation(stream, story_id, node_id);
                    return methodNotAllowed(stream);
                }
            }
            if (std.mem.indexOf(u8, remainder, "/nodes/")) |separator| {
                const story_id = remainder[0..separator];
                const node_id = remainder[separator + "/nodes/".len ..];
                if (!isUuid(story_id) or !isUuid(node_id))
                    return badRequest(stream, "Invalid story or node ID");
                if (std.mem.eql(u8, method, "PUT"))
                    return self.updateNode(stream, story_id, node_id, body);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/records")) {
                const story_id = remainder[0 .. remainder.len - "/records".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "GET")) return self.listRecords(stream, story_id);
                return methodNotAllowed(stream);
            }
            if (std.mem.indexOf(u8, remainder, "/records/")) |separator| {
                const story_id = remainder[0..separator];
                const record_id = remainder[separator + "/records/".len ..];
                if (!isUuid(story_id) or !isUuid(record_id))
                    return badRequest(stream, "Invalid story or record ID");
                if (std.mem.eql(u8, method, "PUT"))
                    return self.updateRecord(stream, story_id, record_id, body);
                return methodNotAllowed(stream);
            }
            if (std.mem.endsWith(u8, remainder, "/model-profile")) {
                const story_id = remainder[0 .. remainder.len - "/model-profile".len];
                if (!isUuid(story_id)) return badRequest(stream, "Invalid story ID");
                if (std.mem.eql(u8, method, "GET")) return self.getModelProfile(stream, story_id);
                if (std.mem.eql(u8, method, "PUT")) return self.updateModelProfile(stream, story_id, body);
                return methodNotAllowed(stream);
            }
            if (isUuid(remainder) and std.mem.eql(u8, method, "GET")) {
                return self.getStory(stream, remainder);
            }
        }
        return sendJson(stream, "404 Not Found", "{\"error\":\"Narrative route not found\"}");
    }

    fn listStories(self: *Controller, stream: common.net.Stream) !void {
        const stories = self.service.listStories() catch |err|
            return self.internalError(stream, err);
        defer {
            for (stories) |*story| story.deinit(self.allocator);
            self.allocator.free(stories);
        }
        const encoded = std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .stories = stories },
            .{},
        ) catch return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn createStory(self: *Controller, stream: common.net.Stream, body: []const u8) !void {
        const CreateBody = struct {
            title: []const u8,
            premise: ?[]const u8 = null,
            genre: ?[]const u8 = null,
            default_model: ?[]const u8 = null,
        };
        var parsed = std.json.parseFromSlice(CreateBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid story JSON");
        defer parsed.deinit();

        var story = self.service.createStory(.{
            .title = parsed.value.title,
            .premise = parsed.value.premise,
            .genre = parsed.value.genre,
            .default_model = parsed.value.default_model,
        }) catch |err| switch (err) {
            error.InvalidTitle => return badRequest(stream, "Story title is required"),
            else => return self.internalError(stream, err),
        };
        defer story.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, story, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "201 Created", encoded);
    }

    fn getStory(self: *Controller, stream: common.net.Stream, story_id: []const u8) !void {
        var story = (self.service.getStory(story_id) catch |err|
            return self.internalError(stream, err)) orelse
            return sendJson(stream, "404 Not Found", "{\"error\":\"Story not found\"}");
        defer story.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, story, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn getModelProfile(self: *Controller, stream: common.net.Stream, story_id: []const u8) !void {
        var profile = (self.service.getModelProfile(story_id) catch |err|
            return self.internalError(stream, err)) orelse
            return sendJson(stream, "404 Not Found", "{\"error\":\"Model profile not found\"}");
        defer profile.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, profile, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn updateModelProfile(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        body: []const u8,
    ) !void {
        const UpdateBody = struct {
            default_model: ?[]const u8 = null,
            role_overrides_json: []const u8 = "{}",
            expected_revision: i64,
        };
        var parsed = std.json.parseFromSlice(UpdateBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid model profile JSON");
        defer parsed.deinit();

        var profile = self.service.updateModelProfile(
            story_id,
            parsed.value.default_model,
            parsed.value.role_overrides_json,
            parsed.value.expected_revision,
        ) catch |err| switch (err) {
            error.InvalidRoleOverrides => return badRequest(stream, "role_overrides_json must be a JSON object"),
            error.StaleRevision => return sendJson(stream, "409 Conflict", "{\"error\":\"Stale model profile revision\"}"),
            error.StoryNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Story not found\"}"),
            else => return self.internalError(stream, err),
        };
        defer profile.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, profile, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn listRecords(self: *Controller, stream: common.net.Stream, story_id: []const u8) !void {
        const records = self.service.listRecords(story_id) catch |err|
            return self.internalError(stream, err);
        defer {
            for (records) |*record| record.deinit(self.allocator);
            self.allocator.free(records);
        }
        const encoded = std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .records = records },
            .{},
        ) catch return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn updateRecord(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        record_id: []const u8,
        body: []const u8,
    ) !void {
        const UpdateBody = struct {
            value_json: []const u8,
            lifecycle: []const u8,
            expected_revision: i64,
        };
        var parsed = std.json.parseFromSlice(UpdateBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid record JSON");
        defer parsed.deinit();

        var record = self.service.updateRecord(
            story_id,
            record_id,
            parsed.value.value_json,
            parsed.value.lifecycle,
            parsed.value.expected_revision,
        ) catch |err| switch (err) {
            error.InvalidRecordValue => return badRequest(stream, "Record value must be a JSON object"),
            error.InvalidLifecycle => return badRequest(stream, "Invalid record lifecycle"),
            error.StaleRevision => return sendJson(stream, "409 Conflict", "{\"error\":\"Stale record revision\"}"),
            error.RecordNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Record not found\"}"),
            else => return self.internalError(stream, err),
        };
        defer record.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, record, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn listNodes(self: *Controller, stream: common.net.Stream, story_id: []const u8) !void {
        const nodes = self.service.listNodes(story_id) catch |err|
            return self.internalError(stream, err);
        defer {
            for (nodes) |*node| node.deinit(self.allocator);
            self.allocator.free(nodes);
        }
        const encoded = std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .nodes = nodes },
            .{},
        ) catch return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn createNode(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        body: []const u8,
    ) !void {
        const CreateBody = struct {
            parent_id: ?[]const u8 = null,
            node_type: []const u8,
            title: []const u8,
            purpose: ?[]const u8 = null,
            synopsis: ?[]const u8 = null,
        };
        var parsed = std.json.parseFromSlice(CreateBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid node JSON");
        defer parsed.deinit();
        var node = self.service.createNode(story_id, .{
            .parent_id = parsed.value.parent_id,
            .node_type = parsed.value.node_type,
            .title = parsed.value.title,
            .purpose = parsed.value.purpose,
            .synopsis = parsed.value.synopsis,
        }) catch |err| switch (err) {
            error.InvalidNodeType => return badRequest(stream, "Node type must be volume, arc, chapter, or scene"),
            error.InvalidTitle => return badRequest(stream, "Node title is required"),
            error.ParentNotFound => return badRequest(stream, "Parent node was not found"),
            error.StoryNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Story not found\"}"),
            else => return self.internalError(stream, err),
        };
        defer node.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, node, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "201 Created", encoded);
    }

    fn updateNode(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        node_id: []const u8,
        body: []const u8,
    ) !void {
        const UpdateBody = struct {
            title: []const u8,
            purpose: ?[]const u8 = null,
            synopsis: ?[]const u8 = null,
            lifecycle: []const u8,
            expected_revision: i64,
        };
        var parsed = std.json.parseFromSlice(UpdateBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid node JSON");
        defer parsed.deinit();
        var node = self.service.updateNode(
            story_id,
            node_id,
            parsed.value.title,
            parsed.value.purpose,
            parsed.value.synopsis,
            parsed.value.lifecycle,
            parsed.value.expected_revision,
        ) catch |err| switch (err) {
            error.InvalidTitle => return badRequest(stream, "Node title is required"),
            error.InvalidLifecycle => return badRequest(stream, "Invalid node lifecycle"),
            error.StaleRevision => return sendJson(stream, "409 Conflict", "{\"error\":\"Stale node revision\"}"),
            error.NodeNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Node not found\"}"),
            else => return self.internalError(stream, err),
        };
        defer node.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, node, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn getProse(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        node_id: []const u8,
    ) !void {
        var document = self.service.getProse(story_id, node_id) catch |err| switch (err) {
            error.NodeNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Chapter or scene not found\"}"),
            else => return self.internalError(stream, err),
        };
        defer document.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, document, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn syncChapterDocumentation(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        node_id: []const u8,
    ) !void {
        self.service.syncChapterDocumentation(story_id, node_id) catch |err| switch (err) {
            error.InferenceUnavailable => return sendJson(stream, "503 Service Unavailable", "{\"error\":\"Narrative inference is unavailable\"}"),
            error.ModelProfileNotFound => return sendJson(stream, "409 Conflict", "{\"error\":\"Story model profile is missing\"}"),
            error.EmptyProse => return badRequest(stream, "Chapter has no prose to extract"),
            error.NodeNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Chapter or scene not found\"}"),
            error.DocumentationExtractionContractViolation => return sendJson(stream, "422 Unprocessable Content", "{\"error\":\"Documentation extractor returned an invalid update\"}"),
            error.StaleRevision => return sendJson(stream, "409 Conflict", "{\"error\":\"A story document changed during extraction; retry against the latest revision\"}"),
            else => return self.internalError(stream, err),
        };
        return sendJson(stream, "200 OK", "{\"status\":\"complete\"}");
    }

    fn applyProsePatch(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        node_id: []const u8,
        body: []const u8,
    ) !void {
        const PatchBody = struct {
            base_revision_id: ?[]const u8 = null,
            operation: []const u8,
            anchor_block_id: ?[]const u8 = null,
            end_anchor_block_id: ?[]const u8 = null,
            text: ?[]const u8 = null,
            block_type: []const u8 = "paragraph",
            author_source: []const u8 = "user",
        };
        var parsed = std.json.parseFromSlice(PatchBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid prose patch JSON");
        defer parsed.deinit();
        var document = self.service.applyProsePatch(story_id, node_id, .{
            .base_revision_id = parsed.value.base_revision_id,
            .operation = parsed.value.operation,
            .anchor_block_id = parsed.value.anchor_block_id,
            .end_anchor_block_id = parsed.value.end_anchor_block_id,
            .text = parsed.value.text,
            .block_type = parsed.value.block_type,
            .author_source = parsed.value.author_source,
        }) catch |err| switch (err) {
            error.InvalidOperation => return badRequest(stream, "Invalid prose operation"),
            error.InvalidBlockType => return badRequest(stream, "Invalid prose block type"),
            error.MissingText => return badRequest(stream, "This operation requires text"),
            error.EmptyPatch => return badRequest(stream, "Prose text cannot be empty"),
            error.MissingAnchor => return badRequest(stream, "This operation requires an anchor block"),
            error.MissingEndAnchor => return badRequest(stream, "This operation requires an ending anchor block"),
            error.AnchorNotFound => return sendJson(stream, "409 Conflict", "{\"error\":\"Anchor block is not in the base revision\"}"),
            error.StaleRevision => return sendJson(stream, "409 Conflict", "{\"error\":\"Stale prose revision\"}"),
            error.NodeNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Chapter or scene not found\"}"),
            else => return self.internalError(stream, err),
        };
        defer document.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, document, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn listAuthorMessages(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
    ) !void {
        const messages = self.service.listAuthorMessages(story_id) catch |err|
            return self.internalError(stream, err);
        defer {
            for (messages) |*message| message.deinit(self.allocator);
            self.allocator.free(messages);
        }
        const encoded = std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .messages = messages },
            .{},
        ) catch return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn authorTurn(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        body: []const u8,
    ) !void {
        const TurnBody = struct {
            message: []const u8,
            model_override: ?[]const u8 = null,
        };
        var parsed = std.json.parseFromSlice(TurnBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid Author Room JSON");
        defer parsed.deinit();
        var message = self.service.authorTurn(
            story_id,
            parsed.value.message,
            parsed.value.model_override,
        ) catch |err| switch (err) {
            error.EmptyMessage => return badRequest(stream, "Message cannot be empty"),
            error.StoryNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Story not found\"}"),
            error.InferenceUnavailable => return sendJson(stream, "503 Service Unavailable", "{\"error\":\"Narrative inference is unavailable\"}"),
            else => return self.internalError(stream, err),
        };
        defer message.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, message, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn listDiscoveryMessages(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
    ) !void {
        const messages = self.service.listDiscoveryMessages(story_id) catch |err|
            return self.internalError(stream, err);
        defer {
            for (messages) |*message| message.deinit(self.allocator);
            self.allocator.free(messages);
        }
        const encoded = std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .messages = messages },
            .{},
        ) catch return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn listDiscoveryProposals(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
    ) !void {
        const proposals = self.service.listDiscoveryProposals(story_id) catch |err|
            return self.internalError(stream, err);
        defer {
            for (proposals) |*proposal| proposal.deinit(self.allocator);
            self.allocator.free(proposals);
        }
        const encoded = std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .proposals = proposals },
            .{},
        ) catch return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn listDiscoveryDocumentChanges(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
    ) !void {
        const changes = self.service.listDiscoveryDocumentChanges(story_id) catch |err|
            return self.internalError(stream, err);
        defer {
            for (changes) |*change| change.deinit(self.allocator);
            self.allocator.free(changes);
        }
        const encoded = std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .changes = changes },
            .{},
        ) catch return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn discoveryTurn(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        body: []const u8,
    ) !void {
        const TurnBody = struct { message: []const u8 };
        var parsed = std.json.parseFromSlice(TurnBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid discovery JSON");
        defer parsed.deinit();
        var message = self.service.discoveryTurn(story_id, parsed.value.message) catch |err| switch (err) {
            error.EmptyMessage => return badRequest(stream, "Discovery answer cannot be empty"),
            error.StoryNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Story not found\"}"),
            error.DiscoveryContractViolation => return sendJson(stream, "422 Unprocessable Content", "{\"error\":\"Discovery model did not finish with the required structured turn\"}"),
            error.InferenceUnavailable => return sendJson(stream, "503 Service Unavailable", "{\"error\":\"Narrative inference is unavailable\"}"),
            else => return self.internalError(stream, err),
        };
        defer message.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, message, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn quickstartArchitect(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        body: []const u8,
    ) !void {
        const QuickstartBody = struct { premise: []const u8 };
        var parsed = std.json.parseFromSlice(QuickstartBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid Quickstart JSON");
        defer parsed.deinit();
        var message = self.service.quickstartArchitect(story_id, parsed.value.premise) catch |err| switch (err) {
            error.EmptyPremise => return badRequest(stream, "Quickstart needs a basic premise"),
            error.PremiseTooLarge => return sendJson(stream, "413 Payload Too Large", "{\"error\":\"Premise exceeds 16 KiB\"}"),
            error.StoryNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Story not found\"}"),
            error.QuickstartContractViolation => return sendJson(stream, "422 Unprocessable Content", "{\"error\":\"Architect did not produce all 19 complete documents with the required character, relationship, and beat-interaction depth; no partial foundation was saved\"}"),
            error.InferenceUnavailable => return sendJson(stream, "503 Service Unavailable", "{\"error\":\"Narrative inference is unavailable\"}"),
            else => return self.internalError(stream, err),
        };
        defer message.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, message, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "201 Created", encoded);
    }

    fn acceptQuickstartFoundation(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
    ) !void {
        var result = self.service.acceptQuickstartFoundation(story_id) catch |err| switch (err) {
            error.StoryNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Story not found\"}"),
            error.StaleRevision => return sendJson(stream, "409 Conflict", "{\"error\":\"A document changed during approval; review the current revisions\"}"),
            else => return self.internalError(stream, err),
        };
        defer result.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn analyzeImportedSources(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        body: []const u8,
    ) !void {
        const ImportBody = struct { source_bundle: []const u8 };
        var parsed = std.json.parseFromSlice(ImportBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid import JSON");
        defer parsed.deinit();
        var proposal = self.service.analyzeImportedSources(
            story_id,
            parsed.value.source_bundle,
        ) catch |err| switch (err) {
            error.EmptyImport => return badRequest(stream, "Import source bundle is empty"),
            error.ImportTooLarge => return sendJson(stream, "413 Payload Too Large", "{\"error\":\"Import source bundle exceeds 2 MiB\"}"),
            error.StoryNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Story not found\"}"),
            error.ImportContractViolation => return sendJson(stream, "422 Unprocessable Content", "{\"error\":\"Import model did not return a valid typed reconstruction\"}"),
            error.InferenceUnavailable => return sendJson(stream, "503 Service Unavailable", "{\"error\":\"Narrative inference is unavailable\"}"),
            else => return self.internalError(stream, err),
        };
        defer proposal.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, proposal, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "201 Created", encoded);
    }

    fn indexImportedSources(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        body: []const u8,
    ) !void {
        const ImportBody = struct { source_bundle: []const u8 };
        var parsed = std.json.parseFromSlice(ImportBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid import JSON");
        defer parsed.deinit();
        const job_id = self.service.indexImportedSources(
            story_id,
            parsed.value.source_bundle,
        ) catch |err| switch (err) {
            error.EmptyImport => return badRequest(stream, "Import source bundle is empty"),
            error.ImportTooLarge => return sendJson(stream, "413 Payload Too Large", "{\"error\":\"Import source bundle exceeds 2 MiB\"}"),
            error.StoryNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Story not found\"}"),
            else => return self.internalError(stream, err),
        };
        defer self.allocator.free(job_id);
        const encoded = std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .job_id = job_id, .status = "completed" },
            .{},
        ) catch return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "201 Created", encoded);
    }

    fn listImportSources(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
    ) !void {
        const sources = self.service.listImportSources(story_id) catch |err|
            return self.internalError(stream, err);
        defer {
            for (sources) |*source| source.deinit(self.allocator);
            self.allocator.free(sources);
        }
        const encoded = std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .sources = sources },
            .{},
        ) catch return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn decideDiscoveryProposal(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        proposal_id: []const u8,
        accept: bool,
    ) !void {
        var proposal = self.service.decideDiscoveryProposal(
            story_id,
            proposal_id,
            accept,
        ) catch |err| switch (err) {
            error.ProposalNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Proposal not found\"}"),
            error.ProposalNotPending => return sendJson(stream, "409 Conflict", "{\"error\":\"Proposal was already decided\"}"),
            error.StaleRevision => return sendJson(stream, "409 Conflict", "{\"error\":\"A target document changed; review the proposal again\"}"),
            else => return self.internalError(stream, err),
        };
        defer proposal.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, proposal, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn decideDiscoveryDocumentChange(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        change_id: []const u8,
        accept: bool,
    ) !void {
        var change = self.service.decideDiscoveryDocumentChange(
            story_id,
            change_id,
            accept,
        ) catch |err| switch (err) {
            error.ProposalNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Document change not found\"}"),
            error.ProposalNotPending => return sendJson(stream, "409 Conflict", "{\"error\":\"A newer revision replaced this document change\"}"),
            error.StaleRevision => return sendJson(stream, "409 Conflict", "{\"error\":\"The accepted document changed; review this revision again\"}"),
            else => return self.internalError(stream, err),
        };
        defer change.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, change, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn listJobs(self: *Controller, stream: common.net.Stream, story_id: []const u8) !void {
        const jobs = self.service.listJobs(story_id) catch |err|
            return self.internalError(stream, err);
        defer {
            for (jobs) |*job| job.deinit(self.allocator);
            self.allocator.free(jobs);
        }
        const encoded = std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .jobs = jobs },
            .{},
        ) catch return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn createWriterJob(
        self: *Controller,
        stream: common.net.Stream,
        story_id: []const u8,
        body: []const u8,
    ) !void {
        const CreateBody = struct {
            node_id: []const u8,
            mode: []const u8 = "continue",
            instruction: []const u8 = "",
        };
        var parsed = std.json.parseFromSlice(CreateBody, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return badRequest(stream, "Invalid writer job JSON");
        defer parsed.deinit();
        if (!isUuid(parsed.value.node_id)) return badRequest(stream, "Invalid node ID");
        if (!std.mem.eql(u8, parsed.value.mode, "continue") and
            !std.mem.eql(u8, parsed.value.mode, "rewrite") and
            !std.mem.eql(u8, parsed.value.mode, "revise"))
            return badRequest(stream, "Invalid writer mode");
        if (parsed.value.instruction.len > 4_000)
            return badRequest(stream, "Revision instruction is too long");
        var job = self.service.createWriterJob(
            story_id,
            parsed.value.node_id,
            parsed.value.mode,
            parsed.value.instruction,
        ) catch |err| switch (err) {
            error.StoryNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Story not found\"}"),
            error.NodeNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Chapter or scene not found\"}"),
            else => return self.internalError(stream, err),
        };
        defer job.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, job, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "201 Created", encoded);
    }

    fn runWriterPass(self: *Controller, stream: common.net.Stream, job_id: []const u8) !void {
        var job = self.service.runWriterPass(job_id) catch |err| switch (err) {
            error.JobNotFound => return sendJson(stream, "404 Not Found", "{\"error\":\"Authoring job not found\"}"),
            error.JobNotRunnable => return sendJson(stream, "409 Conflict", "{\"error\":\"Authoring job is already running\"}"),
            error.PassLimitReached => return sendJson(stream, "409 Conflict", "{\"error\":\"Authoring job reached its pass limit and paused\"}"),
            error.WriterContractViolation => return sendJson(stream, "422 Unprocessable Content", "{\"error\":\"Writer did not use the required terminal tool; job paused\"}"),
            error.WriterPatchTooLarge => return sendJson(stream, "422 Unprocessable Content", "{\"error\":\"Writer passage exceeded the scoped patch limit; job paused\"}"),
            error.WriterQualityViolation => return sendJson(stream, "422 Unprocessable Content", "{\"error\":\"Writer passage failed the fiction readability gate; job paused without changing prose\"}"),
            error.InferenceUnavailable => return sendJson(stream, "503 Service Unavailable", "{\"error\":\"Narrative inference is unavailable\"}"),
            else => return self.internalError(stream, err),
        };
        defer job.deinit(self.allocator);
        const encoded = std.json.Stringify.valueAlloc(self.allocator, job, .{}) catch
            return self.internalError(stream, error.OutOfMemory);
        defer self.allocator.free(encoded);
        return sendJson(stream, "200 OK", encoded);
    }

    fn internalError(self: *Controller, stream: common.net.Stream, err: anyerror) !void {
        _ = self;
        std.log.err("Narrative HTTP error: {}", .{err});
        return sendJson(stream, "500 Internal Server Error", "{\"error\":\"Narrative request failed\"}");
    }
};

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |character, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (character != '-') return false;
            continue;
        }
        if (!std.ascii.isHex(character)) return false;
    }
    return true;
}

fn badRequest(stream: common.net.Stream, message: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const encoded = std.fmt.bufPrint(&buffer, "{{\"error\":\"{s}\"}}", .{message}) catch
        "{\"error\":\"Bad request\"}";
    return sendJson(stream, "400 Bad Request", encoded);
}

fn methodNotAllowed(stream: common.net.Stream) !void {
    return sendJson(stream, "405 Method Not Allowed", "{\"error\":\"Method not allowed\"}");
}

fn sendJson(stream: common.net.Stream, status: []const u8, body: []const u8) !void {
    return send(stream, status, "application/json; charset=utf-8", body);
}

fn send(
    stream: common.net.Stream,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buffer,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Allow-Methods: GET, POST, PUT, PATCH, OPTIONS\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    try stream.writeAll(header);
    try stream.writeAll(body);
}

test "Narrative UUID validation" {
    try std.testing.expect(isUuid("12345678-1234-4234-8234-123456789abc"));
    try std.testing.expect(!isUuid("not-a-uuid"));
}
