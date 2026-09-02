//! Storyboard hierarchy persistence.

const std = @import("std");
const common = @import("common");
const storage = @import("storage");
const domain = @import("../domain/root.zig");

pub const NodeStore = struct {
    allocator: std.mem.Allocator,
    conn: *storage.Connection,

    pub fn init(allocator: std.mem.Allocator, conn: *storage.Connection) NodeStore {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn create(self: *NodeStore, story_id: []const u8, input: domain.CreateNode) !domain.Node {
        if (!validNodeType(input.node_type)) return error.InvalidNodeType;
        const title = std.mem.trim(u8, input.title, " \t\r\n");
        if (title.len == 0) return error.InvalidTitle;
        const branch_id = try self.activeBranch(story_id) orelse return error.StoryNotFound;
        defer self.allocator.free(branch_id);
        if (input.parent_id) |parent_id| {
            if (!try self.nodeExists(story_id, parent_id)) return error.ParentNotFound;
        }

        var id: [36]u8 = undefined;
        generateUuid(&id);
        const ordinal = try self.nextOrdinal(story_id, input.parent_id);
        const now = common.sync.timestamp();
        var statement = try self.conn.prepare(
            \\INSERT INTO narrative_nodes
            \\ (id, story_id, branch_id, parent_id, node_type, title, ordinal,
            \\  lifecycle, purpose, synopsis, metadata_json, revision, created_at, updated_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, 'draft', ?, ?, '{}', 1, ?, ?)
        );
        defer statement.deinit();
        try statement.bindText(1, &id);
        try statement.bindText(2, story_id);
        try statement.bindText(3, branch_id);
        try statement.bindOptionalText(4, input.parent_id);
        try statement.bindText(5, input.node_type);
        try statement.bindText(6, title);
        try statement.bindInt64(7, ordinal);
        try statement.bindOptionalText(8, input.purpose);
        try statement.bindOptionalText(9, input.synopsis);
        try statement.bindInt64(10, now);
        try statement.bindInt64(11, now);
        try statement.exec();
        return try self.get(story_id, &id) orelse error.NodeCreateFailed;
    }

    pub fn list(self: *NodeStore, story_id: []const u8) ![]domain.Node {
        var result: std.ArrayList(domain.Node) = .empty;
        errdefer {
            for (result.items) |*node| node.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        var statement = try self.conn.prepare(
            \\SELECT id, story_id, branch_id, parent_id, node_type, title, ordinal,
            \\       lifecycle, purpose, synopsis, metadata_json, revision, created_at, updated_at
            \\FROM narrative_nodes WHERE story_id = ?
            \\ORDER BY created_at, ordinal
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        while (try statement.step()) {
            try result.append(self.allocator, try readNode(self.allocator, &statement));
        }
        return try result.toOwnedSlice(self.allocator);
    }

    pub fn update(
        self: *NodeStore,
        story_id: []const u8,
        node_id: []const u8,
        title: []const u8,
        purpose: ?[]const u8,
        synopsis: ?[]const u8,
        lifecycle: []const u8,
        expected_revision: i64,
    ) !domain.Node {
        if (std.mem.trim(u8, title, " \t\r\n").len == 0) return error.InvalidTitle;
        if (!validLifecycle(lifecycle)) return error.InvalidLifecycle;
        var statement = try self.conn.prepare(
            \\UPDATE narrative_nodes
            \\SET title = ?, purpose = ?, synopsis = ?, lifecycle = ?,
            \\    revision = revision + 1, updated_at = ?
            \\WHERE story_id = ? AND id = ? AND revision = ?
        );
        defer statement.deinit();
        try statement.bindText(1, title);
        try statement.bindOptionalText(2, purpose);
        try statement.bindOptionalText(3, synopsis);
        try statement.bindText(4, lifecycle);
        try statement.bindInt64(5, common.sync.timestamp());
        try statement.bindText(6, story_id);
        try statement.bindText(7, node_id);
        try statement.bindInt64(8, expected_revision);
        try statement.exec();
        if (self.conn.changes() == 0) return error.StaleRevision;
        return try self.get(story_id, node_id) orelse error.NodeNotFound;
    }

    fn get(self: *NodeStore, story_id: []const u8, node_id: []const u8) !?domain.Node {
        var statement = try self.conn.prepare(
            \\SELECT id, story_id, branch_id, parent_id, node_type, title, ordinal,
            \\       lifecycle, purpose, synopsis, metadata_json, revision, created_at, updated_at
            \\FROM narrative_nodes WHERE story_id = ? AND id = ?
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        try statement.bindText(2, node_id);
        if (!try statement.step()) return null;
        return try readNode(self.allocator, &statement);
    }

    fn activeBranch(self: *NodeStore, story_id: []const u8) !?[]u8 {
        var statement = try self.conn.prepare(
            "SELECT active_branch_id FROM narrative_stories WHERE id = ?",
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        if (!try statement.step()) return null;
        const value = statement.columnOptionalText(0) orelse return null;
        return try self.allocator.dupe(u8, value);
    }

    fn nodeExists(self: *NodeStore, story_id: []const u8, node_id: []const u8) !bool {
        var statement = try self.conn.prepare(
            "SELECT 1 FROM narrative_nodes WHERE story_id = ? AND id = ?",
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        try statement.bindText(2, node_id);
        return try statement.step();
    }

    fn nextOrdinal(self: *NodeStore, story_id: []const u8, parent_id: ?[]const u8) !i64 {
        var statement = if (parent_id != null)
            try self.conn.prepare(
                "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM narrative_nodes WHERE story_id = ? AND parent_id = ?",
            )
        else
            try self.conn.prepare(
                "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM narrative_nodes WHERE story_id = ? AND parent_id IS NULL",
            );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        if (parent_id) |value| try statement.bindText(2, value);
        _ = try statement.step();
        return statement.columnInt64(0);
    }
};

fn readNode(allocator: std.mem.Allocator, statement: *storage.Statement) !domain.Node {
    return .{
        .id = try allocator.dupe(u8, statement.columnText(0) orelse ""),
        .story_id = try allocator.dupe(u8, statement.columnText(1) orelse ""),
        .branch_id = if (statement.columnOptionalText(2)) |value| try allocator.dupe(u8, value) else null,
        .parent_id = if (statement.columnOptionalText(3)) |value| try allocator.dupe(u8, value) else null,
        .node_type = try allocator.dupe(u8, statement.columnText(4) orelse ""),
        .title = try allocator.dupe(u8, statement.columnText(5) orelse ""),
        .ordinal = statement.columnInt64(6),
        .lifecycle = try allocator.dupe(u8, statement.columnText(7) orelse "draft"),
        .purpose = if (statement.columnOptionalText(8)) |value| try allocator.dupe(u8, value) else null,
        .synopsis = if (statement.columnOptionalText(9)) |value| try allocator.dupe(u8, value) else null,
        .metadata_json = try allocator.dupe(u8, statement.columnText(10) orelse "{}"),
        .revision = statement.columnInt64(11),
        .created_at = statement.columnInt64(12),
        .updated_at = statement.columnInt64(13),
    };
}

fn validNodeType(value: []const u8) bool {
    return std.mem.eql(u8, value, "volume") or
        std.mem.eql(u8, value, "arc") or
        std.mem.eql(u8, value, "chapter") or
        std.mem.eql(u8, value, "scene");
}

fn validLifecycle(value: []const u8) bool {
    return std.mem.eql(u8, value, "candidate") or
        std.mem.eql(u8, value, "draft") or
        std.mem.eql(u8, value, "accepted") or
        std.mem.eql(u8, value, "complete");
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
