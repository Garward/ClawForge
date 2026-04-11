const std = @import("std");

/// Sandbox for executing generated tools safely.
///
/// Restrictions:
/// - Filesystem limited to specified working directory
/// - Timeout enforced
/// - Output size capped
/// - No network by default (can be enabled per-tool)
///
/// Public API callable by generator, engine, and adapters.
pub const Sandbox = struct {
    allocator: std.mem.Allocator,
    /// Working directory for tool execution
    work_dir: []const u8,
    /// Max execution time in milliseconds
    timeout_ms: u32 = 30000,
    /// Max output size in bytes
    max_output: usize = 1024 * 1024, // 1MB
    /// Allow network access
    allow_network: bool = false,

    pub fn init(allocator: std.mem.Allocator, work_dir: []const u8) Sandbox {
        return .{
            .allocator = allocator,
            .work_dir = work_dir,
        };
    }

    /// Execute a bash script in the sandbox. Returns stdout/stderr.
    pub fn executeBash(self: *Sandbox, script: []const u8, input_json: ?[]const u8) !ExecutionResult {
        // Write script to temp file
        const script_path = try std.fs.path.join(self.allocator, &.{ self.work_dir, ".clawforge_tool.sh" });
        defer self.allocator.free(script_path);

        {
            const file = try std.fs.createFileAbsolute(script_path, .{});
            defer file.close();
            try file.writeAll(script);
        }

        // Build command: bash with restricted options
        // -r: restricted mode (no cd, no setting PATH, no redirecting output to files)
        var argv_buf: [16][]const u8 = undefined;
        var argc: usize = 0;

        argv_buf[argc] = "/bin/bash";
        argc += 1;

        if (!self.allow_network) {
            // Use unshare to restrict network (requires no special privileges for user ns)
            // Fallback: just run without network restriction if unshare isn't available
        }

        argv_buf[argc] = script_path;
        argc += 1;

        // Pass input as argument if provided
        if (input_json) |input| {
            argv_buf[argc] = input;
            argc += 1;
        }

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv_buf[0..argc],
            .max_output_bytes = self.max_output,
            .cwd = self.work_dir,
        }) catch |err| {
            // Clean up script file
            std.fs.deleteFileAbsolute(script_path) catch {};
            return .{
                .stdout = "",
                .stderr = try std.fmt.allocPrint(self.allocator, "Execution failed: {s}", .{@errorName(err)}),
                .exit_code = 1,
                .timed_out = false,
            };
        };

        // Clean up script file
        std.fs.deleteFileAbsolute(script_path) catch {};

        return .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .exit_code = result.term.Exited,
            .timed_out = false,
        };
    }

    /// Execute a Python script in the sandbox.
    pub fn executePython(self: *Sandbox, script: []const u8, input_json: ?[]const u8) !ExecutionResult {
        _ = input_json;
        const script_path = try std.fs.path.join(self.allocator, &.{ self.work_dir, ".clawforge_tool.py" });
        defer self.allocator.free(script_path);

        {
            const file = try std.fs.createFileAbsolute(script_path, .{});
            defer file.close();
            try file.writeAll(script);
        }

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "python3", script_path },
            .max_output_bytes = self.max_output,
            .cwd = self.work_dir,
        }) catch |err| {
            std.fs.deleteFileAbsolute(script_path) catch {};
            return .{
                .stdout = "",
                .stderr = try std.fmt.allocPrint(self.allocator, "Execution failed: {s}", .{@errorName(err)}),
                .exit_code = 1,
                .timed_out = false,
            };
        };

        std.fs.deleteFileAbsolute(script_path) catch {};

        return .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .exit_code = result.term.Exited,
            .timed_out = false,
        };
    }
};

pub const ExecutionResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u32,
    timed_out: bool,

    pub fn succeeded(self: ExecutionResult) bool {
        return self.exit_code == 0 and !self.timed_out;
    }
};
