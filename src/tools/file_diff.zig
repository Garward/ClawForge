const std = @import("std");
const json = std.json;
const common = @import("common");
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "file_diff",
    .description = "Edit a file using search-and-replace. The PRIMARY tool for modifying existing files. " ++
        "Provide old_text (exact string to find) and new_text (replacement). " ++
        "REQUIRED: you MUST call file_read on the target path at least once before using file_diff. " ++
        "The runtime enforces this — an unread path returns a BLOCKED tool error. This prevents " ++
        "editing files you can't actually see. " ++
        "For new files, set create_if_missing: true (bypasses the read requirement) or use file_write. " ++
        "If old_text is not found, re-read the exact target lines and use the smallest distinctive exact substring. " ++
        "If old_text matches multiple locations, add unchanged context before and after until it is unique. " ++
        "Do not guess file state from memory.",
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
        const home = common.config.getEnvVar("HOME") orelse "/tmp";
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
        const diagnostic = buildClosestMatchDiagnostic(allocator, current_content, old_text) catch
            allocator.dupe(u8, "Closest candidate unavailable; re-read the exact target lines.") catch
            return .{ .content = "old_text not found in file", .is_error = true };
        defer allocator.free(diagnostic);
        const msg = std.fmt.allocPrint(
            allocator,
            "FILE DIFF FAILED\nPath: {s}\nReason: old_text not found\n" ++
                "Hint: the replacement anchor must match exactly, including whitespace.\n" ++
                "Next step: re-read the exact target lines and use the smallest distinctive exact substring.\n\n{s}",
            .{ path, diagnostic },
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

fn buildClosestMatchDiagnostic(allocator: std.mem.Allocator, content: []const u8, expected: []const u8) ![]u8 {
    const actual_starts = try collectLineStarts(allocator, content);
    defer allocator.free(actual_starts);
    const expected_starts = try collectLineStarts(allocator, expected);
    defer allocator.free(expected_starts);

    var anchor_expected_idx: usize = 0;
    var anchor_line: []const u8 = lineAt(expected, expected_starts, 0);
    for (expected_starts, 0..) |_, i| {
        const line = lineAt(expected, expected_starts, i);
        if (std.mem.trim(u8, line, " \t\r").len > std.mem.trim(u8, anchor_line, " \t\r").len) {
            anchor_expected_idx = i;
            anchor_line = line;
        }
    }

    var best_actual_idx: usize = 0;
    var best_score: i64 = std.math.minInt(i64);
    for (actual_starts, 0..) |_, i| {
        const score = lineSimilarity(anchor_line, lineAt(content, actual_starts, i));
        if (score > best_score) {
            best_score = score;
            best_actual_idx = i;
        }
    }

    const candidate_start = best_actual_idx -| anchor_expected_idx;
    var mismatch_expected_idx: usize = 0;
    while (mismatch_expected_idx < expected_starts.len) : (mismatch_expected_idx += 1) {
        const actual_idx = candidate_start + mismatch_expected_idx;
        if (actual_idx >= actual_starts.len or
            !std.mem.eql(
                u8,
                lineAt(expected, expected_starts, mismatch_expected_idx),
                lineAt(content, actual_starts, actual_idx),
            )) break;
    }
    if (mismatch_expected_idx >= expected_starts.len) mismatch_expected_idx = anchor_expected_idx;

    const mismatch_actual_idx = candidate_start + mismatch_expected_idx;
    const expected_line = lineAt(expected, expected_starts, mismatch_expected_idx);
    const actual_line = if (mismatch_actual_idx < actual_starts.len)
        lineAt(content, actual_starts, mismatch_actual_idx)
    else
        "<missing line>";
    const visible_expected = try visibleLine(allocator, expected_line);
    defer allocator.free(visible_expected);
    const visible_actual = try visibleLine(allocator, actual_line);
    defer allocator.free(visible_actual);
    const difference = firstDifference(visible_expected, visible_actual);

    const preview_start = candidate_start -| 2;
    const desired_end = candidate_start + @min(expected_starts.len + 2, 12);
    const preview_end = @min(actual_starts.len, @max(preview_start + 1, desired_end));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "Closest candidate around lines {d}-{d} (diagnostic only; no fuzzy edit applied):\n", .{
        preview_start + 1,
        preview_end,
    });
    for (preview_start..preview_end) |i| {
        const visible = try visibleLine(allocator, lineAt(content, actual_starts, i));
        defer allocator.free(visible);
        try out.print(allocator, "{d:>6}| {s}\\n\n", .{ i + 1, visible });
    }
    try out.print(allocator, "\nexpected: {s}\\n\nactual:   {s}\\n\n          ", .{ visible_expected, visible_actual });
    for (0..difference) |_| try out.append(allocator, ' ');
    try out.appendSlice(allocator, "^ first difference\nWhitespace notation: \\n=line ending, \\r=CR, \\t=tab, \\x20=trailing space.");
    return try out.toOwnedSlice(allocator);
}

fn collectLineStarts(allocator: std.mem.Allocator, text: []const u8) ![]usize {
    var starts: std.ArrayList(usize) = .empty;
    errdefer starts.deinit(allocator);
    try starts.append(allocator, 0);
    for (text, 0..) |byte, i| {
        if (byte == '\n' and i + 1 < text.len) try starts.append(allocator, i + 1);
    }
    return try starts.toOwnedSlice(allocator);
}

fn lineAt(text: []const u8, starts: []const usize, index: usize) []const u8 {
    if (index >= starts.len) return "";
    const start = starts[index];
    const raw_end = if (index + 1 < starts.len) starts[index + 1] - 1 else text.len;
    return text[start..raw_end];
}

fn lineSimilarity(expected: []const u8, actual: []const u8) i64 {
    const prefix = firstDifference(expected, actual);
    var suffix: usize = 0;
    while (suffix < expected.len -| prefix and suffix < actual.len -| prefix and
        expected[expected.len - 1 - suffix] == actual[actual.len - 1 - suffix]) : (suffix += 1)
    {}
    const length_delta = if (expected.len > actual.len) expected.len - actual.len else actual.len - expected.len;
    return @as(i64, @intCast(prefix * 4 + suffix * 2)) - @as(i64, @intCast(length_delta));
}

fn firstDifference(expected: []const u8, actual: []const u8) usize {
    const shared = @min(expected.len, actual.len);
    for (0..shared) |i| {
        if (expected[i] != actual[i]) return i;
    }
    return shared;
}

fn visibleLine(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var trailing_start = line.len;
    while (trailing_start > 0 and line[trailing_start - 1] == ' ') trailing_start -= 1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (line, 0..) |byte, i| {
        switch (byte) {
            '\t' => try out.appendSlice(allocator, "\\t"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            ' ' => if (i >= trailing_start) try out.appendSlice(allocator, "\\x20") else try out.append(allocator, ' '),
            else => if (byte < 0x20 or byte == 0x7f)
                try out.print(allocator, "\\x{x:0>2}", .{byte})
            else
                try out.append(allocator, byte),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = common.config.runtimeIo();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > 10 * 1024 * 1024) return error.FileTooBig;
    var file_reader = file.reader(io, &.{});
    return try file_reader.interface.allocRemaining(allocator, .limited(@intCast(size + 1)));
}

fn createBackup(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const timestamp = common.sync.timestamp();
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.backup.{d}", .{ path, timestamp });
    errdefer allocator.free(backup_path);
    try std.Io.Dir.copyFileAbsolute(path, backup_path, common.config.runtimeIo(), .{});
    return backup_path;
}

fn atomicWriteAbsolute(path: []const u8, content: []const u8) !void {
    const io = common.config.runtimeIo();
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = .fromMode(0o644),
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &write_buffer);
    try file_writer.interface.writeAll(content);
    try file_writer.flush();
    try atomic_file.replace(io);
}

test "closest diagnostic shows wording drift away from file start" {
    const content =
        "title\n" ++
        "unrelated setup\n" ++
        "more unrelated setup\n" ++
        "Optional UnrealPak/repak-style tools\n" ++
        "final line\n";
    const diagnostic = try buildClosestMatchDiagnostic(
        std.testing.allocator,
        content,
        "Optional UnrealPak/IoStore tooling",
    );
    defer std.testing.allocator.free(diagnostic);

    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "expected: Optional UnrealPak/IoStore tooling\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "actual:   Optional UnrealPak/repak-style tools\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "^ first difference") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "diagnostic only; no fuzzy edit applied") != null);
}

test "closest diagnostic exposes skipped lines and whitespace" {
    const content =
        "probe_dst=\"$mods_dir/probe\"\r\n" ++
        "\tif [[ ! -d \"$probe_src\" ]]; then  \r\n" ++
        "    exit 1\r\n" ++
        "fi\r\n" ++
        "mkdir -p \"$mods_dir\"\r\n";
    const expected =
        "probe_dst=\"$mods_dir/probe\"\n" ++
        "mkdir -p \"$mods_dir\"";
    const diagnostic = try buildClosestMatchDiagnostic(std.testing.allocator, content, expected);
    defer std.testing.allocator.free(diagnostic);

    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "expected: mkdir -p \"$mods_dir\"\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "actual:   \\tif [[ ! -d \"$probe_src\" ]]; then\\x20\\x20\\r\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "\\r=CR, \\t=tab, \\x20=trailing space") != null);
}
