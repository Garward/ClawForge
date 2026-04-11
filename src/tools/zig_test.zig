const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "zig_test",
    .description = "Test Zig code for compilation errors BEFORE rebuilding. ALWAYS use this before the rebuild tool. " ++
        "Modes: 'build' (recommended — runs full project build check), 'ast-check' (syntax only for single file). " ++
        "Usage: {\"mode\":\"build\"} to verify the full project compiles. If it fails, fix errors before calling rebuild.",
    .input_schema_json =
        \\{"type":"object","properties":{"mode":{"type":"string","enum":["build","ast-check"],"default":"build","description":"build = full project compile check, ast-check = single file syntax"},"path":{"type":"string","description":"File path (only for ast-check mode)"}}}
    ,
    .requires_confirmation = false,
    .handler = &execute,
};

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    const mode = blk: {
        if (input == .object) {
            if (input.object.get("mode")) |m| {
                if (m == .string) break :blk m.string;
            }
        }
        break :blk "build";
    };

    if (std.mem.eql(u8, mode, "build")) {
        // Full project build check — the only reliable way to catch cross-module errors
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "/usr/bin/timeout", "60", "zig", "build" },
            .max_output_bytes = 256 * 1024,
            .cwd = "/home/garward/Scripts/Tools/ClawForge",
        }) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Build check failed to run: {s}", .{@errorName(err)}) catch
                return .{ .content = "Build check failed", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };

        if (result.stderr.len > 0) allocator.free(result.stderr);

        if (result.term.Exited == 0) {
            return .{ .content = "BUILD OK — safe to call rebuild tool", .is_error = false };
        } else {
            var out: std.ArrayList(u8) = .{};
            out.appendSlice(allocator, "BUILD FAILED — DO NOT rebuild. Fix these errors first:\n\n") catch {};
            out.appendSlice(allocator, if (result.stdout.len > 0) result.stdout else "(no output)") catch {};
            return .{ .content = out.toOwnedSlice(allocator) catch "Build failed", .is_error = true };
        }
    }

    // ast-check mode — single file syntax check
    const raw_path = blk: {
        if (input == .object) {
            if (input.object.get("path")) |p| {
                if (p == .string) break :blk p.string;
            }
        }
        return .{ .content = "ast-check mode requires 'path' parameter", .is_error = true };
    };

    const path = if (raw_path.len > 0 and raw_path[0] == '~') blk: {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        break :blk std.fmt.allocPrint(allocator, "{s}{s}", .{ home, raw_path[1..] }) catch
            return .{ .content = "Path expansion failed", .is_error = true };
    } else raw_path;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "ast-check", path },
        .max_output_bytes = 256 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Failed to run zig: {s}", .{@errorName(err)}) catch
            return .{ .content = "Process execution failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);

    const status_icon = if (result.term.Exited == 0) "✅" else "❌";
    const status_text = if (result.term.Exited == 0) "PASSED" else "FAILED";
    
    output.appendSlice(allocator, "🧪 **Zig Test Results**\n\n") catch {};
    output.appendSlice(allocator, status_icon) catch {};
    output.appendSlice(allocator, " **") catch {};
    output.appendSlice(allocator, status_text) catch {};
    output.appendSlice(allocator, "** (") catch {};
    output.appendSlice(allocator, mode) catch {};
    output.appendSlice(allocator, "): ") catch {};
    output.appendSlice(allocator, path) catch {};
    output.appendSlice(allocator, "\n\n") catch {};

    if (result.stdout.len > 0) {
        output.appendSlice(allocator, "**📤 STDOUT:**\n```\n") catch {};
        output.appendSlice(allocator, result.stdout) catch {};
        output.appendSlice(allocator, "\n```\n\n") catch {};
    }

    if (result.stderr.len > 0) {
        output.appendSlice(allocator, "**📥 STDERR:**\n```\n") catch {};
        output.appendSlice(allocator, result.stderr) catch {};
        output.appendSlice(allocator, "\n```\n\n") catch {};
    }

    if (result.term.Exited == 0) {
        output.appendSlice(allocator, "🎯 **Safe to rebuild!** No compilation errors found.\n") catch {};
    } else {
        output.appendSlice(allocator, "⚠️  **DO NOT REBUILD** - Fix errors first to prevent daemon suicide!\n") catch {};
    }

    return .{ .content = output.toOwnedSlice(allocator) catch "Test complete", .is_error = result.term.Exited != 0 };
}