const std = @import("std");
const json = std.json;
const common = @import("common");
const api = @import("api");
const storage = @import("storage");
const sandbox_mod = @import("sandbox.zig");
const registry_mod = @import("registry.zig");

/// Tool generator. Creates, tests, and registers new tools from natural language.
///
/// Flow:
/// 1. User describes a capability → LLM generates a tool spec
/// 2. Spec includes: name, description, input schema, implementation (bash/python)
/// 3. Implementation tested in sandbox
/// 4. If test passes → stored in DB + registered in tool registry
/// 5. User can approve/revoke generated tools
///
/// Public API callable by engine, adapters, automation.
pub const ToolGenerator = struct {
    allocator: std.mem.Allocator,
    provider: api.Provider,
    sandbox: sandbox_mod.Sandbox,
    conn: *storage.Connection,
    namespace_id: i64,
    tool_registry: *registry_mod.ToolRegistry,
    /// Model for generation (needs to write code — use sonnet)
    model: []const u8 = "claude-sonnet-4-20250514",

    pub fn init(
        allocator: std.mem.Allocator,
        provider: api.Provider,
        conn: *storage.Connection,
        namespace_id: i64,
        tool_registry: *registry_mod.ToolRegistry,
        work_dir: []const u8,
    ) ToolGenerator {
        return .{
            .allocator = allocator,
            .provider = provider,
            .sandbox = sandbox_mod.Sandbox.init(allocator, work_dir),
            .conn = conn,
            .namespace_id = namespace_id,
            .tool_registry = tool_registry,
        };
    }

    // ================================================================
    // PUBLIC API
    // ================================================================

    /// Generate a tool from a natural language description.
    /// Returns the generated tool spec, or null if generation failed.
    pub fn generateTool(self: *ToolGenerator, description: []const u8) !?GeneratedTool {
        // Call LLM to generate tool spec
        const spec = try self.callGenerationModel(description);

        // Store in DB as pending
        const tool_id = try self.storeTool(spec);

        // Test in sandbox
        const test_result = try self.testTool(spec);

        if (test_result.succeeded()) {
            // Update status to tested
            try self.updateToolStatus(tool_id, "tested", test_result.stdout);
            std.log.info("Generated tool '{s}' passed testing", .{spec.name});
            return spec;
        } else {
            // Update status to failed
            const err_msg = if (test_result.stderr.len > 0) test_result.stderr else "Test failed with no output";
            try self.updateToolStatus(tool_id, "test_failed", err_msg);
            std.log.warn("Generated tool '{s}' failed testing: {s}", .{ spec.name, err_msg });
            return null;
        }
    }

    /// Approve a generated tool and register it in the tool registry.
    pub fn approveTool(self: *ToolGenerator, name: []const u8) !void {
        const tool = try self.loadTool(name) orelse return error.ToolNotFound;

        // Update status in DB
        var id_stmt = try self.conn.prepare(
            "SELECT id FROM generated_tools WHERE name = ? AND namespace_id = ?",
        );
        defer id_stmt.deinit();
        try id_stmt.bindText(1, name);
        try id_stmt.bindInt64(2, self.namespace_id);
        if (try id_stmt.step()) {
            const tool_id = id_stmt.columnInt64(0);
            try self.updateToolStatus(tool_id, "approved", null);
        }

        // Write script to tools/generated/ and register
        try self.registerGeneratedTool(tool);
        std.log.info("Tool '{s}' approved and registered", .{name});
    }

    /// Revoke a generated tool — removes from registry and marks as revoked.
    pub fn revokeTool(self: *ToolGenerator, name: []const u8) !void {
        self.tool_registry.disable(name);
        var stmt = try self.conn.prepare(
            "UPDATE generated_tools SET status = 'revoked', updated_at = ? WHERE name = ? AND namespace_id = ?",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, std.time.timestamp());
        try stmt.bindText(2, name);
        try stmt.bindInt64(3, self.namespace_id);
        try stmt.exec();
        std.log.info("Tool '{s}' revoked", .{name});
    }

    /// List all generated tools.
    pub fn listTools(self: *ToolGenerator) ![]const ToolSummary {
        var stmt = try self.conn.prepare(
            "SELECT name, description, language, status, created_at FROM generated_tools " ++
                "WHERE namespace_id = ? ORDER BY created_at DESC",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);

        var buf: [64]ToolSummary = undefined;
        var count: usize = 0;
        while (try stmt.step()) {
            if (count >= buf.len) break;
            buf[count] = .{
                .name = try self.allocator.dupe(u8, stmt.columnText(0) orelse ""),
                .description = try self.allocator.dupe(u8, stmt.columnText(1) orelse ""),
                .language = try self.allocator.dupe(u8, stmt.columnText(2) orelse "bash"),
                .status = try self.allocator.dupe(u8, stmt.columnText(3) orelse "pending"),
            };
            count += 1;
        }

        if (count == 0) return &.{};
        const result = try self.allocator.alloc(ToolSummary, count);
        @memcpy(result, buf[0..count]);
        return result;
    }

    /// Load generated tools from DB and register approved ones in the tool registry.
    /// Called on startup to restore previously approved tools.
    pub fn loadApprovedTools(self: *ToolGenerator) !usize {
        var stmt = try self.conn.prepare(
            "SELECT name, description, input_schema, implementation, language FROM generated_tools " ++
                "WHERE namespace_id = ? AND status = 'approved'",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);

        var loaded: usize = 0;
        while (try stmt.step()) {
            const tool = GeneratedTool{
                .name = try self.allocator.dupe(u8, stmt.columnText(0) orelse continue),
                .description = try self.allocator.dupe(u8, stmt.columnText(1) orelse ""),
                .input_schema = try self.allocator.dupe(u8, stmt.columnText(2) orelse "{}"),
                .implementation = try self.allocator.dupe(u8, stmt.columnText(3) orelse ""),
                .language = try self.allocator.dupe(u8, stmt.columnText(4) orelse "python"),
                .test_command = null,
            };

            self.registerGeneratedTool(tool) catch |err| {
                std.log.warn("Failed to load generated tool '{s}': {}", .{ tool.name, err });
                continue;
            };
            loaded += 1;
        }

        return loaded;
    }

    // ================================================================
    // INTERNAL
    // ================================================================

    /// Write a generated tool's script to disk and register it in the tool registry.
    fn registerGeneratedTool(self: *ToolGenerator, tool: GeneratedTool) !void {
        // Ensure tools/generated/ directory exists
        const gen_dir = try common.config.resolveProjectPath(self.allocator, "tools/generated");
        defer self.allocator.free(gen_dir);
        std.fs.makeDirAbsolute(gen_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Write script file
        const ext = if (std.mem.eql(u8, tool.language, "python")) ".py" else ".sh";
        const script_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ gen_dir, tool.name, ext });

        const file = try std.fs.createFileAbsolute(script_path, .{});
        defer file.close();
        try file.writeAll(tool.implementation);

        // Make executable
        if (std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "chmod", "+x", script_path },
            .max_output_bytes = 1024,
        })) |r| {
            self.allocator.free(r.stdout);
            self.allocator.free(r.stderr);
        } else |_| {}

        // Register in tool registry as a script-based tool
        try self.tool_registry.register(.{
            .name = tool.name,
            .description = tool.description,
            .input_schema_json = tool.input_schema,
            .requires_confirmation = true, // Generated tools always need confirmation
            .handler = null, // No compiled handler
            .script_path = script_path,
            .script_lang = tool.language,
        });
        try self.tool_registry.enable(tool.name);

        std.log.info("Registered generated tool: {s} ({s})", .{ tool.name, script_path });
    }

    fn callGenerationModel(self: *ToolGenerator, description: []const u8) !GeneratedTool {
        const system_prompt =
            \\Generate a command-line tool from this description. Return ONLY a JSON object:
            \\{
            \\  "name": "tool_name_snake_case",
            \\  "description": "what this tool does",
            \\  "input_schema": {"type":"object","properties":{"param1":{"type":"string","description":"..."}}},
            \\  "implementation": "#!/bin/bash\n...",
            \\  "language": "bash",
            \\  "test_command": "echo test input"
            \\}
            \\
            \\Rules:
            \\- name: snake_case, short, descriptive
            \\- implementation: complete, self-contained script
            \\- Input is passed as first argument (JSON string) or via stdin
            \\- Print result to stdout
            \\- Exit 0 on success, non-zero on error
            \\- language: "bash" or "python"
            \\- test_command: a command that exercises the tool with sample input
            \\- Keep it simple and focused on one task
        ;

        const content_block = try self.allocator.alloc(api.messages.ContentBlock, 1);
        content_block[0] = .{ .text = .{ .text = description } };
        const msgs = try self.allocator.alloc(api.messages.Message, 1);
        msgs[0] = .{ .role = .user, .content = content_block };

        const request = api.MessageRequest{
            .model = self.model,
            .max_tokens = 2048,
            .messages = msgs,
            .system = system_prompt,
            .tools = null,
            .stream = false,
        };

        const response = try self.provider.createMessage(&request);
        return try self.parseGenerationResponse(response.text_content);
    }

    fn parseGenerationResponse(self: *ToolGenerator, text: []const u8) !GeneratedTool {
        // Find JSON in response (may be wrapped in markdown code blocks)
        var json_start: usize = 0;
        var json_end: usize = text.len;

        if (std.mem.indexOf(u8, text, "{")) |start| {
            json_start = start;
            // Find matching closing brace
            var depth: i32 = 0;
            for (text[start..], start..) |c, i| {
                if (c == '{') depth += 1;
                if (c == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        json_end = i + 1;
                        break;
                    }
                }
            }
        }

        const json_text = text[json_start..json_end];
        const parsed = try json.parseFromSlice(json.Value, self.allocator, json_text, .{
            .allocate = .alloc_always,
        });

        const obj = parsed.value.object;

        return .{
            .name = try self.allocator.dupe(u8, if (obj.get("name")) |v| (if (v == .string) v.string else "unnamed_tool") else "unnamed_tool"),
            .description = try self.allocator.dupe(u8, if (obj.get("description")) |v| (if (v == .string) v.string else "") else ""),
            .input_schema = try self.allocator.dupe(u8, "{}"), // TODO: serialize schema
            .implementation = try self.allocator.dupe(u8, if (obj.get("implementation")) |v| (if (v == .string) v.string else "") else ""),
            .language = try self.allocator.dupe(u8, if (obj.get("language")) |v| (if (v == .string) v.string else "bash") else "bash"),
            .test_command = if (obj.get("test_command")) |v| (if (v == .string) try self.allocator.dupe(u8, v.string) else null) else null,
        };
    }

    fn testTool(self: *ToolGenerator, spec: GeneratedTool) !sandbox_mod.ExecutionResult {
        if (std.mem.eql(u8, spec.language, "python")) {
            return try self.sandbox.executePython(spec.implementation, spec.test_command);
        }
        return try self.sandbox.executeBash(spec.implementation, spec.test_command);
    }

    fn storeTool(self: *ToolGenerator, spec: GeneratedTool) !i64 {
        const now = std.time.timestamp();
        var stmt = try self.conn.prepare(
            "INSERT OR REPLACE INTO generated_tools " ++
                "(namespace_id, name, description, input_schema, implementation, language, status, created_at, updated_at) " ++
                "VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, self.namespace_id);
        try stmt.bindText(2, spec.name);
        try stmt.bindText(3, spec.description);
        try stmt.bindText(4, spec.input_schema);
        try stmt.bindText(5, spec.implementation);
        try stmt.bindText(6, spec.language);
        try stmt.bindInt64(7, now);
        try stmt.bindInt64(8, now);
        try stmt.exec();
        return self.conn.lastInsertRowId();
    }

    fn updateToolStatus(self: *ToolGenerator, id: i64, status: []const u8, test_output: ?[]const u8) !void {
        if (id > 0) {
            var stmt = try self.conn.prepare(
                "UPDATE generated_tools SET status = ?, test_output = ?, updated_at = ? WHERE id = ?",
            );
            defer stmt.deinit();
            try stmt.bindText(1, status);
            try stmt.bindOptionalText(2, test_output);
            try stmt.bindInt64(3, std.time.timestamp());
            try stmt.bindInt64(4, id);
            try stmt.exec();
        }
    }

    fn loadTool(self: *ToolGenerator, name: []const u8) !?GeneratedTool {
        var stmt = try self.conn.prepare(
            "SELECT name, description, input_schema, implementation, language FROM generated_tools " ++
                "WHERE name = ? AND namespace_id = ?",
        );
        defer stmt.deinit();
        try stmt.bindText(1, name);
        try stmt.bindInt64(2, self.namespace_id);

        if (try stmt.step()) {
            return .{
                .name = try self.allocator.dupe(u8, stmt.columnText(0) orelse ""),
                .description = try self.allocator.dupe(u8, stmt.columnText(1) orelse ""),
                .input_schema = try self.allocator.dupe(u8, stmt.columnText(2) orelse "{}"),
                .implementation = try self.allocator.dupe(u8, stmt.columnText(3) orelse ""),
                .language = try self.allocator.dupe(u8, stmt.columnText(4) orelse "bash"),
                .test_command = null,
            };
        }
        return null;
    }
};

pub const GeneratedTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    implementation: []const u8,
    language: []const u8,
    test_command: ?[]const u8,
};

pub const ToolSummary = struct {
    name: []const u8,
    description: []const u8,
    language: []const u8,
    status: []const u8,
};
