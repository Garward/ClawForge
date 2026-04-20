const std = @import("std");
const json = std.json;
const common = @import("common");
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "research_tool",
    .description = "Web research tool. Search the web, Wikipedia, news, or academic sources. Privacy-focused using DuckDuckGo (no API keys). " ++
        "Types: 'general' (mixed), 'wikipedia' (encyclopedic), 'news' (current events), 'academic' (papers).",
    .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Search term or question"},"search_type":{"type":"string","description":"general, wikipedia, news, or academic","default":"general"},"max_results":{"type":"integer","description":"Max results (1-20)","default":8}},"required":["query"]}
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
    const script = common.config.getToolScript(allocator, "research_tool.py") catch
        return .{ .content = "Failed to resolve research script", .is_error = true };
    defer allocator.free(script);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/usr/bin/timeout", "30", python, script, input_str },
        .max_output_bytes = 512 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Research tool error: {s}", .{@errorName(err)}) catch
            return .{ .content = "Research tool failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    if (result.stderr.len > 0) allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return .{ .content = if (result.stdout.len > 0) result.stdout else "Research tool exited with error", .is_error = true };
    }

    return .{ .content = if (result.stdout.len > 0) result.stdout else "(no results)", .is_error = false };
}
