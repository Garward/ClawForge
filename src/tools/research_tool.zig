const std = @import("std");
const json = std.json;
const common = @import("common");
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "research_tool",
    .description = "Evidence-oriented web research tool. Searches web/Wikipedia/news/academic sources, normalizes URLs, fetches top pages, " ++
        "extracts cited excerpts, reports fetch warnings, and caches short-lived results. Privacy-focused no-key defaults using DuckDuckGo/arXiv/Wikipedia. " ++
        "Use 'queries' for related batch searches in one call; it returns per-query results plus deduped combined_results. " ++
        "Types: 'general' (mixed), 'wikipedia' (encyclopedic), 'news' (current events), 'academic' (papers).",
    .input_schema_json =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Single search term or question. Use this for one lookup."},"queries":{"type":"array","description":"Batch searches. Use this for related variants that should be searched in one tool call. Each item can override the shared options.","items":{"type":"object","properties":{"query":{"type":"string","description":"Search term or question for this batch item."},"search_type":{"type":"string","description":"general, wikipedia, news, or academic"},"max_results":{"type":"integer"},"fetch_pages":{"type":"boolean"},"max_fetches":{"type":"integer"},"freshness":{"type":"string"},"include_wikipedia":{"type":"boolean"},"include_news":{"type":"boolean"},"use_browser_fallback":{"type":"boolean"}},"required":["query"]}},"search_type":{"type":"string","description":"general, wikipedia, news, or academic","default":"general"},"max_results":{"type":"integer","description":"Max results per query (1-20). For batch mode, keep this small and use combined_max_results for the final evidence list.","default":8},"fetch_pages":{"type":"boolean","description":"Fetch and extract evidence from top result pages. Disable for fast shallow search.","default":true},"max_fetches":{"type":"integer","description":"Maximum result pages to fetch/extract per query (0-10).","default":5},"freshness":{"type":"string","description":"Optional freshness filter for web/news search: day, week, month, or year."},"include_wikipedia":{"type":"boolean","description":"Include Wikipedia in general searches.","default":true},"include_news":{"type":"boolean","description":"Include news results in general searches.","default":false},"use_browser_fallback":{"type":"boolean","description":"Use Playwright browser_fetch fallback for pages with poor HTTP extraction. Slower.","default":false},"max_queries":{"type":"integer","description":"Maximum batch queries to run (1-12).","default":8},"max_workers":{"type":"integer","description":"Parallel batch workers (1-8). Lower this if a site rate-limits.","default":4},"combined_max_results":{"type":"integer","description":"Maximum deduped combined_results returned for batch mode (1-50).","default":20}}}
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

    const result = common.process.run(.{
        .allocator = allocator,
        .argv = &.{ "/usr/bin/timeout", "90", python, script, input_str },
        .max_output_bytes = 1024 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Research tool error: {s}", .{@errorName(err)}) catch
            return .{ .content = "Research tool failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    if (result.stderr.len > 0) allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return .{ .content = if (result.stdout.len > 0) result.stdout else "Research tool exited with error", .is_error = true };
    }

    if (result.stdout.len > 0) {
        const parsed = json.parseFromSlice(json.Value, allocator, result.stdout, .{}) catch null;
        if (parsed) |tree| {
            defer tree.deinit();
            if (tree.value == .object) {
                if (tree.value.object.get("success")) |success| {
                    if (success == .bool and !success.bool) {
                        return .{ .content = result.stdout, .is_error = true };
                    }
                }
            }
        }
    }

    return .{ .content = if (result.stdout.len > 0) result.stdout else "(no results)", .is_error = false };
}
