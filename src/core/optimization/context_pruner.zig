const std = @import("std");
const storage = @import("storage");

/// Intelligent context pruning. Segments conversation history by topic,
/// scores each segment by relevance (recency, errors, tool use), and
/// marks low-value segments for summarization. Works with the existing
/// compaction pipeline — this adds smarter selection of *what* to compact.
pub const ContextPruner = struct {
    const SegmentType = enum {
        file_operation,
        tool_development,
        debugging,
        planning,
        conversation,
        meta,
    };

    const Segment = struct {
        start_idx: usize,
        end_idx: usize,
        char_count: usize,
        segment_type: SegmentType,
        relevance_score: f64,
        has_errors: bool,
        has_tools: bool,
    };

    allocator: std.mem.Allocator,
    message_store: *storage.MessageStore,
    /// Chars threshold before pruning is considered (~50K tokens at 4 chars/token)
    char_threshold: usize,
    /// Target fraction of chars to remove (0.3 = remove 30%)
    target_reduction: f64,

    pub fn init(
        allocator: std.mem.Allocator,
        message_store: *storage.MessageStore,
        char_threshold: usize,
        target_reduction: f64,
    ) ContextPruner {
        return .{
            .allocator = allocator,
            .message_store = message_store,
            .char_threshold = char_threshold,
            .target_reduction = target_reduction,
        };
    }

    pub fn shouldPrune(self: *ContextPruner, session_id: []const u8) bool {
        const total = self.message_store.totalApiVisibleContentLength(session_id) catch return false;
        return total > self.char_threshold;
    }

    /// Analyze a session and return indices of messages that are safe to summarize.
    /// Does NOT modify the message store — caller decides what to do with the result.
    pub fn identifyPrunableMessages(self: *ContextPruner, session_id: []const u8) ![]bool {
        const messages = try self.message_store.getFullHistory(session_id);
        if (messages.len < 5) return try self.allocator.alloc(bool, 0);

        // Segment messages by topic
        var segments: std.ArrayList(Segment) = .{};
        defer segments.deinit(self.allocator);
        self.segmentMessages(messages, &segments);

        // Score and select segments to prune
        return try self.calculatePruningPlan(segments.items, messages.len);
    }

    fn segmentMessages(self: *ContextPruner, messages: []const storage.MessageInfo, segments: *std.ArrayList(Segment)) void {
        if (messages.len == 0) return;

        var seg_start: usize = 0;
        var current_type = classifyMessage(messages[0].content);

        for (messages, 0..) |msg, i| {
            const msg_type = classifyMessage(msg.content);

            if (msg_type != current_type or i == messages.len - 1) {
                const end = if (i == messages.len - 1) i + 1 else i;
                if (end > seg_start) {
                    segments.append(self.allocator, self.createSegment(messages, seg_start, end, current_type)) catch {};
                }
                seg_start = i;
                current_type = msg_type;
            }
        }
    }

    fn classifyMessage(content: []const u8) SegmentType {
        if (std.mem.indexOf(u8, content, "file_write") != null or
            std.mem.indexOf(u8, content, "file_read") != null or
            std.mem.indexOf(u8, content, "file_diff") != null)
            return .file_operation;

        if (std.mem.indexOf(u8, content, "tool") != null and
            (std.mem.indexOf(u8, content, "register") != null or
            std.mem.indexOf(u8, content, "implement") != null))
            return .tool_development;

        if (std.mem.indexOf(u8, content, "error") != null or
            std.mem.indexOf(u8, content, "debug") != null or
            std.mem.indexOf(u8, content, "fix") != null)
            return .debugging;

        if (std.mem.indexOf(u8, content, "plan") != null or
            std.mem.indexOf(u8, content, "strategy") != null)
            return .planning;

        if (std.mem.indexOf(u8, content, "summary") != null or
            std.mem.indexOf(u8, content, "compaction") != null)
            return .meta;

        return .conversation;
    }

    fn createSegment(_: *ContextPruner, messages: []const storage.MessageInfo, start: usize, end: usize, seg_type: SegmentType) Segment {
        var char_count: usize = 0;
        var has_errors = false;
        var has_tools = false;

        for (messages[start..end]) |msg| {
            char_count += msg.content.len;
            if (std.mem.indexOf(u8, msg.content, "error") != null) has_errors = true;
            if (std.mem.indexOf(u8, msg.content, "<tool_call") != null) has_tools = true;
        }

        const total: f64 = @floatFromInt(messages.len);
        const avg_pos: f64 = @floatFromInt((start + end) / 2);
        const recency = avg_pos / total;

        var score: f64 = switch (seg_type) {
            .file_operation => 1.5,
            .tool_development => 1.3,
            .debugging => 1.0,
            .planning => 0.8,
            .conversation => 0.6,
            .meta => 0.3,
        };
        if (recency > 0.8) score *= 1.2; // Recent segments are more valuable
        if (has_errors) score *= 1.1;
        if (has_tools) score *= 1.1;

        return .{
            .start_idx = start,
            .end_idx = end,
            .char_count = char_count,
            .segment_type = seg_type,
            .relevance_score = score,
            .has_errors = has_errors,
            .has_tools = has_tools,
        };
    }

    fn calculatePruningPlan(self: *ContextPruner, segments: []const Segment, total_messages: usize) ![]bool {
        // Per-message boolean: true = safe to prune/summarize
        const plan = try self.allocator.alloc(bool, total_messages);
        @memset(plan, false);

        // Total chars across all segments
        var total_chars: usize = 0;
        for (segments) |seg| total_chars += seg.char_count;

        const target_remove: usize = @intFromFloat(@as(f64, @floatFromInt(total_chars)) * self.target_reduction);
        var removed: usize = 0;

        // Sort segment indices by relevance (lowest first = prune first)
        var indices: std.ArrayList(usize) = .{};
        defer indices.deinit(self.allocator);
        for (0..segments.len) |i| {
            try indices.append(self.allocator, i);
        }

        std.mem.sort(usize, indices.items, segments, struct {
            fn lessThan(ctx: []const Segment, a: usize, b: usize) bool {
                return ctx[a].relevance_score < ctx[b].relevance_score;
            }
        }.lessThan);

        for (indices.items) |idx| {
            if (removed >= target_remove) break;
            const seg = segments[idx];
            // Only prune low-relevance segments, never the most recent 20%
            if (seg.relevance_score < 1.0 and seg.end_idx < (total_messages * 4 / 5)) {
                for (seg.start_idx..seg.end_idx) |msg_idx| {
                    plan[msg_idx] = true;
                }
                removed += seg.char_count;
            }
        }

        return plan;
    }
};
