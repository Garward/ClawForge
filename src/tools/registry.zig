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

/// plan — special tool. Execution is intercepted by the engine (it needs
/// session context for plan persistence) so this definition has no handler.
/// The agent MUST use this tool to create and maintain a plan before and
/// during any multi-step work. This is not optional.
pub const plan_def = ToolDefinition{
    .name = "plan",
    .description =
        "Plan tracker for multi-step work. SKIP THIS for simple questions — if you can answer " ++
        "with file_read, introspect, calc, research, or safe bash (ls, git log, etc.), just do " ++
        "it directly. REQUIRED before mutating tools (file_write, file_diff, summon_subagent, " ++
        "or destructive bash commands). " ++
        "Operations: 'create' (goal + steps — unblocks heavy tools), 'update' (mark steps " ++
        "done, add notes with findings), 'view' (show plan), 'clear' (remove when done). " ++
        "Do NOT hallucinate results — only mark done when genuinely complete. " ++
        "Subagents can view/update the plan too, so steps get marked done in real time.",
    .input_schema_json =
        \\{"type":"object","properties":{"operation":{"type":"string","enum":["create","update","view","clear"],"description":"Plan operation to perform."},"goal":{"type":"string","description":"High-level goal for the plan. Required for 'create'."},"steps":{"type":"array","items":{"type":"object","properties":{"id":{"type":"integer","description":"Step number (1-based)."},"description":{"type":"string","description":"What this step does."},"status":{"type":"string","enum":["pending","in_progress","done","skipped"],"description":"Step status."},"notes":{"type":"string","description":"Findings, discoveries, or warnings from execution. Subagents SHOULD populate this so subsequent steps inherit context (e.g. 'config is at /etc/foo not /opt/foo', 'API v2 changed the auth header format')."}},"required":["id","description","status"]},"description":"Steps for 'create', or step updates for 'update'. For 'update', only include steps that changed."}},"required":["operation"]}
    ,
    .requires_confirmation = false,
    .handler = null,
};

/// summon_subagent — special tool. Execution is intercepted by the engine
/// (it needs worker pool + session context) so this definition has no handler.
pub const summon_subagent_def = ToolDefinition{
    .name = "summon_subagent",
    .description =
        "Spawn a background subagent for HEAVY work that requires file_write, file_diff, builds, " ++
        "or destructive shell commands. Do NOT use this for simple questions — if you can answer " ++
        "with file_read, introspect, calc, research, or safe bash (ls, git log, etc.), just do " ++
        "it yourself. Subagents are for multi-step tasks that modify files or run complex builds. " ++
        "Returns a job ID; the user receives the result when it completes. " ++
        "Give the subagent a clear, specific task description including file paths and constraints. " ++
        "The subagent can see and update the shared plan, so it will mark its step done. " ++
        "WRONG: user asks 'what is in main.zig' → spawning a subagent to file_read. " ++
        "WRONG: user asks 'list the src dir' → spawning a subagent to ls. " ++
        "RIGHT: user asks 'what is in main.zig' → call file_read yourself and answer. " ++
        "RIGHT: user asks 'list the src dir' → call bash with 'ls src/' yourself and answer. " ++
        "RIGHT: user asks 'refactor the config module' → plan + subagent (heavy work).",
    .input_schema_json =
        \\{"type":"object","properties":{"task":{"type":"string","description":"Clear, specific task description for the subagent. Include file paths, the goal, and any constraints."},"model":{"type":"string","description":"Optional Anthropic model id for the subagent (e.g. 'claude-sonnet-4-6', 'claude-opus-4-6'). Defaults to the daemon's worker model."}},"required":["task"]}
    ,
    .requires_confirmation = false,
    .handler = null,
};

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
    /// Serializes mutations and reads across threads. Both the main engine
    /// and the background-chat engine share a single registry, and the user
    /// can toggle tool enablement while a subagent is mid-tool-loop.
    mutex: std.Thread.Mutex = .{},
    /// When true, requiresConfirmation() returns false for every tool so
    /// subagents can run mutating tools without prompting the user.
    /// Toggled at runtime via /api/tools/autoapprove and the /autoapprove
    /// Discord slash command.
    auto_approve: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
        try self.register(plan_def);
        try self.register(summon_subagent_def);
    }

    pub fn register(self: *ToolRegistry, tool: ToolDefinition) !void {
        try self.tools.put(tool.name, tool);
    }

    pub fn enable(self: *ToolRegistry, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tools.contains(name)) {
            try self.enabled.put(name, {});
        }
    }

    pub fn disable(self: *ToolRegistry, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.enabled.remove(name);
    }

    pub fn isEnabled(self: *ToolRegistry, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
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

    pub fn setAutoApprove(self: *ToolRegistry, enabled: bool) void {
        self.auto_approve.store(enabled, .release);
    }

    pub fn isAutoApprove(self: *ToolRegistry) bool {
        return self.auto_approve.load(.acquire);
    }

    pub fn requiresConfirmation(self: *ToolRegistry, name: []const u8) bool {
        if (self.auto_approve.load(.acquire)) return false;
        if (self.tools.get(name)) |tool| {
            return tool.requires_confirmation;
        }
        return true;
    }

    /// Max tools we ever fit into a single stack buffer. Callers who exceed
    /// this hit the warning and truncate — realistic tool sets are <20.
    const MAX_TOOL_DEFS = 64;

    /// Finalize a stack-built tool-def slice into an exact-size heap allocation.
    /// The caller's allocator.free(slice) must see the same size that was
    /// allocated, so we return a slice whose backing allocation is exactly
    /// `items.len` long — never a truncated view of an oversized buffer.
    fn duplicateToolDefs(
        self: *ToolRegistry,
        items: []const api_messages.ToolDefinition,
    ) ?[]const api_messages.ToolDefinition {
        if (items.len == 0) return null;
        const heap = self.allocator.alloc(api_messages.ToolDefinition, items.len) catch return null;
        @memcpy(heap, items);
        return heap;
    }

    pub fn getToolDefinitions(self: *ToolRegistry) ?[]const api_messages.ToolDefinition {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.enabled.count() == 0) return null;

        var buf: [MAX_TOOL_DEFS]api_messages.ToolDefinition = undefined;
        var idx: usize = 0;
        var it = self.enabled.keyIterator();
        while (it.next()) |name| {
            if (idx >= buf.len) break;
            if (self.tools.get(name.*)) |tool| {
                buf[idx] = .{
                    .name = tool.name,
                    .description = tool.description,
                    .input_schema_json = tool.input_schema_json,
                };
                idx += 1;
            }
        }
        return self.duplicateToolDefs(buf[0..idx]);
    }

    /// Like getToolDefinitions but drops any tool whose name matches `exclude`.
    /// Used for subagents, which must not see `summon_subagent` (no recursive spawning).
    pub fn getToolDefinitionsExcluding(self: *ToolRegistry, exclude: []const u8) ?[]const api_messages.ToolDefinition {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.enabled.count() == 0) return null;

        var buf: [MAX_TOOL_DEFS]api_messages.ToolDefinition = undefined;
        var idx: usize = 0;
        var it = self.enabled.keyIterator();
        while (it.next()) |name| {
            if (idx >= buf.len) break;
            if (std.mem.eql(u8, name.*, exclude)) continue;
            if (self.tools.get(name.*)) |tool| {
                buf[idx] = .{
                    .name = tool.name,
                    .description = tool.description,
                    .input_schema_json = tool.input_schema_json,
                };
                idx += 1;
            }
        }
        return self.duplicateToolDefs(buf[0..idx]);
    }

    /// Return only the enabled tool definitions named in `names`, preserving the requested order.
    /// Purpose: avoid paying schema tokens for tools that are irrelevant to the current turn.
    pub fn getToolDefinitionsFiltered(self: *ToolRegistry, names: []const []const u8) ?[]const api_messages.ToolDefinition {
        if (names.len == 0) return null;
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: [MAX_TOOL_DEFS]api_messages.ToolDefinition = undefined;
        var idx: usize = 0;

        for (names) |name| {
            if (idx >= buf.len) break;
            if (!self.enabled.contains(name)) continue;
            if (self.tools.get(name)) |tool| {
                var duplicate = false;
                for (buf[0..idx]) |existing| {
                    if (std.mem.eql(u8, existing.name, tool.name)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;

                buf[idx] = .{
                    .name = tool.name,
                    .description = tool.description,
                    .input_schema_json = tool.input_schema_json,
                };
                idx += 1;
            }
        }

        return self.duplicateToolDefs(buf[0..idx]);
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
