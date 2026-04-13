const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "file_diff",
    .description = "Edit a file using search-and-replace. The PRIMARY tool for modifying existing files. " ++
        "Provide old_text (exact string to find) and new_text (replacement). " ++
        "For new files, use file_write instead. Always use file_read first to see current content. " ++
        "If a replacement fails, reread the exact target region and include more unchanged surrounding context. " ++
        "Do not guess the current file state from memory.",
    .input_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the file"},"old_text":{"type":"string","description":"Exact text to find in the file (must match uniquely)"},"new_text":{"type":"string","description":"Replacement text"},"create_if_missing":{"type":"boolean","description":"Create the file with new_text if it doesn't exist","default":false}},"required":["path","old_text","new_text"]}
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

    const old_text = blk: {
        if (input == .object) {
            if (input.object.get("old_text")) |c| {
                if (c == .string) break :blk c.string;
            }
        }
        return .{ .content = "Missing 'old_text' parameter", .is_error = true };
    };

    if (old_text.len == 0) {
        return .{ .content = "old_text must not be empty. Provide the exact text to replace — use file_read first to see current content.", .is_error = true };
    }

    const new_text = blk: {
        if (input == .object) {
            if (input.object.get("new_text")) |c| {
                if (c == .string) break :blk c.string;
            }
        }
        return .{ .content = "Missing 'new_text' parameter", .is_error = true };
    };

    const create_if_missing = blk: {
        if (input == .object) {
            if (input.object.get("create_if_missing")) |a| {
                if (a == .bool) break :blk a.bool;
            }
        }
        break :blk false;
    };

    if (std.mem.indexOf(u8, path, "..") != null) {
        return .{ .content = "Path traversal not allowed", .is_error = true };
    }

    // Read current file
    const current_content = readFile(allocator, path) catch |err| {
        if (err == error.FileNotFound and create_if_missing) {
            // Create new file with new_text as content
            atomicWriteAbsolute(path, new_text) catch |write_err| {
                const msg = std.fmt.allocPrint(allocator, "Failed to create {s}: {s}", .{ path, @errorName(write_err) }) catch
                    return .{ .content = "Failed to create file", .is_error = true };
                return .{ .content = msg, .is_error = true };
            };
            const msg = std.fmt.allocPrint(
                allocator,
                "FILE DIFF APPLIED\nPath: {s}\nAction: created new file\nBytes written: {d}\n\nPreview:\n{s}",
                .{ path, new_text.len, previewText(new_text, 240) },
            ) catch
                return .{ .content = "File created", .is_error = false };
            return .{
                .content = msg,
                .model_content = registry.compactForModel(allocator, "file_diff create result", msg, 1200, 600),
                .is_error = false,
            };
        }
        const msg = std.fmt.allocPrint(allocator, "Error reading {s}: {s}", .{ path, @errorName(err) }) catch
            return .{ .content = "Error reading file", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer allocator.free(current_content);

    // Find the old_text in the file
    const match_pos = std.mem.indexOf(u8, current_content, old_text) orelse {
        // Show a helpful snippet of the file around where the text might be
        const preview_len = @min(current_content.len, 500);
        const msg = std.fmt.allocPrint(
            allocator,
            "FILE DIFF FAILED\nPath: {s}\nReason: old_text not found\nHint: the replacement anchor must match exactly, including whitespace.\nNext step: rerun file_read on the exact target region and copy more unchanged surrounding context into old_text.\n\nFile start preview:\n{s}{s}",
            .{ path, current_content[0..preview_len], if (current_content.len > 500) "\n...(truncated)" else "" },
        ) catch return .{ .content = "old_text not found in file", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    // Check for uniqueness — old_text must match exactly once
    if (std.mem.indexOf(u8, current_content[match_pos + old_text.len ..], old_text) != null) {
        const msg = std.fmt.allocPrint(
            allocator,
            "FILE DIFF FAILED\nPath: {s}\nReason: old_text matched multiple locations\nHint: include more unchanged surrounding context so the match is unique.\nNext step: reread a narrower file slice around the intended location, then retry with a more specific old_text.",
            .{path},
        ) catch return .{ .content = "old_text matches multiple locations", .is_error = true };
        return .{ .content = msg, .is_error = true };
    }

    // Build new content: before + new_text + after
    const before = current_content[0..match_pos];
    const after = current_content[match_pos + old_text.len ..];
    const result_content = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ before, new_text, after }) catch
        return .{ .content = "Failed to build replacement", .is_error = true };
    defer allocator.free(result_content);

    // Backup
    _ = createBackup(allocator, path) catch |err| {
        const msg = std.fmt.allocPrint(
            allocator,
            "Backup failed for {s}: {s}. Aborting to protect original.",
            .{ path, @errorName(err) },
        ) catch "Backup failed";
        return .{ .content = msg, .is_error = true };
    };

    // Write
    atomicWriteAbsolute(path, result_content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Write failed for {s}: {s}", .{ path, @errorName(err) }) catch
            return .{ .content = "Write failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    // Build a concise result showing exactly what changed.
    const context_before = match_pos -| 80;
    const context_after_end = @min(match_pos + old_text.len + 80, current_content.len);
    const bytes_delta = @as(i64, @intCast(new_text.len)) - @as(i64, @intCast(old_text.len));
    const msg = std.fmt.allocPrint(
        allocator,
        "FILE DIFF APPLIED\nPath: {s}\nMatch offset: {d}\nOld bytes: {d}\nNew bytes: {d}\nNet byte delta: {d}\n\nOLD:\n{s}\n\nNEW:\n{s}\n\nMATCH CONTEXT:\n...{s}[REPLACED]{s}...",
        .{
            path,
            match_pos,
            old_text.len,
            new_text.len,
            bytes_delta,
            previewText(old_text, 320),
            previewText(new_text, 320),
            current_content[context_before..match_pos],
            current_content[match_pos + old_text.len .. context_after_end],
        },
    ) catch return .{ .content = "Edit applied successfully", .is_error = false };

    return .{
        .content = msg,
        .model_content = registry.compactForModel(allocator, "file_diff result", msg, 1400, 800),
        .is_error = false,
    };
}

fn previewText(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer file.close();
    const size = try file.getEndPos();
    if (size > 10 * 1024 * 1024) return error.FileTooBig;
    return try file.readToEndAlloc(allocator, @intCast(size + 1));
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
