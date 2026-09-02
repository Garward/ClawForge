const std = @import("std");
const json = std.json;
const common = @import("common");
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "bash",
    .description = "Execute a shell command. For running builds, git, ls, grep, and system utilities ONLY. " ++
        "Use dedicated tools first for code understanding and modification: file_find for locating paths, file_read for reading, file_diff for edits, file_write for new files, zig_test for compiler diagnostics. " ++
        "Use bash for builds, searches, git, and system utilities when a dedicated tool does not fit. " ++
        "Do NOT use bash as a substitute for normal file reading or file editing. " ++
        "File write commands (cat >, echo >, sed -i, Python/Node/Ruby/Perl file-writing scripts) are blocked. " ++
        "Do not generate long heredocs or scripts to create/edit files: they will be rejected after wasting tokens. " ++
        "Use file_write for new files and file_diff for edits.",
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

    // Block actual self-HTTP calls. Do not block code generation that merely
    // writes the local ClawForge URL into a source file or README.
    if (isSelfHttpCommand(allocator, command)) {
        return .{
            .content = "BLOCKED: Cannot HTTP request your own server during a conversation (deadlock). Use sqlite3 to query the database directly: sqlite3 \"$CLAWFORGE_ROOT/data/workspace.db\" \"<SQL>\"",
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

    if (isScriptedFileWriteCommand(allocator, command)) {
        return .{
            .content = "BLOCKED: This bash command appears to use a scripting language to create or edit files. Use file_write for new files or file_diff for edits. Bash is for builds, git, searches, and system utilities only.",
            .model_content = "BLOCKED: Scripted file writes through bash are disabled. Use file_write/file_diff instead.",
            .is_error = true,
        };
    }

    // Execute with 30s timeout
    const result = common.process.run(.{
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

fn isSelfHttpCommand(allocator: std.mem.Allocator, command: []const u8) bool {
    const lower = std.ascii.allocLowerString(allocator, command) catch command;
    defer if (lower.ptr != command.ptr) allocator.free(lower);

    const has_self_target = std.mem.indexOf(u8, lower, "127.0.0.1:8081") != null or
        std.mem.indexOf(u8, lower, "localhost:8081") != null or
        std.mem.indexOf(u8, lower, "0.0.0.0:8081") != null or
        std.mem.indexOf(u8, lower, "/dev/tcp/127.0.0.1/8081") != null or
        std.mem.indexOf(u8, lower, "/dev/tcp/localhost/8081") != null;
    if (!has_self_target) return false;

    return containsShellWord(lower, "curl") or
        containsShellWord(lower, "wget") or
        containsShellWord(lower, "http") or
        containsShellWord(lower, "https") or
        containsShellWord(lower, "xh") or
        containsShellWord(lower, "websocat") or
        containsShellWord(lower, "nc") or
        containsShellWord(lower, "netcat") or
        containsShellWord(lower, "telnet") or
        std.mem.indexOf(u8, lower, "/dev/tcp/127.0.0.1/8081") != null or
        std.mem.indexOf(u8, lower, "/dev/tcp/localhost/8081") != null;
}

fn isScriptedFileWriteCommand(allocator: std.mem.Allocator, command: []const u8) bool {
    const lower = std.ascii.allocLowerString(allocator, command) catch command;
    defer if (lower.ptr != command.ptr) allocator.free(lower);

    const has_script_runner = containsShellWord(lower, "python") or
        containsShellWord(lower, "python3") or
        containsShellWord(lower, "node") or
        containsShellWord(lower, "ruby") or
        containsShellWord(lower, "perl");
    if (!has_script_runner) return false;

    if (std.mem.indexOf(u8, lower, ".write_text(") != null or
        std.mem.indexOf(u8, lower, ".write_bytes(") != null or
        std.mem.indexOf(u8, lower, ".write(") != null or
        std.mem.indexOf(u8, lower, "writefile") != null or
        std.mem.indexOf(u8, lower, "writefilesync") != null or
        std.mem.indexOf(u8, lower, "copyfile") != null or
        std.mem.indexOf(u8, lower, "shutil.copy") != null)
    {
        return true;
    }

    const opens_for_write = std.mem.indexOf(u8, lower, "open(") != null and
        (std.mem.indexOf(u8, lower, ",'w") != null or
            std.mem.indexOf(u8, lower, ", 'w") != null or
            std.mem.indexOf(u8, lower, ",\"w") != null or
            std.mem.indexOf(u8, lower, ", \"w") != null or
            std.mem.indexOf(u8, lower, "mode='w") != null or
            std.mem.indexOf(u8, lower, "mode=\"w") != null or
            std.mem.indexOf(u8, lower, ",'a") != null or
            std.mem.indexOf(u8, lower, ", 'a") != null or
            std.mem.indexOf(u8, lower, ",\"a") != null or
            std.mem.indexOf(u8, lower, ", \"a") != null or
            std.mem.indexOf(u8, lower, "mode='a") != null or
            std.mem.indexOf(u8, lower, "mode=\"a") != null);
    if (opens_for_write) return true;

    return false;
}

fn containsShellWord(haystack: []const u8, word: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, word)) |idx| {
        const before_ok = idx == 0 or isShellWordBoundary(haystack[idx - 1]);
        const end = idx + word.len;
        const after_ok = end >= haystack.len or isShellWordBoundary(haystack[end]);
        if (before_ok and after_ok) return true;
        start = idx + word.len;
    }
    return false;
}

fn isShellWordBoundary(c: u8) bool {
    return std.ascii.isWhitespace(c) or switch (c) {
        ';', '&', '|', '(', ')', '{', '}', '[', ']', '<', '>', '"', '\'', '`' => true,
        else => false,
    };
}
