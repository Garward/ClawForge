const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "file_read",
    .description = "Read file contents with line numbers. Primary grounding tool before editing existing files. " ++
        "Prefer reading the smallest relevant slice first with offset/limit, then expand if needed. " ++
        "Use this before file_diff or file_write on existing files, and reread the exact region after any failed edit or compiler error. " ++
        "Do not rely on memory for file contents.",
    .input_schema_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the file to read"},"offset":{"type":"integer","description":"Starting line number (default 0)"},"limit":{"type":"integer","description":"Number of lines to read (default 2000)"}},"required":["path"]}
    ,
    .requires_confirmation = false,
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
    var owned_path: ?[]u8 = null;
    defer if (owned_path) |p| allocator.free(p);

    const path = if (raw_path.len > 0 and raw_path[0] == '~') blk: {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const expanded = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, raw_path[1..] }) catch
            return .{ .content = "Path expansion failed", .is_error = true };
        owned_path = expanded;
        break :blk expanded;
    } else if (raw_path.len == 0 or raw_path[0] != '/') {
        return .{ .content = "Path must be absolute (start with / or ~). Use bash 'pwd' to find the working directory if needed.", .is_error = true };
    } else raw_path;

    // Security: reject path traversal
    if (std.mem.indexOf(u8, path, "..") != null) {
        return .{ .content = "Path traversal not allowed", .is_error = true };
    }

    // Security: block reading .env files
    if (std.mem.endsWith(u8, path, ".env") or
        std.mem.indexOf(u8, path, "/.env") != null or
        std.mem.indexOf(u8, path, ".env.") != null)
    {
        return .{ .content = "Reading .env files is not permitted for security", .is_error = true };
    }

    const offset: usize = blk: {
        if (input == .object) {
            if (input.object.get("offset")) |o| {
                if (o == .integer) {
                    break :blk @intCast(o.integer);
                }
            }
        }
        break :blk 0;
    };

    const limit: usize = blk: {
        if (input == .object) {
            if (input.object.get("limit")) |l| {
                if (l == .integer) {
                    break :blk @intCast(l.integer);
                }
            }
        }
        break :blk 2000;
    };

    // Open and read file
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error opening file: {s}", .{@errorName(err)}) catch
            return .{ .content = "Error opening file", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };
    defer file.close();

    // Allocate output buffer
    var output = allocator.alloc(u8, 256 * 1024) catch
        return .{ .content = "Out of memory", .is_error = true };
    var pos: usize = 0;
    var truncated = false;
    var first_line_returned: ?usize = null;
    var last_line_returned: ?usize = null;

    var line_num: usize = 1;
    var buf: [4096]u8 = undefined;
    var remaining: usize = 0;

    while (true) {
        const n = file.read(buf[remaining..]) catch break;
        if (n == 0) break;

        const data = buf[0 .. remaining + n];
        var start: usize = 0;

        for (data, 0..) |c, i| {
            if (c == '\n') {
                const line = data[start..i];
                if (line_num > offset and line_num <= offset + limit) {
                    if (first_line_returned == null) first_line_returned = line_num;
                    last_line_returned = line_num;
                    const written = std.fmt.bufPrint(output[pos..], "{d:>6}| ", .{line_num}) catch break;
                    pos += written.len;
                    if (pos + line.len < output.len) {
                        @memcpy(output[pos..][0..line.len], line);
                        pos += line.len;
                        output[pos] = '\n';
                        pos += 1;
                    } else {
                        truncated = true;
                        break;
                    }
                }
                line_num += 1;
                start = i + 1;
                if (line_num > offset + limit) break;
            }
        }

        // Keep unprocessed data for next iteration (may overlap, use copyForwards)
        if (start < data.len) {
            remaining = data.len - start;
            std.mem.copyForwards(u8, buf[0..remaining], data[start..][0..remaining]);
        } else {
            remaining = 0;
        }

        if (line_num > offset + limit or truncated) break;
    }

    // Emit the final line even when the file does not end with a newline.
    if (!truncated and remaining > 0 and line_num > offset and line_num <= offset + limit) {
        const line = buf[0..remaining];
        if (first_line_returned == null) first_line_returned = line_num;
        last_line_returned = line_num;
        const written = blk: {
            const prefix = std.fmt.bufPrint(output[pos..], "{d:>6}| ", .{line_num}) catch {
                truncated = true;
                break :blk @as([]const u8, "");
            };
            break :blk prefix;
        };
        pos += written.len;
        if (pos + line.len + 1 < output.len) {
            @memcpy(output[pos..][0..line.len], line);
            pos += line.len;
            output[pos] = '\n';
            pos += 1;
        } else {
            truncated = true;
        }
    }

    if (pos == 0) {
        allocator.free(output);
        const empty = std.fmt.allocPrint(
            allocator,
            "FILE READ\nPath: {s}\nRequested lines: {d}-{d}\n\n(empty file or offset past end)",
            .{ path, offset + 1, offset + limit },
        ) catch "(empty file or offset past end)";
        return .{
            .content = empty,
            .model_content = empty,
            .is_error = false,
        };
    }

    // Shrink to actual size
    if (truncated) {
        const suffix = "\n...[truncated: output exceeded 256 KiB buffer]";
        if (pos + suffix.len < output.len) {
            @memcpy(output[pos..][0..suffix.len], suffix);
            pos += suffix.len;
        }
    }

    const body = allocator.realloc(output, pos) catch output;
    const result = std.fmt.allocPrint(
        allocator,
        "FILE READ\nPath: {s}\nRequested lines: {d}-{d}\nReturned lines: {d}-{d}{s}\n\n{s}",
        .{
            path,
            offset + 1,
            offset + limit,
            first_line_returned orelse (offset + 1),
            last_line_returned orelse (offset + 1),
            if (truncated) "\nStatus: truncated for display buffer" else "",
            body,
        },
    ) catch body;

    if (result.ptr != body.ptr) allocator.free(body);
    return .{
        .content = result,
        // Purpose: preserve the full read for the user while only replaying a compact slice to the model.
        .model_content = registry.compactForModel(allocator, "file_read result", result, 6000, 2000),
        .is_error = false,
    };
}
