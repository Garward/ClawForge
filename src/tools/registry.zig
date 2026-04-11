const std = @import("std");
const json = std.json;
const api_messages = @import("api").messages;
const bash = @import("bash.zig");
const file_read = @import("file_read.zig");
const file_write = @import("file_write.zig");
const file_diff = @import("file_diff.zig");
const zig_test = @import("zig_test.zig");
const amazon_search = @import("amazon_search.zig");
const calc = @import("calc.zig");
const introspect = @import("introspect.zig");
const meme_tool = @import("meme_tool.zig");
const rebuild = @import("rebuild.zig");
const research_tool = @import("research_tool.zig");

pub const ToolResult = struct {
    content: []const u8,
    /// Optional compact form that is safe to send back to the LLM in follow-up tool rounds.
    /// This keeps human-visible output rich without forcing the model to re-read huge blobs.
    model_content: ?[]const u8 = null,
    is_error: bool = false,

    pub fn modelContent(self: ToolResult) []const u8 {
        return self.model_content orelse self.content;
    }
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8, // Raw JSON string for the input schema
    requires_confirmation: bool,
    handler: ?*const fn (std.mem.Allocator, json.Value) ToolResult = null,
    // For generated/dynamic tools — script-based execution (no compile needed)
    script_path: ?[]const u8 = null,
    script_lang: ?[]const u8 = null, // "python" or "bash"
};

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(ToolDefinition),
    enabled: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(ToolDefinition).init(allocator),
            .enabled = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit();
        self.enabled.deinit();
    }

    pub fn registerDefaults(self: *ToolRegistry) !void {
        try self.register(bash.definition);
        try self.register(file_read.definition);
        try self.register(file_write.definition);
        try self.register(amazon_search.definition);
        try self.register(file_diff.definition);
        try self.register(zig_test.definition);
        try self.register(calc.definition);
        try self.register(introspect.definition);
        try self.register(meme_tool.definition);
        try self.register(rebuild.definition);
        try self.register(research_tool.definition);
    }

    pub fn register(self: *ToolRegistry, tool: ToolDefinition) !void {
        try self.tools.put(tool.name, tool);
    }

    pub fn enable(self: *ToolRegistry, name: []const u8) !void {
        if (self.tools.contains(name)) {
            try self.enabled.put(name, {});
        }
    }

    pub fn disable(self: *ToolRegistry, name: []const u8) void {
        _ = self.enabled.remove(name);
    }

    pub fn isEnabled(self: *ToolRegistry, name: []const u8) bool {
        return self.enabled.contains(name);
    }

    pub fn execute(self: *ToolRegistry, name: []const u8, input: json.Value) ?ToolResult {
        const tool = self.tools.get(name) orelse return null;

        if (tool.handler) |handler| {
            // Native Zig tool
            return handler(self.allocator, input);
        } else if (tool.script_path) |script| {
            // Script-based tool
            if (tool.script_lang) |lang| {
                return self.executeScript(script, lang, input);
            }
            return .{ .content = "Script tool missing language specification", .is_error = true };
        }

        return .{ .content = "Tool has no execution handler", .is_error = true };
    }

    pub fn requiresConfirmation(self: *ToolRegistry, name: []const u8) bool {
        if (self.tools.get(name)) |tool| {
            return tool.requires_confirmation;
        }
        return true;
    }

    pub fn getToolDefinitions(self: *ToolRegistry) ?[]const api_messages.ToolDefinition {
        if (self.enabled.count() == 0) return null;
        const count = self.enabled.count();
        const result = self.allocator.alloc(api_messages.ToolDefinition, count) catch return null;
        var idx: usize = 0;
        var it = self.enabled.keyIterator();
        while (it.next()) |name| {
            if (self.tools.get(name.*)) |tool| {
                if (idx < count) {
                    result[idx] = .{
                        .name = tool.name,
                        .description = tool.description,
                        .input_schema_json = tool.input_schema_json,
                    };
                    idx += 1;
                }
            }
        }
        return result[0..idx];
    }

    /// Return only the enabled tool definitions named in `names`, preserving the requested order.
    /// Purpose: avoid paying schema tokens for tools that are irrelevant to the current turn.
    pub fn getToolDefinitionsFiltered(self: *ToolRegistry, names: []const []const u8) ?[]const api_messages.ToolDefinition {
        if (names.len == 0) return null;

        const result = self.allocator.alloc(api_messages.ToolDefinition, names.len) catch return null;
        var idx: usize = 0;

        for (names) |name| {
            if (!self.enabled.contains(name)) continue;
            if (self.tools.get(name)) |tool| {
                var duplicate = false;
                for (result[0..idx]) |existing| {
                    if (std.mem.eql(u8, existing.name, tool.name)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;

                result[idx] = .{
                    .name = tool.name,
                    .description = tool.description,
                    .input_schema_json = tool.input_schema_json,
                };
                idx += 1;
            }
        }

        if (idx == 0) return null;
        return result[0..idx];
    }

    /// Execute a script-based tool by passing JSON input as argv[1].
    fn executeScript(self: *ToolRegistry, script_path: []const u8, lang: []const u8, input: json.Value) ToolResult {
        var input_aw: std.Io.Writer.Allocating = .init(self.allocator);
        json.Stringify.value(input, .{}, &input_aw.writer) catch {
            return .{ .content = "Failed to serialize input", .is_error = true };
        };
        const input_str = input_aw.written();

        const interpreter = if (std.mem.eql(u8, lang, "bash"))
            "/bin/bash"
        else
            "/home/garward/Scripts/Tools/.venv/bin/python3";

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "/usr/bin/timeout", "30", interpreter, script_path, input_str },
            .max_output_bytes = 512 * 1024,
        }) catch |err| {
            const msg = std.fmt.allocPrint(self.allocator, "Script error: {s}", .{@errorName(err)}) catch
                return .{ .content = "Script execution failed", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };

        if (result.stderr.len > 0) self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            return .{ .content = if (result.stdout.len > 0) result.stdout else "Script exited with error", .is_error = true };
        }

        return .{ .content = if (result.stdout.len > 0) result.stdout else "(no output)", .is_error = false };
    }
};

/// Compact oversized tool output before it is fed back into the model.
/// Purpose: preserve the useful start/end context while preventing multi-round token blowups.
pub fn compactForModel(
    allocator: std.mem.Allocator,
    label: []const u8,
    content: []const u8,
    head_chars: usize,
    tail_chars: usize,
) []const u8 {
    if (content.len <= head_chars + tail_chars + 256) {
        return allocator.dupe(u8, content) catch content;
    }

    const head_len = @min(head_chars, content.len);
    const tail_len = @min(tail_chars, content.len - head_len);
    const omitted = content.len - head_len - tail_len;

    return std.fmt.allocPrint(
        allocator,
        "[{s} trimmed for model context: {d} chars omitted]\n\n--- BEGIN ---\n{s}\n\n--- END ---\n{s}",
        .{ label, omitted, content[0..head_len], content[content.len - tail_len ..] },
    ) catch content;
}
