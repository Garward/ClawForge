//! Compatibility helpers for running child processes through Zig 0.16's Io API.

const std = @import("std");
const config = @import("config.zig");

pub const RunOptions = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    max_output_bytes: usize = 50 * 1024,
    cwd: ?[]const u8 = null,
};

pub const Term = union(enum) {
    Exited: u8,
    Signal: std.posix.SIG,
    Stopped: std.posix.SIG,
    Unknown: u32,
};

pub const RunResult = struct {
    term: Term,
    stdout: []u8,
    stderr: []u8,
};

pub fn run(options: RunOptions) !RunResult {
    const result = try std.process.run(options.allocator, config.runtimeIo(), .{
        .argv = options.argv,
        .stdout_limit = .limited(options.max_output_bytes),
        .stderr_limit = .limited(options.max_output_bytes),
        .cwd = if (options.cwd) |path| .{ .path = path } else .inherit,
    });

    return .{
        .term = switch (result.term) {
            .exited => |code| .{ .Exited = code },
            .signal => |signal| .{ .Signal = signal },
            .stopped => |signal| .{ .Stopped = signal },
            .unknown => |code| .{ .Unknown = code },
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}
