const std = @import("std");
const json = std.json;
const common = @import("common");
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "meme_tool",
    .description =
        "Generate a meme via the Imgflip API and return its image URL. " ++
        "The URL is auto-embedded — do NOT paste it in your reply text. " ++
        "Just react to the meme naturally (comment on it, roast it, etc). " ++
        "\n\nSTRONG PREFERENCE: ALWAYS write your own top_text and bottom_text " ++
        "that are specific to the current conversation. Generic auto-captioned " ++
        "memes are boring. Read the recent messages, pick a template whose " ++
        "format fits the joke you want to make, and write custom captions " ++
        "referencing the actual topic. " ++
        "\n\nOnly omit top_text/bottom_text if the user EXPLICITLY says " ++
        "\"surprise me\", \"random meme\", or gives you nothing to riff on. " ++
        "Writing your own captions is the default, not the fallback. " ++
        "\n\nPicking a template: match the joke shape to the template. " ++
        "\n- drake: rejecting A, preferring B (contrast / upgrade) " ++
        "\n- this_is_fine: everything is on fire but we pretend it's ok " ++
        "\n- success_kid: a small win, victorious fist " ++
        "\n- picard_facepalm: frustrated disbelief at something dumb " ++
        "\n- confused_math: trying to work out incomprehensible logic " ++
        "\n- expanding_brain: escalating levels of (bad) ideas, 4 tiers " ++
        "\n- surprised_pikachu: shocked at the predictable outcome " ++
        "\n- change_my_mind: a hot take you're daring people to challenge " ++
        "\n- batman_slap: aggressively shutting down a bad opinion " ++
        "\n- woman_yelling_cat: person accusing, cat unbothered " ++
        "\n\nKeep captions SHORT (≤60 chars per line). Imgflip auto-wraps " ++
        "long text poorly. " ++
        "\n\nExamples: " ++
        "{\"template\":\"drake\",\"top_text\":\"Spawning a subagent for " ++
        "everything\",\"bottom_text\":\"Using the meme tool directly\"} " ++
        "· {\"template\":\"this_is_fine\",\"top_text\":\"CI pipeline has " ++
        "been red for 3 days\",\"bottom_text\":\"This is fine\"} " ++
        "\n\nOnly fall back to {\"context\":\"debugging\"} (auto-template, " ++
        "default text) when the user has given zero signal about what the " ++
        "joke should be. Available templates: drake, this_is_fine, " ++
        "success_kid, picard_facepalm, confused_math, expanding_brain, " ++
        "surprised_pikachu, change_my_mind, batman_slap, woman_yelling_cat.",
    .input_schema_json =
        \\{"type":"object","properties":{"template":{"type":"string","description":"PREFERRED: pick the template whose format fits the joke. One of: drake, this_is_fine, success_kid, picard_facepalm, confused_math, expanding_brain, surprised_pikachu, change_my_mind, batman_slap, woman_yelling_cat."},"top_text":{"type":"string","description":"PREFERRED: top caption, written by you, specific to the current conversation. Keep under ~60 chars."},"bottom_text":{"type":"string","description":"PREFERRED: bottom caption, written by you, specific to the current conversation. Keep under ~60 chars."},"context":{"type":"string","description":"FALLBACK ONLY: generic context keyword (debugging, success, gaming, etc.) used to auto-pick a template with default captions. Do not use if you can write your own top_text/bottom_text."},"mood":{"type":"string","description":"FALLBACK ONLY: mood keyword for auto-selection. Same guidance as context — prefer writing your own captions."}}}
    ,
    .requires_confirmation = false,
    .handler = &execute,
};

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    // Serialize input to JSON string
    var input_aw: std.Io.Writer.Allocating = .init(allocator);
    json.Stringify.value(input, .{}, &input_aw.writer) catch {
        return .{ .content = "Failed to serialize input", .is_error = true };
    };
    const input_str = input_aw.written();

    const python = common.config.getPython(allocator) catch
        return .{ .content = "Failed to resolve python", .is_error = true };
    defer allocator.free(python);
    const script = common.config.getToolScript(allocator, "meme_tool.py") catch
        return .{ .content = "Failed to resolve meme script", .is_error = true };
    defer allocator.free(script);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ python, script, input_str },
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
