const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "meme_tool",
    .description = "Generate contextual memes using Imgflip API. Auto-selects templates based on context/mood or accepts manual template/caption. Returns meme URL." ++
        " Usage: {\"context\":\"debugging\"} or {\"template\":\"drake\",\"top_text\":\"Before\",\"bottom_text\":\"After\"}" ++
        " Available templates: drake, this_is_fine, success_kid, picard_facepalm, confused_math, expanding_brain, surprised_pikachu, change_my_mind, batman_slap, woman_yelling_cat",
    .input_schema_json =
        \\{"type":"object","properties":{"context":{"type":"string","description":"Context for auto-selecting template (debugging, success, gaming, etc.)"},"mood":{"type":"string","description":"Mood/tone (confusion, excitement, frustration)"},"template":{"type":"string","description":"Specific meme template name"},"top_text":{"type":"string","description":"Top caption text"},"bottom_text":{"type":"string","description":"Bottom caption text"}}}
    ,
    .requires_confirmation = false,
    .handler = &execute,
};

const MEME_SCRIPT = "/home/garward/Scripts/Tools/ClawForge/tools/meme_tool.py";
const PYTHON = "/home/garward/Scripts/Tools/.venv/bin/python3";

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    // Serialize input to JSON string
    var input_aw: std.Io.Writer.Allocating = .init(allocator);
    json.Stringify.value(input, .{}, &input_aw.writer) catch {
        return .{ .content = "Failed to serialize input", .is_error = true };
    };
    const input_str = input_aw.written();

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ PYTHON, MEME_SCRIPT, input_str },
        .max_output_bytes = 256 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Meme tool error: {s}", .{@errorName(err)}) catch
            return .{ .content = "Meme tool execution failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    if (result.stderr.len > 0) {
        allocator.free(result.stderr);
    }

    if (result.term.Exited != 0) {
        return .{ .content = if (result.stdout.len > 0) result.stdout else "Meme tool exited with error", .is_error = true };
    }

    return .{ .content = if (result.stdout.len > 0) result.stdout else "(no output)", .is_error = false };
}
