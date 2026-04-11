const std = @import("std");
const db_mod = @import("db.zig");
const common = @import("common");

/// Project CRUD + rolling context management.
pub const ProjectStore = struct {
    conn: *db_mod.Connection,
    allocator: std.mem.Allocator,
    namespace_id: i64,

    pub fn init(conn: *db_mod.Connection, allocator: std.mem.Allocator, namespace_id: i64) ProjectStore {
        return .{ .conn = conn, .allocator = allocator, .namespace_id = namespace_id };
    }

    pub fn createProject(self: *ProjectStore, name: []const u8, description: ?[]const u8) !ProjectInfo {
        const now = std.time.timestamp();
        var stmt = try self.conn.prepare(
            "INSERT INTO projects (namespace_id, name, description, status, rolling_state, metadata, created_at, updated_at) VALUES (?, ?, ?, 'active', '{}', '{}', ?, ?)",
        );
        defer stmt.deinit();

        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindText(2, name);
        try stmt.bindOptionalText(3, description);
        try stmt.bindInt64(4, now);
        try stmt.bindInt64(5, now);
        try stmt.exec();

        const id = self.conn.lastInsertRowId();
        return .{
            .id = id,
            .name = try self.allocator.dupe(u8, name),
            .description = if (description) |d| try self.allocator.dupe(u8, d) else null,
            .status = "active",
            .rolling_summary = null,
            .rolling_state = null,
            .created_at = now,
            .updated_at = now,
        };
    }

    pub fn getProject(self: *ProjectStore, id: i64) !ProjectInfo {
        var stmt = try self.conn.prepare(
            "SELECT id, name, description, status, rolling_summary, rolling_state, created_at, updated_at FROM projects WHERE id = ? AND namespace_id = ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, id);
        try stmt.bindInt64(2, self.namespace_id);

        if (try stmt.step()) {
            return self.readProjectRow(&stmt);
        }
        return error.ProjectNotFound;
    }

    pub fn findByName(self: *ProjectStore, name: []const u8) !?ProjectInfo {
        var stmt = try self.conn.prepare(
            "SELECT id, name, description, status, rolling_summary, rolling_state, created_at, updated_at FROM projects WHERE name = ? AND namespace_id = ? AND status != 'archived'",
        );
        defer stmt.deinit();
        try stmt.bindText(1, name);
        try stmt.bindInt64(2, self.namespace_id);

        if (try stmt.step()) {
            return try self.readProjectRow(&stmt);
        }
        return null;
    }

    pub fn listProjects(self: *ProjectStore) ![]const ProjectSummary {
        var count_stmt = try self.conn.prepare(
            "SELECT COUNT(*) FROM projects WHERE namespace_id = ?",
        );
        defer count_stmt.deinit();
        try count_stmt.bindInt64(1, self.namespace_id);
        _ = try count_stmt.step();
        const count: usize = @intCast(count_stmt.columnInt64(0));

        if (count == 0) return &.{};

        const result = try self.allocator.alloc(ProjectSummary, count);
        errdefer self.allocator.free(result);

        var stmt = try self.conn.prepare(
            "SELECT id, name, status, updated_at FROM projects WHERE namespace_id = ? ORDER BY updated_at DESC",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);

        var i: usize = 0;
        while (try stmt.step()) {
            if (i >= count) break;
            result[i] = .{
                .id = stmt.columnInt64(0),
                .name = try self.allocator.dupe(u8, stmt.columnText(1) orelse ""),
                .status = try self.allocator.dupe(u8, stmt.columnText(2) orelse "active"),
                .updated_at = stmt.columnInt64(3),
            };
            i += 1;
        }
        return result[0..i];
    }

    /// Update the rolling context for a project. Called synchronously per substantive prompt.
    pub fn updateRollingContext(self: *ProjectStore, project_id: i64, summary: ?[]const u8, state: ?[]const u8) !void {
        var stmt = try self.conn.prepare(
            "UPDATE projects SET rolling_summary = COALESCE(?, rolling_summary), rolling_state = COALESCE(?, rolling_state), updated_at = ? WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bindOptionalText(1, summary);
        try stmt.bindOptionalText(2, state);
        try stmt.bindInt64(3, std.time.timestamp());
        try stmt.bindInt64(4, project_id);
        try stmt.exec();
    }

    /// Get rolling context for a project.
    pub fn getRollingContext(self: *ProjectStore, project_id: i64) !RollingContext {
        var stmt = try self.conn.prepare(
            "SELECT rolling_summary, rolling_state FROM projects WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, project_id);

        if (try stmt.step()) {
            return .{
                .summary = if (stmt.columnOptionalText(0)) |s| try self.allocator.dupe(u8, s) else null,
                .state = if (stmt.columnOptionalText(1)) |s| try self.allocator.dupe(u8, s) else null,
            };
        }
        return error.ProjectNotFound;
    }

    /// Attach a session to a project.
    pub fn attachSession(self: *ProjectStore, session_id: []const u8, project_id: i64) !void {
        var stmt = try self.conn.prepare(
            "UPDATE sessions SET project_id = ?, updated_at = ? WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, project_id);
        try stmt.bindInt64(2, std.time.timestamp());
        try stmt.bindText(3, session_id);
        try stmt.exec();
    }

    /// Detach a session from its project.
    pub fn detachSession(self: *ProjectStore, session_id: []const u8) !void {
        var stmt = try self.conn.prepare(
            "UPDATE sessions SET project_id = NULL, updated_at = ? WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, std.time.timestamp());
        try stmt.bindText(2, session_id);
        try stmt.exec();
    }

    /// Get the project_id attached to a session, if any.
    pub fn getSessionProject(self: *ProjectStore, session_id: []const u8) !?i64 {
        var stmt = try self.conn.prepare(
            "SELECT project_id FROM sessions WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);

        if (try stmt.step()) {
            return stmt.columnOptionalInt64(0);
        }
        return null;
    }

    fn readProjectRow(self: *ProjectStore, stmt: *db_mod.Statement) !ProjectInfo {
        return .{
            .id = stmt.columnInt64(0),
            .name = try self.allocator.dupe(u8, stmt.columnText(1) orelse ""),
            .description = if (stmt.columnOptionalText(2)) |d| try self.allocator.dupe(u8, d) else null,
            .status = try self.allocator.dupe(u8, stmt.columnText(3) orelse "active"),
            .rolling_summary = if (stmt.columnOptionalText(4)) |s| try self.allocator.dupe(u8, s) else null,
            .rolling_state = if (stmt.columnOptionalText(5)) |s| try self.allocator.dupe(u8, s) else null,
            .created_at = stmt.columnInt64(6),
            .updated_at = stmt.columnInt64(7),
        };
    }
};

pub const ProjectInfo = struct {
    id: i64,
    name: []const u8,
    description: ?[]const u8,
    status: []const u8,
    rolling_summary: ?[]const u8,
    rolling_state: ?[]const u8,
    created_at: i64,
    updated_at: i64,
};

pub const ProjectSummary = struct {
    id: i64,
    name: []const u8,
    status: []const u8,
    updated_at: i64,
};

pub const RollingContext = struct {
    summary: ?[]const u8,
    state: ?[]const u8,
};
