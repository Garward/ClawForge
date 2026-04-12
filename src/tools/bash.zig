const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "bash",
    .description = "Execute a shell command. For running builds, git, ls, grep, and system utilities ONLY. " ++
        "Use dedicated tools first for code understanding and modification: file_read for reading, file_diff for edits, file_write for new files, zig_test for compiler diagnostics. " ++
        "Use bash for builds, searches, git, and system utilities when a dedicated tool does not fit. " ++
        "Do NOT use bash as a substitute for normal file reading or file editing. " ++
        "File write commands (cat >, echo >, sed -i) are blocked — use the dedicated file tools instead.",
    .input_schema_json =
    \\{"type":"object","properties":{"command":{"type":"string","description":"The bash command to execute"}},"required":["command"]}
    ,
    .requires_confirmation = true,
    .handler = &execute,
};

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    const command = blk: {
        if (input == .object) {
            if (input.object.get("command")) |cmd| {
                if (cmd == .string) {
                    break :blk cmd.string;
                }
            }
        }
        return .{ .content = "Missing 'command' parameter", .is_error = true };
    };

    // Block self-curling — deadlocks the single-threaded server
    if (std.mem.indexOf(u8, command, "127.0.0.1:8081") != null or
        std.mem.indexOf(u8, command, "localhost:8081") != null)
    {
        return .{
            .content = "BLOCKED: Cannot HTTP request your own server during a conversation (deadlock). Use sqlite3 to query the database directly: sqlite3 /home/garward/Scripts/Tools/ClawForge/data/workspace.db \"<SQL>\"",
            .model_content = "BLOCKED: Local self-HTTP request rejected to avoid deadlock. Query the SQLite DB directly instead.",
            .is_error = true,
        };
    }

    // Block sed -i — use the file_diff tool instead for safe edits with backup
    if (std.mem.indexOf(u8, command, "sed -i") != null) {
        return .{
            .content = "BLOCKED: sed -i is disabled. Use the file_diff tool for safe, targeted edits with automatic backup.",
            .is_error = true,
        };
    }

    // Block file-writing bash patterns — use file_write or file_diff tools instead
    if ((std.mem.indexOf(u8, command, "cat >") != null or
        std.mem.indexOf(u8, command, "cat >>") != null or
        std.mem.indexOf(u8, command, "cat <<") != null or
        std.mem.indexOf(u8, command, "echo >") != null or
        std.mem.indexOf(u8, command, "printf >") != null or
        std.mem.indexOf(u8, command, "printf >>") != null or
        std.mem.indexOf(u8, command, "tee ") != null or
        std.mem.indexOf(u8, command, "dd of=") != null) and
        std.mem.indexOf(u8, command, "/dev/null") == null)
    {
        return .{
            .content = "BLOCKED: Use the file_write tool to create files or file_diff tool to edit them. Writing files through bash causes encoding corruption. The file_write tool handles content cleanly and file_diff creates automatic backups.",
            .is_error = true,
        };
    }

    // Execute with 30s timeout
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/usr/bin/timeout", "30", "/bin/bash", "-c", command },
        .max_output_bytes = 1024 * 1024, // 1MB limit
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Error executing command: {s}", .{@errorName(err)}) catch
            return .{ .content = "Error executing command", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Combine stdout and stderr
    if (result.stderr.len > 0 and result.stdout.len > 0) {
        const combined = std.fmt.allocPrint(allocator, "{s}\n[stderr]\n{s}", .{ result.stdout, result.stderr }) catch
            return .{ .content = result.stdout, .is_error = false };
        return .{
            .content = combined,
            .model_content = registry.compactForModel(allocator, "bash output", combined, 4000, 1500),
            .is_error = result.term.Exited != 0,
        };
    } else if (result.stderr.len > 0) {
        const output = allocator.dupe(u8, result.stderr) catch
            return .{ .content = "Error copying output", .is_error = true };
        return .{
            .content = output,
            .model_content = registry.compactForModel(allocator, "bash stderr", output, 3000, 1000),
            .is_error = result.term.Exited != 0,
        };
    } else {
        const output = allocator.dupe(u8, result.stdout) catch
            return .{ .content = "Error copying output", .is_error = true };
        return .{
            .content = output,
            // Purpose: bash output is often the single biggest repeated prompt cost in tool loops.
            .model_content = registry.compactForModel(allocator, "bash output", output, 4000, 1500),
            .is_error = false,
        };
    }
}
