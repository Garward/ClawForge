const std = @import("std");
const http = std.http;
const json = std.json;
const provider_mod = @import("provider.zig");
const messages = @import("messages.zig");
const codex_oauth = @import("codex_oauth.zig");

/// Codex (ChatGPT subscription) provider — speaks the OpenAI Responses API
/// against `https://chatgpt.com/backend-api/codex/responses`. Auth is an
/// OAuth access_token (Bearer) plus a `chatgpt-account-id` header derived
/// from the JWT, both managed by `codex_oauth.Store`.
///
/// On 401 the provider transparently refreshes the access_token once and
/// retries; persistent failure surfaces as `error.Unauthorized` so the
/// engine can fall back to a different provider.
pub const CodexClient = struct {
    allocator: std.mem.Allocator,
    auth: *codex_oauth.Store,
    base_url: []const u8,
    default_model: []const u8,

    const DEFAULT_BASE_URL = "https://chatgpt.com/backend-api";

    pub fn init(
        allocator: std.mem.Allocator,
        auth: *codex_oauth.Store,
        base_url: []const u8,
        default_model: []const u8,
    ) CodexClient {
        return .{
            .allocator = allocator,
            .auth = auth,
            .base_url = if (base_url.len > 0) base_url else DEFAULT_BASE_URL,
            .default_model = default_model,
        };
    }

    pub fn provider(self: *CodexClient) provider_mod.Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn createMessage(
        self: *CodexClient,
        request: *const messages.MessageRequest,
    ) !messages.MessageResponse {
        // Codex Responses API is streaming-only in practice; collect deltas
        // into a buffer using a no-op stream handler.
        const NoopCtx = struct {
            fn onDelta(_: *anyopaque, _: []const u8) void {}
        };
        var ctx: u8 = 0;
        const handler: provider_mod.StreamHandler = .{
            .ctx = @ptrCast(&ctx),
            .onTextDelta = NoopCtx.onDelta,
        };
        return self.createMessageStreaming(request, handler);
    }

    pub fn createMessageStreaming(
        self: *CodexClient,
        request: *const messages.MessageRequest,
        handler: provider_mod.StreamHandler,
    ) !messages.MessageResponse {
        // Try once; on 401, force-refresh and retry once.
        return self.doRequest(request, handler, false) catch |err| {
            if (err == error.Unauthorized) {
                std.log.info("codex: 401 — refreshing tokens and retrying", .{});
                self.auth.forceRefresh() catch |rerr| {
                    std.log.err("codex: refresh failed: {}", .{rerr});
                    return error.Unauthorized;
                };
                return self.doRequest(request, handler, true);
            }
            return err;
        };
    }

    fn doRequest(
        self: *CodexClient,
        request: *const messages.MessageRequest,
        handler: provider_mod.StreamHandler,
        is_retry: bool,
    ) !messages.MessageResponse {
        const arena_ptr = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena_ptr.deinit();
        const arena = arena_ptr.allocator();

        const effective_model = if (request.model.len > 0) request.model else self.default_model;

        const body = try buildRequestBody(arena, request, effective_model);

        // Snapshot credentials just before sending (refresh inside getCredentials
        // if expiry is near). Slices borrowed — store them locally before we
        // make any other call into the Store.
        const creds = try self.auth.getCredentials();
        const access_token = try arena.dupe(u8, creds.access_token);
        const account_id = try arena.dupe(u8, creds.account_id);

        var url_buf: [256]u8 = undefined;
        const url = try buildResponsesUrl(&url_buf, self.base_url);
        const uri = try std.Uri.parse(url);

        var auth_buf: [4096]u8 = undefined;
        const auth_value = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{access_token});

        const headers = [_]http.Header{
            .{ .name = "authorization", .value = auth_value },
            .{ .name = "chatgpt-account-id", .value = account_id },
            .{ .name = "openai-beta", .value = "responses=experimental" },
            .{ .name = "originator", .value = "clawforge" },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "user-agent", .value = "clawforge/0.1" },
        };

        var client = http.Client{ .allocator = arena };
        var req = client.request(.POST, uri, .{
            .extra_headers = &headers,
            .redirect_behavior = .unhandled,
            .keep_alive = false,
        }) catch return error.NetworkError;

        // Disable compression for SSE so we see line boundaries cleanly.
        req.accept_encoding = @splat(false);
        req.accept_encoding[@intFromEnum(http.ContentEncoding.identity)] = true;

        req.sendBodyComplete(@constCast(body)) catch return error.NetworkError;

        var redirect_buf: [1]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch return error.NetworkError;

        if (response.head.status != .ok) {
            const status = @intFromEnum(response.head.status);
            var err_buf: [4096]u8 = undefined;
            const err_reader = response.reader(&err_buf);
            // Drain the body. Error responses may be short JSON with no
            // trailing newline, so we use peek with a large length to grab
            // whatever's buffered, ignoring delimiters.
            var err_acc: std.ArrayList(u8) = .{};
            while (true) {
                const chunk = err_reader.peekGreedy(1) catch break;
                if (chunk.len == 0) break;
                err_acc.appendSlice(arena, chunk) catch break;
                err_reader.toss(chunk.len);
                if (err_acc.items.len > 4000) break;
            }
            std.log.err("codex API {d} ({s}): {s}", .{
                status,
                url,
                err_acc.items[0..@min(err_acc.items.len, 1500)],
            });
            // Dump the request body too so we can see what tripped the
            // validator. Truncate at 4KB to keep logs sane.
            std.log.err("codex API {d} request body: {s}", .{
                status,
                body[0..@min(body.len, 4000)],
            });
            if (status == 401 and !is_retry) return error.Unauthorized;
            if (status == 401) return error.Unauthorized;
            if (status == 429) return error.RateLimited;
            return error.ServerError;
        }

        return parseSSE(arena, arena_ptr, &response, effective_model, handler);
    }
};

// =============================================================================
// URL helper
// =============================================================================

fn buildResponsesUrl(buf: []u8, base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/codex/responses")) {
        return std.fmt.bufPrint(buf, "{s}", .{trimmed});
    }
    if (std.mem.endsWith(u8, trimmed, "/codex")) {
        return std.fmt.bufPrint(buf, "{s}/responses", .{trimmed});
    }
    return std.fmt.bufPrint(buf, "{s}/codex/responses", .{trimmed});
}

// =============================================================================
// Request body — Responses API
// =============================================================================

fn buildRequestBody(
    arena: std.mem.Allocator,
    request: *const messages.MessageRequest,
    model: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    try out.ensureTotalCapacity(arena, 16 * 1024);

    try out.appendSlice(arena, "{\"model\":\"");
    messages.appendJsonEscaped(&out, arena, model);
    try out.appendSlice(arena, "\",\"store\":false,\"stream\":true");

    // System prompt → top-level "instructions".
    if (request.system) |sys| {
        try out.appendSlice(arena, ",\"instructions\":\"");
        messages.appendJsonEscaped(&out, arena, sys);
        try out.appendSlice(arena, "\"");
    }

    // Verbosity + reasoning summary defaults. These match what the Codex
    // CLI sends and keep the response shape predictable.
    try out.appendSlice(arena, ",\"text\":{\"verbosity\":\"medium\"}");
    try out.appendSlice(arena, ",\"include\":[\"reasoning.encrypted_content\"]");
    try out.appendSlice(arena, ",\"tool_choice\":\"auto\",\"parallel_tool_calls\":true");
    try out.appendSlice(arena, ",\"reasoning\":{\"effort\":\"medium\",\"summary\":\"auto\"}");

    // Tools (Responses API uses flat function shape).
    if (request.tools) |tool_list| {
        if (tool_list.len > 0) {
            try out.appendSlice(arena, ",\"tools\":[");
            for (tool_list, 0..) |tool, i| {
                if (i > 0) try out.appendSlice(arena, ",");
                try out.appendSlice(arena, "{\"type\":\"function\",\"name\":\"");
                messages.appendJsonEscaped(&out, arena, tool.name);
                try out.appendSlice(arena, "\",\"description\":\"");
                messages.appendJsonEscaped(&out, arena, tool.description);
                try out.appendSlice(arena, "\",\"parameters\":");
                try out.appendSlice(arena, tool.input_schema_json);
                try out.appendSlice(arena, ",\"strict\":false}");
            }
            try out.appendSlice(arena, "]");
        }
    }

    // Input items.
    try out.appendSlice(arena, ",\"input\":[");
    var first = true;
    for (request.messages) |msg| {
        try emitInputItems(&out, arena, msg, &first);
    }
    try out.appendSlice(arena, "]");

    try out.appendSlice(arena, "}");
    return out.toOwnedSlice(arena) catch out.items;
}

fn emitInputItems(
    out: *std.ArrayList(u8),
    arena: std.mem.Allocator,
    msg: messages.Message,
    first: *bool,
) !void {
    // Split blocks by category. Tool_use, tool_result, and reasoning each get
    // their own top-level items; text is grouped into one message item per role.
    var text_buf: std.ArrayList(messages.ContentBlock.TextBlock) = .{};
    var image_buf: std.ArrayList(messages.ContentBlock.ImageBlock) = .{};
    var tool_use_buf: std.ArrayList(messages.ContentBlock.ToolUseBlock) = .{};
    var tool_res_buf: std.ArrayList(messages.ContentBlock.ToolResultBlock) = .{};
    var reasoning_buf: std.ArrayList(messages.ContentBlock.ReasoningBlock) = .{};

    for (msg.content) |block| {
        switch (block) {
            .text => |t| try text_buf.append(arena, t),
            .image => |img| try image_buf.append(arena, img),
            .tool_use => |tu| try tool_use_buf.append(arena, tu),
            .tool_result => |tr| try tool_res_buf.append(arena, tr),
            .reasoning => |r| try reasoning_buf.append(arena, r),
        }
    }

    // Tool results first — each its own function_call_output item.
    for (tool_res_buf.items) |tr| {
        if (!first.*) try out.appendSlice(arena, ",");
        first.* = false;
        try out.appendSlice(arena, "{\"type\":\"function_call_output\",\"call_id\":\"");
        messages.appendJsonEscaped(out, arena, tr.tool_use_id);
        try out.appendSlice(arena, "\",\"output\":\"");
        messages.appendJsonEscaped(out, arena, tr.content);
        try out.appendSlice(arena, "\"}");
    }

    // Text/image as a single message item (when present).
    const has_text = text_buf.items.len > 0;
    const has_image = image_buf.items.len > 0;
    if (has_text or has_image) {
        if (!first.*) try out.appendSlice(arena, ",");
        first.* = false;
        try out.appendSlice(arena, "{\"type\":\"message\",\"role\":\"");
        try out.appendSlice(arena, @tagName(msg.role));
        try out.appendSlice(arena, "\",\"content\":[");

        var first_part = true;
        for (text_buf.items) |t| {
            if (!first_part) try out.appendSlice(arena, ",");
            first_part = false;
            // Responses API uses input_text for user, output_text for assistant.
            const part_type: []const u8 = if (msg.role == .assistant) "output_text" else "input_text";
            try out.appendSlice(arena, "{\"type\":\"");
            try out.appendSlice(arena, part_type);
            try out.appendSlice(arena, "\",\"text\":\"");
            messages.appendJsonEscaped(out, arena, t.text);
            try out.appendSlice(arena, "\"}");
        }
        for (image_buf.items) |img| {
            if (!first_part) try out.appendSlice(arena, ",");
            first_part = false;
            try out.appendSlice(arena, "{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:");
            messages.appendJsonEscaped(out, arena, img.media_type);
            try out.appendSlice(arena, ";base64,");
            try out.appendSlice(arena, img.data);
            try out.appendSlice(arena, "\"}");
        }
        try out.appendSlice(arena, "]}");
    }

    // Reasoning items belong with the assistant turn — replay them before
    // their associated function_calls so the model sees its own prior
    // chain-of-thought.
    for (reasoning_buf.items) |r| {
        if (r.encrypted_content.len == 0) continue;
        if (!first.*) try out.appendSlice(arena, ",");
        first.* = false;
        try out.appendSlice(arena, "{\"type\":\"reasoning\",\"id\":\"");
        messages.appendJsonEscaped(out, arena, r.id);
        try out.appendSlice(arena, "\",\"encrypted_content\":\"");
        messages.appendJsonEscaped(out, arena, r.encrypted_content);
        try out.appendSlice(arena, "\",\"summary\":[]}");
    }

    // Tool_use blocks → function_call items.
    for (tool_use_buf.items) |tu| {
        if (!first.*) try out.appendSlice(arena, ",");
        first.* = false;
        try out.appendSlice(arena, "{\"type\":\"function_call\",\"call_id\":\"");
        messages.appendJsonEscaped(out, arena, tu.id);
        try out.appendSlice(arena, "\",\"name\":\"");
        messages.appendJsonEscaped(out, arena, tu.name);
        try out.appendSlice(arena, "\",\"arguments\":\"");

        var args_aw: std.Io.Writer.Allocating = .init(arena);
        json.Stringify.value(tu.input, .{}, &args_aw.writer) catch {};
        const args_json = args_aw.written();
        messages.appendJsonEscaped(out, arena, if (args_json.len > 0) args_json else "{}");
        try out.appendSlice(arena, "\"}");
    }
}

// =============================================================================
// SSE parsing
// =============================================================================

fn parseSSE(
    arena: std.mem.Allocator,
    arena_ptr: *std.heap.ArenaAllocator,
    response: *http.Client.Response,
    model: []const u8,
    handler: provider_mod.StreamHandler,
) !messages.MessageResponse {
    var transfer_buf: [65536]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    var text_buf: std.ArrayList(u8) = .{};
    var tool_uses: std.ArrayList(messages.ToolUseInfo) = .{};
    var reasoning_items: std.ArrayList(messages.ReasoningInfo) = .{};

    // Active function_call accumulator. Codex emits args via
    // `response.function_call_arguments.delta` events keyed by item_id;
    // we track the most-recent function_call item id (and its call_id +
    // name from `output_item.added`).
    const MaxToolCalls = 32;
    var tc_call_ids: [MaxToolCalls][]u8 = undefined;
    var tc_names: [MaxToolCalls][]u8 = undefined;
    var tc_args: [MaxToolCalls]std.ArrayList(u8) = undefined;
    var tc_item_ids: [MaxToolCalls][]const u8 = undefined; // borrowed from arena
    var tc_count: usize = 0;
    for (0..MaxToolCalls) |i| {
        tc_call_ids[i] = &.{};
        tc_names[i] = &.{};
        tc_args[i] = .{};
        tc_item_ids[i] = "";
    }

    var stop_reason: ?[]const u8 = null;
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    var cache_read_tokens: u32 = 0;
    var msg_id: []const u8 = "";

    var line_count: usize = 0;
    var current_event: []const u8 = "";

    while (true) {
        const line_with_nl = reader.peekDelimiterInclusive('\n') catch |err| {
            std.log.info("codex SSE ended after {d} lines: {}", .{ line_count, err });
            break;
        };
        line_count += 1;
        const line_len = line_with_nl.len;
        var line = line_with_nl;
        if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (std.mem.startsWith(u8, line, "event: ")) {
            current_event = arena.dupe(u8, line[7..]) catch "";
            reader.toss(line_len);
            continue;
        }

        if (std.mem.startsWith(u8, line, "data: ")) {
            const data = line[6..];
            if (data.len == 0 or std.mem.eql(u8, data, "[DONE]")) {
                reader.toss(line_len);
                if (std.mem.eql(u8, data, "[DONE]")) break;
                continue;
            }

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
            const ev = parsed.value.object;

            // event "type" field is authoritative; the SSE `event:` line and
            // the JSON `"type"` agree in practice.
            const ev_type: []const u8 = blk: {
                if (ev.get("type")) |t| {
                    if (t == .string) break :blk t.string;
                }
                break :blk current_event;
            };

            if (std.mem.eql(u8, ev_type, "response.created")) {
                if (ev.get("response")) |r| {
                    if (r == .object) {
                        if (r.object.get("id")) |id_val| {
                            if (id_val == .string) msg_id = id_val.string;
                        }
                    }
                }
            } else if (std.mem.eql(u8, ev_type, "response.output_item.added")) {
                if (ev.get("item")) |item_val| {
                    if (item_val == .object) {
                        const it = item_val.object;
                        const it_type: []const u8 = if (it.get("type")) |t| (if (t == .string) t.string else "") else "";
                        if (std.mem.eql(u8, it_type, "function_call") and tc_count < MaxToolCalls) {
                            const item_id: []const u8 = if (it.get("id")) |v| (if (v == .string) v.string else "") else "";
                            const call_id: []const u8 = if (it.get("call_id")) |v| (if (v == .string) v.string else "") else "";
                            const name: []const u8 = if (it.get("name")) |v| (if (v == .string) v.string else "") else "";
                            tc_item_ids[tc_count] = item_id;
                            tc_call_ids[tc_count] = arena.dupe(u8, call_id) catch &.{};
                            tc_names[tc_count] = arena.dupe(u8, name) catch &.{};
                            // Some events seed initial args.
                            if (it.get("arguments")) |a| {
                                if (a == .string and a.string.len > 0) {
                                    tc_args[tc_count].appendSlice(arena, a.string) catch {};
                                }
                            }
                            tc_count += 1;
                        }
                    }
                }
            } else if (std.mem.eql(u8, ev_type, "response.output_item.done")) {
                // Reasoning items carry encrypted_content only on the final
                // `done` event — capture it here for replay in the next round.
                if (ev.get("item")) |item_val| {
                    if (item_val == .object) {
                        const it = item_val.object;
                        const it_type: []const u8 = if (it.get("type")) |t| (if (t == .string) t.string else "") else "";
                        if (std.mem.eql(u8, it_type, "reasoning")) {
                            const id: []const u8 = if (it.get("id")) |v| (if (v == .string) v.string else "") else "";
                            const enc: []const u8 = if (it.get("encrypted_content")) |v| (if (v == .string) v.string else "") else "";
                            if (id.len > 0 and enc.len > 0) {
                                reasoning_items.append(arena, .{
                                    .id = arena.dupe(u8, id) catch &.{},
                                    .encrypted_content = arena.dupe(u8, enc) catch &.{},
                                }) catch {};
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, ev_type, "response.output_text.delta")) {
                if (ev.get("delta")) |d| {
                    if (d == .string and d.string.len > 0) {
                        handler.emitText(d.string);
                        text_buf.appendSlice(arena, d.string) catch {};
                    }
                }
            } else if (std.mem.eql(u8, ev_type, "response.function_call_arguments.delta")) {
                // Match by item_id to find which accumulator to extend.
                const item_id: []const u8 = if (ev.get("item_id")) |v| (if (v == .string) v.string else "") else "";
                const delta: []const u8 = if (ev.get("delta")) |v| (if (v == .string) v.string else "") else "";
                if (item_id.len > 0 and delta.len > 0) {
                    for (0..tc_count) |i| {
                        if (std.mem.eql(u8, tc_item_ids[i], item_id)) {
                            tc_args[i].appendSlice(arena, delta) catch {};
                            break;
                        }
                    }
                }
            } else if (std.mem.eql(u8, ev_type, "response.function_call_arguments.done")) {
                // Final args string — replace the accumulator if provided.
                const item_id: []const u8 = if (ev.get("item_id")) |v| (if (v == .string) v.string else "") else "";
                const args_full: []const u8 = if (ev.get("arguments")) |v| (if (v == .string) v.string else "") else "";
                if (item_id.len > 0 and args_full.len > 0) {
                    for (0..tc_count) |i| {
                        if (std.mem.eql(u8, tc_item_ids[i], item_id)) {
                            tc_args[i].clearRetainingCapacity();
                            tc_args[i].appendSlice(arena, args_full) catch {};
                            break;
                        }
                    }
                }
            } else if (std.mem.eql(u8, ev_type, "response.completed")) {
                if (ev.get("response")) |r| {
                    if (r == .object) {
                        if (r.object.get("status")) |s| {
                            if (s == .string) {
                                stop_reason = if (std.mem.eql(u8, s.string, "completed"))
                                    "end_turn"
                                else
                                    "end_turn";
                            }
                        }
                        if (r.object.get("usage")) |usage| {
                            if (usage == .object) {
                                if (usage.object.get("input_tokens")) |c| {
                                    if (c == .integer) input_tokens = @intCast(c.integer);
                                }
                                if (usage.object.get("output_tokens")) |c| {
                                    if (c == .integer) output_tokens = @intCast(c.integer);
                                }
                                if (usage.object.get("input_tokens_details")) |d| {
                                    if (d == .object) {
                                        if (d.object.get("cached_tokens")) |c| {
                                            if (c == .integer) cache_read_tokens = @intCast(c.integer);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                reader.toss(line_len);
                break;
            } else if (std.mem.eql(u8, ev_type, "response.failed") or std.mem.eql(u8, ev_type, "error")) {
                std.log.err("codex stream error event: {s}", .{data[0..@min(data.len, 500)]});
                reader.toss(line_len);
                return error.ServerError;
            }
        }

        reader.toss(line_len);
    }

    // Finalize tool calls.
    for (0..tc_count) |i| {
        const args_str: []const u8 = if (tc_args[i].items.len > 0) tc_args[i].items else "{}";
        const parsed_args = json.parseFromSliceLeaky(
            json.Value,
            arena,
            args_str,
            .{ .allocate = .alloc_always },
        ) catch json.Value{ .object = json.ObjectMap.init(arena) };

        tool_uses.append(arena, .{
            .id = tc_call_ids[i],
            .name = tc_names[i],
            .input_json = args_str,
            .input = parsed_args,
        }) catch {};
    }

    if (tool_uses.items.len > 0) {
        stop_reason = "tool_use";
    }

    std.log.info("codex SSE complete: {d} lines, text={d}b, tools={d}, reasoning={d}, stop={s}", .{
        line_count,
        text_buf.items.len,
        tool_uses.items.len,
        reasoning_items.items.len,
        stop_reason orelse "null",
    });

    return .{
        .id = msg_id,
        .model = model,
        .role = "assistant",
        .content = &.{},
        .text_content = text_buf.items,
        .tool_use = tool_uses.items,
        .reasoning_items = reasoning_items.items,
        .stop_reason = stop_reason,
        .usage = .{
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .cache_read_tokens = cache_read_tokens,
            .cache_creation_tokens = 0,
        },
        .arena = arena_ptr,
    };
}

// =============================================================================
// VTable
// =============================================================================

const vtable = provider_mod.Provider.VTable{
    .createMessage = struct {
        fn f(ptr: *anyopaque, request: *const messages.MessageRequest) anyerror!messages.MessageResponse {
            const self: *CodexClient = @ptrCast(@alignCast(ptr));
            return self.createMessage(request);
        }
    }.f,
    .createMessageStreaming = struct {
        fn f(ptr: *anyopaque, request: *const messages.MessageRequest, handler: provider_mod.StreamHandler) anyerror!messages.MessageResponse {
            const self: *CodexClient = @ptrCast(@alignCast(ptr));
            return self.createMessageStreaming(request, handler);
        }
    }.f,
    .setCredential = struct {
        fn f(_: *anyopaque, _: []const u8) void {
            // No-op: credentials managed by codex_oauth.Store.
        }
    }.f,
    .getName = struct {
        fn f(_: *anyopaque) []const u8 {
            return "codex";
        }
    }.f,
};
