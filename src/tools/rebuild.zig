const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "rebuild",
    .description = "Rebuild and restart the ClawForge daemon. This schedules a deferred rebuild that runs AFTER your response finishes streaming — you will NOT be interrupted. " ++
        "Use this after modifying Zig source files (src/tools/*.zig, src/adapters/*.zig, etc.). " ++
        "NOT needed for Python-only tools registered via /api/tools/register. " ++
        "The rebuild log is written to /tmp/clawforge_rebuild.log.",
    .input_schema_json =
        \\{"type":"object","properties":{"delay":{"type":"integer","description":"Seconds to wait before rebuilding (default: 3, minimum: 2)"}}}
    ,
    .requires_confirmation = true,
    .handler = &execute,
};

const REBUILD_SCRIPT = "/home/garward/.local/bin/clawforge-rebuild.sh";

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    // Get delay (default 3, min 2)
    var delay: u32 = 3;
    if (input == .object) {
        if (input.object.get("delay")) |d| {
            if (d == .integer) {
                delay = @max(2, @as(u32, @intCast(@min(d.integer, 30))));
            }
        }
    }

    var delay_buf: [8]u8 = undefined;
    const delay_str = std.fmt.bufPrint(&delay_buf, "{d}", .{delay}) catch "3";

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/bin/bash", REBUILD_SCRIPT, delay_str },
        .max_output_bytes = 4096,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Rebuild script error: {s}", .{@errorName(err)}) catch
            return .{ .content = "Rebuild script failed to launch", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    if (result.stderr.len > 0) allocator.free(result.stderr);

    return .{
        .content = if (result.stdout.len > 0) result.stdout else "Rebuild scheduled",
        .is_error = result.term.Exited != 0,
    };
}
