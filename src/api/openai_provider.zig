const std = @import("std");
const http = std.http;
const json = std.json;
const provider_mod = @import("provider.zig");
const messages = @import("messages.zig");

/// OpenAI-compatible provider. Targets any backend speaking
/// `POST /v1/chat/completions` — OpenAI, Azure OpenAI, Groq, Together,
/// and Ollama (via its OpenAI-compat `/v1` endpoints). The body builder
/// and response parser are file-scope `pub` so the Ollama provider can
/// reuse them without duplicating ~400 lines.
pub const OpenAIClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    default_model: []const u8,
    owns_api_key: bool,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, base_url: []const u8, default_model: []const u8) OpenAIClient {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .base_url = base_url,
            .default_model = default_model,
            .owns_api_key = false,
        };
    }

    pub fn deinit(self: *OpenAIClient) void {
        if (self.owns_api_key) {
            self.allocator.free(self.api_key);
        }
    }

    pub fn provider(self: *OpenAIClient) provider_mod.Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn createMessage(self: *OpenAIClient, request: *const messages.MessageRequest) !messages.MessageResponse {
        // Per-request arena holds everything the response touches.
        const arena_ptr = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena_ptr.deinit();
        const arena = arena_ptr.allocator();

        var client = http.Client{ .allocator = arena };

        const effective_model = if (request.model.len > 0) request.model else self.default_model;

        const body = try buildChatCompletionsBody(arena, request, effective_model, null);

        var url_buf: [512]u8 = undefined;
        const url = buildChatCompletionsUrl(&url_buf, self.base_url) catch return error.InvalidRequest;

        var auth_buf: [512]u8 = undefined;
        const has_key = self.api_key.len > 0;
        const auth_value = if (has_key)
            std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.api_key}) catch return error.InvalidRequest
        else
            "";

        var response_writer = std.Io.Writer.Allocating.init(arena);
        var redirect_buf: [8 * 1024]u8 = undefined;

        const headers_with_auth = [_]http.Header{
            .{ .name = "authorization", .value = auth_value },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "HTTP-Referer", .value = "http://localhost:8081" },
            .{ .name = "X-OpenRouter-Title", .value = "Clawforge" },
        };
        const headers_no_auth = [_]http.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .redirect_buffer = &redirect_buf,
            .response_writer = &response_writer.writer,
            .extra_headers = if (has_key) &headers_with_auth else &headers_no_auth,
            .payload = body,
        }) catch return error.NetworkError;

        const response_data = response_writer.written();
        if (result.status != .ok) {
            std.log.err(
                "OpenAI API {d} ({s}): {s}",
                .{ @intFromEnum(result.status), url, response_data[0..@min(response_data.len, 1000)] },
            );
            return error.ServerError;
        }
        std.log.info(
            "OpenAI API raw ({s}, {d}b): {s}",
            .{ url, response_data.len, response_data[0..@min(response_data.len, 600)] },
        );

        return parseChatCompletionsResponse(arena, arena_ptr, response_data, effective_model);
    }

    pub fn createMessageStreaming(
        self: *OpenAIClient,
        request: *const messages.MessageRequest,
        handler: provider_mod.StreamHandler,
    ) !messages.MessageResponse {
        const arena_ptr = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena_ptr.deinit();
        const arena = arena_ptr.allocator();

        var client = http.Client{ .allocator = arena };

        const effective_model = if (request.model.len > 0) request.model else self.default_model;

        const body = try buildChatCompletionsBodyEx(arena, request, effective_model, null, true);

        var url_buf: [512]u8 = undefined;
        const url = buildChatCompletionsUrl(&url_buf, self.base_url) catch return error.InvalidRequest;

        var auth_buf: [512]u8 = undefined;
        const has_key = self.api_key.len > 0;
        const auth_value = if (has_key)
            std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.api_key}) catch return error.InvalidRequest
        else
            "";

        const uri = try std.Uri.parse(url);

        const headers_with_auth = [_]http.Header{
            .{ .name = "authorization", .value = auth_value },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "HTTP-Referer", .value = "http://localhost:8081" },
            .{ .name = "X-OpenRouter-Title", .value = "Clawforge" },
        };
        const headers_no_auth = [_]http.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        var req = client.request(.POST, uri, .{
            .extra_headers = if (has_key) &headers_with_auth else &headers_no_auth,
            .redirect_behavior = .unhandled,
            .keep_alive = false,
        }) catch return error.NetworkError;

        // Disable compression for SSE
        req.accept_encoding = @splat(false);
        req.accept_encoding[@intFromEnum(http.ContentEncoding.identity)] = true;

        req.sendBodyComplete(@constCast(body)) catch return error.NetworkError;

        var redirect_buf: [1]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch return error.NetworkError;

        if (response.head.status != .ok) {
            var err_buf: [1024]u8 = undefined;
            const err_reader = response.reader(&err_buf);
            if (err_reader.peekDelimiterInclusive(0)) |err_data| {
                std.log.err("OpenAI stream API {d} ({s}): {s}", .{
                    @intFromEnum(response.head.status),
                    url,
                    err_data[0..@min(err_data.len, 500)],
                });
            } else |_| {}
            return error.ServerError;
        }

        // SSE reading
        var transfer_buf: [65536]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        var text_buf: std.ArrayList(u8) = .{};
        var tool_uses: std.ArrayList(messages.ToolUseInfo) = .{};

        // Tool call accumulation by index — OpenAI streams tool calls in
        // multiple chunks: first chunk has id+name, subsequent chunks
        // append to arguments.
        const MaxToolCalls = 32;
        var tc_ids: [MaxToolCalls]std.ArrayList(u8) = undefined;
        var tc_names: [MaxToolCalls]std.ArrayList(u8) = undefined;
        var tc_args: [MaxToolCalls]std.ArrayList(u8) = undefined;
        var tc_count: usize = 0;
        for (0..MaxToolCalls) |i| {
            tc_ids[i] = .{};
            tc_names[i] = .{};
            tc_args[i] = .{};
        }

        var stop_reason: ?[]const u8 = null;
        var input_tokens: u32 = 0;
        var output_tokens: u32 = 0;
        var cache_read_tokens: u32 = 0;
        var cache_creation_tokens: u32 = 0;
        var msg_id: []const u8 = "";
        var line_count: usize = 0;

        while (true) {
            const line_with_nl = reader.peekDelimiterInclusive('\n') catch |err| {
                std.log.info("OpenAI SSE ended after {d} lines: {}", .{ line_count, err });
                break;
            };
            line_count += 1;
            const line_len = line_with_nl.len;
            var line = line_with_nl;
            if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

            if (std.mem.startsWith(u8, line, "data: ")) {
                const data = line[6..];
                if (std.mem.eql(u8, data, "[DONE]")) {
                    reader.toss(line_len);
                    break;
                }

                // Parse the JSON chunk
                const parsed = json.parseFromSlice(json.Value, arena, data, .{
                    .allocate = .alloc_always,
                }) catch {
                    reader.toss(line_len);
                    continue;
                };

                if (parsed.value != .object) {
                    reader.toss(line_len);
                    continue;
                }
                const obj = parsed.value.object;

                // Capture message id
                if (msg_id.len == 0) {
                    if (obj.get("id")) |id_val| {
                        if (id_val == .string) msg_id = id_val.string;
                    }
                }

                // Usage (sent in the final chunk when stream_options.include_usage is true)
                if (obj.get("usage")) |usage| {
                    if (usage == .object) {
                        if (usage.object.get("prompt_tokens")) |c| {
                            if (c == .integer) input_tokens = @intCast(c.integer);
                        }
                        if (usage.object.get("completion_tokens")) |c| {
                            if (c == .integer) output_tokens = @intCast(c.integer);
                        }
                        if (usage.object.get("cache_read_input_tokens")) |c| {
                            if (c == .integer) cache_read_tokens = @intCast(c.integer);
                        }
                        if (usage.object.get("cache_creation_input_tokens")) |c| {
                            if (c == .integer) cache_creation_tokens = @intCast(c.integer);
                        }
                        if (usage.object.get("prompt_tokens_details")) |details| {
                            if (details == .object) {
                                if (details.object.get("cached_tokens")) |c| {
                                    if (c == .integer and cache_read_tokens == 0) cache_read_tokens = @intCast(c.integer);
                                }
                            }
                        }
                    }
                }

                // choices[0]
                if (obj.get("choices")) |choices| {
                    if (choices == .array and choices.array.items.len > 0) {
                        const choice = choices.array.items[0];
                        if (choice != .object) {
                            reader.toss(line_len);
                            continue;
                        }

                        // finish_reason
                        if (choice.object.get("finish_reason")) |fr| {
                            if (fr == .string) {
                                stop_reason = if (std.mem.eql(u8, fr.string, "tool_calls"))
                                    "tool_use"
                                else
                                    "end_turn";
                            }
                        }

                        // delta
                        if (choice.object.get("delta")) |delta| {
                            if (delta == .object) {
                                // Text content
                                if (delta.object.get("content")) |content| {
                                    if (content == .string and content.string.len > 0) {
                                        handler.emitText(content.string);
                                        text_buf.appendSlice(arena, content.string) catch {};
                                    }
                                }

                                // Tool calls (streamed by index)
                                if (delta.object.get("tool_calls")) |tc_arr| {
                                    if (tc_arr == .array) {
                                        for (tc_arr.array.items) |tc_item| {
                                            if (tc_item != .object) continue;
                                            const tc_obj = tc_item.object;

                                            // Get index
                                            const idx: usize = blk: {
                                                if (tc_obj.get("index")) |iv| {
                                                    if (iv == .integer and iv.integer >= 0) break :blk @intCast(iv.integer);
                                                }
                                                break :blk 0;
                                            };
                                            if (idx >= MaxToolCalls) continue;

                                            // Expand count
                                            if (idx >= tc_count) tc_count = idx + 1;

                                            // id (first chunk only)
                                            if (tc_obj.get("id")) |id_val| {
                                                if (id_val == .string) {
                                                    tc_ids[idx].appendSlice(arena, id_val.string) catch {};
                                                }
                                            }

                                            // function.name and function.arguments
                                            if (tc_obj.get("function")) |fn_val| {
                                                if (fn_val == .object) {
                                                    if (fn_val.object.get("name")) |nv| {
                                                        if (nv == .string) {
                                                            tc_names[idx].appendSlice(arena, nv.string) catch {};
                                                        }
                                                    }
                                                    if (fn_val.object.get("arguments")) |av| {
                                                        if (av == .string) {
                                                            tc_args[idx].appendSlice(arena, av.string) catch {};
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            reader.toss(line_len);
        }

        // Finalize accumulated tool calls
        for (0..tc_count) |i| {
            const id_str = if (tc_ids[i].items.len > 0)
                (arena.dupe(u8, tc_ids[i].items) catch "")
            else
                "";
            const name_str = if (tc_names[i].items.len > 0)
                (arena.dupe(u8, tc_names[i].items) catch "")
            else
                "";
            const args_str = if (tc_args[i].items.len > 0)
                (arena.dupe(u8, tc_args[i].items) catch "{}")
            else
                "{}";

            const parsed_args = json.parseFromSliceLeaky(
                json.Value, arena, args_str, .{ .allocate = .alloc_always },
            ) catch json.Value{ .object = json.ObjectMap.init(arena) };

            tool_uses.append(arena, .{
                .id = id_str,
                .name = name_str,
                .input_json = args_str,
                .input = parsed_args,
            }) catch {};
        }

        if (tool_uses.items.len > 0 and stop_reason == null) {
            stop_reason = "tool_use";
        }

        std.log.info("OpenAI SSE complete: {d} lines, text={d}b, tools={d}, stop={s}", .{
            line_count,
            text_buf.items.len,
            tool_uses.items.len,
            stop_reason orelse "null",
        });

        if (cache_read_tokens > 0 or cache_creation_tokens > 0) {
            std.log.info("Cache stats: read={d} creation={d}", .{ cache_read_tokens, cache_creation_tokens });
        }

        return .{
            .id = msg_id,
            .model = effective_model,
            .role = "assistant",
            .content = &.{},
            .text_content = text_buf.items,
            .tool_use = tool_uses.items,
            .stop_reason = stop_reason,
            .usage = .{
                .input_tokens = input_tokens,
                .output_tokens = output_tokens,
                .cache_read_tokens = cache_read_tokens,
                .cache_creation_tokens = cache_creation_tokens,
            },
            .arena = arena_ptr,
        };
    }
};

fn buildChatCompletionsUrl(buf: []u8, base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/v1")) {
        return std.fmt.bufPrint(buf, "{s}/chat/completions", .{trimmed});
    }
    return std.fmt.bufPrint(buf, "{s}/v1/chat/completions", .{trimmed});
}

/// Strip ClawForge's `<tool_calls>...</tool_calls>` XML log from a text
/// block. The engine embeds per-round tool calls into the stored
/// assistant-message text using an XML wrapper so Anthropic models can
/// read them natively on replay. On OpenAI-compat providers (Ollama,
/// OpenAI, etc.) this XML-in-text is actively harmful: Qwen's chat
/// template sees prior "assistant used tools by writing JSON in text"
/// history and the model then mimics that pattern on round 2+, emitting
/// tool calls as JSON prose instead of as proper `tool_calls` fields.
/// Stripping the wrapper keeps the assistant's final narrative text
/// (so the model still knows the conclusion of the prior turn) while
/// removing the misleading training signal.
///
/// Allocates on `arena` only if a wrapper is found; otherwise returns
/// the input slice unchanged.
fn stripToolCallsXml(arena: std.mem.Allocator, text: []const u8) []const u8 {
    const open_tag = "<tool_calls>";
    const close_tag = "</tool_calls>";
    const start = std.mem.indexOf(u8, text, open_tag) orelse return text;
    const after_start = start + open_tag.len;
    const close_rel = std.mem.indexOf(u8, text[after_start..], close_tag) orelse return text;
    const close_end = after_start + close_rel + close_tag.len;

    // Produce: text[0..start] ++ text[close_end..], trimming extra
    // whitespace around the join point so we don't leave a dangling
    // double-newline where the XML used to be.
    var tail = text[close_end..];
    while (tail.len > 0 and (tail[0] == '\n' or tail[0] == '\r' or tail[0] == ' ' or tail[0] == '\t')) {
        tail = tail[1..];
    }
    var head = text[0..start];
    while (head.len > 0 and (head[head.len - 1] == '\n' or head[head.len - 1] == '\r' or head[head.len - 1] == ' ' or head[head.len - 1] == '\t')) {
        head = head[0 .. head.len - 1];
    }

    const new_len = head.len + tail.len + (if (head.len > 0 and tail.len > 0) @as(usize, 2) else 0);
    const out = arena.alloc(u8, new_len) catch return text;
    @memcpy(out[0..head.len], head);
    var pos = head.len;
    if (head.len > 0 and tail.len > 0) {
        out[pos] = '\n';
        out[pos + 1] = '\n';
        pos += 2;
    }
    @memcpy(out[pos..], tail);
    return out;
}

/// Serialize a MessageRequest into an OpenAI `/v1/chat/completions` body.
/// Handles: system, message history (text + image + tool_use + tool_result),
/// tools array. All user content goes through `messages.appendJsonEscaped`
/// for UTF-8 safety. Caller owns the returned slice (arena-allocated).
///
/// `extra_fields` is an optional pre-built JSON fragment injected at the
/// top level (e.g. `,"options":{"num_ctx":16384}` for Ollama). Caller owns
/// the leading comma and is responsible for valid JSON. OpenAI's endpoint
/// ignores unknown fields, so this is safe for strict OpenAI too.
pub fn buildChatCompletionsBody(
    arena: std.mem.Allocator,
    request: *const messages.MessageRequest,
    model: []const u8,
    extra_fields: ?[]const u8,
) ![]u8 {
    return buildChatCompletionsBodyEx(arena, request, model, extra_fields, false);
}

pub fn buildChatCompletionsBodyEx(
    arena: std.mem.Allocator,
    request: *const messages.MessageRequest,
    model: []const u8,
    extra_fields: ?[]const u8,
    stream: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    try out.ensureTotalCapacity(arena, 16 * 1024);

    try out.appendSlice(arena, "{\"model\":\"");
    messages.appendJsonEscaped(&out, arena, model);
    try out.appendSlice(arena, "\",\"max_tokens\":");
    var num_buf: [32]u8 = undefined;
    const max_str = std.fmt.bufPrint(&num_buf, "{d}", .{request.max_tokens}) catch "4096";
    try out.appendSlice(arena, max_str);
    try out.appendSlice(arena, if (stream) ",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[" else ",\"stream\":false,\"messages\":[");

    var first_msg = true;

    // System prompt as a leading `role=system` message.
    if (request.system) |sys| {
        try out.appendSlice(arena, "{\"role\":\"system\",\"content\":\"");
        messages.appendJsonEscaped(&out, arena, sys);
        try out.appendSlice(arena, "\"}");
        first_msg = false;
    }

    // Conversation history. Each Message becomes one entry, but tool_use
    // blocks split off into a synthetic `role=assistant` message with
    // `tool_calls`, and tool_result blocks become one `role=tool` entry
    // each. Mixed text + image content goes in the array-form `content`.
    for (request.messages) |msg| {
        // Split blocks into categories.
        var text_blocks: std.ArrayList(messages.ContentBlock.TextBlock) = .{};
        var image_blocks: std.ArrayList(messages.ContentBlock.ImageBlock) = .{};
        var tool_use_blocks: std.ArrayList(messages.ContentBlock.ToolUseBlock) = .{};
        var tool_result_blocks: std.ArrayList(messages.ContentBlock.ToolResultBlock) = .{};

        for (msg.content) |block| {
            switch (block) {
                .text => |t| try text_blocks.append(arena, t),
                .image => |img| try image_blocks.append(arena, img),
                .tool_use => |tu| try tool_use_blocks.append(arena, tu),
                .tool_result => |tr| try tool_result_blocks.append(arena, tr),
            }
        }

        // Emit tool_result blocks first — each as its own `role=tool` entry.
        for (tool_result_blocks.items) |tr| {
            if (!first_msg) try out.appendSlice(arena, ",");
            first_msg = false;
            try out.appendSlice(arena, "{\"role\":\"tool\",\"tool_call_id\":\"");
            messages.appendJsonEscaped(&out, arena, tr.tool_use_id);
            try out.appendSlice(arena, "\",\"content\":\"");
            messages.appendJsonEscaped(&out, arena, tr.content);
            try out.appendSlice(arena, "\"}");
        }

        // Text + image content AND tool_use blocks — complicated. Ollama's
        // built-in Qwen chat template has a hard constraint in its message
        // rendering logic:
        //   `{{ if .Content }}{{ .Content }}{{- else if .ToolCalls }}...`
        // meaning an assistant message with BOTH content and tool_calls
        // renders only the content and silently drops the tool_calls. So
        // merging them produces a history where the model sees its own
        // text ("Let me check...") followed by a tool_response appearing
        // out of nowhere — no record of the actual tool call. Round 2 then
        // improvises the tool-call format because it has no valid example
        // to copy, and emits JSON-in-text like `<{json}>` or `[{json}]`.
        //
        // The fix: when an assistant message has tool_use, emit ONLY the
        // tool_calls (with content: null) and drop the text preamble. The
        // preamble is narrative, not load-bearing; the tool call itself is
        // what the loop depends on. This matches Qwen's template's
        // "content-xor-tool_calls" assumption and renders cleanly as
        // `<tool_call>...</tool_call>` on replay.
        //
        // Assistant messages with text-only or image-only content still
        // emit normally.
        const has_text = text_blocks.items.len > 0;
        const has_image = image_blocks.items.len > 0;
        const has_tool_use = tool_use_blocks.items.len > 0;
        // When a role=assistant message has tool_use, we suppress text+image
        // in favor of clean tool_calls rendering. For user messages, this
        // doesn't apply — users can't call tools anyway.
        const suppress_text_for_tool_use = has_tool_use and msg.role == .assistant;
        const emit_text_or_image = (has_text or has_image) and !suppress_text_for_tool_use;

        if (emit_text_or_image or has_tool_use) {
            if (!first_msg) try out.appendSlice(arena, ",");
            first_msg = false;
            try out.appendSlice(arena, "{\"role\":\"");
            try out.appendSlice(arena, @tagName(msg.role));
            try out.appendSlice(arena, "\",\"content\":");

            if (!emit_text_or_image) {
                // Tool_use only (or text was suppressed to fit Qwen's
                // template constraint). OpenAI spec says content must be
                // null (or empty string) when tool_calls are present
                // with no text.
                try out.appendSlice(arena, "null");
            } else if (!has_image) {
                // Plain text, no images — use string-form content.
                // Assistant turns in history may contain a ClawForge
                // `<tool_calls>` XML wrapper from prior rounds; strip it
                // so OpenAI-compat models don't mimic the pattern.
                try out.appendSlice(arena, "\"");
                for (text_blocks.items, 0..) |t, i| {
                    if (i > 0) messages.appendJsonEscaped(&out, arena, "\n\n");
                    const cleaned = if (msg.role == .assistant)
                        stripToolCallsXml(arena, t.text)
                    else
                        t.text;
                    messages.appendJsonEscaped(&out, arena, cleaned);
                }
                try out.appendSlice(arena, "\"");
            } else {
                // Images force the array-form multimodal content.
                try out.appendSlice(arena, "[");
                var first_part = true;
                for (text_blocks.items) |t| {
                    if (!first_part) try out.appendSlice(arena, ",");
                    first_part = false;
                    try out.appendSlice(arena, "{\"type\":\"text\",\"text\":\"");
                    const cleaned = if (msg.role == .assistant)
                        stripToolCallsXml(arena, t.text)
                    else
                        t.text;
                    messages.appendJsonEscaped(&out, arena, cleaned);
                    try out.appendSlice(arena, "\"}");
                }
                for (image_blocks.items) |img| {
                    if (!first_part) try out.appendSlice(arena, ",");
                    first_part = false;
                    // OpenAI-compat image blocks use data URLs:
                    //   {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}
                    try out.appendSlice(arena, "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
                    messages.appendJsonEscaped(&out, arena, img.media_type);
                    try out.appendSlice(arena, ";base64,");
                    // base64 alphabet is JSON-safe
                    try out.appendSlice(arena, img.data);
                    try out.appendSlice(arena, "\"}}");
                }
                try out.appendSlice(arena, "]");
            }

            // Tool calls attached to the SAME assistant message.
            if (has_tool_use) {
                try out.appendSlice(arena, ",\"tool_calls\":[");
                for (tool_use_blocks.items, 0..) |tu, i| {
                    if (i > 0) try out.appendSlice(arena, ",");
                    try out.appendSlice(arena, "{\"id\":\"");
                    messages.appendJsonEscaped(&out, arena, tu.id);
                    try out.appendSlice(arena, "\",\"type\":\"function\",\"function\":{\"name\":\"");
                    messages.appendJsonEscaped(&out, arena, tu.name);
                    try out.appendSlice(arena, "\",\"arguments\":\"");
                    // `tu.input` is a parsed json.Value — re-serialize it then
                    // JSON-escape the result (arguments is a string containing JSON).
                    var args_aw: std.Io.Writer.Allocating = .init(arena);
                    json.Stringify.value(tu.input, .{}, &args_aw.writer) catch {};
                    const args_json = args_aw.written();
                    messages.appendJsonEscaped(&out, arena, if (args_json.len > 0) args_json else "{}");
                    try out.appendSlice(arena, "\"}}");
                }
                try out.appendSlice(arena, "]");
            }

            try out.appendSlice(arena, "}");
        }
    }

    try out.appendSlice(arena, "]");

    // Tools array (OpenAI function-calling format).
    if (request.tools) |tool_list| {
        if (tool_list.len > 0) {
            try out.appendSlice(arena, ",\"tools\":[");
            for (tool_list, 0..) |tool, i| {
                if (i > 0) try out.appendSlice(arena, ",");
                try out.appendSlice(arena, "{\"type\":\"function\",\"function\":{\"name\":\"");
                messages.appendJsonEscaped(&out, arena, tool.name);
                try out.appendSlice(arena, "\",\"description\":\"");
                messages.appendJsonEscaped(&out, arena, tool.description);
                try out.appendSlice(arena, "\",\"parameters\":");
                // input_schema_json is raw JSON — trust it, don't re-escape.
                try out.appendSlice(arena, tool.input_schema_json);
                try out.appendSlice(arena, "}}");
            }
            try out.appendSlice(arena, "]");
        }
    }

    if (extra_fields) |extras| {
        if (extras.len > 0) try out.appendSlice(arena, extras);
    }

    try out.appendSlice(arena, "}");
    return out.toOwnedSlice(arena) catch out.items;
}

/// Parse a `/v1/chat/completions` response into a MessageResponse.
/// Fills `text_content`, `tool_use` (parsed function calls), and `usage`.
/// The returned response takes ownership of `arena_ptr` — callers must
/// call `response.deinit(parent_allocator)` to free it.
pub fn parseChatCompletionsResponse(
    arena: std.mem.Allocator,
    arena_ptr: *std.heap.ArenaAllocator,
    data: []const u8,
    model: []const u8,
) !messages.MessageResponse {
    const parsed = json.parseFromSlice(json.Value, arena, data, .{
        .allocate = .alloc_always,
    }) catch return error.ParseError;

    if (parsed.value != .object) return error.ParseError;
    const obj = parsed.value.object;

    // id
    var id_out: []const u8 = "";
    if (obj.get("id")) |id| {
        if (id == .string) id_out = id.string;
    }

    // choices[0].message
    var text_out: []const u8 = "";
    var stop_reason: ?[]const u8 = null;
    var tool_use_list: std.ArrayList(messages.ToolUseInfo) = .{};

    if (obj.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const choice = choices.array.items[0];
            if (choice == .object) {
                if (choice.object.get("finish_reason")) |fr| {
                    if (fr == .string) {
                        // Map OpenAI finish_reason to something the engine
                        // understands. `tool_calls` means the model wants
                        // tool execution; anything else is a terminal stop.
                        stop_reason = if (std.mem.eql(u8, fr.string, "tool_calls"))
                            "tool_use"
                        else
                            "end_turn";
                    }
                }
                if (choice.object.get("message")) |msg_val| {
                    if (msg_val == .object) {
                        const m = msg_val.object;
                        if (m.get("content")) |c| {
                            if (c == .string) text_out = c.string;
                        }
                        if (m.get("tool_calls")) |tc| {
                            if (tc == .array) {
                                for (tc.array.items) |call| {
                                    if (call != .object) continue;
                                    const co = call.object;
                                    var call_id: []const u8 = "";
                                    var fn_name: []const u8 = "";
                                    var args_str: []const u8 = "{}";
                                    var args_val: json.Value = .{ .object = json.ObjectMap.init(arena) };
                                    if (co.get("id")) |idv| {
                                        if (idv == .string) call_id = idv.string;
                                    }
                                    if (co.get("function")) |fv| {
                                        if (fv == .object) {
                                            if (fv.object.get("name")) |nv| {
                                                if (nv == .string) fn_name = nv.string;
                                            }
                                            if (fv.object.get("arguments")) |av| {
                                                if (av == .string) {
                                                    args_str = av.string;
                                                    // OpenAI returns `arguments` as a JSON string; parse
                                                    // it so the engine can treat it as a json.Value.
                                                    const parsed_args = json.parseFromSliceLeaky(
                                                        json.Value,
                                                        arena,
                                                        av.string,
                                                        .{ .allocate = .alloc_always },
                                                    ) catch json.Value{ .object = json.ObjectMap.init(arena) };
                                                    args_val = parsed_args;
                                                }
                                            }
                                        }
                                    }
                                    try tool_use_list.append(arena, .{
                                        .id = call_id,
                                        .name = fn_name,
                                        .input_json = args_str,
                                        .input = args_val,
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // If we got tool_calls but no explicit finish_reason, force tool_use.
    if (tool_use_list.items.len > 0 and stop_reason == null) {
        stop_reason = "tool_use";
    }

    // Usage tokens
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;
    var cache_creation_tokens: u32 = 0;
    if (obj.get("usage")) |usage| {
        if (usage == .object) {
            if (usage.object.get("prompt_tokens")) |c| {
                if (c == .integer) input_tokens = @intCast(c.integer);
            }
            if (usage.object.get("completion_tokens")) |c| {
                if (c == .integer) output_tokens = @intCast(c.integer);
            }
            // OpenRouter / Anthropic cache stats
            if (usage.object.get("cache_read_input_tokens")) |c| {
                if (c == .integer) cache_read_tokens = @intCast(c.integer);
            }
            if (usage.object.get("cache_creation_input_tokens")) |c| {
                if (c == .integer) cache_creation_tokens = @intCast(c.integer);
            }
            // Some providers use prompt_tokens_details.cached_tokens
            if (usage.object.get("prompt_tokens_details")) |details| {
                if (details == .object) {
                    if (details.object.get("cached_tokens")) |c| {
                        if (c == .integer and cache_read_tokens == 0) cache_read_tokens = @intCast(c.integer);
                    }
                }
            }
        }
    }

    return .{
        .id = id_out,
        .model = model,
        .role = "assistant",
        .content = &.{},
        .text_content = text_out,
        .tool_use = try tool_use_list.toOwnedSlice(arena),
        .stop_reason = stop_reason,
        .usage = .{
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .cache_read_tokens = cache_read_tokens,
            .cache_creation_tokens = cache_creation_tokens,
        },
        .arena = arena_ptr,
    };
}

const vtable = provider_mod.Provider.VTable{
    .createMessage = struct {
        fn f(ptr: *anyopaque, request: *const messages.MessageRequest) anyerror!messages.MessageResponse {
            const self: *OpenAIClient = @ptrCast(@alignCast(ptr));
            return self.createMessage(request);
        }
    }.f,
    .createMessageStreaming = struct {
        fn f(ptr: *anyopaque, request: *const messages.MessageRequest, handler: provider_mod.StreamHandler) anyerror!messages.MessageResponse {
            const self: *OpenAIClient = @ptrCast(@alignCast(ptr));
            return self.createMessageStreaming(request, handler);
        }
    }.f,
    .setCredential = struct {
        fn f(ptr: *anyopaque, credential: []const u8) void {
            const self: *OpenAIClient = @ptrCast(@alignCast(ptr));
            self.api_key = credential;
        }
    }.f,
    .getName = struct {
        fn f(_: *anyopaque) []const u8 {
            return "openai";
        }
    }.f,
};
