const std = @import("std");
const json = std.json;
const common = @import("common");
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "calc",
    .description = "Safe math calculator. Evaluates expressions, converts units, sorts lists, and does batch computations. Use this for ANY arithmetic instead of computing it yourself." ++
        " Modes: (1) {\"expression\": \"22.86 / 150\"} single calc, (2) {\"expressions\": [\"a/b\", \"c/d\"]} batch," ++
        " (3) {\"convert\": 2.5, \"from\": \"lb\", \"to\": \"oz\"} unit conversion," ++
        " (4) {\"sort\": [{\"name\":\"A\",\"val\":3},{\"name\":\"B\",\"val\":1}], \"by\":\"val\"} sorting." ++
        " Supports: +, -, *, /, **, %, round, sqrt, min, max, abs, ceil, floor, log, pi, e." ++
        " Weight units: g, kg, oz, lb, mg. Volume: ml, l, fl_oz, cup, tbsp, tsp, gal. Temp: c, f, k.",
    .input_schema_json =
        \\{"type":"object","properties":{"expression":{"type":"string","description":"A math expression to evaluate, e.g. '22.86 / 150' or 'round(3.14, 1)'"},"expressions":{"type":"array","items":{"type":"string"},"description":"Batch: list of expressions to evaluate at once"},"convert":{"type":"number","description":"Value to convert between units"},"from":{"type":"string","description":"Source unit for conversion"},"to":{"type":"string","description":"Target unit for conversion"},"sort":{"type":"array","description":"List of objects to sort"},"by":{"type":"string","description":"Key to sort by"},"order":{"type":"string","description":"Sort order: 'asc' or 'desc'"},"label":{"type":"string","description":"Optional label for the result"}}}
    ,
    .requires_confirmation = false,
    .handler = &execute,
};

fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    // Serialize the input JSON back to a string to pass to the Python script
    var input_aw: std.Io.Writer.Allocating = .init(allocator);
    json.Stringify.value(input, .{}, &input_aw.writer) catch {
        return .{ .content = "Failed to serialize input", .is_error = true };
    };
    const input_str = input_aw.written();

    if (input_str.len == 0) {
        return .{ .content = "Empty input", .is_error = true };
    }

    const python = common.config.getPython(allocator) catch
        return .{ .content = "Failed to resolve python", .is_error = true };
    defer allocator.free(python);
    const script = common.config.getToolScript(allocator, "calc.py") catch
        return .{ .content = "Failed to resolve calc script", .is_error = true };
    defer allocator.free(script);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ python, script, input_str },
        .max_output_bytes = 64 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Failed to run calc: {s}", .{@errorName(err)}) catch
            return .{ .content = "Failed to run calc", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        defer allocator.free(result.stdout);
        const msg = if (result.stderr.len > 0)
            std.fmt.allocPrint(allocator, "Calc error:\n{s}", .{result.stderr}) catch
                return .{ .content = "Calc script error", .is_error = true }
        else
            std.fmt.allocPrint(allocator, "Calc exited with code {d}", .{result.term.Exited}) catch
                return .{ .content = "Calc script error", .is_error = true };
        return .{ .content = msg, .is_error = true };
    }

    return .{ .content = result.stdout, .is_error = false };
}
