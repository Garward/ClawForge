const std = @import("std");
const json = std.json;
const common = @import("common");
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
///
/// Takes a STRUCTURED BRIEF, not a free-form task. The dispatcher is expected
/// to do enough recon (file_read, bash grep, introspect) to fill target_files,
/// known_facts, and acceptance before delegating. Subagents inherit none of
/// the dispatcher's conversation context, so whatever isn't in the brief is
/// invisible to them.
pub const summon_subagent_def = ToolDefinition{
    .name = "summon_subagent",
    .description =
        "Spawn a background subagent. Two modes:\n" ++
        "\n" ++
        "  mode='explore' — READ-ONLY research agent. Investigates a question and returns a " ++
        "structured 3-layer brief (executive map + structured facts + pinned evidence). Use " ++
        "this FIRST when you need to understand code you haven't read. Bypasses the plan gate. " ++
        "Required fields: task (the question). Optional: target_files (hint paths to focus on), " ++
        "context. The returned brief is designed to drop into a follow-up execute subagent's " ++
        "known_facts.\n" ++
        "\n" ++
        "  mode='execute' (default) — the worker that does real changes (multi-file edits, " ++
        "builds, destructive shell). Requires a full brief: task + target_files + acceptance. " ++
        "Do NOT use execute mode for single-file edits or simple reads — handle those yourself " ++
        "inline with file_read, file_diff, bash, introspect.\n" ++
        "\n" ++
        "Common pattern: dispatcher → explore subagent → read its 3-layer brief → execute " ++
        "subagent with the findings in known_facts + target_files.\n" ++
        "\n" ++
        "A subagent gets NONE of your conversation context — it only sees the brief. Empty or " ++
        "vague briefs are the #1 cause of failure. The subagent can view/update the shared plan. " ++
        "Returns a job ID; the user (for execute) or you (for explore) receives the result " ++
        "automatically when it completes.",
    .input_schema_json =
        \\{"type":"object","properties":{"mode":{"type":"string","enum":["execute","explore"],"description":"'execute' (default) = worker that makes changes. 'explore' = read-only research agent that returns a structured 3-layer brief."},"task":{"type":"string","description":"For execute: one-sentence goal (the end state). For explore: the question to investigate (e.g. 'How does the dispatcher wire summon_subagent results back to Discord?')."},"context":{"type":"string","description":"Why this matters / the user's actual words. The subagent does not see chat history."},"target_files":{"type":"array","items":{"type":"string"},"description":"For execute: files the subagent will read or modify (REQUIRED non-empty for execute unless pure-discovery). For explore: hint paths to focus recon on (optional)."},"known_facts":{"type":"array","items":{"type":"string"},"description":"Findings the subagent should NOT re-derive. Paste relevant lines from a prior explore subagent's brief here. e.g. 'handleSummonSubagent is at engine.zig:1868'."},"acceptance":{"type":"string","description":"For execute (REQUIRED): concrete testable stop condition. e.g. 'zig build succeeds AND new function visible in engine.zig'. Not used by explore."},"constraints":{"type":"array","items":{"type":"string"},"description":"Things the subagent must NOT do. e.g. 'do not modify discord_adapter.zig'."},"out_of_scope":{"type":"array","items":{"type":"string"},"description":"Related work to resist. Stops scope creep."},"model":{"type":"string","description":"Optional model id override. Inherits parent's model by default."},"wait":{"type":"boolean","description":"If true, block this tool call until the subagent completes and return its full result as the tool_result (useful for in-turn chaining). Default false."},"chain":{"type":"boolean","description":"Explore only. If true (default for explore), after the subagent returns the worker automatically runs a dispatcher continuation turn that ingests the brief and generates the user-facing reply (summary, or auto-summon of execute). The polling adapter sees the continuation's reply, not the raw JSON. Ignored when wait=true or mode=execute."}},"required":["task"]}
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

        const is_bash = std.mem.eql(u8, lang, "bash");
        const interpreter_owned: ?[]const u8 = if (is_bash) null else (common.config.getPython(self.allocator) catch null);
        defer if (interpreter_owned) |p| self.allocator.free(p);
        const interpreter: []const u8 = if (is_bash) "/bin/bash" else (interpreter_owned orelse "python3");

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
