const std = @import("std");
const storage = @import("storage");

/// Hybrid search: FTS5 keyword + vector semantic, merged via Reciprocal Rank Fusion.
///
/// Neither search alone is sufficient:
///   FTS catches exact terms (error codes, names, identifiers)
///   Vectors catch meaning ("what keeps me engaged" ≈ "progression systems")
///
/// Public API callable by engine, prompt assembler, adapters.
pub const HybridSearch = struct {
    allocator: std.mem.Allocator,
    conn: *storage.Connection,
    embedding_store: *storage.EmbeddingStore,
    namespace_id: i64,
    /// RRF constant (default 60, standard in literature)
    rrf_k: f32 = 60.0,

    pub fn init(
        allocator: std.mem.Allocator,
        conn: *storage.Connection,
        embedding_store: *storage.EmbeddingStore,
        namespace_id: i64,
    ) HybridSearch {
        return .{
            .allocator = allocator,
            .conn = conn,
            .embedding_store = embedding_store,
            .namespace_id = namespace_id,
        };
    }

    // ================================================================
    // PUBLIC API
    // ================================================================

    /// Search across all content types using hybrid FTS + vector search.
    /// query_text: the search query string
    /// query_vector: optional pre-computed embedding (pass null to skip vector search)
    /// limit: max results
    pub fn search(
        self: *HybridSearch,
        query_text: []const u8,
        query_vector: ?[]const f32,
        limit: usize,
    ) ![]const HybridResult {
        // Run both search paths
        const fts_results = try self.ftsSearch(query_text, limit * 2);
        const vec_results = if (query_vector) |qv|
            try self.embedding_store.vectorSearch(qv, 100, limit * 2)
        else
            &[_]storage.embeddings.SearchResult{};

        // Merge via Reciprocal Rank Fusion
        return try self.mergeRRF(fts_results, vec_results, limit);
    }

    /// Search only messages via FTS.
    pub fn searchMessages(self: *HybridSearch, query: []const u8, limit: usize) ![]const FtsResult {
        return try self.ftsSearchTable("messages_fts", "messages", query, limit);
    }

    /// Search only summaries via FTS.
    pub fn searchSummaries(self: *HybridSearch, query: []const u8, limit: usize) ![]const FtsResult {
        return try self.ftsSearchTable("summaries_fts", "summaries", query, limit);
    }

    /// Search only knowledge via FTS.
    pub fn searchKnowledge(self: *HybridSearch, query: []const u8, limit: usize) ![]const FtsResult {
        return try self.ftsSearchTable("knowledge_fts", "knowledge", query, limit);
    }

    // ================================================================
    // INTERNAL — FTS search across all tables
    // ================================================================

    fn ftsSearch(self: *HybridSearch, query: []const u8, limit: usize) ![]const RankedItem {
        var items_buf: [256]RankedItem = undefined;
        var item_count: usize = 0;

        // Search messages
        {
            var stmt = self.conn.prepare(
                "SELECT m.id, 'message' as type, m.content, rank " ++
                    "FROM messages_fts fts " ++
                    "JOIN messages m ON m.id = fts.rowid " ++
                    "JOIN sessions s ON s.id = m.session_id " ++
                    "WHERE s.namespace_id = ? AND messages_fts MATCH ? " ++
                    "ORDER BY rank LIMIT ?",
            ) catch return items_buf[0..0];
            defer stmt.deinit();
            stmt.bindInt64(1, self.namespace_id) catch return items_buf[0..0];
            stmt.bindText(2, query) catch return items_buf[0..0];
            stmt.bindInt64(3, @intCast(limit / 3)) catch return items_buf[0..0];

            while (stmt.step() catch false) {
                if (item_count >= items_buf.len) break;
                items_buf[item_count] = .{
                    .source_type = "message",
                    .source_id = stmt.columnInt64(0),
                    .text = self.allocator.dupe(u8, stmt.columnText(2) orelse "") catch "",
                    .fts_rank = item_count, // rank by position
                };
                item_count += 1;
            }
        }

        // Search summaries
        {
            var stmt = self.conn.prepare(
                "SELECT s.id, 'summary' as type, s.summary, rank " ++
                    "FROM summaries_fts fts " ++
                    "JOIN summaries s ON s.id = fts.rowid " ++
                    "WHERE s.namespace_id = ? AND summaries_fts MATCH ? " ++
                    "ORDER BY rank LIMIT ?",
            ) catch return items_buf[0..item_count];
            defer stmt.deinit();
            stmt.bindInt64(1, self.namespace_id) catch return items_buf[0..item_count];
            stmt.bindText(2, query) catch return items_buf[0..item_count];
            stmt.bindInt64(3, @intCast(limit / 3)) catch return items_buf[0..item_count];

            while (stmt.step() catch false) {
                if (item_count >= items_buf.len) break;
                items_buf[item_count] = .{
                    .source_type = "summary",
                    .source_id = stmt.columnInt64(0),
                    .text = self.allocator.dupe(u8, stmt.columnText(2) orelse "") catch "",
                    .fts_rank = item_count,
                };
                item_count += 1;
            }
        }

        // Search knowledge
        {
            var stmt = self.conn.prepare(
                "SELECT k.id, 'knowledge' as type, k.title || ': ' || k.content, rank " ++
                    "FROM knowledge_fts fts " ++
                    "JOIN knowledge k ON k.id = fts.rowid " ++
                    "WHERE k.namespace_id = ? AND knowledge_fts MATCH ? " ++
                    "ORDER BY rank LIMIT ?",
            ) catch return items_buf[0..item_count];
            defer stmt.deinit();
            stmt.bindInt64(1, self.namespace_id) catch return items_buf[0..item_count];
            stmt.bindText(2, query) catch return items_buf[0..item_count];
            stmt.bindInt64(3, @intCast(limit / 3)) catch return items_buf[0..item_count];

            while (stmt.step() catch false) {
                if (item_count >= items_buf.len) break;
                items_buf[item_count] = .{
                    .source_type = "knowledge",
                    .source_id = stmt.columnInt64(0),
                    .text = self.allocator.dupe(u8, stmt.columnText(2) orelse "") catch "",
                    .fts_rank = item_count,
                };
                item_count += 1;
            }
        }

        // Copy to heap
        if (item_count == 0) return &.{};
        const result = try self.allocator.alloc(RankedItem, item_count);
        @memcpy(result, items_buf[0..item_count]);
        return result;
    }

    fn ftsSearchTable(self: *HybridSearch, fts_table: []const u8, _: []const u8, query: []const u8, limit: usize) ![]const FtsResult {
        // Build query dynamically
        var query_buf: [512]u8 = undefined;
        const sql = std.fmt.bufPrint(&query_buf,
            "SELECT rowid, rank FROM {s} WHERE {s} MATCH ? ORDER BY rank LIMIT ?",
            .{ fts_table, fts_table },
        ) catch return &.{};

        var stmt = try self.conn.prepare(@ptrCast(sql.ptr));
        defer stmt.deinit();
        try stmt.bindText(1, query);
        try stmt.bindInt64(2, @intCast(limit));

        const results = try self.allocator.alloc(FtsResult, limit);
        var i: usize = 0;
        while (try stmt.step()) {
            if (i >= limit) break;
            results[i] = .{
                .id = stmt.columnInt64(0),
                .rank = i,
            };
            i += 1;
        }
        return results[0..i];
    }

    // ================================================================
    // RRF Merge — Reciprocal Rank Fusion
    // ================================================================

    fn mergeRRF(
        self: *HybridSearch,
        fts_items: []const RankedItem,
        vec_items: []const storage.embeddings.SearchResult,
        limit: usize,
    ) ![]const HybridResult {
        // Build a map of source_type+source_id → RRF score
        const MapKey = struct { source_type: []const u8, source_id: i64 };

        // Simple array-based merge (good enough for <500 results)
        const Scored = struct {
            source_type: []const u8,
            source_id: i64,
            text: []const u8,
            rrf_score: f32,
        };

        var scored_buf: [256]Scored = undefined;
        var scored_count: usize = 0;

        // Add FTS results
        for (fts_items, 0..) |item, rank| {
            if (scored_count >= scored_buf.len) break;
            const fts_score = 1.0 / (self.rrf_k + @as(f32, @floatFromInt(rank)));

            // Check if already exists (from vector results)
            var found = false;
            for (scored_buf[0..scored_count]) |*existing| {
                if (existing.source_id == item.source_id and
                    std.mem.eql(u8, existing.source_type, item.source_type))
                {
                    existing.rrf_score += fts_score;
                    found = true;
                    break;
                }
            }
            if (!found) {
                scored_buf[scored_count] = .{
                    .source_type = item.source_type,
                    .source_id = item.source_id,
                    .text = item.text,
                    .rrf_score = fts_score,
                };
                scored_count += 1;
            }
            _ = MapKey;
        }

        // Add vector results
        for (vec_items, 0..) |item, rank| {
            if (scored_count >= scored_buf.len) break;
            const vec_score = 1.0 / (self.rrf_k + @as(f32, @floatFromInt(rank)));

            var found = false;
            for (scored_buf[0..scored_count]) |*existing| {
                if (existing.source_id == item.source_id and
                    std.mem.eql(u8, existing.source_type, item.source_type))
                {
                    existing.rrf_score += vec_score;
                    found = true;
                    break;
                }
            }
            if (!found) {
                scored_buf[scored_count] = .{
                    .source_type = item.source_type,
                    .source_id = item.source_id,
                    .text = item.chunk_text,
                    .rrf_score = vec_score,
                };
                scored_count += 1;
            }
        }

        // Sort by RRF score descending
        const scored = scored_buf[0..scored_count];
        std.mem.sort(Scored, scored, {}, struct {
            fn lessThan(_: void, a: Scored, b: Scored) bool {
                return a.rrf_score > b.rrf_score;
            }
        }.lessThan);

        const result_count = @min(scored_count, limit);
        const results = try self.allocator.alloc(HybridResult, result_count);

        for (scored[0..result_count], 0..) |s, i| {
            results[i] = .{
                .source_type = s.source_type,
                .source_id = s.source_id,
                .text = s.text,
                .score = s.rrf_score,
            };
        }

        return results;
    }
};

const RankedItem = struct {
    source_type: []const u8,
    source_id: i64,
    text: []const u8,
    fts_rank: usize,
};

pub const HybridResult = struct {
    source_type: []const u8,
    source_id: i64,
    text: []const u8,
    score: f32,
};

pub const FtsResult = struct {
    id: i64,
    rank: usize,
};
