const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "file_write",
    .description = "Create or overwrite a file. Use this instead of bash for ALL file creation. " ++
        "For editing existing files, prefer file_diff (targeted changes with backup). " ++
        "Set force=true to overwrite existing files after reading them first. Creates automatic backups. " ++
        "Do not use this to guess edits to an existing file you have not reread.",
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
                if (p == .string) break :blk p.string;
            }
        }
        return .{ .content = "Missing 'path' parameter", .is_error = true };
    };

    var owned_path: ?[]u8 = null;
    defer if (owned_path) |p| allocator.free(p);

    const path = if (raw_path.len > 0 and raw_path[0] == '~') blk: {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const expanded = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, raw_path[1..] }) catch
            return .{ .content = "Path expansion failed", .is_error = true };
        owned_path = expanded;
        break :blk expanded;
    } else if (raw_path.len == 0 or raw_path[0] != '/') {
        return .{ .content = "Path must be absolute (start with / or ~). Use bash 'pwd' if needed.", .is_error = true };
    } else raw_path;

    const content = blk: {
        if (input == .object) {
            if (input.object.get("content")) |c| {
                if (c == .string) break :blk c.string;
            }
        }
        return .{ .content = "Missing 'content' parameter", .is_error = true };
    };

    const force = blk: {
        if (input == .object) {
            if (input.object.get("force")) |f| {
                if (f == .bool) break :blk f.bool;
            }
        }
        break :blk false;
    };

    if (std.mem.indexOf(u8, path, "..") != null) {
        return .{ .content = "Path traversal not allowed", .is_error = true };
    }

    const existed_before = fileExists(path);
    if (existed_before and !force) {
        const error_msg = std.fmt.allocPrint(
            allocator,
            \\FILE WRITE BLOCKED
            \\Path: {s}
            \\Reason: file already exists and force=false
            \\Action: use file_read first, then rerun with force=true to confirm overwrite.
            \\
            \\Example:
            \\  file_read("{s}")
            \\  file_write("{s}", "...", force=true)
        ,
            .{ path, path, path },
        ) catch "File exists. Use file_read first, then file_write with force=true";
        return .{ .content = error_msg, .is_error = true };
    }

    var backup_path: ?[]u8 = null;
    defer if (backup_path) |bp| allocator.free(bp);
    if (existed_before) {
        backup_path = createBackup(allocator, path) catch |err| {
            const msg = std.fmt.allocPrint(
                allocator,
                "Backup failed for {s}: {s}. Aborting write to protect the original file.",
                .{ path, @errorName(err) },
            ) catch "Backup failed, aborting write for safety";
            return .{ .content = msg, .is_error = true };
        };
    }

    atomicWriteAbsolute(path, content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Atomic write failed for {s}: {s}", .{ path, @errorName(err) }) catch
            return .{ .content = "Atomic write failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    const success_msg = if (backup_path) |bp|
        std.fmt.allocPrint(
            allocator,
            "FILE WRITE APPLIED\nPath: {s}\nAction: overwrite\nBytes written: {d}\nBackup: {s}\n\nPreview:\n{s}",
            .{ path, content.len, bp, previewText(content, 320) },
        ) catch "File written successfully"
    else
        std.fmt.allocPrint(
            allocator,
            "FILE WRITE APPLIED\nPath: {s}\nAction: create\nBytes written: {d}\n\nPreview:\n{s}",
            .{ path, content.len, previewText(content, 320) },
        ) catch "File written successfully";

    return .{
        .content = success_msg,
        .model_content = registry.compactForModel(allocator, "file_write result", success_msg, 1200, 600),
        .is_error = false,
    };
}

fn previewText(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn createBackup(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const timestamp = std.time.timestamp();
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.backup.{d}", .{ path, timestamp });
    errdefer allocator.free(backup_path);
    try std.fs.copyFileAbsolute(path, backup_path, .{});
    return backup_path;
}

fn atomicWriteAbsolute(path: []const u8, content: []const u8) !void {
    var write_buffer: [4096]u8 = undefined;
    var atomic_file = try std.fs.cwd().atomicFile(path, .{
        .mode = 0o644,
        .make_path = true,
        .write_buffer = &write_buffer,
    });
    defer atomic_file.deinit();

    try atomic_file.file_writer.interface.writeAll(content);
    try atomic_file.finish();
}
