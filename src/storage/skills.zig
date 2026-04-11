const std = @import("std");
const db_mod = @import("db.zig");

/// Skill — a reusable instruction template with trigger matching.
pub const Skill = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    trigger_type: []const u8,
    trigger_value: ?[]const u8,
    instruction: []const u8,
    priority: i64,
    enabled: bool,
};

pub const CreateParams = struct {
    name: []const u8,
    category: []const u8 = "general",
    trigger_type: []const u8 = "always",
    trigger_value: ?[]const u8 = null,
    instruction: []const u8,
    priority: i64 = 0,
};

pub const UpdateParams = struct {
    name: ?[]const u8 = null,
    category: ?[]const u8 = null,
    trigger_type: ?[]const u8 = null,
    trigger_value: ?[]const u8 = null,
    instruction: ?[]const u8 = null,
    priority: ?i64 = null,
    enabled: ?bool = null,
};

/// Skills CRUD + trigger-based matching for prompt injection.
pub const SkillStore = struct {
    conn: *db_mod.Connection,
    allocator: std.mem.Allocator,
    namespace_id: i64,

    pub fn init(conn: *db_mod.Connection, allocator: std.mem.Allocator, namespace_id: i64) SkillStore {
        return .{ .conn = conn, .allocator = allocator, .namespace_id = namespace_id };
    }

    pub fn create(self: *SkillStore, params: CreateParams) !i64 {
        const now = std.time.timestamp();
        var stmt = try self.conn.prepare(
            "INSERT INTO skills (namespace_id, name, category, trigger_type, trigger_value, " ++
                "instruction, priority, enabled, created_at, updated_at) " ++
                "VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)",
        );
        defer stmt.deinit();

        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindText(2, params.name);
        try stmt.bindText(3, params.category);
        try stmt.bindText(4, params.trigger_type);
        try stmt.bindOptionalText(5, params.trigger_value);
        try stmt.bindText(6, params.instruction);
        try stmt.bindInt64(7, params.priority);
        try stmt.bindInt64(8, now);
        try stmt.bindInt64(9, now);
        try stmt.exec();

        return self.conn.lastInsertRowId();
    }

    pub fn delete(self: *SkillStore, id: i64) !void {
        var stmt = try self.conn.prepare("DELETE FROM skills WHERE id = ? AND namespace_id = ?");
        defer stmt.deinit();
        try stmt.bindInt64(1, id);
        try stmt.bindInt64(2, self.namespace_id);
        try stmt.exec();
    }

    pub fn setEnabled(self: *SkillStore, id: i64, enabled: bool) !void {
        const now = std.time.timestamp();
        var stmt = try self.conn.prepare("UPDATE skills SET enabled = ?, updated_at = ? WHERE id = ? AND namespace_id = ?");
        defer stmt.deinit();
        try stmt.bindInt64(1, if (enabled) 1 else 0);
        try stmt.bindInt64(2, now);
        try stmt.bindInt64(3, id);
        try stmt.bindInt64(4, self.namespace_id);
        try stmt.exec();
    }

    pub fn list(self: *SkillStore, limit: usize) ![]const Skill {
        var stmt = try self.conn.prepare(
            "SELECT id, name, category, trigger_type, trigger_value, instruction, priority, enabled " ++
                "FROM skills WHERE namespace_id = ? ORDER BY priority DESC, name ASC LIMIT ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindInt64(2, @intCast(limit));

        var buf: [128]Skill = undefined;
        var n: usize = 0;
        while (try stmt.step()) {
            if (n >= buf.len) break;
            buf[n] = try self.readSkill(&stmt);
            n += 1;
        }

        if (n == 0) return &.{};
        const result = try self.allocator.alloc(Skill, n);
        @memcpy(result, buf[0..n]);
        return result;
    }

    /// Match skills against current request context.
    /// Returns skills whose triggers fire, up to max_chars of instruction text.
    pub fn matchForContext(
        self: *SkillStore,
        enabled_tools: []const []const u8,
        user_message: []const u8,
        max_chars: usize,
    ) ![]const Skill {
        var stmt = try self.conn.prepare(
            "SELECT id, name, category, trigger_type, trigger_value, instruction, priority, enabled " ++
                "FROM skills WHERE namespace_id = ? AND enabled = 1 ORDER BY priority DESC",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);

        var buf: [64]Skill = undefined;
        var n: usize = 0;
        var total_chars: usize = 0;

        while (try stmt.step()) {
            const skill = try self.readSkill(&stmt);

            // Check trigger
            const matches = switch_trigger: {
                if (std.mem.eql(u8, skill.trigger_type, "always")) break :switch_trigger true;

                if (std.mem.eql(u8, skill.trigger_type, "tool")) {
                    if (skill.trigger_value) |tv| {
                        var it = std.mem.splitScalar(u8, tv, ',');
                        while (it.next()) |trigger_tool| {
                            const trimmed = std.mem.trim(u8, trigger_tool, " ");
                            for (enabled_tools) |et| {
                                if (std.mem.eql(u8, et, trimmed)) break :switch_trigger true;
                            }
                        }
                    }
                    break :switch_trigger false;
                }

                if (std.mem.eql(u8, skill.trigger_type, "keyword")) {
                    if (skill.trigger_value) |tv| {
                        // Case-insensitive keyword check
                        var msg_lower_buf: [4096]u8 = undefined;
                        const msg_len = @min(user_message.len, msg_lower_buf.len);
                        for (user_message[0..msg_len], 0..) |c, i| {
                            msg_lower_buf[i] = std.ascii.toLower(c);
                        }
                        const msg_lower = msg_lower_buf[0..msg_len];

                        var it = std.mem.splitScalar(u8, tv, ',');
                        while (it.next()) |kw| {
                            const trimmed = std.mem.trim(u8, kw, " ");
                            // Lowercase the keyword too
                            var kw_lower_buf: [128]u8 = undefined;
                            const kw_len = @min(trimmed.len, kw_lower_buf.len);
                            for (trimmed[0..kw_len], 0..) |c, i| {
                                kw_lower_buf[i] = std.ascii.toLower(c);
                            }
                            if (std.mem.indexOf(u8, msg_lower, kw_lower_buf[0..kw_len]) != null) {
                                break :switch_trigger true;
                            }
                        }
                    }
                    break :switch_trigger false;
                }

                break :switch_trigger false;
            };

            if (!matches) continue;

            // Budget check
            if (total_chars + skill.instruction.len > max_chars and n > 0) break;
            total_chars += skill.instruction.len;

            if (n >= buf.len) break;
            buf[n] = skill;
            n += 1;
        }

        if (n == 0) return &.{};
        const result = try self.allocator.alloc(Skill, n);
        @memcpy(result, buf[0..n]);
        return result;
    }

    fn readSkill(self: *SkillStore, stmt: *db_mod.Statement) !Skill {
        return .{
            .id = stmt.columnInt64(0),
            .name = try self.allocator.dupe(u8, stmt.columnText(1) orelse ""),
            .category = try self.allocator.dupe(u8, stmt.columnText(2) orelse "general"),
            .trigger_type = try self.allocator.dupe(u8, stmt.columnText(3) orelse "always"),
            .trigger_value = if (stmt.columnOptionalText(4)) |v| try self.allocator.dupe(u8, v) else null,
            .instruction = try self.allocator.dupe(u8, stmt.columnText(5) orelse ""),
            .priority = stmt.columnInt64(6),
            .enabled = stmt.columnInt64(7) != 0,
        };
    }

    pub fn count(self: *SkillStore) !usize {
        var stmt = try self.conn.prepare("SELECT COUNT(*) FROM skills WHERE namespace_id = ?");
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        _ = try stmt.step();
        return @intCast(stmt.columnInt64(0));
    }
};
