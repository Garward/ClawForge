const std = @import("std");
const json = std.json;

pub const Role = enum {
    user,
    assistant,
};

pub const ContentBlock = union(enum) {
    text: TextBlock,
    tool_use: ToolUseBlock,
    tool_result: ToolResultBlock,

    pub const TextBlock = struct {
        text: []const u8,
    };

    pub const ToolUseBlock = struct {
        id: []const u8,
        name: []const u8,
        input: json.Value,
    };

    pub const ToolResultBlock = struct {
        tool_use_id: []const u8,
        content: []const u8,
        is_error: bool = false,
    };
};

pub const Message = struct {
    role: Role,
    content: []const ContentBlock,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8, // Raw JSON string
};

pub const MessageRequest = struct {
    model: []const u8,
    max_tokens: u32,
    messages: []const Message,
    system: ?[]const u8 = null,
    tools: ?[]const ToolDefinition = null,
    stream: bool = true,

    // Claude Code identity prompt required for OAuth authentication
    const CLAUDE_CODE_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude.";

    /// Serialize request to JSON
    /// is_oauth: If true, use array-based system prompt with Claude Code identity prepended
    pub fn toJson(self: *const MessageRequest, allocator: std.mem.Allocator, is_oauth: bool) ![]u8 {
        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(allocator);

        // Pre-allocate reasonable capacity
        out.ensureTotalCapacity(allocator, 16 * 1024) catch {};

        const w = struct {
            fn append(o: *std.ArrayList(u8), a: std.mem.Allocator, data: []const u8) void {
                o.appendSlice(a, data) catch {};
            }
            fn appendEscaped(o: *std.ArrayList(u8), a: std.mem.Allocator, data: []const u8) void {
                for (data) |c| {
                    switch (c) {
                        '"' => { o.append(a, '\\') catch {}; o.append(a, '"') catch {}; },
                        '\\' => { o.append(a, '\\') catch {}; o.append(a, '\\') catch {}; },
                        '\n' => { o.append(a, '\\') catch {}; o.append(a, 'n') catch {}; },
                        '\r' => { o.append(a, '\\') catch {}; o.append(a, 'r') catch {}; },
                        '\t' => { o.append(a, '\\') catch {}; o.append(a, 't') catch {}; },
                        else => o.append(a, c) catch {},
                    }
                }
            }
            fn appendNum(o: *std.ArrayList(u8), a: std.mem.Allocator, n: anytype) void {
                var num_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch "0";
                o.appendSlice(a, s) catch {};
            }
        };

        w.append(&out, allocator, "{\"model\":\"");
        w.append(&out, allocator, self.model);
        w.append(&out, allocator, "\",\"max_tokens\":");
        w.appendNum(&out, allocator, self.max_tokens);
        w.append(&out, allocator, ",\"stream\":");
        w.append(&out, allocator, if (self.stream) "true" else "false");

        // System prompt
        if (is_oauth) {
            w.append(&out, allocator, ",\"system\":[{\"type\":\"text\",\"text\":\"");
            w.append(&out, allocator, CLAUDE_CODE_IDENTITY);
            w.append(&out, allocator, "\"}");
            if (self.system) |sys| {
                w.append(&out, allocator, ",{\"type\":\"text\",\"text\":\"");
                w.appendEscaped(&out, allocator, sys);
                w.append(&out, allocator, "\"}");
            }
            w.append(&out, allocator, "]");
        } else {
            if (self.system) |sys| {
                w.append(&out, allocator, ",\"system\":\"");
                w.appendEscaped(&out, allocator, sys);
                w.append(&out, allocator, "\"");
            }
        }

        // Messages
        w.append(&out, allocator, ",\"messages\":[");
        for (self.messages, 0..) |msg, msg_idx| {
            if (msg_idx > 0) w.append(&out, allocator, ",");
            w.append(&out, allocator, "{\"role\":\"");
            w.append(&out, allocator, @tagName(msg.role));
            w.append(&out, allocator, "\",\"content\":[");

            for (msg.content, 0..) |block, block_idx| {
                if (block_idx > 0) w.append(&out, allocator, ",");
                switch (block) {
                    .text => |t| {
                        w.append(&out, allocator, "{\"type\":\"text\",\"text\":\"");
                        w.appendEscaped(&out, allocator, t.text);
                        w.append(&out, allocator, "\"}");
                    },
                    .tool_use => |tu| {
                        w.append(&out, allocator, "{\"type\":\"tool_use\",\"id\":\"");
                        w.append(&out, allocator, tu.id);
                        w.append(&out, allocator, "\",\"name\":\"");
                        w.append(&out, allocator, tu.name);
                        w.append(&out, allocator, "\",\"input\":");
                        // Serialize the input JSON value
                        var input_aw: std.Io.Writer.Allocating = .init(allocator);
                        json.Stringify.value(tu.input, .{}, &input_aw.writer) catch {};
                        const input_json = input_aw.written();
                        w.append(&out, allocator, if (input_json.len > 0) input_json else "{}");
                        w.append(&out, allocator, "}");
                    },
                    .tool_result => |tr| {
                        w.append(&out, allocator, "{\"type\":\"tool_result\",\"tool_use_id\":\"");
                        w.append(&out, allocator, tr.tool_use_id);
                        w.append(&out, allocator, "\",\"content\":\"");
                        w.appendEscaped(&out, allocator, tr.content);
                        w.append(&out, allocator, "\"");
                        if (tr.is_error) {
                            w.append(&out, allocator, ",\"is_error\":true");
                        }
                        w.append(&out, allocator, "}");
                    },
                }
            }
            w.append(&out, allocator, "]}");
        }
        w.append(&out, allocator, "]");

        // Tools
        if (self.tools) |tool_list| {
            w.append(&out, allocator, ",\"tools\":[");
            for (tool_list, 0..) |tool, idx| {
                if (idx > 0) w.append(&out, allocator, ",");
                w.append(&out, allocator, "{\"name\":\"");
                w.append(&out, allocator, tool.name);
                w.append(&out, allocator, "\",\"description\":\"");
                w.appendEscaped(&out, allocator, tool.description);
                w.append(&out, allocator, "\",\"input_schema\":");
                w.append(&out, allocator, tool.input_schema_json);
                w.append(&out, allocator, "}");
            }
            w.append(&out, allocator, "]");
        }

        w.append(&out, allocator, "}");

        // Return owned slice
        return out.toOwnedSlice(allocator) catch out.items;
    }
};

pub const ToolUseInfo = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8, // Preview string for display
    input: std.json.Value, // Parsed input for execution
};

pub const MessageResponse = struct {
    id: []const u8,
    model: []const u8,
    role: []const u8,
    content: []ContentBlock,
    text_content: []const u8, // Extracted text from content blocks
    tool_use: []const ToolUseInfo, // Tool calls requested by the model
    stop_reason: ?[]const u8,
    usage: Usage,
    /// Arena that owns all string/value memory in this response.
    /// Caller must call deinit() when done with the response data.
    /// null for streaming responses (which manage their own memory).
    arena: ?*std.heap.ArenaAllocator = null,

    pub const Usage = struct {
        input_tokens: u32,
        output_tokens: u32,
    };

    pub fn hasToolUse(self: *const MessageResponse) bool {
        return self.tool_use.len > 0;
    }

    /// Free all memory associated with this response.
    pub fn deinit(self: *MessageResponse, parent_allocator: std.mem.Allocator) void {
        if (self.arena) |arena| {
            arena.deinit();
            parent_allocator.destroy(arena);
            self.arena = null;
        }
    }
};
