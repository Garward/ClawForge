const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "file_diff",
    .description = "Edit a file with a unified diff. The PRIMARY tool for modifying existing files. " ++
        "Pass the full new content and set apply=true to write. Creates automatic backup before writing. " ++
        "Always use file_read first to see current content, then file_diff to apply changes.",
    .input_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the file"},"new_content":{"type":"string","description":"Proposed new content"},"apply":{"type":"boolean","description":"Apply the changes after showing diff","default":false}},"required":["path","new_content"]}
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
        return .{ .content = "Path must be absolute (start with / or ~)", .is_error = true };
    } else raw_path;

    const new_content = blk: {
        if (input == .object) {
            if (input.object.get("new_content")) |c| {
                if (c == .string) break :blk c.string;
            }
        }
        return .{ .content = "Missing 'new_content' parameter", .is_error = true };
    };

    const apply = blk: {
        if (input == .object) {
            if (input.object.get("apply")) |a| {
                if (a == .bool) break :blk a.bool;
            }
        }
        break :blk false;
    };

    if (std.mem.indexOf(u8, path, "..") != null) {
        return .{ .content = "Path traversal not allowed", .is_error = true };
    }

    const existed_before = fileExists(path);
    const current_content = readFileIfExists(allocator, path) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error reading file: {s}", .{@errorName(err)}) catch
            return .{ .content = "Error reading file", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer if (current_content) |buf| allocator.free(buf);

    const diff_output = buildUnifiedDiff(allocator, path, current_content orelse "", new_content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Unified diff generation failed: {s}", .{@errorName(err)}) catch
            return .{ .content = "Unified diff generation failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    if (!apply) {
        return .{
            .content = diff_output,
            .model_content = registry.compactForModel(allocator, "file_diff preview", diff_output, 5000, 1500),
            .is_error = false,
        };
    }

    var backup_path: ?[]u8 = null;
    defer if (backup_path) |bp| allocator.free(bp);
    if (existed_before) {
        backup_path = createBackup(allocator, path) catch |err| {
            const msg = std.fmt.allocPrint(
                allocator,
                "Backup failed for {s}: {s}. Aborting apply to protect the original file.",
                .{ path, @errorName(err) },
            ) catch "Backup failed";
            return .{ .content = msg, .is_error = true };
        };
    }

    atomicWriteAbsolute(path, new_content) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Applying diff failed for {s}: {s}", .{ path, @errorName(err) }) catch
            return .{ .content = "Apply failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    const result = if (backup_path) |bp|
        std.fmt.allocPrint(
            allocator,
            "{s}\n\nChanges applied successfully.\nBackup created: {s}",
            .{ diff_output, bp },
        ) catch diff_output
    else
        std.fmt.allocPrint(
            allocator,
            "{s}\n\nChanges applied successfully.\nCreated new file: {s}",
            .{ diff_output, path },
        ) catch diff_output;

    return .{
        .content = result,
        .model_content = registry.compactForModel(allocator, "file_diff apply result", result, 5000, 1500),
        .is_error = false,
    };
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size > 10 * 1024 * 1024) return error.FileTooBig;
    return try file.readToEndAlloc(allocator, @intCast(file_size + 1));
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

fn buildUnifiedDiff(allocator: std.mem.Allocator, path: []const u8, current_content: []const u8, new_content: []const u8) ![]u8 {
    if (std.mem.eql(u8, current_content, new_content)) {
        return std.fmt.allocPrint(allocator, "No changes needed for {s}", .{path});
    }

    const timestamp = std.time.timestamp();
    const old_tmp = try std.fmt.allocPrint(allocator, "/tmp/clawforge-diff-old-{d}", .{timestamp});
    defer allocator.free(old_tmp);
    const new_tmp = try std.fmt.allocPrint(allocator, "/tmp/clawforge-diff-new-{d}", .{timestamp});
    defer allocator.free(new_tmp);
    defer std.fs.deleteFileAbsolute(old_tmp) catch {};
    defer std.fs.deleteFileAbsolute(new_tmp) catch {};

    {
        const file = try std.fs.createFileAbsolute(old_tmp, .{ .truncate = true });
        defer file.close();
        try file.writeAll(current_content);
    }
    {
        const file = try std.fs.createFileAbsolute(new_tmp, .{ .truncate = true });
        defer file.close();
        try file.writeAll(new_content);
    }

    const old_label = if (current_content.len == 0)
        try std.fmt.allocPrint(allocator, "{s} (missing)", .{path})
    else
        try std.fmt.allocPrint(allocator, "{s} (current)", .{path});
    defer allocator.free(old_label);

    const new_label = if (new_content.len == 0)
        try std.fmt.allocPrint(allocator, "{s} (empty)", .{path})
    else
        try std.fmt.allocPrint(allocator, "{s} (proposed)", .{path});
    defer allocator.free(new_label);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "diff", "-u", "--label", old_label, "--label", new_label, old_tmp, new_tmp },
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stderr);

    if (result.term.Exited == 0 or result.term.Exited == 1) {
        if (result.stdout.len > 0) return result.stdout;
        allocator.free(result.stdout);
        return std.fmt.allocPrint(allocator, "No changes needed for {s}", .{path});
    }

    defer allocator.free(result.stdout);
    return error.DiffFailed;
}
