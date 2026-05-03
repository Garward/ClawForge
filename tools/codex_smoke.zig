//! Smoke test for codex OAuth store. Reads `~/.codex/auth.json`, decodes
//! the JWT, and prints account_id + expiry info. No network calls.
//!
//! Run with:
//!   zig run tools/codex_smoke.zig --dep codex_oauth -Mcodex_oauth=src/api/codex_oauth.zig
//! or via `zig build smoke-codex` if wired.

const std = @import("std");
const codex_oauth = @import("codex_oauth");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const path = try std.fmt.allocPrint(allocator, "{s}/.codex/auth.json", .{home});
    defer allocator.free(path);

    var store = try codex_oauth.Store.init(allocator, path);
    defer store.deinit();

    const now = std.time.timestamp();
    const seconds_left = store.tokens.expires_at - now;

    std.debug.print("codex auth loaded:\n", .{});
    std.debug.print("  path:        {s}\n", .{path});
    std.debug.print("  account_id:  {s}\n", .{store.tokens.account_id});
    std.debug.print("  expires_at:  {d} (in {d} seconds)\n", .{ store.tokens.expires_at, seconds_left });
    std.debug.print("  access_len:  {d} bytes\n", .{store.tokens.access_token.len});
    std.debug.print("  refresh_len: {d} bytes\n", .{store.tokens.refresh_token.len});
    std.debug.print("  id_token:    {d} bytes\n", .{store.tokens.id_token.len});

    if (seconds_left < 0) {
        std.debug.print("  STATUS:      EXPIRED — would refresh on first request\n", .{});
    } else if (seconds_left < 60) {
        std.debug.print("  STATUS:      expiring soon — would refresh on first request\n", .{});
    } else {
        std.debug.print("  STATUS:      valid\n", .{});
    }
}
