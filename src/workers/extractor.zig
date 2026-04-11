const std = @import("std");
const api = @import("api");
const storage = @import("storage");

/// Knowledge extraction worker. Distills reusable insights from summaries.
///
/// Public API callable by engine hooks, adapters, or background workers.
///
/// Flow: summaries (cheap to read) → haiku extracts insights → dedup → store/reinforce
/// This is the automated version of MO2Veteran's hand-curated knowledge files.
pub const Extractor = struct {
    allocator: std.mem.Allocator,
    client: *api.AnthropicClient,
    summary_store: *storage.SummaryStore,
    knowledge_store: *storage.KnowledgeStore,
    /// Model for extraction (cheap — haiku).
    model: []const u8 = "claude-haiku-4-5-20251001",

    pub fn init(
        allocator: std.mem.Allocator,
        client: *api.AnthropicClient,
        summary_store: *storage.SummaryStore,
        knowledge_store: *storage.KnowledgeStore,
    ) Extractor {
        return .{
            .allocator = allocator,
            .client = client,
            .summary_store = summary_store,
            .knowledge_store = knowledge_store,
        };
    }

    // ================================================================
    // PUBLIC API — callable by engine, adapters, automation, cron
    // ================================================================

    /// Extract knowledge from recent session summaries.
    /// Reads summaries created since `since_timestamp`, calls haiku to extract
    /// insights, dedup-checks against existing knowledge, inserts or reinforces.
    pub fn extractFromRecentSummaries(self: *Extractor, session_id: []const u8, since: ?i64) !usize {
        const summaries = try self.summary_store.getSessionSummaries(session_id);
        if (summaries.len == 0) return 0;

        _ = since;

        // Build input from summaries
        var input_buf: [16384]u8 = undefined;
        var pos: usize = 0;

        const write = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                const len = @min(data.len, b.len -| p.*);
                @memcpy(b[p.*..][0..len], data[0..len]);
                p.* += len;
            }
        }.f;

        for (summaries) |summary| {
            write(&input_buf, &pos, "--- Summary ---\n");
            write(&input_buf, &pos, summary.summary);
            if (summary.topics) |t| {
                write(&input_buf, &pos, "\nTopics: ");
                write(&input_buf, &pos, t);
            }
            if (summary.recall) |r| {
                write(&input_buf, &pos, "\nRecall: ");
                const r_len = @min(r.len, 500);
                write(&input_buf, &pos, r[0..r_len]);
            }
            write(&input_buf, &pos, "\n\n");
            if (pos > 12000) break; // Stay within token budget
        }

        if (pos < 50) return 0; // Not enough content

        // Call LLM for extraction
        const entries = try self.callExtractionModel(input_buf[0..pos]);

        // Process each extracted entry: dedup, insert or reinforce
        var inserted: usize = 0;
        for (entries) |entry| {
            // Check for existing similar knowledge
            const similar = self.knowledge_store.findSimilar(entry.title, 3) catch continue;

            if (similar.len > 0) {
                // Found similar — reinforce the best match
                self.knowledge_store.reinforce(similar[0].id, session_id) catch {};
                std.log.debug("Reinforced knowledge: {s}", .{similar[0].title});
            } else {
                // New knowledge — insert
                _ = self.knowledge_store.createEntry(.{
                    .category = entry.category,
                    .subcategory = entry.subcategory,
                    .title = entry.title,
                    .content = entry.content,
                    .confidence = entry.confidence,
                    .source_sessions = session_id,
                    .tags = entry.tags,
                }) catch continue;
                inserted += 1;
                std.log.info("Extracted knowledge: {s}", .{entry.title});
            }
        }

        return inserted;
    }

    /// Extract knowledge from a single conversation exchange.
    /// Lighter than full summary extraction — used for high-signal messages.
    pub fn extractFromExchange(
        self: *Extractor,
        session_id: []const u8,
        user_message: []const u8,
        assistant_response: []const u8,
    ) !usize {
        // Only extract from substantive exchanges
        if (user_message.len < 50 and assistant_response.len < 100) return 0;

        var input_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        const write = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                const len = @min(data.len, b.len -| p.*);
                @memcpy(b[p.*..][0..len], data[0..len]);
                p.* += len;
            }
        }.f;

        write(&input_buf, &pos, "User: ");
        const u_len = @min(user_message.len, 2000);
        write(&input_buf, &pos, user_message[0..u_len]);
        write(&input_buf, &pos, "\n\nAssistant: ");
        const a_len = @min(assistant_response.len, 3000);
        write(&input_buf, &pos, assistant_response[0..a_len]);

        const entries = try self.callExtractionModel(input_buf[0..pos]);

        var inserted: usize = 0;
        for (entries) |entry| {
            const similar = self.knowledge_store.findSimilar(entry.title, 3) catch continue;
            if (similar.len > 0) {
                self.knowledge_store.reinforce(similar[0].id, session_id) catch {};
            } else {
                _ = self.knowledge_store.createEntry(.{
                    .category = entry.category,
                    .subcategory = entry.subcategory,
                    .title = entry.title,
                    .content = entry.content,
                    .confidence = entry.confidence,
                    .source_sessions = session_id,
                    .tags = entry.tags,
                }) catch continue;
                inserted += 1;
            }
        }
        return inserted;
    }

    /// Run confidence decay on stale knowledge entries. Call periodically (daily).
    pub fn runDecay(self: *Extractor, days_threshold: i64) !usize {
        return try self.knowledge_store.applyDecay(days_threshold, 0.9);
    }

    // ================================================================
    // INTERNAL — LLM extraction call
    // ================================================================

    const ExtractedEntry = struct {
        category: []const u8,
        subcategory: ?[]const u8,
        title: []const u8,
        content: []const u8,
        confidence: f64,
        tags: ?[]const u8,
    };

    fn callExtractionModel(self: *Extractor, input: []const u8) ![]const ExtractedEntry {
        const system_prompt =
            \\Extract reusable knowledge from this conversation. Return a JSON array.
            \\Each entry: {"category","subcategory","title","content","confidence","tags"}
            \\
            \\Categories: "preference", "insight", "fact", "pattern", "decision", "technique"
            \\
            \\Only extract things that would be USEFUL TO RECALL in future conversations.
            \\Not every conversation has extractable knowledge — return [] if nothing is worth keeping.
            \\
            \\confidence: 0.5 = mentioned once casually, 0.8 = stated clearly, 1.0 = demonstrated/proven
            \\tags: JSON array of searchable keywords
            \\
            \\Examples:
            \\  {"category":"preference","subcategory":"coding","title":"Prefers composition over inheritance","content":"User explicitly stated preference for composition patterns over class hierarchies, citing maintainability.","confidence":0.9,"tags":["coding","design","oop"]}
            \\  {"category":"fact","subcategory":"system","title":"GPU is AMD 7900 XT","content":"System has AMD Radeon RX 7900 XT. Use ROCm, not CUDA. Vulkan preferred.","confidence":1.0,"tags":["hardware","gpu","amd"]}
            \\
            \\Keep titles under 60 chars. Content should include enough context to be useful standalone.
            \\Respond with ONLY the JSON array, no explanation.
        ;

        const content_block = try self.allocator.alloc(api.messages.ContentBlock, 1);
        content_block[0] = .{ .text = .{ .text = input } };
        const msgs = try self.allocator.alloc(api.messages.Message, 1);
        msgs[0] = .{ .role = .user, .content = content_block };

        const request = api.MessageRequest{
            .model = self.model,
            .max_tokens = 2048,
            .messages = msgs,
            .system = system_prompt,
            .tools = null,
            .stream = false,
        };

        const response = self.client.createMessage(&request, null) catch |err| {
            std.log.warn("Knowledge extraction LLM call failed: {}", .{err});
            return &.{};
        };

        return self.parseExtractionResponse(response.text_content);
    }

    fn parseExtractionResponse(self: *Extractor, text: []const u8) ![]const ExtractedEntry {
        // Parse JSON array of entries
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{
            .allocate = .alloc_always,
        }) catch return &.{};

        if (parsed.value != .array) return &.{};

        const items = parsed.value.array.items;
        const result = try self.allocator.alloc(ExtractedEntry, @min(items.len, 20));

        var count: usize = 0;
        for (items) |item| {
            if (item != .object) continue;
            if (count >= result.len) break;

            const obj = item.object;
            const category = if (obj.get("category")) |v| (if (v == .string) v.string else continue) else continue;
            const title = if (obj.get("title")) |v| (if (v == .string) v.string else continue) else continue;
            const content = if (obj.get("content")) |v| (if (v == .string) v.string else continue) else continue;

            result[count] = .{
                .category = category,
                .subcategory = if (obj.get("subcategory")) |v| (if (v == .string) v.string else null) else null,
                .title = title,
                .content = content,
                .confidence = if (obj.get("confidence")) |v| switch (v) {
                    .float => v.float,
                    .integer => @floatFromInt(v.integer),
                    else => 0.8,
                } else 0.8,
                .tags = if (obj.get("tags")) |_| null else null, // TODO: serialize tags array
            };
            count += 1;
        }

        return result[0..count];
    }
};
