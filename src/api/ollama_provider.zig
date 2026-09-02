const std = @import("std");
const http = std.http;
const json = std.json;
const provider_mod = @import("provider.zig");
const messages = @import("messages.zig");
const common = @import("common");

/// Ollama provider — local LLM inference via Ollama's native `/api/chat`
/// endpoint. This keeps ClawForge's internal provider interface stable
/// while using the endpoint that honors runtime `options.num_ctx`.
pub const OllamaClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    default_model: []const u8,
    /// VRAM ceiling: the maximum `options.num_ctx` this provider is
    /// allowed to use per request. Actual num_ctx scales DOWN from this
    /// to fit each specific request's estimated token count, rounded up
    /// to the nearest standard size so Ollama doesn't constantly reload
    /// the model with different KV cache sizes.
    num_ctx_max: u32,
    model_contexts: []const common.config.OllamaModelContext,

    /// Floor: smallest num_ctx we'll ever pick, even for tiny prompts.
    /// Keeps model-reload overhead predictable.
    const NUM_CTX_FLOOR: u32 = 8192;

    /// Rough char-to-token ratio for estimating prompt size. English
    /// averages ~4 chars/token; code is a bit denser; base64 image data
    /// is a LOT denser (we treat it as opaque below). 3.5 is a safer
    /// middle ground that over-estimates slightly, which is what we
    /// want — under-estimating would cause the same silent truncation
    /// we're trying to avoid.
    const CHARS_PER_TOKEN: f32 = 3.5;

    pub fn init(
        allocator: std.mem.Allocator,
        base_url: []const u8,
        default_model: []const u8,
        num_ctx_max: u32,
        model_contexts: []const common.config.OllamaModelContext,
    ) OllamaClient {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .default_model = default_model,
            .num_ctx_max = num_ctx_max,
            .model_contexts = model_contexts,
        };
    }

    fn modelContextCap(self: *const OllamaClient, model: []const u8) u32 {
        for (self.model_contexts) |entry| {
            if (std.mem.eql(u8, entry.model, model)) return entry.num_ctx;
            if (std.mem.startsWith(u8, entry.model, "ollama:") and
                std.mem.eql(u8, entry.model["ollama:".len..], model))
            {
                return entry.num_ctx;
            }
        }
        return self.num_ctx_max;
    }

    /// Estimate how much context the request needs and pick the smallest
    /// standard num_ctx size that fits, clamped to [FLOOR, num_ctx_max].
    /// Rounding to standard sizes prevents Ollama from rebuilding the KV
    /// cache on every request when prompt sizes fluctuate slightly.
    fn pickNumCtx(self: *const OllamaClient, request: *const messages.MessageRequest, model: []const u8) u32 {
        const ctx_cap = self.modelContextCap(model);

        // Estimate the total prompt character count.
        var char_count: usize = 0;
        if (request.system) |s| char_count += s.len;
        for (request.messages) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| char_count += t.text.len,
                    .image => |img| {
                        // Base64 is ~1 token per 3-4 chars on average but
                        // Ollama/Qwen tokenizes images differently; treat
                        // each image as a fixed ~300 tokens which is the
                        // rough practical cost of an image content block.
                        // Still add the raw b64 length too as a safety
                        // margin for models that tokenize the string.
                        char_count += img.data.len + 1200;
                    },
                    .tool_use => |tu| char_count += tu.name.len + tu.id.len + 256,
                    .tool_result => |tr| char_count += tr.content.len + tr.tool_use_id.len + 64,
                    // Reasoning blocks are codex-only; ollama drops them on the
                    // wire so they don't count toward num_ctx.
                    .reasoning => {},
                }
            }
        }
        if (request.tools) |tool_list| {
            for (tool_list) |tool| {
                char_count += tool.name.len + tool.description.len + tool.input_schema_json.len + 64;
            }
        }

        // chars → tokens, plus output headroom, plus a slack buffer.
        const input_tokens: u32 = @intFromFloat(@as(f32, @floatFromInt(char_count)) / CHARS_PER_TOKEN);
        const output_tokens: u32 = request.max_tokens;
        const slack: u32 = 1024;
        const needed: u32 = input_tokens + output_tokens + slack;

        // Round up to the next standard size. Standard sizes are powers
        // of 2 multiplied by 8192 (so KV cache allocations match Ollama's
        // default model-reload boundaries and we don't thrash).
        const standard_sizes = [_]u32{ 8192, 16384, 32768, 49152, 65536, 98304, 131072, 196608, 262144 };
        var chosen: u32 = NUM_CTX_FLOOR;
        for (standard_sizes) |size| {
            if (size >= needed) {
                chosen = size;
                break;
            }
        } else {
            // Request exceeds our largest standard size — cap at max.
            chosen = ctx_cap;
        }

        // Clamp to [FLOOR, ctx_cap].
        if (chosen < NUM_CTX_FLOOR) chosen = NUM_CTX_FLOOR;
        if (chosen > ctx_cap) chosen = ctx_cap;
        return chosen;
    }

    pub fn provider(self: *OllamaClient) provider_mod.Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn createMessage(self: *OllamaClient, request: *const messages.MessageRequest) !messages.MessageResponse {
        const arena_ptr = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena_ptr.deinit();
        const arena = arena_ptr.allocator();

        var client = http.Client{ .allocator = arena, .io = common.config.runtimeIo() };

        const effective_model = if (request.model.len > 0) request.model else self.default_model;

        // Dynamic num_ctx: scale per-request up to the configured VRAM
        // ceiling, so short prompts don't waste KV cache and long agent
        // loops don't silently truncate. See pickNumCtx for the math.
        const chosen_ctx = self.pickNumCtx(request, effective_model);
        const ctx_cap = self.modelContextCap(effective_model);
        std.log.info(
            "Ollama: model={s} num_ctx={d} (cap {d})",
            .{ effective_model, chosen_ctx, ctx_cap },
        );

        const body = try buildNativeChatBody(arena, request, effective_model, chosen_ctx);

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/api/chat", .{self.base_url}) catch return error.InvalidRequest;

        var response_writer = std.Io.Writer.Allocating.init(arena);
        var redirect_buf: [8 * 1024]u8 = undefined;

        const headers = [_]http.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .redirect_buffer = &redirect_buf,
            .response_writer = &response_writer.writer,
            .extra_headers = &headers,
            .payload = body,
        }) catch return error.NetworkError;

        const response_data = response_writer.written();
        if (result.status != .ok) {
            std.log.err(
                "Ollama API {d}: {s}",
                .{ @intFromEnum(result.status), response_data[0..@min(response_data.len, 1000)] },
            );
            return error.ServerError;
        }
        std.log.info(
            "Ollama API raw ({d}b): {s}",
            .{ response_data.len, response_data[0..@min(response_data.len, 600)] },
        );

        return parseNativeChatResponse(arena, arena_ptr, response_data, effective_model);
    }
};

fn stripToolCallsXml(arena: std.mem.Allocator, text: []const u8) []const u8 {
    const open_tag = "<tool_calls>";
    const close_tag = "</tool_calls>";
    const start = std.mem.indexOf(u8, text, open_tag) orelse return text;
    const after_start = start + open_tag.len;
    const close_rel = std.mem.indexOf(u8, text[after_start..], close_tag) orelse return text;
    const close_end = after_start + close_rel + close_tag.len;

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

fn appendRole(out: *std.ArrayList(u8), arena: std.mem.Allocator, role: messages.Role) !void {
    try out.appendSlice(arena, @tagName(role));
}

fn appendTextBlocks(
    out: *std.ArrayList(u8),
    arena: std.mem.Allocator,
    text_blocks: []const messages.ContentBlock.TextBlock,
    role: messages.Role,
) !void {
    for (text_blocks, 0..) |t, i| {
        if (i > 0) messages.appendJsonEscaped(out, arena, "\n\n");
        const cleaned = if (role == .assistant) stripToolCallsXml(arena, t.text) else t.text;
        messages.appendJsonEscaped(out, arena, cleaned);
    }
}

fn buildNativeChatBody(
    arena: std.mem.Allocator,
    request: *const messages.MessageRequest,
    model: []const u8,
    num_ctx: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, 16 * 1024);

    var tool_name_by_id = std.StringHashMap([]const u8).init(arena);

    try out.appendSlice(arena, "{\"model\":\"");
    messages.appendJsonEscaped(&out, arena, model);
    try out.appendSlice(arena, "\",\"stream\":false,\"options\":{\"num_ctx\":");
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(arena, std.fmt.bufPrint(&num_buf, "{d}", .{num_ctx}) catch "4096");
    try out.appendSlice(arena, ",\"num_predict\":");
    try out.appendSlice(arena, std.fmt.bufPrint(&num_buf, "{d}", .{request.max_tokens}) catch "4096");
    try out.appendSlice(arena, "},\"messages\":[");

    var first_msg = true;
    if (request.system) |sys| {
        try out.appendSlice(arena, "{\"role\":\"system\",\"content\":\"");
        messages.appendJsonEscaped(&out, arena, sys);
        try out.appendSlice(arena, "\"}");
        first_msg = false;
    }

    for (request.messages) |msg| {
        var text_blocks: std.ArrayList(messages.ContentBlock.TextBlock) = .empty;
        var image_blocks: std.ArrayList(messages.ContentBlock.ImageBlock) = .empty;
        var tool_use_blocks: std.ArrayList(messages.ContentBlock.ToolUseBlock) = .empty;
        var tool_result_blocks: std.ArrayList(messages.ContentBlock.ToolResultBlock) = .empty;

        for (msg.content) |block| {
            switch (block) {
                .text => |t| try text_blocks.append(arena, t),
                .image => |img| try image_blocks.append(arena, img),
                .tool_use => |tu| try tool_use_blocks.append(arena, tu),
                .tool_result => |tr| try tool_result_blocks.append(arena, tr),
                .reasoning => {},
            }
        }

        for (tool_result_blocks.items) |tr| {
            if (!first_msg) try out.appendSlice(arena, ",");
            first_msg = false;
            const tool_name = tool_name_by_id.get(tr.tool_use_id) orelse "tool";
            try out.appendSlice(arena, "{\"role\":\"tool\",\"tool_name\":\"");
            messages.appendJsonEscaped(&out, arena, tool_name);
            try out.appendSlice(arena, "\",\"content\":\"");
            messages.appendJsonEscaped(&out, arena, tr.content);
            try out.appendSlice(arena, "\"}");
        }

        const has_text = text_blocks.items.len > 0;
        const has_image = image_blocks.items.len > 0;
        const has_tool_use = tool_use_blocks.items.len > 0;
        const suppress_text_for_tool_use = has_tool_use and msg.role == .assistant;
        const emit_text_or_image = (has_text or has_image) and !suppress_text_for_tool_use;

        if (emit_text_or_image or has_tool_use) {
            if (!first_msg) try out.appendSlice(arena, ",");
            first_msg = false;
            try out.appendSlice(arena, "{\"role\":\"");
            try appendRole(&out, arena, msg.role);
            try out.appendSlice(arena, "\",\"content\":\"");
            if (emit_text_or_image and has_text) {
                try appendTextBlocks(&out, arena, text_blocks.items, msg.role);
            }
            try out.appendSlice(arena, "\"");

            if (has_image) {
                try out.appendSlice(arena, ",\"images\":[");
                for (image_blocks.items, 0..) |img, i| {
                    if (i > 0) try out.appendSlice(arena, ",");
                    try out.appendSlice(arena, "\"");
                    try out.appendSlice(arena, img.data);
                    try out.appendSlice(arena, "\"");
                }
                try out.appendSlice(arena, "]");
            }

            if (has_tool_use) {
                try out.appendSlice(arena, ",\"tool_calls\":[");
                for (tool_use_blocks.items, 0..) |tu, i| {
                    if (i > 0) try out.appendSlice(arena, ",");
                    try tool_name_by_id.put(tu.id, tu.name);
                    try out.appendSlice(arena, "{\"type\":\"function\",\"function\":{\"index\":");
                    try out.appendSlice(arena, std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch "0");
                    try out.appendSlice(arena, ",\"name\":\"");
                    messages.appendJsonEscaped(&out, arena, tu.name);
                    try out.appendSlice(arena, "\",\"arguments\":");
                    var args_aw: std.Io.Writer.Allocating = .init(arena);
                    json.Stringify.value(tu.input, .{}, &args_aw.writer) catch {};
                    const args_json = args_aw.written();
                    try out.appendSlice(arena, if (args_json.len > 0) args_json else "{}");
                    try out.appendSlice(arena, "}}");
                }
                try out.appendSlice(arena, "]");
            }

            try out.appendSlice(arena, "}");
        }
    }

    try out.appendSlice(arena, "]");

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
                try out.appendSlice(arena, tool.input_schema_json);
                try out.appendSlice(arena, "}}");
            }
            try out.appendSlice(arena, "]");
        }
    }

    try out.appendSlice(arena, "}");
    return out.toOwnedSlice(arena) catch out.items;
}

fn parseNativeChatResponse(
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

    var model_out = model;
    if (obj.get("model")) |m| {
        if (m == .string) model_out = m.string;
    }

    var id_out: []const u8 = "";
    if (obj.get("created_at")) |created| {
        if (created == .string) id_out = created.string;
    }

    var text_out: []const u8 = "";
    var stop_reason: ?[]const u8 = "end_turn";
    var tool_use_list: std.ArrayList(messages.ToolUseInfo) = .empty;

    if (obj.get("message")) |msg_val| {
        if (msg_val == .object) {
            const msg_obj = msg_val.object;
            if (msg_obj.get("content")) |content| {
                if (content == .string) text_out = content.string;
            }
            if (msg_obj.get("tool_calls")) |tc| {
                if (tc == .array) {
                    for (tc.array.items, 0..) |call, i| {
                        if (call != .object) continue;
                        const co = call.object;
                        var fn_name: []const u8 = "";
                        var args_val: json.Value = .{ .object = .empty };
                        var args_str: []const u8 = "{}";
                        if (co.get("function")) |fv| {
                            if (fv == .object) {
                                if (fv.object.get("name")) |nv| {
                                    if (nv == .string) fn_name = nv.string;
                                }
                                if (fv.object.get("arguments")) |av| {
                                    args_val = av;
                                    var args_aw: std.Io.Writer.Allocating = .init(arena);
                                    json.Stringify.value(av, .{}, &args_aw.writer) catch {};
                                    const serialized = args_aw.written();
                                    args_str = if (serialized.len > 0) serialized else "{}";
                                }
                            }
                        }
                        const call_id = try std.fmt.allocPrint(arena, "ollama-tool-{d}", .{i});
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

    if (tool_use_list.items.len > 0) stop_reason = "tool_use";

    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    if (obj.get("prompt_eval_count")) |c| {
        if (c == .integer) input_tokens = @intCast(c.integer);
    }
    if (obj.get("eval_count")) |c| {
        if (c == .integer) output_tokens = @intCast(c.integer);
    }

    return .{
        .id = id_out,
        .model = model_out,
        .role = "assistant",
        .content = &.{},
        .text_content = text_out,
        .tool_use = try tool_use_list.toOwnedSlice(arena),
        .stop_reason = stop_reason,
        .usage = .{
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .cache_read_tokens = 0,
            .cache_creation_tokens = 0,
        },
        .arena = arena_ptr,
    };
}

const vtable = provider_mod.Provider.VTable{
    .createMessage = struct {
        fn f(ptr: *anyopaque, request: *const messages.MessageRequest) anyerror!messages.MessageResponse {
            const self: *OllamaClient = @ptrCast(@alignCast(ptr));
            return self.createMessage(request);
        }
    }.f,
    .createMessageStreaming = struct {
        fn f(ptr: *anyopaque, request: *const messages.MessageRequest, _: provider_mod.StreamHandler) anyerror!messages.MessageResponse {
            // Streaming TODO — fall back to non-streaming.
            const self: *OllamaClient = @ptrCast(@alignCast(ptr));
            return self.createMessage(request);
        }
    }.f,
    .setCredential = struct {
        fn f(_: *anyopaque, _: []const u8) void {
            // Ollama doesn't use credentials.
        }
    }.f,
    .getName = struct {
        fn f(_: *anyopaque) []const u8 {
            return "ollama";
        }
    }.f,
};
