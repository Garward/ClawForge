const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "file_write",
    .description = "Write content to a file. For existing files, requires force=true and shows a warning to use file_read first. Creates automatic backups.",
    .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to write to"},"content":{"type":"string","description":"Content to write to the file"},"force":{"type":"boolean","description":"Required to overwrite existing files. Use file_read first to see current content.","default":false}},"required":["path","content"]}
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

    const force = blk: {
        if (input == .object) {
            if (input.object.get("force")) |f| {
                if (f == .bool) {
                    break :blk f.bool;
                }
            }
        }
        break :blk false;
    };

    // Security: reject path traversal
    if (std.mem.indexOf(u8, path, "..") != null) {
        return .{ .content = "Path traversal not allowed", .is_error = true };
    }

    // Check if file exists and enforce read-first pattern
    var file_exists = false;
    if (std.fs.openFileAbsolute(path, .{})) |existing| {
        existing.close();
        file_exists = true;

        if (!force) {
            const error_msg = std.fmt.allocPrint(allocator, 
                \\❌ SAFETY CHECK: File '{s}' already exists!
                \\
                \\🛡️ To prevent accidental overwrites:
                \\1. Use file_read to see current content first
                \\2. Then use file_write with force=true to confirm overwrite
                \\
                \\Example:
                \\  file_read("{s}")  // See current content
                \\  file_write("{s}", "new content", force=true)  // Confirm overwrite
            , .{ path, path, path }) catch 
                return .{ .content = "File exists. Use file_read first, then file_write with force=true", .is_error = true };
            return .{ .content = error_msg, .is_error = true };
        }

        // Create backup with timestamp
        var backup_path_buf: [4096]u8 = undefined;
        const timestamp = std.time.timestamp();
        const backup_path = std.fmt.bufPrint(&backup_path_buf, "{s}.backup.{d}", .{ path, timestamp }) catch {
            return .{ .content = "Failed to create backup path", .is_error = true };
        };

        std.fs.copyFileAbsolute(path, backup_path, .{}) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "❌ BACKUP FAILED: Could not create backup at {s}: {s}\nAborting write to protect your data!", .{ backup_path, @errorName(err) }) catch 
                return .{ .content = "Backup failed, aborting write for safety", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
    } else |_| {
        // File doesn't exist, safe to create
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

    // Success message with backup info
    const success_msg = if (file_exists) 
        std.fmt.allocPrint(allocator, "✅ Successfully wrote {d} bytes to {s}\n💾 Backup created: {s}.backup.{d}", .{ content.len, path, path, std.time.timestamp() }) 
    else 
        std.fmt.allocPrint(allocator, "✅ Successfully created new file {s} with {d} bytes", .{ path, content.len });
    
    return .{ .content = success_msg catch "File written successfully", .is_error = false };
}