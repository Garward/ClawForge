const std = @import("std");
const db_mod = @import("db.zig");
const simd = @import("common").simd;

/// Embedding storage and vector search.
/// Stores FP32 vectors as BLOBs with binary (1-bit) companions for fast broad search.
/// Search pipeline: binary hamming broad → FP32 cosine rescore top-k.
pub const EmbeddingStore = struct {
    conn: *db_mod.Connection,
    allocator: std.mem.Allocator,
    namespace_id: i64,

    pub fn init(conn: *db_mod.Connection, allocator: std.mem.Allocator, namespace_id: i64) EmbeddingStore {
        return .{ .conn = conn, .allocator = allocator, .namespace_id = namespace_id };
    }

    /// Store an embedding for a source entity.
    pub fn store(
        self: *EmbeddingStore,
        source_type: []const u8,
        source_id: i64,
        chunk_text: []const u8,
        context_header: ?[]const u8,
        vector: []const f32,
        model: []const u8,
    ) !i64 {
        // Convert to binary for fast broad search
        const binary = try simd.toBinary(self.allocator, vector);
        defer self.allocator.free(binary);

        const now = std.time.timestamp();
        var stmt = try self.conn.prepare(
            "INSERT OR REPLACE INTO embeddings (source_type, source_id, namespace_id, " ++
                "chunk_text, context_header, model, dimensions, " ++
                "vector_fp32, vector_binary, created_at) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        );
        defer stmt.deinit();

        try stmt.bindText(1, source_type);
        try stmt.bindInt64(2, source_id);
        try stmt.bindInt64(3, self.namespace_id);
        try stmt.bindText(4, chunk_text);
        try stmt.bindOptionalText(5, context_header);
        try stmt.bindText(6, model);
        try stmt.bindInt(7, @intCast(vector.len));

        // Store FP32 vector as BLOB
        const fp32_bytes = std.mem.sliceAsBytes(vector);
        try stmt.bindBlob(8, fp32_bytes);

        // Store binary vector as BLOB
        const binary_bytes = std.mem.sliceAsBytes(binary);
        try stmt.bindBlob(9, binary_bytes);

        try stmt.bindInt64(10, now);
        try stmt.exec();

        return self.conn.lastInsertRowId();
    }

    /// Two-pass vector search:
    /// 1. Binary hamming distance over all vectors (fast, broad)
    /// 2. FP32 cosine rescore on top candidates (precise)
    pub fn vectorSearch(
        self: *EmbeddingStore,
        query_vector: []const f32,
        broad_limit: usize,
        final_limit: usize,
    ) ![]const SearchResult {
        // Convert query to binary
        const query_binary = try simd.toBinary(self.allocator, query_vector);
        defer self.allocator.free(query_binary);

        // Pass 1: Broad search via binary hamming distance
        var stmt = try self.conn.prepare(
            "SELECT id, source_type, source_id, chunk_text, vector_fp32, vector_binary " ++
                "FROM embeddings WHERE namespace_id = ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);

        // Collect candidates with hamming scores
        const Candidate = struct {
            id: i64,
            source_type: []const u8,
            source_id: i64,
            chunk_text: []const u8,
            fp32_blob: []const u8,
            hamming_dist: u32,
        };

        var candidates_buf: [512]Candidate = undefined;
        var candidate_count: usize = 0;

        while (try stmt.step()) {
            if (candidate_count >= candidates_buf.len) break;

            const binary_blob = stmt.columnBlob(5);
            if (binary_blob == null) continue;

            const stored_binary = std.mem.bytesAsSlice(u64, binary_blob.?);
            const dist = simd.hammingDistance(query_binary, stored_binary);

            candidates_buf[candidate_count] = .{
                .id = stmt.columnInt64(0),
                .source_type = try self.allocator.dupe(u8, stmt.columnText(1) orelse ""),
                .source_id = stmt.columnInt64(2),
                .chunk_text = try self.allocator.dupe(u8, stmt.columnText(3) orelse ""),
                .fp32_blob = if (stmt.columnBlob(4)) |b| try self.allocator.dupe(u8, b) else "",
                .hamming_dist = dist,
            };
            candidate_count += 1;
        }

        if (candidate_count == 0) return &.{};

        // Sort by hamming distance (ascending = most similar)
        const candidates = candidates_buf[0..candidate_count];
        std.mem.sort(Candidate, candidates, {}, struct {
            fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                return a.hamming_dist < b.hamming_dist;
            }
        }.lessThan);

        // Pass 2: Rescore top-k with FP32 cosine similarity
        const rescore_count = @min(candidate_count, broad_limit);
        const result_count = @min(rescore_count, final_limit);
        const results = try self.allocator.alloc(SearchResult, result_count);

        const ScoredResult = struct {
            result: SearchResult,
            score: f32,
        };

        var scored_buf: [128]ScoredResult = undefined;
        var scored_count: usize = 0;

        for (candidates[0..rescore_count]) |cand| {
            if (scored_count >= scored_buf.len) break;
            if (cand.fp32_blob.len == 0) continue;

            const stored_vec = std.mem.bytesAsSlice(f32, cand.fp32_blob);
            const score = simd.cosineSimilarity(query_vector, stored_vec);

            scored_buf[scored_count] = .{
                .result = .{
                    .id = cand.id,
                    .source_type = cand.source_type,
                    .source_id = cand.source_id,
                    .chunk_text = cand.chunk_text,
                    .score = score,
                },
                .score = score,
            };
            scored_count += 1;
        }

        // Sort by cosine similarity (descending = most similar)
        const scored = scored_buf[0..scored_count];
        std.mem.sort(ScoredResult, scored, {}, struct {
            fn lessThan(_: void, a: ScoredResult, b: ScoredResult) bool {
                return a.score > b.score;
            }
        }.lessThan);

        const copy_count = @min(scored_count, result_count);
        for (scored[0..copy_count], 0..) |s, i| {
            results[i] = s.result;
        }

        return results[0..copy_count];
    }

    /// Get embedding count.
    pub fn count(self: *EmbeddingStore) !usize {
        var stmt = try self.conn.prepare("SELECT COUNT(*) FROM embeddings WHERE namespace_id = ?");
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        _ = try stmt.step();
        return @intCast(stmt.columnInt64(0));
    }
};

pub const SearchResult = struct {
    id: i64,
    source_type: []const u8,
    source_id: i64,
    chunk_text: []const u8,
    score: f32,
};
