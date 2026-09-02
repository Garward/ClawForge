const std = @import("std");
const json = std.json;
const common = @import("common");
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "file_find",
    .description = "Structured read-only filesystem discovery. Use instead of bash find for locating project files, directories, Gradle files, configs, jars, or convention files. Accepts absolute root, multiple glob/name patterns, excludes, max_depth, and include_dirs.",
    .input_schema_json =
    \\{"type":"object","properties":{"root":{"type":"string","description":"Absolute root directory to search, or ~ path."},"patterns":{"type":"array","items":{"type":"string"},"description":"File or directory name/glob patterns, e.g. ['build.gradle','settings.gradle','*.toml']"},"exclude":{"type":"array","items":{"type":"string"},"description":"Directory or path fragments to exclude, e.g. ['.git','build','.gradle']"},"max_depth":{"type":"integer","description":"Maximum search depth, capped at 12. Default 5."},"include_dirs":{"type":"boolean","description":"Include directories in results. Default false."},"max_results":{"type":"integer","description":"Maximum returned paths, capped at 500. Default 100."}},"required":["root"]}
    ,
    .requires_confirmation = false,
    .handler = &execute,
};

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    if (input != .object) {
        return .{ .content = "Expected JSON object", .is_error = true };
    }

    const raw_root = if (input.object.get("root")) |r| (if (r == .string) r.string else null) else null;
    const root = expandRoot(allocator, raw_root orelse return .{ .content = "Missing 'root' parameter", .is_error = true }) catch
        return .{ .content = "Failed to resolve root path", .is_error = true };
    defer allocator.free(root);

    if (root.len == 0 or root[0] != '/') {
        return .{ .content = "root must be absolute or start with ~", .is_error = true };
    }
    if (std.mem.indexOf(u8, root, "..") != null) {
        return .{ .content = "Path traversal is not allowed in root", .is_error = true };
    }

    const max_depth = parseBoundedInt(input, "max_depth", 5, 1, 12);
    const max_results = parseBoundedInt(input, "max_results", 100, 1, 500);
    const include_dirs = if (input.object.get("include_dirs")) |v| (v == .bool and v.bool) else false;

    var depth_buf: [16]u8 = undefined;
    const depth_str = std.fmt.bufPrint(&depth_buf, "{d}", .{max_depth}) catch "5";

    var argv: std.ArrayList([]const u8) = .empty;
    var owned_args: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_args.items) |arg| allocator.free(arg);
        owned_args.deinit(allocator);
        argv.deinit(allocator);
    }

    argv.append(allocator, "find") catch return allocErr();
    argv.append(allocator, root) catch return allocErr();
    argv.append(allocator, "-maxdepth") catch return allocErr();
    argv.append(allocator, depth_str) catch return allocErr();

    if (!include_dirs) {
        argv.append(allocator, "-type") catch return allocErr();
        argv.append(allocator, "f") catch return allocErr();
    }

    tryAppendExclude(allocator, &argv, &owned_args, ".git");
    tryAppendExclude(allocator, &argv, &owned_args, ".zig-cache");
    tryAppendExclude(allocator, &argv, &owned_args, "__pycache__");
    tryAppendExclude(allocator, &argv, &owned_args, "node_modules");

    if (input.object.get("exclude")) |excludes| {
        if (excludes == .array) {
            for (excludes.array.items) |item| {
                if (item == .string and item.string.len > 0) {
                    if (!isSafePattern(item.string)) {
                        return .{ .content = "Invalid characters in exclude entry", .is_error = true };
                    }
                    tryAppendExclude(allocator, &argv, &owned_args, item.string);
                }
            }
        }
    }

    var pattern_count: usize = 0;
    if (input.object.get("patterns")) |patterns| {
        if (patterns == .array) {
            for (patterns.array.items) |item| {
                if (item == .string and item.string.len > 0) pattern_count += 1;
            }
        }
    }

    if (pattern_count > 0) {
        argv.append(allocator, "(") catch return allocErr();
        var appended: usize = 0;
        if (input.object.get("patterns")) |patterns| {
            if (patterns == .array) {
                for (patterns.array.items) |item| {
                    if (item != .string or item.string.len == 0) continue;
                    if (!isSafePattern(item.string)) {
                        return .{ .content = "Invalid characters in pattern", .is_error = true };
                    }
                    if (appended > 0) argv.append(allocator, "-o") catch return allocErr();
                    argv.append(allocator, "-name") catch return allocErr();
                    argv.append(allocator, item.string) catch return allocErr();
                    appended += 1;
                }
            }
        }
        argv.append(allocator, ")") catch return allocErr();
    }

    const result = common.process.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 512 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "file_find failed: {s}", .{@errorName(err)}) catch
            return .{ .content = "file_find failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        defer allocator.free(result.stdout);
        const msg = if (result.stderr.len > 0)
            std.fmt.allocPrint(allocator, "file_find error:\n{s}", .{result.stderr}) catch "file_find error"
        else
            "file_find exited non-zero";
        return .{ .content = msg, .is_error = true };
    }

    return .{ .content = formatOutput(allocator, root, result.stdout, max_results) orelse result.stdout, .is_error = false };
}

fn parseBoundedInt(input: json.Value, field: []const u8, default: usize, min: usize, max: usize) usize {
    if (input.object.get(field)) |v| {
        if (v == .integer and v.integer > 0) {
            const raw: usize = @intCast(v.integer);
            return @max(min, @min(max, raw));
        }
    }
    return default;
}

fn expandRoot(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len > 0 and raw[0] == '~') {
        const home = common.config.getEnvVar("HOME") orelse "/tmp";
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, raw[1..] });
    }
    return try allocator.dupe(u8, raw);
}

fn isSafePattern(text: []const u8) bool {
    if (text.len > 240) return false;
    for (text) |c| {
        switch (c) {
            0, '\n', '\r', '|', ';', '&', '>', '<', '`', '$', '(', ')', '{', '}', '!', '\\' => return false,
            else => {},
        }
    }
    return true;
}

fn tryAppendExclude(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    owned_args: *std.ArrayList([]u8),
    exclude: []const u8,
) void {
    argv.append(allocator, "-not") catch return;
    argv.append(allocator, "-path") catch return;
    const pat = std.fmt.allocPrint(allocator, "*/{s}/*", .{exclude}) catch return;
    owned_args.append(allocator, pat) catch {
        allocator.free(pat);
        return;
    };
    argv.append(allocator, pat) catch return;
}

fn formatOutput(allocator: std.mem.Allocator, root: []const u8, raw: []const u8, max_results: usize) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(allocator, "FILE FIND\nRoot: ") catch return null;
    out.appendSlice(allocator, root) catch return null;
    out.appendSlice(allocator, "\n\n") catch return null;

    if (raw.len == 0) {
        out.appendSlice(allocator, "(no matches)\n") catch return null;
        return out.items;
    }

    const prefix = std.fmt.allocPrint(allocator, "{s}/", .{root}) catch return null;
    defer allocator.free(prefix);

    var count: usize = 0;
    var omitted: usize = 0;
    var iter = std.mem.splitScalar(u8, raw, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (count >= max_results) {
            omitted += 1;
            continue;
        }
        count += 1;
        out.appendSlice(allocator, "  ") catch return null;
        if (std.mem.startsWith(u8, line, prefix)) {
            out.appendSlice(allocator, line[prefix.len..]) catch return null;
        } else if (std.mem.eql(u8, line, root)) {
            out.appendSlice(allocator, ".") catch return null;
        } else {
            out.appendSlice(allocator, line) catch return null;
        }
        out.append(allocator, '\n') catch return null;
    }
    if (omitted > 0) {
        out.print(allocator, "\n... omitted {d} additional matches\n", .{omitted}) catch return null;
    }
    return out.items;
}

fn allocErr() registry.ToolResult {
    return .{ .content = "Allocation failed", .is_error = true };
}
