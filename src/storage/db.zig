const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Sqlite = c;

/// A single SQLite connection with prepared statement caching.
pub const Connection = struct {
    handle: *c.sqlite3,

    pub fn open(path: [*:0]const u8) !Connection {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path, &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX, null);
        if (rc != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SqliteOpenFailed;
        }
        return .{ .handle = handle.? };
    }

    pub fn close(self: *Connection) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Enable WAL mode and set pragmas for performance.
    pub fn applyPragmas(self: *Connection) !void {
        try self.execSimple("PRAGMA journal_mode=WAL");
        try self.execSimple("PRAGMA busy_timeout=5000");
        // FULL sync ensures WAL commits survive SIGKILL / power loss.
        // With WAL mode the perf cost is minimal (sync on commit, not on every write).
        try self.execSimple("PRAGMA synchronous=FULL");
        try self.execSimple("PRAGMA foreign_keys=ON");
        try self.execSimple("PRAGMA cache_size=-64000"); // 64MB cache
        // Checkpoint any WAL data left from a previous unclean shutdown
        try self.execSimple("PRAGMA wal_checkpoint(TRUNCATE)");
    }

    /// Execute a SQL statement with no results.
    pub fn execSimple(self: *Connection, sql: [*:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                std.log.err("SQLite error: {s}", .{std.mem.span(msg)});
                c.sqlite3_free(msg);
            }
            return error.SqliteExecFailed;
        }
    }

    /// Execute multiple SQL statements (for schema creation).
    pub fn execMulti(self: *Connection, sql: [*:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                std.log.err("SQLite error: {s}", .{std.mem.span(msg)});
                c.sqlite3_free(msg);
            }
            return error.SqliteExecFailed;
        }
    }

    /// Prepare a statement for execution.
    pub fn prepare(self: *Connection, sql: [*:0]const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            std.log.err("SQLite prepare error: {s}", .{c.sqlite3_errmsg(self.handle)});
            return error.SqlitePrepareFailed;
        }
        return .{ .handle = stmt.?, .db = self.handle };
    }

    pub fn lastInsertRowId(self: *Connection) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn changes(self: *Connection) i32 {
        return c.sqlite3_changes(self.handle);
    }

    pub fn errmsg(self: *Connection) [*:0]const u8 {
        return c.sqlite3_errmsg(self.handle);
    }
};

/// A prepared SQLite statement.
pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    db: *c.sqlite3,

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    // -- Bind parameters --

    pub fn bindText(self: *Statement, col: c_int, value: []const u8) !void {
        const rc = c.sqlite3_bind_text(self.handle, col, value.ptr, @intCast(value.len), c.SQLITE_TRANSIENT);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindInt(self: *Statement, col: c_int, value: i32) !void {
        const rc = c.sqlite3_bind_int(self.handle, col, value);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindInt64(self: *Statement, col: c_int, value: i64) !void {
        const rc = c.sqlite3_bind_int64(self.handle, col, value);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindNull(self: *Statement, col: c_int) !void {
        const rc = c.sqlite3_bind_null(self.handle, col);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindBlob(self: *Statement, col: c_int, value: []const u8) !void {
        const rc = c.sqlite3_bind_blob(self.handle, col, value.ptr, @intCast(value.len), c.SQLITE_TRANSIENT);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindOptionalText(self: *Statement, col: c_int, value: ?[]const u8) !void {
        if (value) |v| {
            try self.bindText(col, v);
        } else {
            try self.bindNull(col);
        }
    }

    pub fn bindOptionalInt64(self: *Statement, col: c_int, value: ?i64) !void {
        if (value) |v| {
            try self.bindInt64(col, v);
        } else {
            try self.bindNull(col);
        }
    }

    // -- Step / execute --

    /// Step the statement. Returns true if there is a row, false if done.
    pub fn step(self: *Statement) !bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        std.log.err("SQLite step error: {s}", .{c.sqlite3_errmsg(self.db)});
        return error.SqliteStepFailed;
    }

    /// Execute a statement that should not return rows.
    pub fn exec(self: *Statement) !void {
        _ = try self.step();
    }

    pub fn reset(self: *Statement) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    // -- Read columns --

    pub fn columnText(self: *Statement, col: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_text(self.handle, col);
        if (ptr == null) return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, col));
        return ptr[0..len];
    }

    pub fn columnInt(self: *Statement, col: c_int) i32 {
        return c.sqlite3_column_int(self.handle, col);
    }

    pub fn columnInt64(self: *Statement, col: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, col);
    }

    pub fn columnOptionalText(self: *Statement, col: c_int) ?[]const u8 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) return null;
        return self.columnText(col);
    }

    pub fn columnBlob(self: *Statement, col: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_blob(self.handle, col);
        if (ptr == null) return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, col));
        const byte_ptr: [*]const u8 = @ptrCast(ptr.?);
        return byte_ptr[0..len];
    }

    pub fn columnOptionalInt64(self: *Statement, col: c_int) ?i64 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) return null;
        return self.columnInt64(col);
    }
};

/// Database manager with connection pool.
/// Primary connection is used for the main thread (migrations, adapters).
/// Additional connections can be opened for worker threads via openConnection().
/// All connections share the same WAL-mode database — SQLite handles concurrency:
///   - Multiple readers: concurrent (each has own connection)
///   - Single writer: serialized via SQLite's WAL write lock + busy_timeout
pub const Database = struct {
    conn: Connection,
    allocator: std.mem.Allocator,
    path: []const u8,
    /// Extra connections vended to worker threads. Cleaned up on deinit.
    extra_conns: std.ArrayList(Connection),

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8) !Database {
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const db_path = try std.fs.path.joinZ(allocator, &.{ dir_path, "workspace.db" });

        var conn = try Connection.open(db_path);
        errdefer conn.close();

        try conn.applyPragmas();

        return .{
            .conn = conn,
            .allocator = allocator,
            .path = db_path,
            .extra_conns = .{},
        };
    }

    /// Open a new connection to the same database for use on a separate thread.
    /// The returned connection has WAL pragmas applied and is safe for concurrent use.
    /// Caller does NOT need to close it — Database.deinit() handles cleanup.
    pub fn openConnection(self: *Database) !*Connection {
        var conn = try Connection.open(@ptrCast(self.path.ptr));
        errdefer conn.close();
        try conn.applyPragmas();
        try self.extra_conns.append(self.allocator, conn);
        return &self.extra_conns.items[self.extra_conns.items.len - 1];
    }

    pub fn deinit(self: *Database) void {
        for (self.extra_conns.items) |*ec| {
            ec.close();
        }
        self.extra_conns.deinit(self.allocator);
        self.conn.close();
        self.allocator.free(self.path);
    }
};
