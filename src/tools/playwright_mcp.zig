const std = @import("std");
const json = std.json;
const common = @import("common");
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "playwright_mcp",
    .description = "Use the Playwright MCP server configured in Codex (~/.codex/config.toml). Starts a temporary MCP stdio server, runs a sequence of browser tool calls, then shuts it down. Best for browser interaction, page snapshots, screenshots, clicking, typing, and JS evaluation. Inline screenshot image data is written to /tmp/clawforge_playwright_mcp and returned as a path; call vision_read on that path to inspect/OCR it. Use action='list_tools' to inspect available MCP tools, action='call' for one raw MCP tool call, or action='run' with steps for stateful navigate→snapshot→click sequences.",
    .input_schema_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["list_tools","call","run"],"description":"list_tools = list Playwright MCP tools. call = one raw MCP tools/call. run = sequence of raw or convenience steps. Default run."},"tool_name":{"type":"string","description":"Raw MCP tool name for action=call, e.g. browser_navigate or browser_snapshot."},"arguments":{"type":"object","description":"Arguments for action=call."},"steps":{"type":"array","description":"Sequence for action=run. Each item may be {'tool_name':'browser_*','arguments':{...}} or a convenience action such as navigate/snapshot/screenshot/click/type/press_key/wait/evaluate/resize/close.","items":{"type":"object","properties":{"action":{"type":"string","description":"Convenience action: navigate, snapshot, screenshot, click, type, press_key, wait, evaluate, resize, close."},"tool_name":{"type":"string","description":"Raw MCP tool name."},"arguments":{"type":"object"},"url":{"type":"string"},"element":{"type":"string"},"ref":{"type":"string"},"text":{"type":"string"},"key":{"type":"string"},"time":{"type":"number"},"function":{"type":"string"},"width":{"type":"integer"},"height":{"type":"integer"}}}},"timeout_ms":{"type":"integer","description":"Per MCP request timeout, capped at 120000. Default 30000."},"command":{"type":"array","items":{"type":"string"},"description":"Optional override MCP server command. Defaults to ~/.codex mcp_servers.playwright."}}}
    ,
    .requires_confirmation = false,
    .handler = &execute,
};

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    if (input != .object) {
        return .{ .content = "Expected JSON object", .is_error = true };
    }

    var input_aw: std.Io.Writer.Allocating = .init(allocator);
    json.Stringify.value(input, .{}, &input_aw.writer) catch {
        return .{ .content = "Failed to serialize input", .is_error = true };
    };
    const input_str = input_aw.written();

    const python = common.config.getPython(allocator) catch
        return .{ .content = "Failed to resolve python", .is_error = true };
    defer allocator.free(python);

    const script = common.config.getToolScript(allocator, "playwright_mcp.py") catch
        return .{ .content = "Failed to resolve playwright_mcp.py", .is_error = true };
    defer allocator.free(script);

    const result = common.process.run(.{
        .allocator = allocator,
        .argv = &.{ python, script, input_str },
        .max_output_bytes = 2 * 1024 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Failed to run Playwright MCP wrapper: {s}", .{@errorName(err)}) catch
            return .{ .content = "Failed to run Playwright MCP wrapper", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        defer allocator.free(result.stdout);
        const msg = if (result.stdout.len > 0 and result.stderr.len > 0)
            std.fmt.allocPrint(allocator, "{s}\n\n[stderr]\n{s}", .{ result.stdout, result.stderr }) catch "Playwright MCP failed"
        else if (result.stdout.len > 0)
            std.fmt.allocPrint(allocator, "{s}", .{result.stdout}) catch "Playwright MCP failed"
        else if (result.stderr.len > 0)
            std.fmt.allocPrint(allocator, "Playwright MCP failed:\n{s}", .{result.stderr}) catch "Playwright MCP failed"
        else
            "Playwright MCP failed";
        return .{ .content = msg, .is_error = true };
    }

    return .{ .content = result.stdout, .is_error = false };
}
