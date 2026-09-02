//! Immutable manuscript revisions and bounded block patch operations.

const std = @import("std");
const common = @import("common");
const storage = @import("storage");
const domain = @import("../domain/root.zig");

const Seed = struct {
    block_type: []const u8,
    text: []const u8,
};

pub const ProseStore = struct {
    allocator: std.mem.Allocator,
    conn: *storage.Connection,

    pub fn init(allocator: std.mem.Allocator, conn: *storage.Connection) ProseStore {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn latest(self: *ProseStore, story_id: []const u8, node_id: []const u8) !domain.ProseDocument {
        if (!try self.nodeExists(story_id, node_id)) return error.NodeNotFound;
        const revision_id = try self.latestRevisionId(story_id, node_id);
        defer if (revision_id) |value| self.allocator.free(value);
        if (revision_id == null) {
            return .{
                .node_id = try self.allocator.dupe(u8, node_id),
                .revision_id = null,
                .parent_revision_id = null,
                .lifecycle = try self.allocator.dupe(u8, "empty"),
                .author_source = try self.allocator.dupe(u8, "none"),
                .word_count = 0,
                .created_at = null,
                .blocks = try self.allocator.alloc(domain.ProseBlock, 0),
            };
        }
        return self.loadRevision(node_id, revision_id.?);
    }

    pub fn applyPatch(
        self: *ProseStore,
        story_id: []const u8,
        node_id: []const u8,
        patch: domain.ProsePatch,
    ) !domain.ProseDocument {
        if (!validOperation(patch.operation)) return error.InvalidOperation;
        if (!validBlockType(patch.block_type)) return error.InvalidBlockType;
        if (!try self.nodeExists(story_id, node_id)) return error.NodeNotFound;

        const latest_id = try self.latestRevisionId(story_id, node_id);
        defer if (latest_id) |value| self.allocator.free(value);
        if (!optionalEqual(latest_id, patch.base_revision_id)) return error.StaleRevision;

        var old_document: ?domain.ProseDocument = if (latest_id) |value|
            try self.loadRevision(node_id, value)
        else
            null;
        defer if (old_document) |*document| document.deinit(self.allocator);
        const old_blocks: []const domain.ProseBlock = if (old_document) |*document|
            document.blocks
        else
            &.{};

        var seeds: std.ArrayList(Seed) = .empty;
        defer seeds.deinit(self.allocator);
        for (old_blocks) |block| try seeds.append(self.allocator, .{
            .block_type = block.block_type,
            .text = block.text,
        });

        try mutateSeeds(self.allocator, &seeds, old_blocks, patch);
        if (seeds.items.len == 0 and !std.mem.eql(u8, patch.operation, "delete"))
            return error.EmptyPatch;

        var revision_id: [36]u8 = undefined;
        var patch_id: [36]u8 = undefined;
        var version_id: [36]u8 = undefined;
        generateUuid(&revision_id);
        generateUuid(&patch_id);
        generateUuid(&version_id);
        const now = common.sync.timestamp();
        const branch_id = try self.activeBranch(story_id) orelse return error.StoryNotFound;
        defer self.allocator.free(branch_id);
        const next_version = (try self.activeVersion(story_id)) + 1;
        const total_words = wordCount(seeds.items);
        var revision_hash: [16]u8 = undefined;
        hashSeeds(seeds.items, &revision_hash);

        try self.conn.execSimple("BEGIN IMMEDIATE");
        errdefer self.conn.execSimple("ROLLBACK") catch {};

        var revision_stmt = try self.conn.prepare(
            \\INSERT INTO narrative_prose_revisions
            \\ (id, story_id, branch_id, node_id, parent_revision_id, lifecycle,
            \\  author_source, content_hash, word_count, created_at)
            \\VALUES (?, ?, ?, ?, ?, 'accepted', ?, ?, ?, ?)
        );
        defer revision_stmt.deinit();
        try revision_stmt.bindText(1, &revision_id);
        try revision_stmt.bindText(2, story_id);
        try revision_stmt.bindText(3, branch_id);
        try revision_stmt.bindText(4, node_id);
        try revision_stmt.bindOptionalText(5, latest_id);
        try revision_stmt.bindText(6, patch.author_source);
        try revision_stmt.bindText(7, &revision_hash);
        try revision_stmt.bindInt64(8, total_words);
        try revision_stmt.bindInt64(9, now);
        try revision_stmt.exec();

        for (seeds.items, 0..) |seed, index| {
            var block_id: [36]u8 = undefined;
            var block_hash: [16]u8 = undefined;
            generateUuid(&block_id);
            hashText(seed.text, &block_hash);
            var block_stmt = try self.conn.prepare(
                "INSERT INTO narrative_prose_blocks (id, revision_id, ordinal, block_type, text, content_hash) VALUES (?, ?, ?, ?, ?, ?)",
            );
            defer block_stmt.deinit();
            try block_stmt.bindText(1, &block_id);
            try block_stmt.bindText(2, &revision_id);
            try block_stmt.bindInt64(3, @intCast(index));
            try block_stmt.bindText(4, seed.block_type);
            try block_stmt.bindText(5, seed.text);
            try block_stmt.bindText(6, &block_hash);
            try block_stmt.exec();
        }

        var anchors_buf: [256]u8 = undefined;
        const anchors = if (patch.anchor_block_id) |anchor|
            if (patch.end_anchor_block_id) |end_anchor|
                std.fmt.bufPrint(
                    &anchors_buf,
                    "{{\"block_id\":\"{s}\",\"end_block_id\":\"{s}\"}}",
                    .{ anchor, end_anchor },
                ) catch "{}"
            else
                std.fmt.bufPrint(&anchors_buf, "{{\"block_id\":\"{s}\"}}", .{anchor}) catch "{}"
        else
            "{}";
        var patch_stmt = try self.conn.prepare(
            \\INSERT INTO narrative_prose_patches
            \\ (id, parent_revision_id, resulting_revision_id, operation,
            \\  anchors_json, patch_json, created_at)
            \\VALUES (?, ?, ?, ?, ?, '{}', ?)
        );
        defer patch_stmt.deinit();
        try patch_stmt.bindText(1, &patch_id);
        try patch_stmt.bindOptionalText(2, latest_id);
        try patch_stmt.bindText(3, &revision_id);
        try patch_stmt.bindText(4, patch.operation);
        try patch_stmt.bindText(5, anchors);
        try patch_stmt.bindInt64(6, now);
        try patch_stmt.exec();

        var version_stmt = try self.conn.prepare(
            "INSERT INTO narrative_story_versions (id, story_id, branch_id, version_number, parent_version_id, reason, created_at) VALUES (?, ?, ?, ?, (SELECT id FROM narrative_story_versions WHERE story_id = ? AND branch_id = ? ORDER BY version_number DESC LIMIT 1), 'prose_patch', ?)",
        );
        defer version_stmt.deinit();
        try version_stmt.bindText(1, &version_id);
        try version_stmt.bindText(2, story_id);
        try version_stmt.bindText(3, branch_id);
        try version_stmt.bindInt64(4, next_version);
        try version_stmt.bindText(5, story_id);
        try version_stmt.bindText(6, branch_id);
        try version_stmt.bindInt64(7, now);
        try version_stmt.exec();

        var story_stmt = try self.conn.prepare(
            "UPDATE narrative_stories SET active_version = ?, updated_at = ? WHERE id = ?",
        );
        defer story_stmt.deinit();
        try story_stmt.bindInt64(1, next_version);
        try story_stmt.bindInt64(2, now);
        try story_stmt.bindText(3, story_id);
        try story_stmt.exec();
        try self.conn.execSimple("COMMIT");
        return self.loadRevision(node_id, &revision_id);
    }

    fn loadRevision(self: *ProseStore, node_id: []const u8, revision_id: []const u8) !domain.ProseDocument {
        var revision_stmt = try self.conn.prepare(
            "SELECT parent_revision_id, lifecycle, author_source, word_count, created_at FROM narrative_prose_revisions WHERE id = ?",
        );
        defer revision_stmt.deinit();
        try revision_stmt.bindText(1, revision_id);
        if (!try revision_stmt.step()) return error.RevisionNotFound;

        var blocks: std.ArrayList(domain.ProseBlock) = .empty;
        errdefer {
            for (blocks.items) |*block| block.deinit(self.allocator);
            blocks.deinit(self.allocator);
        }
        var block_stmt = try self.conn.prepare(
            "SELECT id, ordinal, block_type, text, content_hash FROM narrative_prose_blocks WHERE revision_id = ? ORDER BY ordinal",
        );
        defer block_stmt.deinit();
        try block_stmt.bindText(1, revision_id);
        while (try block_stmt.step()) {
            try blocks.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, block_stmt.columnText(0) orelse ""),
                .ordinal = block_stmt.columnInt64(1),
                .block_type = try self.allocator.dupe(u8, block_stmt.columnText(2) orelse "paragraph"),
                .text = try self.allocator.dupe(u8, block_stmt.columnText(3) orelse ""),
                .content_hash = try self.allocator.dupe(u8, block_stmt.columnText(4) orelse ""),
            });
        }
        return .{
            .node_id = try self.allocator.dupe(u8, node_id),
            .revision_id = try self.allocator.dupe(u8, revision_id),
            .parent_revision_id = if (revision_stmt.columnOptionalText(0)) |value|
                try self.allocator.dupe(u8, value)
            else
                null,
            .lifecycle = try self.allocator.dupe(u8, revision_stmt.columnText(1) orelse "accepted"),
            .author_source = try self.allocator.dupe(u8, revision_stmt.columnText(2) orelse "unknown"),
            .word_count = revision_stmt.columnInt64(3),
            .created_at = revision_stmt.columnInt64(4),
            .blocks = try blocks.toOwnedSlice(self.allocator),
        };
    }

    fn latestRevisionId(self: *ProseStore, story_id: []const u8, node_id: []const u8) !?[]u8 {
        var statement = try self.conn.prepare(
            "SELECT id FROM narrative_prose_revisions WHERE story_id = ? AND node_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        try statement.bindText(2, node_id);
        if (!try statement.step()) return null;
        return try self.allocator.dupe(u8, statement.columnText(0) orelse "");
    }

    fn nodeExists(self: *ProseStore, story_id: []const u8, node_id: []const u8) !bool {
        var statement = try self.conn.prepare(
            "SELECT 1 FROM narrative_nodes WHERE story_id = ? AND id = ? AND node_type IN ('chapter', 'scene')",
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        try statement.bindText(2, node_id);
        return try statement.step();
    }

    fn activeBranch(self: *ProseStore, story_id: []const u8) !?[]u8 {
        var statement = try self.conn.prepare("SELECT active_branch_id FROM narrative_stories WHERE id = ?");
        defer statement.deinit();
        try statement.bindText(1, story_id);
        if (!try statement.step()) return null;
        const value = statement.columnOptionalText(0) orelse return null;
        return try self.allocator.dupe(u8, value);
    }

    fn activeVersion(self: *ProseStore, story_id: []const u8) !i64 {
        var statement = try self.conn.prepare("SELECT active_version FROM narrative_stories WHERE id = ?");
        defer statement.deinit();
        try statement.bindText(1, story_id);
        if (!try statement.step()) return error.StoryNotFound;
        return statement.columnInt64(0);
    }
};

fn mutateSeeds(
    allocator: std.mem.Allocator,
    seeds: *std.ArrayList(Seed),
    old_blocks: []const domain.ProseBlock,
    patch: domain.ProsePatch,
) !void {
    if (std.mem.eql(u8, patch.operation, "replace_all")) {
        const text = patch.text orelse return error.MissingText;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.EmptyPatch;
        seeds.clearRetainingCapacity();
        try appendParagraphSeeds(allocator, seeds, 0, patch.block_type, text);
        return;
    }
    if (std.mem.eql(u8, patch.operation, "append")) {
        const text = patch.text orelse return error.MissingText;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.EmptyPatch;
        try appendParagraphSeeds(allocator, seeds, seeds.items.len, patch.block_type, text);
        return;
    }
    const anchor = patch.anchor_block_id orelse return error.MissingAnchor;
    var anchor_index: ?usize = null;
    for (old_blocks, 0..) |block, index| {
        if (std.mem.eql(u8, block.id, anchor)) {
            anchor_index = index;
            break;
        }
    }
    const index = anchor_index orelse return error.AnchorNotFound;
    if (std.mem.eql(u8, patch.operation, "replace_range")) {
        const end_anchor = patch.end_anchor_block_id orelse return error.MissingEndAnchor;
        var end_index: ?usize = null;
        for (old_blocks[index..], index..) |block, candidate_index| {
            if (std.mem.eql(u8, block.id, end_anchor)) {
                end_index = candidate_index;
                break;
            }
        }
        const inclusive_end = end_index orelse return error.AnchorNotFound;
        const text = patch.text orelse return error.MissingText;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.EmptyPatch;
        var remove_count = inclusive_end - index + 1;
        while (remove_count > 0) : (remove_count -= 1) _ = seeds.orderedRemove(index);
        try appendParagraphSeeds(allocator, seeds, index, patch.block_type, text);
        return;
    }
    if (std.mem.eql(u8, patch.operation, "delete")) {
        _ = seeds.orderedRemove(index);
        return;
    }
    const text = patch.text orelse return error.MissingText;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.EmptyPatch;
    const seed = Seed{ .block_type = patch.block_type, .text = text };
    if (std.mem.eql(u8, patch.operation, "replace")) {
        _ = seeds.orderedRemove(index);
        try appendParagraphSeeds(allocator, seeds, index, patch.block_type, text);
    } else if (std.mem.eql(u8, patch.operation, "insert_before")) {
        try seeds.insert(allocator, index, seed);
    } else if (std.mem.eql(u8, patch.operation, "insert_after")) {
        try seeds.insert(allocator, index + 1, seed);
    }
}

fn appendParagraphSeeds(
    allocator: std.mem.Allocator,
    seeds: *std.ArrayList(Seed),
    start_index: usize,
    block_type: []const u8,
    text: []const u8,
) !void {
    if (!std.mem.eql(u8, block_type, "paragraph")) {
        try seeds.insert(allocator, start_index, .{ .block_type = block_type, .text = text });
        return;
    }
    var index = start_index;
    var parts = std.mem.splitSequence(u8, text, "\n\n");
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        const inferred_type: []const u8 = if (std.mem.eql(u8, trimmed, "---"))
            "divider"
        else if (std.mem.startsWith(u8, trimmed, "#"))
            "heading"
        else
            block_type;
        const inferred_text = if (std.mem.eql(u8, inferred_type, "heading"))
            std.mem.trimStart(u8, std.mem.trimStart(u8, trimmed, "#"), " ")
        else
            trimmed;
        try seeds.insert(allocator, index, .{
            .block_type = inferred_type,
            .text = inferred_text,
        });
        index += 1;
    }
}

fn validOperation(value: []const u8) bool {
    return std.mem.eql(u8, value, "append") or
        std.mem.eql(u8, value, "replace_all") or
        std.mem.eql(u8, value, "replace_range") or
        std.mem.eql(u8, value, "replace") or
        std.mem.eql(u8, value, "insert_before") or
        std.mem.eql(u8, value, "insert_after") or
        std.mem.eql(u8, value, "delete");
}

fn validBlockType(value: []const u8) bool {
    return std.mem.eql(u8, value, "paragraph") or
        std.mem.eql(u8, value, "heading") or
        std.mem.eql(u8, value, "divider");
}

fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn wordCount(seeds: []const Seed) i64 {
    var count: i64 = 0;
    for (seeds) |seed| {
        var words = std.mem.tokenizeAny(u8, seed.text, " \t\r\n");
        while (words.next() != null) count += 1;
    }
    return count;
}

fn hashSeeds(seeds: []const Seed, output: *[16]u8) void {
    var hash = std.hash.Wyhash.init(0);
    for (seeds) |seed| {
        hash.update(seed.block_type);
        hash.update(seed.text);
    }
    writeHash(hash.final(), output);
}

fn hashText(value: []const u8, output: *[16]u8) void {
    writeHash(std.hash.Wyhash.hash(0, value), output);
}

fn writeHash(value: u64, output: *[16]u8) void {
    const hex = "0123456789abcdef";
    for (0..16) |index| {
        const shift: u6 = @intCast((15 - index) * 4);
        output[index] = hex[@intCast((value >> shift) & 0xf)];
    }
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
