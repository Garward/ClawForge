const std = @import("std");
const core = @import("core");
const common = @import("common");
const storage = @import("storage");

/// Formal adapter interface. Any transport (CLI socket, HTTP, Discord, etc.)
/// implements this to plug into ClawForge.
///
/// Adapters:
/// - Receive input in their own protocol
/// - Call engine.process() (the canonical API)
/// - Format and deliver output in their protocol
/// - Register themselves in the adapter_registry table
/// - Run in their own thread (except the primary adapter on main thread)
pub const Adapter = struct {
    /// Unique adapter name: "cli", "web", "discord", "http_api"
    name: []const u8,
    /// Human-readable display name
    display_name: []const u8,
    /// Adapter version
    version: []const u8,

    // VTable for runtime dispatch
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Start the adapter (bind sockets, set up listeners).
        /// Called once on daemon startup. Must not block.
        start: *const fn (ptr: *anyopaque) anyerror!void,
        /// Run the adapter's main loop. Blocks until stopped.
        /// Called in adapter's own thread (or main thread for primary).
        run: *const fn (ptr: *anyopaque) void,
        /// Stop the adapter gracefully. Called from signal handler or shutdown.
        stop: *const fn (ptr: *anyopaque) void,
    };

    pub fn start(self: Adapter) !void {
        return self.vtable.start(self.ptr);
    }

    pub fn run(self: Adapter) void {
        self.vtable.run(self.ptr);
    }

    pub fn stop(self: Adapter) void {
        self.vtable.stop(self.ptr);
    }
};

/// Register an adapter in the database. Idempotent.
pub fn registerAdapter(conn: *storage.Connection, adapter: Adapter) void {
    const now = std.time.timestamp();
    var stmt = conn.prepare(
        "INSERT OR REPLACE INTO adapter_registry (adapter_name, display_name, version, registered_at, updated_at) VALUES (?, ?, ?, ?, ?)",
    ) catch return;
    defer stmt.deinit();
    stmt.bindText(1, adapter.name) catch return;
    stmt.bindText(2, adapter.display_name) catch return;
    stmt.bindText(3, adapter.version) catch return;
    stmt.bindInt64(4, now) catch return;
    stmt.bindInt64(5, now) catch return;
    stmt.exec() catch return;
}

/// Check if adapter_registry table exists (it's created in migration 1 only if we add it).
/// For now, create it on first registration if missing.
pub fn ensureRegistryTable(conn: *storage.Connection) void {
    conn.execSimple(
        \\CREATE TABLE IF NOT EXISTS adapter_registry (
        \\    adapter_name    TEXT PRIMARY KEY,
        \\    display_name    TEXT NOT NULL,
        \\    version         TEXT NOT NULL,
        \\    schema_version  INTEGER DEFAULT 1,
        \\    metadata        TEXT DEFAULT '{}',
        \\    registered_at   INTEGER NOT NULL,
        \\    updated_at      INTEGER NOT NULL
        \\)
    ) catch {};
}

/// List registered adapters. Returns adapter names.
pub fn listRegisteredAdapters(allocator: std.mem.Allocator, conn: *storage.Connection) ![]const AdapterInfo {
    var count_stmt = conn.prepare("SELECT COUNT(*) FROM adapter_registry") catch return &.{};
    defer count_stmt.deinit();
    _ = count_stmt.step() catch return &.{};
    const count: usize = @intCast(count_stmt.columnInt64(0));
    if (count == 0) return &.{};

    const result = try allocator.alloc(AdapterInfo, count);
    var stmt = conn.prepare("SELECT adapter_name, display_name, version FROM adapter_registry ORDER BY adapter_name") catch return &.{};
    defer stmt.deinit();

    var i: usize = 0;
    while (stmt.step() catch false) {
        if (i >= count) break;
        result[i] = .{
            .name = try allocator.dupe(u8, stmt.columnText(0) orelse ""),
            .display_name = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
            .version = try allocator.dupe(u8, stmt.columnText(2) orelse ""),
        };
        i += 1;
    }
    return result[0..i];
}

pub const AdapterInfo = struct {
    name: []const u8,
    display_name: []const u8,
    version: []const u8,
};
