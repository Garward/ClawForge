//! SQLite persistence for Narrative story workspaces.

const std = @import("std");
const common = @import("common");
const storage = @import("storage");
const domain = @import("../domain/root.zig");

pub const StoryStore = struct {
    allocator: std.mem.Allocator,
    conn: *storage.Connection,

    pub fn init(allocator: std.mem.Allocator, conn: *storage.Connection) StoryStore {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn create(self: *StoryStore, input: domain.CreateStory, fallback_model: []const u8) !domain.Story {
        const title = std.mem.trim(u8, input.title, " \t\r\n");
        if (title.len == 0) return error.InvalidTitle;

        var story_id: [36]u8 = undefined;
        var branch_id: [36]u8 = undefined;
        var version_id: [36]u8 = undefined;
        generateUuid(&story_id);
        generateUuid(&branch_id);
        generateUuid(&version_id);
        const now = common.sync.timestamp();
        const selected_model = input.default_model orelse fallback_model;

        try self.conn.execSimple("BEGIN IMMEDIATE");
        errdefer self.conn.execSimple("ROLLBACK") catch {};

        var story_stmt = try self.conn.prepare(
            "INSERT INTO narrative_stories (id, title, premise, genre, status, active_branch_id, active_version, created_at, updated_at) VALUES (?, ?, ?, ?, 'active', ?, 1, ?, ?)",
        );
        defer story_stmt.deinit();
        try story_stmt.bindText(1, &story_id);
        try story_stmt.bindText(2, title);
        try story_stmt.bindOptionalText(3, input.premise);
        try story_stmt.bindOptionalText(4, input.genre);
        try story_stmt.bindText(5, &branch_id);
        try story_stmt.bindInt64(6, now);
        try story_stmt.bindInt64(7, now);
        try story_stmt.exec();

        var branch_stmt = try self.conn.prepare(
            "INSERT INTO narrative_branches (id, story_id, name, status, created_at, updated_at) VALUES (?, ?, 'main', 'accepted', ?, ?)",
        );
        defer branch_stmt.deinit();
        try branch_stmt.bindText(1, &branch_id);
        try branch_stmt.bindText(2, &story_id);
        try branch_stmt.bindInt64(3, now);
        try branch_stmt.bindInt64(4, now);
        try branch_stmt.exec();

        var version_stmt = try self.conn.prepare(
            "INSERT INTO narrative_story_versions (id, story_id, branch_id, version_number, reason, created_at) VALUES (?, ?, ?, 1, 'story_created', ?)",
        );
        defer version_stmt.deinit();
        try version_stmt.bindText(1, &version_id);
        try version_stmt.bindText(2, &story_id);
        try version_stmt.bindText(3, &branch_id);
        try version_stmt.bindInt64(4, now);
        try version_stmt.exec();

        var model_stmt = try self.conn.prepare(
            "INSERT INTO narrative_model_profiles (story_id, default_model, role_overrides_json, revision, updated_at) VALUES (?, ?, '{}', 1, ?)",
        );
        defer model_stmt.deinit();
        try model_stmt.bindText(1, &story_id);
        try model_stmt.bindText(2, selected_model);
        try model_stmt.bindInt64(3, now);
        try model_stmt.exec();

        try self.conn.execSimple("COMMIT");
        return try self.get(&story_id) orelse error.StoryCreateFailed;
    }

    pub fn get(self: *StoryStore, id: []const u8) !?domain.Story {
        var statement = try self.conn.prepare(
            "SELECT id, title, premise, genre, status, active_branch_id, active_version, created_at, updated_at FROM narrative_stories WHERE id = ?",
        );
        defer statement.deinit();
        try statement.bindText(1, id);
        if (!try statement.step()) return null;
        return try readStory(self.allocator, &statement);
    }

    pub fn list(self: *StoryStore) ![]domain.Story {
        var result: std.ArrayList(domain.Story) = .empty;
        errdefer {
            for (result.items) |*story| story.deinit(self.allocator);
            result.deinit(self.allocator);
        }

        var statement = try self.conn.prepare(
            "SELECT id, title, premise, genre, status, active_branch_id, active_version, created_at, updated_at FROM narrative_stories ORDER BY updated_at DESC",
        );
        defer statement.deinit();
        while (try statement.step()) {
            try result.append(self.allocator, try readStory(self.allocator, &statement));
        }
        return try result.toOwnedSlice(self.allocator);
    }

    pub fn getModelProfile(self: *StoryStore, story_id: []const u8) !?domain.ModelProfile {
        var statement = try self.conn.prepare(
            "SELECT story_id, default_model, role_overrides_json, revision, updated_at FROM narrative_model_profiles WHERE story_id = ?",
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        if (!try statement.step()) return null;
        return .{
            .story_id = try self.allocator.dupe(u8, statement.columnText(0) orelse ""),
            .default_model = if (statement.columnOptionalText(1)) |value|
                try self.allocator.dupe(u8, value)
            else
                null,
            .role_overrides_json = try self.allocator.dupe(u8, statement.columnText(2) orelse "{}"),
            .revision = statement.columnInt64(3),
            .updated_at = statement.columnInt64(4),
        };
    }

    pub fn updateModelProfile(
        self: *StoryStore,
        story_id: []const u8,
        default_model: ?[]const u8,
        role_overrides_json: []const u8,
        expected_revision: i64,
    ) !domain.ModelProfile {
        var validate = std.json.parseFromSlice(std.json.Value, self.allocator, role_overrides_json, .{}) catch
            return error.InvalidRoleOverrides;
        defer validate.deinit();
        if (validate.value != .object) return error.InvalidRoleOverrides;

        var statement = try self.conn.prepare(
            "UPDATE narrative_model_profiles SET default_model = ?, role_overrides_json = ?, revision = revision + 1, updated_at = ? WHERE story_id = ? AND revision = ?",
        );
        defer statement.deinit();
        try statement.bindOptionalText(1, default_model);
        try statement.bindText(2, role_overrides_json);
        try statement.bindInt64(3, common.sync.timestamp());
        try statement.bindText(4, story_id);
        try statement.bindInt64(5, expected_revision);
        try statement.exec();
        if (self.conn.changes() == 0) return error.StaleRevision;
        return try self.getModelProfile(story_id) orelse error.StoryNotFound;
    }
};

fn readStory(allocator: std.mem.Allocator, statement: *storage.Statement) !domain.Story {
    return .{
        .id = try allocator.dupe(u8, statement.columnText(0) orelse ""),
        .title = try allocator.dupe(u8, statement.columnText(1) orelse ""),
        .premise = if (statement.columnOptionalText(2)) |value| try allocator.dupe(u8, value) else null,
        .genre = if (statement.columnOptionalText(3)) |value| try allocator.dupe(u8, value) else null,
        .status = try allocator.dupe(u8, statement.columnText(4) orelse "active"),
        .active_branch_id = if (statement.columnOptionalText(5)) |value| try allocator.dupe(u8, value) else null,
        .active_version = statement.columnInt64(6),
        .created_at = statement.columnInt64(7),
        .updated_at = statement.columnInt64(8),
    };
}

fn generateUuid(buffer: *[36]u8) void {
    var random_bytes: [16]u8 = undefined;
    std.Io.random(common.config.runtimeIo(), &random_bytes);
    random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40;
    random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var source: usize = 0;
    var destination: usize = 0;
    while (source < random_bytes.len) : (source += 1) {
        if (source == 4 or source == 6 or source == 8 or source == 10) {
            buffer[destination] = '-';
            destination += 1;
        }
        buffer[destination] = hex[random_bytes[source] >> 4];
        buffer[destination + 1] = hex[random_bytes[source] & 0x0f];
        destination += 2;
    }
}
