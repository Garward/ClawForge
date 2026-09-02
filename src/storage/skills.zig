const std = @import("std");
const common = @import("common");
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

    /// Add or refresh built-in operational guidance without touching other skills.
    pub fn ensureBuiltinSkills(self: *SkillStore) !void {
        const now = common.sync.timestamp();
        var stmt = try self.conn.prepare(
            "INSERT INTO skills " ++
                "(namespace_id, name, category, trigger_type, trigger_value, instruction, priority, enabled, created_at, updated_at) " ++
                "VALUES (?, 'ClawForge operations', 'operations', 'keyword', ?, ?, 30, 1, ?, ?) " ++
                "ON CONFLICT(namespace_id, name) DO UPDATE SET " ++
                "category = excluded.category, trigger_type = excluded.trigger_type, " ++
                "trigger_value = excluded.trigger_value, instruction = excluded.instruction, " ++
                "priority = excluded.priority, enabled = 1, updated_at = excluded.updated_at",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindText(2, "clawforge,clawforged,clawforge-update,clawforge-active,workspace.db");
        try stmt.bindText(3,
            \\For ClawForge operational questions, first distinguish the Git source checkout from the active runtime. The recommended source workspace is ClawForge/repo for Git and builds plus ClawForge/runtime for active use. Release installs default to ${XDG_DATA_HOME:-$HOME/.local/share}/clawforge. Confirm actual paths from CLAWFORGE_ROOT, CLAWFORGE_DB, CLAWFORGE_DAEMON, the running process, or .env instead of assuming.
            \\
            \\The active root owns mutable state: .env contains secrets and machine paths; config/config.json contains provider, routing, adapter, and tool settings; config/personas contains personas; data/workspace.db contains sessions, messages, knowledge, projects, and skills; data/auth-profiles.json and token files are sensitive. Never replace these during an update. Back up .env, config, and data before destructive maintenance or database repair.
            \\
            \\From source, use scripts/deploy.sh --build, then restart the active tree. A build failure must leave the active runtime unchanged. From an installed release, use clawforge-update; it downloads the latest versioned archive, verifies its SHA-256 checksum, preserves runtime data/config, and restarts only if already running. restart.sh clean deletes messages and sessions and requires explicit user intent.
            \\
            \\The clawforged Zig daemon owns the model providers, agent loop, tools, workers, SQLite storage, web UI, and socket server. The clawforge binary is the CLI. The Discord adapter launches bridges/discord_bridge.py with the active .venv. For failures, check /tmp/clawforge.log, /tmp/clawforge_rebuild.log, the configured paths, and http://127.0.0.1:8081/api/status.
        );
        try stmt.bindInt64(4, now);
        try stmt.bindInt64(5, now);
        try stmt.exec();
    }

    pub fn create(self: *SkillStore, params: CreateParams) !i64 {
        const now = common.sync.timestamp();
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
        const now = common.sync.timestamp();
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
    /// Explicit $skill-name or @skill-name invocations always win. Implicit
    /// matches respect max_chars and are selected in priority order.
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
            const explicitly_invoked = containsSkillInvocation(user_message, skill.name);

            // Check trigger
            const matches = switch_trigger: {
                if (explicitly_invoked) break :switch_trigger true;
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
                        var it = std.mem.splitScalar(u8, tv, ',');
                        while (it.next()) |kw| {
                            const trimmed = std.mem.trim(u8, kw, " ");
                            if (containsKeyword(user_message, trimmed)) {
                                break :switch_trigger true;
                            }
                        }
                    }
                    break :switch_trigger false;
                }

                break :switch_trigger false;
            };

            if (!matches) continue;

            // Keep looking after an oversized implicit skill: a lower-priority
            // explicit invocation may still appear later in the result set.
            if (!explicitly_invoked and total_chars + skill.instruction.len > max_chars and n > 0) continue;
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

fn isWordChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

fn containsKeyword(message: []const u8, raw_keyword: []const u8) bool {
    const keyword = std.mem.trim(u8, raw_keyword, &std.ascii.whitespace);
    if (keyword.len == 0 or keyword.len > message.len) return false;

    var start: usize = 0;
    while (start + keyword.len <= message.len) : (start += 1) {
        if (!std.ascii.eqlIgnoreCase(message[start .. start + keyword.len], keyword)) continue;

        const before_ok = start == 0 or !isWordChar(keyword[0]) or !isWordChar(message[start - 1]);
        const end = start + keyword.len;
        const after_ok = end == message.len or !isWordChar(keyword[keyword.len - 1]) or !isWordChar(message[end]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn skillSlug(name: []const u8, output: []u8) []const u8 {
    var len: usize = 0;
    var pending_dash = false;
    for (name) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            if (pending_dash and len > 0 and len < output.len) {
                output[len] = '-';
                len += 1;
            }
            if (len >= output.len) break;
            output[len] = std.ascii.toLower(char);
            len += 1;
            pending_dash = false;
        } else if (len > 0) {
            pending_dash = true;
        }
    }
    return output[0..len];
}

fn containsSkillInvocation(message: []const u8, name: []const u8) bool {
    var slug_buf: [128]u8 = undefined;
    const slug = skillSlug(name, &slug_buf);
    if (slug.len == 0) return false;

    for (message, 0..) |char, index| {
        if (char != '$' and char != '@') continue;
        const start = index + 1;
        if (start + slug.len > message.len) continue;
        if (!std.ascii.eqlIgnoreCase(message[start .. start + slug.len], slug)) continue;
        const end = start + slug.len;
        if (end == message.len or (!isWordChar(message[end]) and message[end] != '-')) return true;
    }
    return false;
}

test "keyword matching is case insensitive and respects word boundaries" {
    try std.testing.expect(containsKeyword("Please update ClawForge now", "clawforge"));
    try std.testing.expect(containsKeyword("Use CC:Tweaked", "cc:tweaked"));
    try std.testing.expect(!containsKeyword("Choose a model", "mod"));
    try std.testing.expect(!containsKeyword("unrelated", ""));
}

test "skill invocation uses a stable slug and token boundary" {
    try std.testing.expect(containsSkillInvocation("Use $clawforge-operations for this", "ClawForge operations"));
    try std.testing.expect(containsSkillInvocation("@CLAWFORGE-OPERATIONS", "ClawForge operations"));
    try std.testing.expect(!containsSkillInvocation("$clawforge-operations-extra", "ClawForge operations"));
}
