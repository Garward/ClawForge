const std = @import("std");
const json = std.json;
const common = @import("common");
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "visual_audit",
    .description = "Audit frontend visuals from a URL, local HTML/file, or static screenshot/image path. " ++
        "For rendered targets, uses Playwright to capture desktop/tablet/mobile screenshots and returns DOM boxes, layout issues, " ++
        "console/page errors, clipping, overflow, low-contrast heuristics, small tap targets, and screenshot paths. " ++
        "For static images, prepares metadata and a screenshot path for vision_read. Call vision_read on returned screenshot paths when you need actual visual/OCR interpretation.",
    .input_schema_json =
    \\{"type":"object","properties":{"target":{"type":"string","description":"URL, local HTML/file path, or screenshot/image path to audit."},"target_type":{"type":"string","enum":["auto","url","file","html","image"],"description":"Target kind. Use auto unless you need to force image/file/url.","default":"auto"},"viewports":{"type":"array","description":"Viewport presets or objects. Presets: desktop, tablet, mobile. Object entries may use {name,width,height}.","items":{}},"wait_ms":{"type":"integer","description":"Extra wait after page load before screenshots, in milliseconds.","default":800},"timeout_ms":{"type":"integer","description":"Navigation timeout in milliseconds.","default":20000},"full_page":{"type":"boolean","description":"Capture full-page screenshots instead of viewport-only screenshots.","default":true},"max_elements":{"type":"integer","description":"Maximum visible DOM elements to return per viewport.","default":80},"prompt":{"type":"string","description":"Optional product/style context for the follow-up vision critique."}},"required":["target"]}
    ,
    .requires_confirmation = false,
    .handler = &execute,
};

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    var input_aw: std.Io.Writer.Allocating = .init(allocator);
    json.Stringify.value(input, .{}, &input_aw.writer) catch {
        return .{ .content = "Failed to serialize input", .is_error = true };
    };
    const input_str = input_aw.written();

    const python = common.config.getPython(allocator) catch
        return .{ .content = "Failed to resolve python", .is_error = true };
    defer allocator.free(python);
    const script = common.config.getToolScript(allocator, "visual_audit.py") catch
        return .{ .content = "Failed to resolve visual audit script", .is_error = true };
    defer allocator.free(script);

    const result = common.process.run(.{
        .allocator = allocator,
        .argv = &.{ "/usr/bin/timeout", "90", python, script, input_str },
        .max_output_bytes = 1024 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Visual audit tool error: {s}", .{@errorName(err)}) catch
            return .{ .content = "Visual audit tool failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    if (result.stderr.len > 0) allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return .{ .content = if (result.stdout.len > 0) result.stdout else "Visual audit exited with error", .is_error = true };
    }

    return .{ .content = if (result.stdout.len > 0) result.stdout else "(no visual audit output)", .is_error = false };
}
