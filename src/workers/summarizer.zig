const std = @import("std");
const api = @import("api");
const storage = @import("storage");

/// Summarization worker. Generates multi-level summaries from conversations.
///
/// Public API methods are callable by the engine's post-response hooks,
/// by adapters, or by the future background worker thread (Phase 11).
///
/// Summary levels:
/// - Session: after N messages or session close. Most detailed.
/// - Daily: roll up session summaries for a project. Medium detail.
/// - Weekly: roll up dailies. Coarsest, only key decisions and outcomes.
pub const Summarizer = struct {
    allocator: std.mem.Allocator,
    client: *api.AnthropicClient,
    message_store: *storage.MessageStore,
    summary_store: *storage.SummaryStore,
    project_store: *storage.ProjectStore,

    /// How many unsummarized content chars trigger a session summary.
    /// 200K chars ≈ 50K tokens — high enough to avoid mid-coding interruptions.
    summary_threshold: usize = 200000,
    /// Model to use for summarization (cheap — haiku).
    summary_model: []const u8 = "claude-haiku-4-5-20251001",

    pub fn init(
        allocator: std.mem.Allocator,
        client: *api.AnthropicClient,
        message_store: *storage.MessageStore,
        summary_store: *storage.SummaryStore,
        project_store: *storage.ProjectStore,
    ) Summarizer {
        return .{
            .allocator = allocator,
            .client = client,
            .message_store = message_store,
            .summary_store = summary_store,
            .project_store = project_store,
        };
    }

    // ================================================================
    // PUBLIC API — callable by engine hooks, adapters, automation
    // ================================================================

    /// Check if a session needs summarization and do it if so.
    /// Called from post-response hooks. Cheap check, expensive action.
    pub fn maybeSummarizeSession(self: *Summarizer, session_id: []const u8) void {
        const needs_it = self.summary_store.needsSummarization(session_id, self.summary_threshold) catch |err| {
            std.log.warn("Summarization check failed: {}", .{err});
            return;
        };
        if (needs_it) {
            std.log.info("Compaction starting for session {s}...", .{session_id[0..8]});
            self.summarizeSession(session_id) catch |err| {
                std.log.warn("Summarization failed for session {s}: {}", .{ session_id, err });
                return;
            };
            std.log.info("Compaction complete for session {s}", .{session_id[0..8]});
        }
    }

    /// Force-summarize a session. Creates a session-level summary from messages
    /// that haven't been summarized yet.
    pub fn summarizeSession(self: *Summarizer, session_id: []const u8) !void {
        // Get messages to summarize
        const messages = try self.message_store.getRecentMessages(session_id, 200);
        if (messages.len < 3) return; // Not enough to summarize

        // Build the summarization prompt
        var prompt_buf: [32768]u8 = undefined;
        var pos: usize = 0;

        const write = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                const len = @min(data.len, b.len -| p.*);
                @memcpy(b[p.*..][0..len], data[0..len]);
                p.* += len;
            }
        }.f;

        // Build conversation transcript
        for (messages) |msg| {
            write(&prompt_buf, &pos, msg.role);
            write(&prompt_buf, &pos, ": ");
            // Truncate long messages to keep prompt reasonable
            const content_len = @min(msg.content.len, 500);
            write(&prompt_buf, &pos, msg.content[0..content_len]);
            if (msg.content.len > 500) write(&prompt_buf, &pos, "...[truncated]");
            write(&prompt_buf, &pos, "\n\n");
        }

        const transcript = prompt_buf[0..pos];

        // Call the LLM for summarization
        const result = try self.callSummarizationModel(transcript);

        // Store the summary
        const first_msg = messages[0];
        const last_msg = messages[messages.len - 1];

        _ = try self.summary_store.createSummary(.{
            .session_id = session_id,
            .project_id = try self.getSessionProjectId(session_id),
            .scope = "session",
            .granularity = "session",
            .start_message = first_msg.id,
            .end_message = last_msg.id,
            .start_time = first_msg.created_at,
            .end_time = last_msg.created_at,
            .message_count = messages.len,
            .summary = result.summary,
            .topics = result.topics,
            .final_state = result.final_state,
            .continuation = result.continuation,
            .recall = result.recall,
            .model_used = self.summary_model,
            .token_cost = result.token_cost,
        });

        // Update project rolling context if attached
        if (try self.getSessionProjectId(session_id)) |project_id| {
            try self.project_store.updateRollingContext(
                project_id,
                result.summary,
                null, // rolling_state updated separately
            );
            std.log.info("Updated rolling summary for project from session {s}", .{session_id});
        }

        std.log.info("Summarized session {s}: {d} messages", .{ session_id, messages.len });
    }

    /// Generate a rolling context update for a project.
    /// Called after each substantive prompt (from engine post-response hooks).
    /// Uses the last few messages + existing rolling summary to produce an updated summary.
    pub fn updateRollingContext(
        self: *Summarizer,
        project_id: i64,
        session_id: []const u8,
        user_message: []const u8,
        assistant_response: []const u8,
    ) !void {
        // Get existing rolling context
        const existing = self.project_store.getRollingContext(project_id) catch
            storage.RollingContext{ .summary = null, .state = null };

        // Build a compact update prompt
        var prompt_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        const write = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                const len = @min(data.len, b.len -| p.*);
                @memcpy(b[p.*..][0..len], data[0..len]);
                p.* += len;
            }
        }.f;

        if (existing.summary) |s| {
            write(&prompt_buf, &pos, "Previous state:\n");
            const s_len = @min(s.len, 2000);
            write(&prompt_buf, &pos, s[0..s_len]);
            write(&prompt_buf, &pos, "\n\n");
        }

        write(&prompt_buf, &pos, "Latest exchange:\nUser: ");
        const u_len = @min(user_message.len, 1000);
        write(&prompt_buf, &pos, user_message[0..u_len]);
        write(&prompt_buf, &pos, "\nAssistant: ");
        const a_len = @min(assistant_response.len, 1000);
        write(&prompt_buf, &pos, assistant_response[0..a_len]);

        const context = prompt_buf[0..pos];

        // Call model for update
        const updated = self.callRollingUpdateModel(context, session_id) catch |err| {
            std.log.debug("Rolling context update skipped: {}", .{err});
            return;
        };

        // Store updated context
        try self.project_store.updateRollingContext(project_id, updated.summary, null);
    }

    // ================================================================
    // INTERNAL — LLM calls for summarization
    // ================================================================

    const SummarizationResult = struct {
        summary: []const u8,
        topics: ?[]const u8,
        final_state: ?[]const u8,
        continuation: ?[]const u8,
        recall: ?[]const u8,
        token_cost: ?i64,
    };

    const RollingUpdateResult = struct {
        summary: []const u8,
    };

    fn callSummarizationModel(self: *Summarizer, transcript: []const u8) !SummarizationResult {
        const system_prompt =
            \\Summarize this conversation concisely. Respond with ONLY a JSON object:
            \\{
            \\  "summary": "narrative of what happened and where things stand",
            \\  "topics": ["topic1", "topic2"],
            \\  "final_state": "completed|WIP|blocked|abandoned",
            \\  "continuation": "what needs to happen next if resumed",
            \\  "recall": { /* any structured fields relevant to this conversation type */ }
            \\}
            \\
            \\The recall field is flexible — include whatever structured data would be
            \\useful to recall this conversation. For technical work: approaches_tried,
            \\key_discoveries, blockers. For planning: decisions, action_items.
            \\For casual chat: topics_enjoyed, mood. You decide what's relevant.
            \\Keep the summary under 300 words. Be specific, not vague.
        ;

        // Build messages array
        const content_block = try self.allocator.alloc(api.messages.ContentBlock, 1);
        content_block[0] = .{ .text = .{ .text = transcript } };
        const msgs = try self.allocator.alloc(api.messages.Message, 1);
        msgs[0] = .{ .role = .user, .content = content_block };

        const request = api.MessageRequest{
            .model = self.summary_model,
            .max_tokens = 1024,
            .messages = msgs,
            .system = system_prompt,
            .tools = null,
            .stream = false,
        };

        const response = try self.client.createMessage(&request, null);

        // Parse the JSON response
        const text = response.text_content;
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{
            .allocate = .alloc_always,
        }) catch {
            // If not valid JSON, use the raw text as summary
            return .{
                .summary = text,
                .topics = null,
                .final_state = null,
                .continuation = null,
                .recall = null,
                .token_cost = @as(?i64, @intCast(response.usage.input_tokens + response.usage.output_tokens)),
            };
        };

        const obj = parsed.value.object;
        return .{
            .summary = if (obj.get("summary")) |s| (if (s == .string) s.string else text) else text,
            .topics = if (obj.get("topics")) |t| blk: {
                // Serialize topics array back to JSON string
                var buf: [1024]u8 = undefined;
                var p: usize = 0;
                buf[p] = '[';
                p += 1;
                if (t == .array) {
                    for (t.array.items, 0..) |item, i| {
                        if (i > 0) { buf[p] = ','; p += 1; }
                        buf[p] = '"'; p += 1;
                        if (item == .string) {
                            const len = @min(item.string.len, 100);
                            @memcpy(buf[p..][0..len], item.string[0..len]);
                            p += len;
                        }
                        buf[p] = '"'; p += 1;
                    }
                }
                buf[p] = ']';
                p += 1;
                break :blk try self.allocator.dupe(u8, buf[0..p]);
            } else null,
            .final_state = if (obj.get("final_state")) |s| (if (s == .string) s.string else null) else null,
            .continuation = if (obj.get("continuation")) |s| (if (s == .string) s.string else null) else null,
            .recall = if (obj.get("recall")) |_| text else null, // Store full JSON as recall for now
            .token_cost = @as(?i64, @intCast(response.usage.input_tokens + response.usage.output_tokens)),
        };
    }

    fn callRollingUpdateModel(self: *Summarizer, context: []const u8, _: []const u8) !RollingUpdateResult {
        const system_prompt =
            \\You are updating a project's rolling summary. Given the previous state
            \\and the latest exchange, produce an updated summary that captures where
            \\things stand NOW. Keep it under 200 words. Be specific and actionable.
            \\Respond with ONLY the updated summary text, no JSON wrapping.
        ;

        const content_block = try self.allocator.alloc(api.messages.ContentBlock, 1);
        content_block[0] = .{ .text = .{ .text = context } };
        const msgs = try self.allocator.alloc(api.messages.Message, 1);
        msgs[0] = .{ .role = .user, .content = content_block };

        const request = api.MessageRequest{
            .model = self.summary_model,
            .max_tokens = 512,
            .messages = msgs,
            .system = system_prompt,
            .tools = null,
            .stream = false,
        };

        const response = try self.client.createMessage(&request, null);

        return .{ .summary = response.text_content };
    }

    fn getSessionProjectId(self: *Summarizer, session_id: []const u8) !?i64 {
        return try self.project_store.getSessionProject(session_id);
    }
};

/// Message info for summarization (lightweight, just what the summarizer needs).
pub const MessageInfo = struct {
    id: ?i64,
    role: []const u8,
    content: []const u8,
    created_at: i64,
};
