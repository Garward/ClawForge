const std = @import("std");
const db_mod = @import("db.zig");

/// Summary CRUD backed by SQLite. FTS sync handled by triggers.
pub const SummaryStore = struct {
    conn: *db_mod.Connection,
    allocator: std.mem.Allocator,
    namespace_id: i64,

    pub fn init(conn: *db_mod.Connection, allocator: std.mem.Allocator, namespace_id: i64) SummaryStore {
        return .{ .conn = conn, .allocator = allocator, .namespace_id = namespace_id };
    }

    /// Insert a new summary. Returns the summary id.
    pub fn createSummary(self: *SummaryStore, params: CreateParams) !i64 {
        var stmt = try self.conn.prepare(
            "INSERT INTO summaries (namespace_id, session_id, project_id, scope, granularity, " ++
                "start_message, end_message, start_time, end_time, message_count, " ++
                "summary, topics, final_state, continuation, recall, model_used, token_cost, created_at) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        );
        defer stmt.deinit();

        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindOptionalText(2, params.session_id);
        try stmt.bindOptionalInt64(3, params.project_id);
        try stmt.bindText(4, params.scope);
        try stmt.bindText(5, params.granularity);
        try stmt.bindOptionalInt64(6, params.start_message);
        try stmt.bindOptionalInt64(7, params.end_message);
        try stmt.bindInt64(8, params.start_time);
        try stmt.bindInt64(9, params.end_time);
        try stmt.bindInt(10, @intCast(params.message_count));
        try stmt.bindText(11, params.summary);
        try stmt.bindOptionalText(12, params.topics);
        try stmt.bindOptionalText(13, params.final_state);
        try stmt.bindOptionalText(14, params.continuation);
        try stmt.bindOptionalText(15, params.recall);
        try stmt.bindOptionalText(16, params.model_used);
        try stmt.bindOptionalInt64(17, params.token_cost);
        try stmt.bindInt64(18, std.time.timestamp());
        try stmt.exec();

        return self.conn.lastInsertRowId();
    }

    /// Get summaries for a session, ordered by time.
    pub fn getSessionSummaries(self: *SummaryStore, session_id: []const u8) ![]const SummaryInfo {
        var count_stmt = try self.conn.prepare(
            "SELECT COUNT(*) FROM summaries WHERE session_id = ?",
        );
        defer count_stmt.deinit();
        try count_stmt.bindText(1, session_id);
        _ = try count_stmt.step();
        const count: usize = @intCast(count_stmt.columnInt64(0));
        if (count == 0) return &.{};

        const result = try self.allocator.alloc(SummaryInfo, count);

        var stmt = try self.conn.prepare(
            "SELECT id, scope, granularity, message_count, summary, topics, final_state, continuation, recall, start_time, end_time " ++
                "FROM summaries WHERE session_id = ? ORDER BY start_time ASC",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);

        var i: usize = 0;
        while (try stmt.step()) {
            if (i >= count) break;
            result[i] = try self.readRow(&stmt);
            i += 1;
        }
        return result[0..i];
    }

    /// Get summaries for a project within a time range.
    pub fn getProjectSummaries(self: *SummaryStore, project_id: i64, since: ?i64) ![]const SummaryInfo {
        const since_time = since orelse 0;

        var count_stmt = try self.conn.prepare(
            "SELECT COUNT(*) FROM summaries WHERE project_id = ? AND end_time >= ?",
        );
        defer count_stmt.deinit();
        try count_stmt.bindInt64(1, project_id);
        try count_stmt.bindInt64(2, since_time);
        _ = try count_stmt.step();
        const count: usize = @intCast(count_stmt.columnInt64(0));
        if (count == 0) return &.{};

        const result = try self.allocator.alloc(SummaryInfo, count);

        var stmt = try self.conn.prepare(
            "SELECT id, scope, granularity, message_count, summary, topics, final_state, continuation, recall, start_time, end_time " ++
                "FROM summaries WHERE project_id = ? AND end_time >= ? ORDER BY end_time DESC",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, project_id);
        try stmt.bindInt64(2, since_time);

        var i: usize = 0;
        while (try stmt.step()) {
            if (i >= count) break;
            result[i] = try self.readRow(&stmt);
            i += 1;
        }
        return result[0..i];
    }

    /// Search summaries via FTS. Returns matching summaries ranked by relevance.
    pub fn searchSummaries(self: *SummaryStore, query: []const u8, limit: usize) ![]const SummaryInfo {
        const result = try self.allocator.alloc(SummaryInfo, limit);

        var stmt = try self.conn.prepare(
            "SELECT s.id, s.scope, s.granularity, s.message_count, s.summary, s.topics, s.final_state, s.continuation, s.recall, s.start_time, s.end_time " ++
                "FROM summaries_fts fts " ++
                "JOIN summaries s ON s.id = fts.rowid " ++
                "WHERE s.namespace_id = ? AND summaries_fts MATCH ? " ++
                "ORDER BY rank LIMIT ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindText(2, query);
        try stmt.bindInt64(3, @intCast(limit));

        var i: usize = 0;
        while (try stmt.step()) {
            if (i >= limit) break;
            result[i] = try self.readRow(&stmt);
            i += 1;
        }
        return result[0..i];
    }

    /// Get the latest summary for a session (for continuation context).
    pub fn getLatestSessionSummary(self: *SummaryStore, session_id: []const u8) !?SummaryInfo {
        var stmt = try self.conn.prepare(
            "SELECT id, scope, granularity, message_count, summary, topics, final_state, continuation, recall, start_time, end_time " ++
                "FROM summaries WHERE session_id = ? ORDER BY end_time DESC LIMIT 1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);

        if (try stmt.step()) {
            return try self.readRow(&stmt);
        }
        return null;
    }

    /// Get the summary that covers a specific message.
    /// Finds the nearest summary whose range includes the message.
    pub fn getSummaryForMessage(self: *SummaryStore, session_id: []const u8, message_id: i64) !?SummaryInfo {
        var stmt = try self.conn.prepare(
            "SELECT id, scope, granularity, message_count, summary, topics, final_state, continuation, recall, start_time, end_time " ++
                "FROM summaries WHERE session_id = ? AND start_message <= ? AND end_message >= ? " ++
                "ORDER BY end_time DESC LIMIT 1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindInt64(2, message_id);
        try stmt.bindInt64(3, message_id);

        if (try stmt.step()) {
            return try self.readRow(&stmt);
        }
        return null;
    }

    /// Get the message ID range that a summary covers.
    /// Used for drilling down: summary → raw messages.
    pub fn getSummaryRange(self: *SummaryStore, summary_id: i64) !?struct { session_id: []const u8, start: i64, end: i64 } {
        var stmt = try self.conn.prepare(
            "SELECT session_id, start_message, end_message FROM summaries WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, summary_id);

        if (try stmt.step()) {
            const sid = stmt.columnOptionalText(0);
            const start = stmt.columnOptionalInt64(1);
            const end_val = stmt.columnOptionalInt64(2);
            if (sid != null and start != null and end_val != null) {
                return .{
                    .session_id = try self.allocator.dupe(u8, sid.?),
                    .start = start.?,
                    .end = end_val.?,
                };
            }
        }
        return null;
    }

    /// Check if a session needs summarization (message count threshold).
    /// Check if session needs summarization based on unsummarized content size (chars).
    pub fn needsSummarization(self: *SummaryStore, session_id: []const u8, threshold: usize) !bool {
        // Get last summarized message for this session
        var stmt = try self.conn.prepare(
            "SELECT COALESCE(MAX(end_message), 0) FROM summaries WHERE session_id = ? AND scope = 'session'",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        _ = try stmt.step();
        const last_summarized = stmt.columnInt64(0);

        // Sum content length of unsummarized messages (token-based, not count-based)
        var size_stmt = try self.conn.prepare(
            "SELECT COALESCE(SUM(LENGTH(content)), 0) FROM messages WHERE session_id = ? AND id > ?",
        );
        defer size_stmt.deinit();
        try size_stmt.bindText(1, session_id);
        try size_stmt.bindInt64(2, last_summarized);
        _ = try size_stmt.step();
        const unsummarized_chars: usize = @intCast(size_stmt.columnInt64(0));

        return unsummarized_chars >= threshold;
    }

    fn readRow(self: *SummaryStore, stmt: *db_mod.Statement) !SummaryInfo {
        return .{
            .id = stmt.columnInt64(0),
            .scope = try self.allocator.dupe(u8, stmt.columnText(1) orelse "session"),
            .granularity = try self.allocator.dupe(u8, stmt.columnText(2) orelse "session"),
            .message_count = @intCast(stmt.columnInt64(3)),
            .summary = try self.allocator.dupe(u8, stmt.columnText(4) orelse ""),
            .topics = if (stmt.columnOptionalText(5)) |t| try self.allocator.dupe(u8, t) else null,
            .final_state = if (stmt.columnOptionalText(6)) |t| try self.allocator.dupe(u8, t) else null,
            .continuation = if (stmt.columnOptionalText(7)) |t| try self.allocator.dupe(u8, t) else null,
            .recall = if (stmt.columnOptionalText(8)) |t| try self.allocator.dupe(u8, t) else null,
            .start_time = stmt.columnInt64(9),
            .end_time = stmt.columnInt64(10),
        };
    }
};

pub const CreateParams = struct {
    session_id: ?[]const u8 = null,
    project_id: ?i64 = null,
    scope: []const u8, // "session", "daily", "weekly"
    granularity: []const u8, // "session", "daily", "weekly"
    start_message: ?i64 = null,
    end_message: ?i64 = null,
    start_time: i64,
    end_time: i64,
    message_count: usize,
    summary: []const u8,
    topics: ?[]const u8 = null,
    final_state: ?[]const u8 = null,
    continuation: ?[]const u8 = null,
    recall: ?[]const u8 = null,
    model_used: ?[]const u8 = null,
    token_cost: ?i64 = null,
};

pub const SummaryInfo = struct {
    id: i64,
    scope: []const u8,
    granularity: []const u8,
    message_count: usize,
    summary: []const u8,
    topics: ?[]const u8,
    final_state: ?[]const u8,
    continuation: ?[]const u8,
    recall: ?[]const u8,
    start_time: i64,
    end_time: i64,
};
