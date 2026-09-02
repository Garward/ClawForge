//! Durable imported-source storage and bounded lexical retrieval.

const std = @import("std");
const common = @import("common");
const storage = @import("storage");

const source_marker = "===== SOURCE: ";
const marker_end = " =====";
const max_evidence_chunks = 12;

pub const SourceSummary = struct {
    id: []u8,
    display_name: []u8,
    source_type: []u8,
    metadata_json: []u8,
    chunk_count: i64,
    embedded_count: i64,
    created_at: i64,

    pub fn deinit(self: *SourceSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.display_name);
        allocator.free(self.source_type);
        allocator.free(self.metadata_json);
    }
};

pub const SourceChunk = struct {
    id: i64,
    text: []u8,
    context_header: []u8,

    pub fn deinit(self: *SourceChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.context_header);
    }
};

const EvidenceChunk = struct {
    source_name: []u8,
    text: []u8,
    score: usize,

    fn deinit(self: *EvidenceChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.source_name);
        allocator.free(self.text);
    }
};

pub const ImportStore = struct {
    allocator: std.mem.Allocator,
    conn: *storage.Connection,

    pub fn init(allocator: std.mem.Allocator, conn: *storage.Connection) ImportStore {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn indexBundle(
        self: *ImportStore,
        story_id: []const u8,
        source_bundle: []const u8,
    ) ![]u8 {
        if (std.mem.trim(u8, source_bundle, " \t\r\n").len == 0) return error.EmptyImport;
        var job_id_buffer: [36]u8 = undefined;
        generateUuid(&job_id_buffer);
        const now = common.sync.timestamp();
        var job_statement = try self.conn.prepare(
            \\INSERT INTO narrative_import_jobs
            \\ (id, story_id, import_type, status, coverage_json, created_at, updated_at)
            \\VALUES (?, ?, 'source_bundle', 'indexing', '{}', ?, ?)
        );
        defer job_statement.deinit();
        try job_statement.bindText(1, &job_id_buffer);
        try job_statement.bindText(2, story_id);
        try job_statement.bindInt64(3, now);
        try job_statement.bindInt64(4, now);
        try job_statement.exec();

        var source_count: usize = 0;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, source_bundle, cursor, source_marker)) |marker_start| {
            const name_start = marker_start + source_marker.len;
            const name_end = std.mem.indexOfPos(u8, source_bundle, name_start, marker_end) orelse
                return error.InvalidSourceBundle;
            const header_end = std.mem.indexOfScalarPos(u8, source_bundle, name_end + marker_end.len, '\n') orelse
                source_bundle.len;
            const next_marker = std.mem.indexOfPos(u8, source_bundle, header_end, source_marker) orelse
                source_bundle.len;
            const display_name = std.mem.trim(u8, source_bundle[name_start..name_end], " \t\r\n");
            const content = std.mem.trim(u8, source_bundle[header_end..next_marker], " \t\r\n");
            if (display_name.len > 0 and content.len > 0) {
                try self.insertSource(
                    &job_id_buffer,
                    story_id,
                    display_name,
                    content,
                    now,
                );
                source_count += 1;
            }
            cursor = next_marker;
            if (cursor >= source_bundle.len) break;
        }
        if (source_count == 0) {
            try self.insertSource(
                &job_id_buffer,
                story_id,
                "Imported source bundle",
                source_bundle,
                now,
            );
            source_count = 1;
        }

        const coverage = try std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .source_count = source_count, .byte_count = source_bundle.len },
            .{},
        );
        defer self.allocator.free(coverage);
        var complete_statement = try self.conn.prepare(
            "UPDATE narrative_import_jobs SET status = 'completed', coverage_json = ?, updated_at = ? WHERE id = ?",
        );
        defer complete_statement.deinit();
        try complete_statement.bindText(1, coverage);
        try complete_statement.bindInt64(2, common.sync.timestamp());
        try complete_statement.bindText(3, &job_id_buffer);
        try complete_statement.exec();
        return self.allocator.dupe(u8, &job_id_buffer);
    }

    pub fn relevantEvidence(
        self: *ImportStore,
        story_id: []const u8,
        query: []const u8,
        max_output_bytes: usize,
    ) ![]u8 {
        var candidates: std.ArrayList(EvidenceChunk) = .empty;
        defer {
            for (candidates.items) |*candidate| candidate.deinit(self.allocator);
            candidates.deinit(self.allocator);
        }
        var statement = try self.conn.prepare(
            \\SELECT s.display_name, s.content_text
            \\FROM narrative_import_sources s
            \\JOIN narrative_import_jobs j ON j.id = s.import_job_id
            \\WHERE j.id = (
            \\  SELECT id FROM narrative_import_jobs
            \\  WHERE story_id = ? AND status = 'completed'
            \\  ORDER BY created_at DESC LIMIT 1
            \\) AND length(s.content_text) > 0
            \\ORDER BY s.created_at
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        while (try statement.step()) {
            const source_name = statement.columnText(0) orelse "Imported source";
            const content = statement.columnText(1) orelse "";
            var paragraphs = std.mem.splitSequence(u8, content, "\n\n");
            while (paragraphs.next()) |paragraph| {
                const trimmed = std.mem.trim(u8, paragraph, " \t\r\n");
                if (trimmed.len < 24) continue;
                const score = relevanceScore(query, trimmed);
                if (score == 0) continue;
                try retainCandidate(
                    self.allocator,
                    &candidates,
                    source_name,
                    trimmed[0..@min(trimmed.len, 2400)],
                    score,
                );
            }
        }
        std.mem.sort(EvidenceChunk, candidates.items, {}, struct {
            fn lessThan(_: void, left: EvidenceChunk, right: EvidenceChunk) bool {
                return left.score > right.score;
            }
        }.lessThan);

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (candidates.items) |candidate| {
            if (output.items.len >= max_output_bytes) break;
            const remaining = max_output_bytes - output.items.len;
            const text = candidate.text[0..@min(candidate.text.len, remaining)];
            try output.print(
                self.allocator,
                "\n[SOURCE: {s}; relevance {d}]\n{s}\n",
                .{ candidate.source_name, candidate.score, text },
            );
        }
        return output.toOwnedSlice(self.allocator);
    }

    pub fn listLatestSources(self: *ImportStore, story_id: []const u8) ![]SourceSummary {
        var result: std.ArrayList(SourceSummary) = .empty;
        errdefer {
            for (result.items) |*source| source.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        var statement = try self.conn.prepare(
            \\SELECT s.id, s.display_name, s.source_type, s.metadata_json,
            \\       COUNT(c.id),
            \\       SUM(CASE WHEN e.id IS NOT NULL THEN 1 ELSE 0 END),
            \\       s.created_at
            \\FROM narrative_import_sources s
            \\JOIN narrative_import_jobs j ON j.id = s.import_job_id
            \\LEFT JOIN narrative_import_source_chunks c ON c.source_id = s.id
            \\LEFT JOIN embeddings e
            \\  ON e.source_id = c.id
            \\ AND e.source_type = 'narrative_source:' || j.story_id || ':' || j.id
            \\WHERE j.id = (
            \\  SELECT id FROM narrative_import_jobs
            \\  WHERE story_id = ? AND status = 'completed'
            \\  ORDER BY created_at DESC LIMIT 1
            \\)
            \\GROUP BY s.id, s.display_name, s.source_type, s.metadata_json, s.created_at
            \\ORDER BY s.display_name
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        while (try statement.step()) {
            try result.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, statement.columnText(0) orelse ""),
                .display_name = try self.allocator.dupe(u8, statement.columnText(1) orelse ""),
                .source_type = try self.allocator.dupe(u8, statement.columnText(2) orelse ""),
                .metadata_json = try self.allocator.dupe(u8, statement.columnText(3) orelse "{}"),
                .chunk_count = statement.columnInt64(4),
                .embedded_count = statement.columnInt64(5),
                .created_at = statement.columnInt64(6),
            });
        }
        return result.toOwnedSlice(self.allocator);
    }

    pub fn latestJobId(self: *ImportStore, story_id: []const u8) !?[]u8 {
        var statement = try self.conn.prepare(
            \\SELECT id FROM narrative_import_jobs
            \\WHERE story_id = ? AND status = 'completed'
            \\ORDER BY created_at DESC LIMIT 1
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        if (!try statement.step()) return null;
        return @as(
            ?[]u8,
            try self.allocator.dupe(u8, statement.columnText(0) orelse ""),
        );
    }

    pub fn listJobChunks(self: *ImportStore, job_id: []const u8) ![]SourceChunk {
        var result: std.ArrayList(SourceChunk) = .empty;
        errdefer {
            for (result.items) |*chunk| chunk.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        var statement = try self.conn.prepare(
            \\SELECT c.id, c.chunk_text, c.context_header
            \\FROM narrative_import_source_chunks c
            \\JOIN narrative_import_sources s ON s.id = c.source_id
            \\WHERE s.import_job_id = ?
            \\ORDER BY c.id
        );
        defer statement.deinit();
        try statement.bindText(1, job_id);
        while (try statement.step()) {
            try result.append(self.allocator, .{
                .id = statement.columnInt64(0),
                .text = try self.allocator.dupe(u8, statement.columnText(1) orelse ""),
                .context_header = try self.allocator.dupe(u8, statement.columnText(2) orelse ""),
            });
        }
        return result.toOwnedSlice(self.allocator);
    }

    fn insertSource(
        self: *ImportStore,
        job_id: []const u8,
        story_id: []const u8,
        display_name: []const u8,
        content: []const u8,
        created_at: i64,
    ) !void {
        var source_id: [36]u8 = undefined;
        generateUuid(&source_id);
        var hash_buffer: [16]u8 = undefined;
        writeHash(std.hash.Wyhash.hash(0, content), &hash_buffer);
        const metadata = try std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .byte_count = content.len },
            .{},
        );
        defer self.allocator.free(metadata);
        var statement = try self.conn.prepare(
            \\INSERT INTO narrative_import_sources
            \\ (id, import_job_id, display_name, source_type, content_hash,
            \\  metadata_json, created_at, content_text)
            \\VALUES (?, ?, ?, 'text', ?, ?, ?, ?)
        );
        defer statement.deinit();
        try statement.bindText(1, &source_id);
        try statement.bindText(2, job_id);
        try statement.bindText(3, display_name);
        try statement.bindText(4, &hash_buffer);
        try statement.bindText(5, metadata);
        try statement.bindInt64(6, created_at);
        try statement.bindText(7, content);
        try statement.exec();
        try self.insertChunks(&source_id, story_id, display_name, content, created_at);
    }

    fn insertChunks(
        self: *ImportStore,
        source_id: []const u8,
        story_id: []const u8,
        display_name: []const u8,
        content: []const u8,
        created_at: i64,
    ) !void {
        const context_header = try std.fmt.allocPrint(
            self.allocator,
            "Narrative source file: {s}",
            .{display_name},
        );
        defer self.allocator.free(context_header);
        var chunk: std.ArrayList(u8) = .empty;
        defer chunk.deinit(self.allocator);
        var ordinal: i64 = 0;
        var paragraphs = std.mem.splitSequence(u8, content, "\n\n");
        while (paragraphs.next()) |paragraph| {
            const trimmed = std.mem.trim(u8, paragraph, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (chunk.items.len > 0 and chunk.items.len + trimmed.len + 2 > 2200) {
                try self.insertChunk(
                    source_id,
                    story_id,
                    ordinal,
                    chunk.items,
                    context_header,
                    created_at,
                );
                ordinal += 1;
                chunk.clearRetainingCapacity();
            }
            if (trimmed.len > 3000) {
                if (chunk.items.len > 0) {
                    try self.insertChunk(
                        source_id,
                        story_id,
                        ordinal,
                        chunk.items,
                        context_header,
                        created_at,
                    );
                    ordinal += 1;
                    chunk.clearRetainingCapacity();
                }
                var start: usize = 0;
                while (start < trimmed.len) {
                    const end = @min(start + 2200, trimmed.len);
                    try self.insertChunk(
                        source_id,
                        story_id,
                        ordinal,
                        trimmed[start..end],
                        context_header,
                        created_at,
                    );
                    ordinal += 1;
                    start = end;
                }
                continue;
            }
            if (chunk.items.len > 0) try chunk.appendSlice(self.allocator, "\n\n");
            try chunk.appendSlice(self.allocator, trimmed);
        }
        if (chunk.items.len > 0) {
            try self.insertChunk(
                source_id,
                story_id,
                ordinal,
                chunk.items,
                context_header,
                created_at,
            );
        }
    }

    fn insertChunk(
        self: *ImportStore,
        source_id: []const u8,
        story_id: []const u8,
        ordinal: i64,
        text: []const u8,
        context_header: []const u8,
        created_at: i64,
    ) !void {
        var statement = try self.conn.prepare(
            \\INSERT INTO narrative_import_source_chunks
            \\ (source_id, story_id, ordinal, chunk_text, context_header, created_at)
            \\VALUES (?, ?, ?, ?, ?, ?)
        );
        defer statement.deinit();
        try statement.bindText(1, source_id);
        try statement.bindText(2, story_id);
        try statement.bindInt64(3, ordinal);
        try statement.bindText(4, text);
        try statement.bindText(5, context_header);
        try statement.bindInt64(6, created_at);
        try statement.exec();
    }
};

fn retainCandidate(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(EvidenceChunk),
    source_name: []const u8,
    text: []const u8,
    score: usize,
) !void {
    if (candidates.items.len < max_evidence_chunks) {
        try candidates.append(allocator, .{
            .source_name = try allocator.dupe(u8, source_name),
            .text = try allocator.dupe(u8, text),
            .score = score,
        });
        return;
    }
    var lowest_index: usize = 0;
    for (candidates.items, 1..) |candidate, index| {
        if (candidate.score < candidates.items[lowest_index].score) lowest_index = index;
    }
    if (score <= candidates.items[lowest_index].score) return;
    candidates.items[lowest_index].deinit(allocator);
    candidates.items[lowest_index] = .{
        .source_name = try allocator.dupe(u8, source_name),
        .text = try allocator.dupe(u8, text),
        .score = score,
    };
}

fn relevanceScore(query: []const u8, text: []const u8) usize {
    var score: usize = 0;
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n.,:;!?()[]{}\"'*/\\-_");
    while (words.next()) |word| {
        if (word.len < 4 or isStopWord(word)) continue;
        if (containsIgnoreCase(text, word)) score += 1;
    }
    return score;
}

fn isStopWord(word: []const u8) bool {
    const stop_words = [_][]const u8{
        "that",   "this",   "with",  "from", "what", "when", "where", "which",
        "should", "would",  "could", "have", "been", "were", "their", "there",
        "about",  "before", "after", "into", "only", "than", "then",
    };
    for (stop_words) |stop_word| {
        if (std.ascii.eqlIgnoreCase(word, stop_word)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn generateUuid(buffer: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    std.Io.random(common.config.runtimeIo(), &bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var source: usize = 0;
    var destination: usize = 0;
    while (source < bytes.len) : (source += 1) {
        if (source == 4 or source == 6 or source == 8 or source == 10) {
            buffer[destination] = '-';
            destination += 1;
        }
        buffer[destination] = hex[bytes[source] >> 4];
        buffer[destination + 1] = hex[bytes[source] & 0x0f];
        destination += 2;
    }
}

fn writeHash(value: u64, output: *[16]u8) void {
    const hex = "0123456789abcdef";
    for (0..16) |index| {
        const shift: u6 = @intCast((15 - index) * 4);
        output[index] = hex[@intCast((value >> shift) & 0xf)];
    }
}
