const std = @import("std");
const json = std.json;
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "amazon_search",
    .description = "Search Amazon for products. Supports parallel multi-query: pass 'queries' array to search multiple terms at once using parallel browser contexts." ++
        " Returns per product: title, price, rating, review_count, unit_size_oz, pack_count, total_oz, price_per_oz (pre-computed), url, value_rank, sponsored." ++
        " Results are sorted by best value (lowest price_per_oz first).",
    .input_schema_json =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Single search term or ASIN"},"queries":{"type":"array","items":{"type":"string"},"description":"Multiple search terms/ASINs to search in parallel (e.g. ['rice', 'chicken breast', 'peanut butter'])"},"max_results":{"type":"integer","description":"Max results per query (default 10)"}}}
    ,
    .requires_confirmation = false,
    .handler = &execute,
};

const SEARCH_SCRIPT = "/home/garward/Scripts/Tools/ClawForge/tools/amazon_search.py";
const PYTHON = "/home/garward/Scripts/Tools/.venv/bin/python3";

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    if (input != .object) {
        return .{ .content = "Expected JSON object with 'query' or 'queries'", .is_error = true };
    }

    // Build argv dynamically
    var argv_list: std.ArrayList([]const u8) = .{};
    argv_list.append(allocator, PYTHON) catch return .{ .content = "Alloc error", .is_error = true };
    argv_list.append(allocator, SEARCH_SCRIPT) catch return .{ .content = "Alloc error", .is_error = true };

    // Support both "query" (single) and "queries" (parallel array)
    if (input.object.get("queries")) |queries| {
        if (queries == .array) {
            for (queries.array.items) |q| {
                if (q == .string) {
                    argv_list.append(allocator, q.string) catch continue;
                }
            }
        }
    } else if (input.object.get("query")) |q| {
        if (q == .string) {
            argv_list.append(allocator, q.string) catch {};
        }
    }

    // Must have at least one query
    if (argv_list.items.len <= 2) {
        return .{ .content = "Missing 'query' or 'queries' parameter.", .is_error = true };
    }

    // Optional max_results
    if (input.object.get("max_results")) |mr| {
        if (mr == .integer) {
            argv_list.append(allocator, "--max-results") catch {};
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{mr.integer}) catch "10";
            argv_list.append(allocator, allocator.dupe(u8, s) catch "10") catch {};
        }
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv_list.items,
        .max_output_bytes = 1024 * 1024, // 1MB for multi-query
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Failed to run Amazon search: {s}", .{@errorName(err)}) catch
            return .{ .content = "Failed to run Amazon search script", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        defer allocator.free(result.stdout);
        const msg = if (result.stderr.len > 0)
            std.fmt.allocPrint(allocator, "Amazon search failed:\n{s}", .{result.stderr}) catch
                return .{ .content = "Amazon search script error", .is_error = true }
        else
            std.fmt.allocPrint(allocator, "Amazon search exited with code {d}", .{result.term.Exited}) catch
                return .{ .content = "Amazon search script error", .is_error = true };
        return .{ .content = msg, .is_error = true };
    }

    return .{ .content = result.stdout, .is_error = false };
}
