const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "file_diff",
    .description = "Show differences between current file content and proposed new content. Creates backup automatically if apply=true.",
    .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the file"},"new_content":{"type":"string","description":"Proposed new content"},"apply":{"type":"boolean","description":"Apply the changes after showing diff","default":false}},"required":["path","new_content"]}
    ,
    .requires_confirmation = false,  // Just showing diff is safe
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

    const new_content = blk: {
        if (input == .object) {
            if (input.object.get("new_content")) |c| {
                if (c == .string) {
                    break :blk c.string;
                }
            }
        }
        return .{ .content = "Missing 'new_content' parameter", .is_error = true };
    };

    const apply = blk: {
        if (input == .object) {
            if (input.object.get("apply")) |a| {
                if (a == .bool) {
                    break :blk a.bool;
                }
            }
        }
        break :blk false;
    };

    // Security: reject path traversal
    if (std.mem.indexOf(u8, path, "..") != null) {
        return .{ .content = "Path traversal not allowed", .is_error = true };
    }

    // Read current content
    const current_content = blk: {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                break :blk "";  // File doesn't exist, treat as empty
            } else {
                const msg = std.fmt.allocPrint(allocator, "Error reading file: {s}", .{@errorName(err)}) catch
                    return .{ .content = "Error reading file", .is_error = true };
                return .{ .content = msg, .is_error = true };
            }
        };
        defer file.close();

        const file_size = file.getEndPos() catch 
            return .{ .content = "Error getting file size", .is_error = true };
        
        if (file_size > 10 * 1024 * 1024) {  // 10MB limit
            return .{ .content = "File too large for diff (>10MB)", .is_error = true };
        }

        const content = allocator.alloc(u8, file_size) catch
            return .{ .content = "Memory allocation failed", .is_error = true };
        
        _ = file.readAll(content) catch
            return .{ .content = "Error reading file content", .is_error = true };
            
        break :blk content;
    };

    // Split into lines for comparison - FIXED: Use .init() not .{}
    var current_lines = std.ArrayList([]const u8).init(allocator);
    var current_iter = std.mem.splitScalar(u8, current_content, '\n');
    while (current_iter.next()) |line| {
        current_lines.append(line) catch continue;
    }

    var new_lines = std.ArrayList([]const u8).init(allocator);
    var new_iter = std.mem.splitScalar(u8, new_content, '\n');
    while (new_iter.next()) |line| {
        new_lines.append(line) catch continue;
    }

    // Generate diff output - FIXED: Use .init() not .{}
    var diff_output = std.ArrayList(u8).init(allocator);
    diff_output.ensureTotalCapacity(8192) catch {};

    const W = struct {
        fn print(buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) void {
            var tmp: [1024]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
            buf.appendSlice(s) catch {};
        }
        fn str(buf: *std.ArrayList(u8), s: []const u8) void {
            buf.appendSlice(s) catch {};
        }
    };

    // Header
    W.str(&diff_output, "📝 **File Diff Preview**\n");
    W.print(&diff_output, "**Path:** `{s}`\n", .{path});
    W.print(&diff_output, "**Current lines:** {d}, **New lines:** {d}\n\n", .{current_lines.items.len, new_lines.items.len});

    // Simple line-by-line diff
    const max_lines = @max(current_lines.items.len, new_lines.items.len);
    
    for (0..max_lines) |i| {
        const current_line = if (i < current_lines.items.len) current_lines.items[i] else null;
        const new_line = if (i < new_lines.items.len) new_lines.items[i] else null;
        
        if (current_line == null and new_line != null) {
            // Added line
            W.print(&diff_output, "**+{d}:** `{s}`\n", .{i + 1, new_line.?});
        } else if (current_line != null and new_line == null) {
            // Removed line  
            W.print(&diff_output, "**-{d}:** `{s}`\n", .{i + 1, current_line.?});
        } else if (current_line != null and new_line != null) {
            // Compare lines
            if (!std.mem.eql(u8, current_line.?, new_line.?)) {
                W.print(&diff_output, "**-{d}:** `{s}`\n", .{i + 1, current_line.?});
                W.print(&diff_output, "**+{d}:** `{s}`\n", .{i + 1, new_line.?});
            }
        }
    }

    if (apply) {
        W.str(&diff_output, "\n🔄 **Applying changes...**\n");
        
        // Create backup
        const backup_path = std.fmt.allocPrint(allocator, "{s}.backup.{d}", .{ path, std.time.timestamp() }) catch
            return .{ .content = "Backup path generation failed", .is_error = true };
            
        // Only backup if original file exists
        if (std.fs.accessAbsolute(path, .{})) {
            std.fs.copyFileAbsolute(path, backup_path, .{}) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "Backup failed: {s}", .{@errorName(err)}) catch "Backup failed";
                return .{ .content = msg, .is_error = true };
            };
            W.print(&diff_output, "💾 **Backup created:** `{s}`\n", .{backup_path});
        } else |_| {
            W.str(&diff_output, "📄 **Creating new file** (no backup needed)\n");
        }
        
        // Write new content
        const file = std.fs.createFileAbsolute(path, .{}) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "File creation failed: {s}", .{@errorName(err)}) catch "File creation failed";
            return .{ .content = msg, .is_error = true };
        };
        defer file.close();
        
        file.writeAll(new_content) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "File write failed: {s}", .{@errorName(err)}) catch "File write failed";
            return .{ .content = msg, .is_error = true };
        };
        
        W.str(&diff_output, "✅ **Changes applied successfully!**\n");
    } else {
        W.str(&diff_output, "\n💡 **Use `apply=true` to apply these changes**\n");
    }

    return .{ .content = diff_output.toOwnedSlice() catch "Diff generated", .is_error = false };
}