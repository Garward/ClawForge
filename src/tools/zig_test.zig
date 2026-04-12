const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "zig_test",
    .description = "Run Zig compiler checks and return the actual diagnostics. " ++
        "Use mode='build' for full-project compiler errors before rebuild. " ++
        "Use mode='ast-check' for a single-file syntax check. " ++
        "After a failure, reread the cited file and nearby lines before attempting another edit. " ++
        "Do not retry the same patch without checking the current file state.",
    .input_schema_json =
    \\{"type":"object","properties":{"mode":{"type":"string","enum":["build","ast-check"],"default":"build","description":"build = full project compile check, ast-check = syntax check for one file"},"path":{"type":"string","description":"Absolute file path required for ast-check mode"}},"additionalProperties":false}
    ,
    .requires_confirmation = false,
    .handler = &execute,
};

const project_root = "/home/garward/Scripts/Tools/ClawForge";

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
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "/usr/bin/timeout", "90", "zig", "build" },
            .max_output_bytes = 512 * 1024,
            .cwd = project_root,
        }) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Failed to run zig build: {s}", .{@errorName(err)}) catch
                return .{ .content = "Failed to run zig build", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };

        return formatCompilerResult(allocator, "build", null, result);
    }

    const raw_path = blk: {
        if (input == .object) {
            if (input.object.get("path")) |p| {
                if (p == .string) break :blk p.string;
            }
        }
        return .{ .content = "ast-check mode requires 'path' parameter", .is_error = true };
    };

    var owned_path: ?[]u8 = null;
    defer if (owned_path) |p| allocator.free(p);

    const path = if (raw_path.len > 0 and raw_path[0] == '~') blk: {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const expanded = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, raw_path[1..] }) catch
            return .{ .content = "Path expansion failed", .is_error = true };
        owned_path = expanded;
        break :blk expanded;
    } else raw_path;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/usr/bin/timeout", "30", "zig", "ast-check", path },
        .max_output_bytes = 256 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Failed to run zig ast-check: {s}", .{@errorName(err)}) catch
            return .{ .content = "Failed to run zig ast-check", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    return formatCompilerResult(allocator, "ast-check", path, result);
}

fn formatCompilerResult(
    allocator: std.mem.Allocator,
    mode: []const u8,
    path: ?[]const u8,
    result: std.process.Child.RunResult,
) registry.ToolResult {
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const diagnostics = joinDiagnostics(allocator, result.stdout, result.stderr) catch
        return .{ .content = "Failed to format compiler diagnostics", .is_error = true };
    defer allocator.free(diagnostics);

    const success = result.term == .Exited and result.term.Exited == 0;
    const subject = path orelse project_root;
    const term_text = formatTermination(allocator, result.term) catch "process status unavailable";
    defer if (term_text.ptr != "process status unavailable".ptr) allocator.free(term_text);
    const mode_label = if (std.mem.eql(u8, mode, "build")) "BUILD" else "AST-CHECK";

    const content = if (success)
        std.fmt.allocPrint(
            allocator,
            "ZIG {s} OK\nTarget: {s}\nStatus: {s}\n\n{s}",
            .{ mode_label, subject, term_text, if (diagnostics.len > 0) diagnostics else "No compiler diagnostics." },
        ) catch "Zig check passed"
    else
        std.fmt.allocPrint(
            allocator,
            "ZIG {s} FAILED\nTarget: {s}\nStatus: {s}\n\nCompiler diagnostics:\n{s}\n\nNext step: reread the cited file and nearby lines before patching. Do not guess from a stale read.",
            .{ mode_label, subject, term_text, if (diagnostics.len > 0) diagnostics else "(no compiler output)" },
        ) catch "Zig check failed";

    const model_content = registry.compactForModel(
        allocator,
        "zig compiler diagnostics",
        content,
        1800,
        1600,
    );

    return .{
        .content = content,
        .model_content = model_content,
        .is_error = !success,
    };
}

fn joinDiagnostics(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8) ![]const u8 {
    if (stdout.len == 0 and stderr.len == 0) {
        return try allocator.dupe(u8, "");
    }

    if (stdout.len == 0) {
        return try allocator.dupe(u8, stderr);
    }

    if (stderr.len == 0) {
        return try allocator.dupe(u8, stdout);
    }

    return std.fmt.allocPrint(
        allocator,
        "[stdout]\n{s}\n\n[stderr]\n{s}",
        .{ stdout, stderr },
    );
}

fn formatTermination(allocator: std.mem.Allocator, term: std.process.Child.Term) ![]const u8 {
    return switch (term) {
        .Exited => |code| std.fmt.allocPrint(allocator, "exit {d}", .{code}),
        .Signal => |sig| std.fmt.allocPrint(allocator, "signal {d}", .{sig}),
        .Stopped => |sig| std.fmt.allocPrint(allocator, "stopped {d}", .{sig}),
        .Unknown => |code| std.fmt.allocPrint(allocator, "unknown {d}", .{code}),
    };
}
