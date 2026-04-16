const std = @import("std");
const json = std.json;

/// Append `data` to `out` as a JSON-escaped string body (without the
/// surrounding quotes). Walks input as UTF-8: any invalid lead byte,
/// truncated sequence, overlong encoding, or surrogate codepoint
/// (U+D800–U+DFFF) is replaced with U+FFFD. ASCII control chars get
/// `\u00XX` escapes per the JSON spec. This is the chokepoint for
/// everything going to the Anthropic API, so a single poisoned byte
/// in session history can't kill subsequent turns.
pub fn appendJsonEscaped(out: *std.ArrayList(u8), a: std.mem.Allocator, data: []const u8) void {
    const REPLACEMENT = "\xEF\xBF\xBD";
    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];
        if (b < 0x80) {
            switch (b) {
                '"' => { out.append(a, '\\') catch {}; out.append(a, '"') catch {}; },
                '\\' => { out.append(a, '\\') catch {}; out.append(a, '\\') catch {}; },
                '\n' => { out.append(a, '\\') catch {}; out.append(a, 'n') catch {}; },
                '\r' => { out.append(a, '\\') catch {}; out.append(a, 'r') catch {}; },
                '\t' => { out.append(a, '\\') catch {}; out.append(a, 't') catch {}; },
                else => {
                    if (b < 0x20) {
                        var buf: [8]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{b}) catch {
                            i += 1;
                            continue;
                        };
                        out.appendSlice(a, s) catch {};
                    } else {
                        out.append(a, b) catch {};
                    }
                },
            }
            i += 1;
            continue;
        }
        const seq_len: usize = if (b & 0b11100000 == 0b11000000) 2
            else if (b & 0b11110000 == 0b11100000) 3
            else if (b & 0b11111000 == 0b11110000) 4
            else 0;
        if (seq_len == 0 or i + seq_len > data.len) {
            out.appendSlice(a, REPLACEMENT) catch {};
            i += 1;
            continue;
        }
        var cont_ok = true;
        var j: usize = 1;
        while (j < seq_len) : (j += 1) {
            if (data[i + j] & 0b11000000 != 0b10000000) {
                cont_ok = false;
                break;
            }
        }
        if (!cont_ok) {
            out.appendSlice(a, REPLACEMENT) catch {};
            i += 1;
            continue;
        }
        const cp: u32 = switch (seq_len) {
            2 => (@as(u32, b & 0x1F) << 6) |
                 @as(u32, data[i + 1] & 0x3F),
            3 => (@as(u32, b & 0x0F) << 12) |
                 (@as(u32, data[i + 1] & 0x3F) << 6) |
                 @as(u32, data[i + 2] & 0x3F),
            4 => (@as(u32, b & 0x07) << 18) |
                 (@as(u32, data[i + 1] & 0x3F) << 12) |
                 (@as(u32, data[i + 2] & 0x3F) << 6) |
                 @as(u32, data[i + 3] & 0x3F),
            else => unreachable,
        };
        const min_cp: u32 = switch (seq_len) {
            2 => 0x80,
            3 => 0x800,
            4 => 0x10000,
            else => 0,
        };
        const is_surrogate = cp >= 0xD800 and cp <= 0xDFFF;
        const is_oob = cp > 0x10FFFF;
        if (cp < min_cp or is_surrogate or is_oob) {
            out.appendSlice(a, REPLACEMENT) catch {};
            i += 1;
            continue;
        }
        out.appendSlice(a, data[i .. i + seq_len]) catch {};
        i += seq_len;
    }
}

pub const Role = enum {
    user,
    assistant,
};

pub const ContentBlock = union(enum) {
    text: TextBlock,
    image: ImageBlock,
    tool_use: ToolUseBlock,
    tool_result: ToolResultBlock,

    pub const TextBlock = struct {
        text: []const u8,
    };

    pub const ImageBlock = struct {
        /// e.g. "image/png", "image/jpeg"
        media_type: []const u8,
        /// Base64-encoded image data (no prefix). Borrowed slice; caller owns.
        data: []const u8,
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
                appendJsonEscaped(o, a, data);
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
                    .image => |img| {
                        w.append(&out, allocator, "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"");
                        w.appendEscaped(&out, allocator, img.media_type);
                        w.append(&out, allocator, "\",\"data\":\"");
                        // base64 alphabet is JSON-safe — no escaping needed
                        w.append(&out, allocator, img.data);
                        w.append(&out, allocator, "\"}}");
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
        /// Tokens read from cache (OpenRouter/Anthropic prompt caching)
        cache_read_tokens: u32 = 0,
        /// Tokens written to cache on this request
        cache_creation_tokens: u32 = 0,
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
