const std = @import("std");
const db_mod = @import("db.zig");

/// Artifact + artifact_analysis CRUD. Used by the vision pipeline:
/// an image is hashed, looked up by content_hash, analyzed with a vision
/// model on cache miss, and re-used on future matches.
pub const ArtifactStore = struct {
    conn: *db_mod.Connection,
    allocator: std.mem.Allocator,
    namespace_id: i64,

    pub fn init(conn: *db_mod.Connection, allocator: std.mem.Allocator, namespace_id: i64) ArtifactStore {
        return .{ .conn = conn, .allocator = allocator, .namespace_id = namespace_id };
    }

    /// Look up a cached analysis by content hash + analysis_type + detail_level.
    /// Returned slices are allocated from `allocator` (caller frees via freeAnalysis).
    pub fn lookupAnalysis(
        self: *ArtifactStore,
        content_hash: []const u8,
        analysis_type: []const u8,
        detail_level: []const u8,
    ) !?CachedAnalysis {
        var stmt = try self.conn.prepare(
            "SELECT description, structured_data, model_used, created_at " ++
                "FROM artifact_analysis " ++
                "WHERE content_hash = ? AND analysis_type = ? AND detail_level = ? " ++
                "LIMIT 1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, content_hash);
        try stmt.bindText(2, analysis_type);
        try stmt.bindText(3, detail_level);

        if (try stmt.step()) {
            const desc = stmt.columnText(0) orelse "";
            const structured = stmt.columnOptionalText(1);
            const model = stmt.columnText(2) orelse "";
            const created_at = stmt.columnInt64(3);
            return .{
                .description = try self.allocator.dupe(u8, desc),
                .structured_data = if (structured) |s| try self.allocator.dupe(u8, s) else null,
                .model_used = try self.allocator.dupe(u8, model),
                .created_at = created_at,
            };
        }
        return null;
    }

    /// Insert (or upsert) an artifact row. Returns the artifact id.
    pub fn insertArtifact(self: *ArtifactStore, req: InsertArtifact) !i64 {
        const now = std.time.timestamp();
        var stmt = try self.conn.prepare(
            "INSERT INTO artifacts (namespace_id, session_id, name, artifact_type, mime_type, " ++
                "content_path, content_size, content_hash, description, source, created_at, updated_at) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindOptionalText(2, req.session_id);
        try stmt.bindText(3, req.name);
        try stmt.bindText(4, req.artifact_type);
        try stmt.bindOptionalText(5, req.mime_type);
        try stmt.bindOptionalText(6, req.content_path);
        if (req.content_size) |sz| {
            try stmt.bindInt64(7, @intCast(sz));
        } else {
            try stmt.bindNull(7);
        }
        try stmt.bindOptionalText(8, req.content_hash);
        try stmt.bindOptionalText(9, req.description);
        try stmt.bindOptionalText(10, req.source);
        try stmt.bindInt64(11, now);
        try stmt.bindInt64(12, now);
        try stmt.exec();
        return self.conn.lastInsertRowId();
    }

    /// Insert a cached analysis result. Uses INSERT OR IGNORE so concurrent
    /// inserts of the same (content_hash, analysis_type, detail_level) don't
    /// error — the first writer wins.
    pub fn insertAnalysis(self: *ArtifactStore, req: InsertAnalysis) !void {
        const now = std.time.timestamp();
        var stmt = try self.conn.prepare(
            "INSERT OR IGNORE INTO artifact_analysis " ++
                "(artifact_id, content_hash, analysis_type, detail_level, description, " ++
                "structured_data, model_used, input_tokens, output_tokens, prompt_used, created_at) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, req.artifact_id);
        try stmt.bindText(2, req.content_hash);
        try stmt.bindText(3, req.analysis_type);
        try stmt.bindText(4, req.detail_level);
        try stmt.bindText(5, req.description);
        try stmt.bindOptionalText(6, req.structured_data);
        try stmt.bindText(7, req.model_used);
        if (req.input_tokens) |t| try stmt.bindInt64(8, @intCast(t)) else try stmt.bindNull(8);
        if (req.output_tokens) |t| try stmt.bindInt64(9, @intCast(t)) else try stmt.bindNull(9);
        try stmt.bindOptionalText(10, req.prompt_used);
        try stmt.bindInt64(11, now);
        try stmt.exec();
    }

    /// Find an existing artifact row for a given content_hash in this namespace.
    /// Returns the id if found. Lets the vision module reuse the artifact row
    /// across sessions instead of duplicating the file metadata.
    pub fn findArtifactIdByHash(self: *ArtifactStore, content_hash: []const u8) !?i64 {
        var stmt = try self.conn.prepare(
            "SELECT id FROM artifacts WHERE content_hash = ? AND namespace_id = ? LIMIT 1",
        );
        defer stmt.deinit();
        try stmt.bindText(1, content_hash);
        try stmt.bindInt64(2, self.namespace_id);
        if (try stmt.step()) {
            return stmt.columnInt64(0);
        }
        return null;
    }

    pub fn freeAnalysis(self: *ArtifactStore, a: CachedAnalysis) void {
        self.allocator.free(a.description);
        if (a.structured_data) |s| self.allocator.free(s);
        self.allocator.free(a.model_used);
    }
};

pub const CachedAnalysis = struct {
    description: []const u8,
    structured_data: ?[]const u8,
    model_used: []const u8,
    created_at: i64,
};

pub const InsertArtifact = struct {
    session_id: ?[]const u8,
    name: []const u8,
    artifact_type: []const u8,
    mime_type: ?[]const u8,
    content_path: ?[]const u8,
    content_size: ?usize,
    content_hash: ?[]const u8,
    description: ?[]const u8,
    source: ?[]const u8,
};

pub const InsertAnalysis = struct {
    artifact_id: i64,
    content_hash: []const u8,
    analysis_type: []const u8,
    detail_level: []const u8,
    description: []const u8,
    structured_data: ?[]const u8,
    model_used: []const u8,
    input_tokens: ?u32,
    output_tokens: ?u32,
    prompt_used: ?[]const u8,
};
