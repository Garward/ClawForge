const std = @import("std");
const api = @import("api");
const storage = @import("storage");

/// Assembled context for a prompt — combines project state with session history.
pub const PromptContext = struct {
    /// Project rolling summary (narrative of where things stand)
    project_summary: ?[]const u8,
    /// Project rolling state (structured JSON)
    project_state: ?[]const u8,
    /// Project name for display
    project_name: ?[]const u8,
};

/// Load project context for the active session, if attached to a project.
pub fn loadProjectContext(
    project_store: *storage.ProjectStore,
    session_id: []const u8,
) !PromptContext {
    const project_id = (try project_store.getSessionProject(session_id)) orelse {
        return .{ .project_summary = null, .project_state = null, .project_name = null };
    };

    const ctx = try project_store.getRollingContext(project_id);
    const project = project_store.getProject(project_id) catch {
        return .{ .project_summary = ctx.summary, .project_state = ctx.state, .project_name = null };
    };

    return .{
        .project_summary = ctx.summary,
        .project_state = ctx.state,
        .project_name = project.name,
    };
}

/// Build a context injection string for the system prompt.
/// Returns null if no project context is available.
pub fn buildContextInjection(allocator: std.mem.Allocator, ctx: PromptContext) !?[]const u8 {
    if (ctx.project_summary == null and ctx.project_state == null) return null;

    var buf: [8192]u8 = undefined;
    var pos: usize = 0;

    const write = struct {
        fn f(b: []u8, p: *usize, data: []const u8) void {
            const len = @min(data.len, b.len - p.*);
            @memcpy(b[p.*..][0..len], data[0..len]);
            p.* += len;
        }
    }.f;

    write(&buf, &pos, "\n\n--- Project Context ---\n");

    if (ctx.project_name) |name| {
        write(&buf, &pos, "Project: ");
        write(&buf, &pos, name);
        write(&buf, &pos, "\n");
    }

    if (ctx.project_summary) |summary| {
        write(&buf, &pos, "\nCurrent state:\n");
        write(&buf, &pos, summary);
        write(&buf, &pos, "\n");
    }

    if (ctx.project_state) |state| {
        if (state.len > 2) {
            write(&buf, &pos, "\nStructured state:\n");
            write(&buf, &pos, state);
            write(&buf, &pos, "\n");
        }
    }

    write(&buf, &pos, "--- End Project Context ---");

    return try allocator.dupe(u8, buf[0..pos]);
}

// ================================================================
// SESSION CONTEXT COMPACTION
//
// When a session has too many messages for the context window,
// older messages are replaced with their summaries. Recent messages
// are kept verbatim so the LLM has full fidelity on the current exchange.
//
// Budget logic:
//   total messages <= compact_threshold → use all raw messages
//   total messages > compact_threshold → summary of older + recent N raw
//
// The summary comes from the summaries table (Phase 8).
// If no summary exists yet, we truncate the oldest messages.
// ================================================================

/// Configuration for context compaction.
pub const CompactConfig = struct {
    /// Max estimated context chars before compaction kicks in.
    /// Uses actual content length, not message count.
    /// 200K chars ≈ 50K tokens — high enough to avoid mid-coding compaction.
    compact_threshold: usize = 200000,
    /// Number of recent messages to keep verbatim when compacting.
    recent_window: usize = 20,
    /// Estimated chars per token (for rough budget calculations).
    chars_per_token: usize = 4,
    /// Max total chars for conversation context (messages portion only).
    max_context_chars: usize = 100000, // ~25k tokens
};

/// Build API messages with automatic compaction.
/// If the session is short, returns all messages.
/// If long, injects summary of older messages + recent raw messages.
///
/// Public API — callable by engine, adapters, automation.
pub fn buildCompactedMessages(
    allocator: std.mem.Allocator,
    message_store: *storage.MessageStore,
    summary_store: ?*storage.SummaryStore,
    session_id: []const u8,
    compact_config: CompactConfig,
) ![]const api.messages.Message {
    // Use API-visible content size so stored tool XML does not distort compaction decisions.
    const total_chars = try message_store.totalApiVisibleContentLength(session_id);

    if (total_chars <= compact_config.compact_threshold and total_chars <= compact_config.max_context_chars) {
        // Small session — use all raw messages (no compaction needed)
        return try message_store.buildApiMessages(session_id);
    }

    // Long session — compact older messages into summary + keep recent raw

    // Get latest session summary (if available)
    var summary_text: ?[]const u8 = null;
    if (summary_store) |ss| {
        if (try ss.getLatestSessionSummary(session_id)) |summary| {
            summary_text = summary.summary;
        }
    }

    // Get recent messages
    if (summary_text == null) {
        // No summary available — fall back to a hard-capped recent window rather than resending huge history.
        return try message_store.buildApiMessagesRecentBudgeted(
            session_id,
            compact_config.recent_window,
            compact_config.max_context_chars,
        );
    }

    // Reserve room for the injected summary and bridge text before picking raw recent messages.
    const summary_budget = @min(summary_text.?.len + 64, compact_config.max_context_chars / 3);
    const bridge_budget: usize = 128;
    const recent_budget = if (compact_config.max_context_chars > summary_budget + bridge_budget)
        compact_config.max_context_chars - summary_budget - bridge_budget
    else
        compact_config.max_context_chars / 2;

    const recent = try message_store.buildApiMessagesRecentBudgeted(
        session_id,
        compact_config.recent_window,
        recent_budget,
    );

    // Build compacted message list:
    // [0] system-injected summary of older context (as a user message)
    // [1..N] recent raw messages
    const compacted = try allocator.alloc(api.messages.Message, recent.len + 1);

    // Create summary message
    var summary_buf: [16384]u8 = undefined;
    var pos: usize = 0;
    const write = struct {
        fn f(b: []u8, p: *usize, data: []const u8) void {
            const len = @min(data.len, b.len -| p.*);
            @memcpy(b[p.*..][0..len], data[0..len]);
            p.* += len;
        }
    }.f;

    write(&summary_buf, &pos, "[Earlier conversation summary — older messages compacted]\n\n");
    write(&summary_buf, &pos, summary_text.?);

    const summary_content = try allocator.alloc(api.messages.ContentBlock, 1);
    summary_content[0] = .{ .text = .{ .text = try allocator.dupe(u8, summary_buf[0..pos]) } };

    compacted[0] = .{
        .role = .user,
        .content = summary_content,
    };

    // Copy recent messages after the summary
    @memcpy(compacted[1..][0..recent.len], recent);

    // If recent messages start with user, the summary (also user) creates
    // consecutive same-role. Insert a placeholder assistant message between.
    if (recent.len > 0 and recent[0].role == .user) {
        const with_bridge = try allocator.alloc(api.messages.Message, recent.len + 2);
        with_bridge[0] = compacted[0]; // summary (user)
        const bridge_content = try allocator.alloc(api.messages.ContentBlock, 1);
        bridge_content[0] = .{ .text = .{ .text = "[Acknowledged — continuing from prior context.]" } };
        with_bridge[1] = .{ .role = .assistant, .content = bridge_content };
        @memcpy(with_bridge[2..][0..recent.len], recent);
        return with_bridge;
    }

    return compacted;
}
