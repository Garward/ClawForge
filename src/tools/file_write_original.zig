const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "file_write",
    .description = "Write content to a file. Creates the file if it doesn't exist, or overwrites if it does.",
    .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to write to"},"content":{"type":"string","description":"Content to write to the file"}},"required":["path","content"]}
    ,
    .requires_confirmation = true,
    .handler = &execute,
};

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    const raw_path = blk: {
        if (input == .object) {
            if (input.object.get("path")) |p| {
                if (p == .string) {
                    break :blk p.string;
                }
            }
        }
        return .{ .content = "Missing 'path' parameter", .is_error = true };
    };

    // Expand ~ to home directory
    const path = if (raw_path.len > 0 and raw_path[0] == '~') blk: {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        break :blk std.fmt.allocPrint(allocator, "{s}{s}", .{ home, raw_path[1..] }) catch
            return .{ .content = "Path expansion failed", .is_error = true };
    } else if (raw_path.len == 0 or raw_path[0] != '/') {
        return .{ .content = "Path must be absolute (start with / or ~)", .is_error = true };
    } else raw_path;

    const content = blk: {
        if (input == .object) {
            if (input.object.get("content")) |c| {
                if (c == .string) {
                    break :blk c.string;
                }
            }
        }
        return .{ .content = "Missing 'content' parameter", .is_error = true };
    };

    // Security: reject path traversal
    if (std.mem.indexOf(u8, path, "..") != null) {
        return .{ .content = "Path traversal not allowed", .is_error = true };
    }

    // Create backup if file exists
    if (std.fs.openFileAbsolute(path, .{})) |existing| {
        existing.close();

        // Create backup
        var backup_path_buf: [4096]u8 = undefined;
        const timestamp = std.time.timestamp();
        const backup_path = std.fmt.bufPrint(&backup_path_buf, "{s}.backup.{d}", .{ path, timestamp }) catch {
            return .{ .content = "Failed to create backup path", .is_error = true };
        };

        std.fs.copyFileAbsolute(path, backup_path, .{}) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Warning: Could not create backup: {s}", .{@errorName(err)}) catch "";
            _ = msg; // Log but continue
        };
    } else |_| {
        // File doesn't exist, no backup needed
    }

    // Write new content
    const file = std.fs.createFileAbsolute(path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error creating file: {s}", .{@errorName(err)}) catch
            return .{ .content = "Error creating file", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error writing file: {s}", .{@errorName(err)}) catch
            return .{ .content = "Error writing file", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    const success_msg = std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to {s}", .{ content.len, path }) catch
        return .{ .content = "File written successfully", .is_error = false };
    return .{ .content = success_msg, .is_error = false };
}
