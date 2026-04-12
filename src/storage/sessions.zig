const std = @import("std");
const db_mod = @import("db.zig");
const common = @import("common");

/// SQLite-backed session manager. Drop-in replacement for the old in-memory SessionManager.
pub const SessionStore = struct {
    conn: *db_mod.Connection,
    allocator: std.mem.Allocator,
    namespace_id: i64,
    default_model: []const u8,
    active_session_id: ?[36]u8,

    pub fn init(
        conn: *db_mod.Connection,
        allocator: std.mem.Allocator,
        namespace_id: i64,
        default_model: []const u8,
    ) SessionStore {
        return .{
            .conn = conn,
            .allocator = allocator,
            .namespace_id = namespace_id,
            .default_model = default_model,
            .active_session_id = null,
        };
    }

    pub fn createSession(self: *SessionStore, name: ?[]const u8) !SessionInfo {
        var id: [36]u8 = undefined;
        generateUUID(&id);
        const now = std.time.timestamp();

        var stmt = try self.conn.prepare(
            "INSERT INTO sessions (id, namespace_id, name, model, status, message_count, created_at, updated_at) VALUES (?, ?, ?, ?, 'active', 0, ?, ?)",
        );
        defer stmt.deinit();

        try stmt.bindText(1, &id);
        try stmt.bindInt64(2, self.namespace_id);
        try stmt.bindOptionalText(3, name);
        try stmt.bindText(4, self.default_model);
        try stmt.bindInt64(5, now);
        try stmt.bindInt64(6, now);
        try stmt.exec();

        self.active_session_id = id;

        return .{
            .id = id,
            .name = if (name) |n| try self.allocator.dupe(u8, n) else null,
            .model = self.default_model,
            .system_prompt = null,
            .message_count = 0,
            .created_at = now,
            .updated_at = now,
        };
    }

    pub fn getActiveSession(self: *SessionStore) ?SessionInfo {
        if (self.active_session_id) |id| {
            return self.getSession(&id) catch null;
        }
        // No active session in memory — try to resume the most recent one from DB
        return self.resumeLatestSession();
    }

    /// Resume the most recently updated session from the DB.
    fn resumeLatestSession(self: *SessionStore) ?SessionInfo {
        var stmt = self.conn.prepare(
            "SELECT id FROM sessions WHERE namespace_id = ? AND status = 'active' ORDER BY updated_at DESC LIMIT 1",
        ) catch return null;
        defer stmt.deinit();
        stmt.bindInt64(1, self.namespace_id) catch return null;

        if (stmt.step() catch false) {
            const id_text = stmt.columnText(0) orelse return null;
            if (id_text.len == 36) {
                var id_buf: [36]u8 = undefined;
                @memcpy(&id_buf, id_text[0..36]);
                self.active_session_id = id_buf;
                return self.getSession(&self.active_session_id.?) catch null;
            }
        }
        return null;
    }

    pub fn getSession(self: *SessionStore, id: []const u8) !SessionInfo {
        var stmt = try self.conn.prepare(
            "SELECT id, name, model, system_prompt, message_count, created_at, updated_at FROM sessions WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bindText(1, id);

        if (try stmt.step()) {
            const sess_id = stmt.columnText(0) orelse return error.SqliteStepFailed;
            var result_id: [36]u8 = undefined;
            @memcpy(&result_id, sess_id[0..36]);

            return .{
                .id = result_id,
                .name = if (stmt.columnOptionalText(1)) |n| try self.allocator.dupe(u8, n) else null,
                .model = try self.allocator.dupe(u8, stmt.columnText(2) orelse self.default_model),
                .system_prompt = if (stmt.columnOptionalText(3)) |s| try self.allocator.dupe(u8, s) else null,
                .message_count = @intCast(stmt.columnInt64(4)),
                .created_at = stmt.columnInt64(5),
                .updated_at = stmt.columnInt64(6),
            };
        }
        return error.SessionNotFound;
    }

    pub fn switchSession(self: *SessionStore, id: []const u8) !void {
        if (id.len != 36) return error.InvalidSessionId;

        // Verify it exists
        var stmt = try self.conn.prepare("SELECT 1 FROM sessions WHERE id = ?");
        defer stmt.deinit();
        try stmt.bindText(1, id);
        if (!try stmt.step()) return error.SessionNotFound;

        var id_buf: [36]u8 = undefined;
        @memcpy(&id_buf, id[0..36]);
        self.active_session_id = id_buf;
    }

    pub fn deleteSession(self: *SessionStore, id: []const u8) !void {
        if (id.len != 36) return error.InvalidSessionId;

        var stmt = try self.conn.prepare("DELETE FROM sessions WHERE id = ?");
        defer stmt.deinit();
        try stmt.bindText(1, id);
        try stmt.exec();

        if (self.conn.changes() == 0) return error.SessionNotFound;

        // Clear active if it was this session
        if (self.active_session_id) |active_id| {
            if (std.mem.eql(u8, &active_id, id)) {
                self.active_session_id = null;
            }
        }
    }

    pub fn listSessions(self: *SessionStore) ![]const common.protocol.Response.SessionSummary {
        return self.listSessionsByStatus("active");
    }

    pub fn listSessionsByStatus(self: *SessionStore, status: []const u8) ![]const common.protocol.Response.SessionSummary {
        var stmt = try self.conn.prepare(
            "SELECT id, name, message_count, updated_at FROM sessions WHERE namespace_id = ? AND status = ? ORDER BY updated_at DESC",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindText(2, status);

        var buf: [128]common.protocol.Response.SessionSummary = undefined;
        var i: usize = 0;
        while (try stmt.step()) {
            if (i >= buf.len) break;
            buf[i] = .{
                .id = try self.allocator.dupe(u8, stmt.columnText(0) orelse ""),
                .name = if (stmt.columnOptionalText(1)) |n| try self.allocator.dupe(u8, n) else null,
                .message_count = @intCast(stmt.columnInt64(2)),
                .updated_at = stmt.columnInt64(3),
            };
            i += 1;
        }

        if (i == 0) return &.{};
        const result = try self.allocator.alloc(common.protocol.Response.SessionSummary, i);
        @memcpy(result, buf[0..i]);
        return result;
    }

    pub fn updateModel(self: *SessionStore, id: []const u8, model: []const u8) !void {
        var stmt = try self.conn.prepare("UPDATE sessions SET model = ?, updated_at = ? WHERE id = ?");
        defer stmt.deinit();
        try stmt.bindText(1, model);
        try stmt.bindInt64(2, std.time.timestamp());
        try stmt.bindText(3, id);
        try stmt.exec();
    }

    pub fn updateSystemPrompt(self: *SessionStore, id: []const u8, system_prompt: ?[]const u8) !void {
        var stmt = try self.conn.prepare("UPDATE sessions SET system_prompt = ?, updated_at = ? WHERE id = ?");
        defer stmt.deinit();
        try stmt.bindOptionalText(1, system_prompt);
        try stmt.bindInt64(2, std.time.timestamp());
        try stmt.bindText(3, id);
        try stmt.exec();
    }

    /// Get session count for the current namespace.
    pub fn sessionCount(self: *SessionStore) !u32 {
        var stmt = try self.conn.prepare("SELECT COUNT(*) FROM sessions WHERE namespace_id = ?");
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        _ = try stmt.step();
        return @intCast(stmt.columnInt64(0));
    }

    pub fn renameSession(self: *SessionStore, id: []const u8, name: []const u8) !void {
        var stmt = try self.conn.prepare("UPDATE sessions SET name = ?, updated_at = ? WHERE id = ? AND namespace_id = ?");
        defer stmt.deinit();
        try stmt.bindText(1, name);
        try stmt.bindInt64(2, std.time.timestamp());
        try stmt.bindText(3, id);
        try stmt.bindInt64(4, self.namespace_id);
        try stmt.exec();
    }

    pub fn setSessionStatus(self: *SessionStore, id: []const u8, status: []const u8) !void {
        var stmt = try self.conn.prepare("UPDATE sessions SET status = ?, updated_at = ? WHERE id = ? AND namespace_id = ?");
        defer stmt.deinit();
        try stmt.bindText(1, status);
        try stmt.bindInt64(2, std.time.timestamp());
        try stmt.bindText(3, id);
        try stmt.bindInt64(4, self.namespace_id);
        try stmt.exec();
    }

    pub fn freeSessionInfo(self: *SessionStore, info: *SessionInfo) void {
        if (info.name) |n| self.allocator.free(n);
        // model and system_prompt may alias default_model or be allocated
        if (info.model.ptr != self.default_model.ptr) {
            self.allocator.free(info.model);
        }
        if (info.system_prompt) |sp| self.allocator.free(sp);
    }
};

/// Session metadata (read from DB). Not the full message history — that's in messages.zig.
pub const SessionInfo = struct {
    id: [36]u8,
    name: ?[]const u8,
    model: []const u8,
    system_prompt: ?[]const u8,
    message_count: usize,
    created_at: i64,
    updated_at: i64,
};

fn generateUUID(buf: *[36]u8) void {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40;
    random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var i: usize = 0;
    var j: usize = 0;

    while (i < 16) : (i += 1) {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[j] = '-';
            j += 1;
        }
        buf[j] = hex[random_bytes[i] >> 4];
        buf[j + 1] = hex[random_bytes[i] & 0x0f];
        j += 2;
    }
}
