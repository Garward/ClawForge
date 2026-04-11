const std = @import("std");
const db_mod = @import("db.zig");

/// Namespace tree operations. Creates/resolves hierarchical path nodes.
pub const Namespaces = struct {
    conn: *db_mod.Connection,

    pub fn init(conn: *db_mod.Connection) Namespaces {
        return .{ .conn = conn };
    }

    /// Create or get a namespace node. Returns the namespace id.
    /// parent_id is null for root nodes (user level).
    pub fn ensureNode(self: *Namespaces, parent_id: ?i64, name: []const u8, node_type: []const u8) !i64 {
        // Try to find existing
        if (try self.findNode(parent_id, name)) |id| {
            return id;
        }

        // Create new
        const now = std.time.timestamp();
        var stmt = try self.conn.prepare(
            "INSERT INTO namespaces (parent_id, name, node_type, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        );
        defer stmt.deinit();

        try stmt.bindOptionalInt64(1, parent_id);
        try stmt.bindText(2, name);
        try stmt.bindText(3, node_type);
        try stmt.bindInt64(4, now);
        try stmt.bindInt64(5, now);
        try stmt.exec();

        const id = self.conn.lastInsertRowId();

        // Update materialized path
        try self.updatePath(id, parent_id, name);

        return id;
    }

    fn findNode(self: *Namespaces, parent_id: ?i64, name: []const u8) !?i64 {
        if (parent_id) |pid| {
            var stmt = try self.conn.prepare(
                "SELECT id FROM namespaces WHERE parent_id = ? AND name = ?",
            );
            defer stmt.deinit();
            try stmt.bindInt64(1, pid);
            try stmt.bindText(2, name);
            if (try stmt.step()) {
                return stmt.columnInt64(0);
            }
        } else {
            var stmt = try self.conn.prepare(
                "SELECT id FROM namespaces WHERE parent_id IS NULL AND name = ?",
            );
            defer stmt.deinit();
            try stmt.bindText(1, name);
            if (try stmt.step()) {
                return stmt.columnInt64(0);
            }
        }
        return null;
    }

    fn updatePath(self: *Namespaces, id: i64, parent_id: ?i64, name: []const u8) !void {
        var path_buf: [1024]u8 = undefined;
        var depth: i32 = 0;

        const full_path = blk: {
            if (parent_id) |pid| {
                // Get parent path
                var stmt = try self.conn.prepare(
                    "SELECT full_path, depth FROM namespace_paths WHERE namespace_id = ?",
                );
                defer stmt.deinit();
                try stmt.bindInt64(1, pid);
                if (try stmt.step()) {
                    const parent_path = stmt.columnText(0) orelse "";
                    depth = stmt.columnInt(0 + 1) + 1;
                    break :blk std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ parent_path, name }) catch return error.SqliteExecFailed;
                }
                // Parent not found in paths, shouldn't happen
                break :blk std.fmt.bufPrint(&path_buf, "{s}", .{name}) catch return error.SqliteExecFailed;
            } else {
                break :blk std.fmt.bufPrint(&path_buf, "{s}", .{name}) catch return error.SqliteExecFailed;
            }
        };

        var stmt = try self.conn.prepare(
            "INSERT OR REPLACE INTO namespace_paths (namespace_id, full_path, depth) VALUES (?, ?, ?)",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, id);
        try stmt.bindText(2, full_path);
        try stmt.bindInt(3, depth);
        try stmt.exec();
    }

    /// Ensure a full path exists, creating intermediate nodes as needed.
    /// Path format: "user/adapter/context" (slash-separated).
    /// Returns the namespace_id of the leaf node.
    pub fn ensurePath(self: *Namespaces, path: []const u8) !i64 {
        var parent_id: ?i64 = null;
        var parts = std.mem.splitScalar(u8, path, '/');
        var depth: usize = 0;

        while (parts.next()) |segment| {
            if (segment.len == 0) continue;
            const node_type = switch (depth) {
                0 => "user",
                1 => "adapter",
                else => "context",
            };
            parent_id = try self.ensureNode(parent_id, segment, node_type);
            depth += 1;
        }

        return parent_id orelse error.SqliteExecFailed;
    }

    /// Find namespace_id by full path. Returns null if not found.
    pub fn findByPath(self: *Namespaces, path: []const u8) !?i64 {
        var stmt = try self.conn.prepare(
            "SELECT namespace_id FROM namespace_paths WHERE full_path = ?",
        );
        defer stmt.deinit();
        try stmt.bindText(1, path);
        if (try stmt.step()) {
            return stmt.columnInt64(0);
        }
        return null;
    }
};
