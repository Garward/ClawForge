//! Persistence for canonical narrative records and required story packages.

const std = @import("std");
const common = @import("common");
const storage = @import("storage");
const domain = @import("../domain/root.zig");

pub const RecordStore = struct {
    allocator: std.mem.Allocator,
    conn: *storage.Connection,

    pub fn init(allocator: std.mem.Allocator, conn: *storage.Connection) RecordStore {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn ensureStoryPackage(self: *RecordStore, story_id: []const u8) !void {
        const now = common.sync.timestamp();
        for (domain.required_story_record_types) |record_type| {
            var id: [36]u8 = undefined;
            generateUuid(&id);
            var statement = try self.conn.prepare(
                \\INSERT INTO narrative_records
                \\ (id, story_id, record_type, lifecycle, truth_class, value_json,
                \\  provenance_json, revision, created_at, updated_at)
                \\ SELECT ?, ?, ?, 'draft', 'authorial', '{}', '[]', 1, ?, ?
                \\ WHERE NOT EXISTS (
                \\   SELECT 1 FROM narrative_records
                \\   WHERE story_id = ? AND branch_id IS NULL AND record_type = ?
                \\ )
            );
            defer statement.deinit();
            try statement.bindText(1, &id);
            try statement.bindText(2, story_id);
            try statement.bindText(3, record_type);
            try statement.bindInt64(4, now);
            try statement.bindInt64(5, now);
            try statement.bindText(6, story_id);
            try statement.bindText(7, record_type);
            try statement.exec();
        }
    }

    pub fn listForStory(self: *RecordStore, story_id: []const u8) ![]domain.Record {
        try self.ensureStoryPackage(story_id);
        var result: std.ArrayList(domain.Record) = .empty;
        errdefer {
            for (result.items) |*record| record.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        var statement = try self.conn.prepare(
            \\SELECT id, story_id, parent_id, record_type, lifecycle, truth_class,
            \\       value_json, provenance_json, revision, created_at, updated_at
            \\FROM narrative_records
            \\WHERE story_id = ? AND branch_id IS NULL
            \\ORDER BY record_type, created_at
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        while (try statement.step()) {
            try result.append(self.allocator, try readRecord(self.allocator, &statement));
        }
        return try result.toOwnedSlice(self.allocator);
    }

    pub fn update(
        self: *RecordStore,
        story_id: []const u8,
        record_id: []const u8,
        value_json: []const u8,
        lifecycle: []const u8,
        expected_revision: i64,
    ) !domain.Record {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, value_json, .{}) catch
            return error.InvalidRecordValue;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidRecordValue;
        if (!validLifecycle(lifecycle)) return error.InvalidLifecycle;

        var statement = try self.conn.prepare(
            \\UPDATE narrative_records
            \\SET value_json = ?, lifecycle = ?, revision = revision + 1, updated_at = ?
            \\WHERE id = ? AND story_id = ? AND revision = ?
        );
        defer statement.deinit();
        try statement.bindText(1, value_json);
        try statement.bindText(2, lifecycle);
        try statement.bindInt64(3, common.sync.timestamp());
        try statement.bindText(4, record_id);
        try statement.bindText(5, story_id);
        try statement.bindInt64(6, expected_revision);
        try statement.exec();
        if (self.conn.changes() == 0) return error.StaleRevision;
        return try self.get(story_id, record_id) orelse error.RecordNotFound;
    }

    pub fn appendDerived(
        self: *RecordStore,
        story_id: []const u8,
        parent_id: ?[]const u8,
        record_type: []const u8,
        value_json: []const u8,
        provenance_json: []const u8,
    ) !domain.Record {
        var parsed_value = std.json.parseFromSlice(std.json.Value, self.allocator, value_json, .{}) catch
            return error.InvalidRecordValue;
        defer parsed_value.deinit();
        if (parsed_value.value != .object) return error.InvalidRecordValue;
        var parsed_provenance = std.json.parseFromSlice(std.json.Value, self.allocator, provenance_json, .{}) catch
            return error.InvalidProvenance;
        defer parsed_provenance.deinit();
        if (parsed_provenance.value != .array) return error.InvalidProvenance;
        var id: [36]u8 = undefined;
        generateUuid(&id);
        const now = common.sync.timestamp();
        var statement = try self.conn.prepare(
            \\INSERT INTO narrative_records
            \\ (id, story_id, parent_id, record_type, lifecycle, truth_class,
            \\  value_json, provenance_json, revision, created_at, updated_at)
            \\VALUES (?, ?, ?, ?, 'accepted', 'observed', ?, ?, 1, ?, ?)
        );
        defer statement.deinit();
        try statement.bindText(1, &id);
        try statement.bindText(2, story_id);
        try statement.bindOptionalText(3, parent_id);
        try statement.bindText(4, record_type);
        try statement.bindText(5, value_json);
        try statement.bindText(6, provenance_json);
        try statement.bindInt64(7, now);
        try statement.bindInt64(8, now);
        try statement.exec();
        return try self.get(story_id, &id) orelse error.RecordCreateFailed;
    }

    fn get(self: *RecordStore, story_id: []const u8, record_id: []const u8) !?domain.Record {
        var statement = try self.conn.prepare(
            \\SELECT id, story_id, parent_id, record_type, lifecycle, truth_class,
            \\       value_json, provenance_json, revision, created_at, updated_at
            \\FROM narrative_records WHERE story_id = ? AND id = ?
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        try statement.bindText(2, record_id);
        if (!try statement.step()) return null;
        return try readRecord(self.allocator, &statement);
    }
};

fn validLifecycle(value: []const u8) bool {
    return std.mem.eql(u8, value, "candidate") or
        std.mem.eql(u8, value, "draft") or
        std.mem.eql(u8, value, "accepted") or
        std.mem.eql(u8, value, "superseded") or
        std.mem.eql(u8, value, "rejected");
}

fn readRecord(allocator: std.mem.Allocator, statement: *storage.Statement) !domain.Record {
    return .{
        .id = try allocator.dupe(u8, statement.columnText(0) orelse ""),
        .story_id = try allocator.dupe(u8, statement.columnText(1) orelse ""),
        .parent_id = if (statement.columnOptionalText(2)) |value| try allocator.dupe(u8, value) else null,
        .record_type = try allocator.dupe(u8, statement.columnText(3) orelse ""),
        .lifecycle = try allocator.dupe(u8, statement.columnText(4) orelse "draft"),
        .truth_class = try allocator.dupe(u8, statement.columnText(5) orelse "authorial"),
        .value_json = try allocator.dupe(u8, statement.columnText(6) orelse "{}"),
        .provenance_json = try allocator.dupe(u8, statement.columnText(7) orelse "[]"),
        .revision = statement.columnInt64(8),
        .created_at = statement.columnInt64(9),
        .updated_at = statement.columnInt64(10),
    };
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
