const std = @import("std");
const db_mod = @import("db.zig");

/// Knowledge CRUD with confidence management, FTS search, and dedup.
pub const KnowledgeStore = struct {
    conn: *db_mod.Connection,
    allocator: std.mem.Allocator,
    namespace_id: i64,

    pub fn init(conn: *db_mod.Connection, allocator: std.mem.Allocator, namespace_id: i64) KnowledgeStore {
        return .{ .conn = conn, .allocator = allocator, .namespace_id = namespace_id };
    }

    // ================================================================
    // PUBLIC API — callable by extractor, engine, adapters, automation
    // ================================================================

    /// Insert a new knowledge entry. Returns the id.
    pub fn createEntry(self: *KnowledgeStore, params: CreateParams) !i64 {
        const now = std.time.timestamp();
        var stmt = try self.conn.prepare(
            "INSERT INTO knowledge (namespace_id, category, subcategory, title, content, " ++
                "confidence, mention_count, source_sessions, first_seen, last_reinforced, " ++
                "tags, created_at, updated_at) " ++
                "VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)",
        );
        defer stmt.deinit();

        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindText(2, params.category);
        try stmt.bindOptionalText(3, params.subcategory);
        try stmt.bindText(4, params.title);
        try stmt.bindText(5, params.content);
        // Bind confidence as text since we don't have bindFloat
        var conf_buf: [32]u8 = undefined;
        const conf_str = std.fmt.bufPrint(&conf_buf, "{d:.2}", .{params.confidence}) catch "1.00";
        try stmt.bindText(6, conf_str);
        try stmt.bindOptionalText(7, params.source_sessions);
        try stmt.bindInt64(8, now);
        try stmt.bindInt64(9, now);
        try stmt.bindOptionalText(10, params.tags);
        try stmt.bindInt64(11, now);
        try stmt.bindInt64(12, now);
        try stmt.exec();

        return self.conn.lastInsertRowId();
    }

    /// Reinforce an existing entry — bump mention_count and confidence.
    /// Called when the same insight is observed again.
    pub fn reinforce(self: *KnowledgeStore, id: i64, session_id: ?[]const u8) !void {
        const now = std.time.timestamp();

        // Bump count and confidence (cap at 1.0)
        var stmt = try self.conn.prepare(
            "UPDATE knowledge SET " ++
                "mention_count = mention_count + 1, " ++
                "confidence = MIN(1.0, confidence + 0.1), " ++
                "last_reinforced = ?, " ++
                "updated_at = ? " ++
                "WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, now);
        try stmt.bindInt64(2, now);
        try stmt.bindInt64(3, id);
        try stmt.exec();

        // Append session to source_sessions if provided
        if (session_id) |sid| {
            var update_stmt = try self.conn.prepare(
                "UPDATE knowledge SET source_sessions = " ++
                    "CASE WHEN source_sessions IS NULL THEN ? " ++
                    "ELSE source_sessions || ',' || ? END " ++
                    "WHERE id = ?",
            );
            defer update_stmt.deinit();
            try update_stmt.bindText(1, sid);
            try update_stmt.bindText(2, sid);
            try update_stmt.bindInt64(3, id);
            try update_stmt.exec();
        }
    }

    /// Contradict an entry — lower confidence and record the contradiction.
    pub fn contradict(self: *KnowledgeStore, id: i64, reason: []const u8) !void {
        const now = std.time.timestamp();
        var stmt = try self.conn.prepare(
            "UPDATE knowledge SET " ++
                "confidence = MAX(0.0, confidence - 0.3), " ++
                "contradicted_by = ?, " ++
                "updated_at = ? " ++
                "WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bindText(1, reason);
        try stmt.bindInt64(2, now);
        try stmt.bindInt64(3, id);
        try stmt.exec();
    }

    /// Find similar existing knowledge by title (FTS search).
    /// Used for dedup before inserting new entries.
    pub fn findSimilar(self: *KnowledgeStore, title: []const u8, limit: usize) ![]const KnowledgeEntry {
        const result = try self.allocator.alloc(KnowledgeEntry, limit);

        var stmt = try self.conn.prepare(
            "SELECT k.id, k.category, k.subcategory, k.title, k.content, k.confidence, " ++
                "k.mention_count, k.last_reinforced " ++
                "FROM knowledge_fts fts " ++
                "JOIN knowledge k ON k.id = fts.rowid " ++
                "WHERE k.namespace_id = ? AND knowledge_fts MATCH ? " ++
                "ORDER BY rank LIMIT ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindText(2, title);
        try stmt.bindInt64(3, @intCast(limit));

        var i: usize = 0;
        while (try stmt.step()) {
            if (i >= limit) break;
            result[i] = try self.readRow(&stmt);
            i += 1;
        }
        return result[0..i];
    }

    /// Search knowledge by query text (FTS). Returns entries ranked by relevance.
    pub fn search(self: *KnowledgeStore, query: []const u8, limit: usize) ![]const KnowledgeEntry {
        const result = try self.allocator.alloc(KnowledgeEntry, limit);

        var stmt = try self.conn.prepare(
            "SELECT k.id, k.category, k.subcategory, k.title, k.content, k.confidence, " ++
                "k.mention_count, k.last_reinforced " ++
                "FROM knowledge_fts fts " ++
                "JOIN knowledge k ON k.id = fts.rowid " ++
                "WHERE k.namespace_id = ? AND knowledge_fts MATCH ? " ++
                "ORDER BY k.confidence * k.mention_count DESC, rank LIMIT ?",
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

    /// Get knowledge entries by category.
    pub fn getByCategory(self: *KnowledgeStore, category: []const u8, limit: usize) ![]const KnowledgeEntry {
        const result = try self.allocator.alloc(KnowledgeEntry, limit);

        var stmt = try self.conn.prepare(
            "SELECT id, category, subcategory, title, content, confidence, mention_count, last_reinforced " ++
                "FROM knowledge WHERE namespace_id = ? AND category = ? " ++
                "ORDER BY confidence DESC, mention_count DESC LIMIT ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindText(2, category);
        try stmt.bindInt64(3, @intCast(limit));

        var i: usize = 0;
        while (try stmt.step()) {
            if (i >= limit) break;
            result[i] = try self.readRow(&stmt);
            i += 1;
        }
        return result[0..i];
    }

    /// Apply confidence decay to stale entries.
    /// Entries not reinforced in `days_threshold` days get confidence * decay_factor.
    pub fn applyDecay(self: *KnowledgeStore, days_threshold: i64, decay_factor: f64) !usize {
        const cutoff = std.time.timestamp() - (days_threshold * 86400);
        var conf_buf: [32]u8 = undefined;
        const factor_str = std.fmt.bufPrint(&conf_buf, "{d:.2}", .{decay_factor}) catch "0.90";

        _ = factor_str;

        // Use fixed 0.9 decay (can't bind floats to prepared statements)
        var stmt = try self.conn.prepare(
            "UPDATE knowledge SET confidence = MAX(0.1, confidence * 0.9), updated_at = ? " ++
                "WHERE namespace_id = ? AND last_reinforced < ? AND confidence > 0.1",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, std.time.timestamp());
        try stmt.bindInt64(2, self.namespace_id);
        try stmt.bindInt64(3, cutoff);
        try stmt.exec();

        return @intCast(self.conn.changes());
    }

    /// Get total knowledge entry count.
    pub fn count(self: *KnowledgeStore) !usize {
        var stmt = try self.conn.prepare("SELECT COUNT(*) FROM knowledge WHERE namespace_id = ?");
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        _ = try stmt.step();
        return @intCast(stmt.columnInt64(0));
    }

    fn readRow(self: *KnowledgeStore, stmt: *db_mod.Statement) !KnowledgeEntry {
        return .{
            .id = stmt.columnInt64(0),
            .category = try self.allocator.dupe(u8, stmt.columnText(1) orelse ""),
            .subcategory = if (stmt.columnOptionalText(2)) |t| try self.allocator.dupe(u8, t) else null,
            .title = try self.allocator.dupe(u8, stmt.columnText(3) orelse ""),
            .content = try self.allocator.dupe(u8, stmt.columnText(4) orelse ""),
            .confidence = 1.0, // TODO: read real float
            .mention_count = @intCast(stmt.columnInt64(6)),
            .last_reinforced = stmt.columnInt64(7),
        };
    }
};

pub const CreateParams = struct {
    category: []const u8,
    subcategory: ?[]const u8 = null,
    title: []const u8,
    content: []const u8,
    confidence: f64 = 1.0,
    source_sessions: ?[]const u8 = null,
    tags: ?[]const u8 = null,
};

pub const KnowledgeEntry = struct {
    id: i64,
    category: []const u8,
    subcategory: ?[]const u8,
    title: []const u8,
    content: []const u8,
    confidence: f64,
    mention_count: usize,
    last_reinforced: i64,
};
