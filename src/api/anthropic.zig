const std = @import("std");
const http = std.http;
const json = std.json;
const common = @import("common");
const messages = @import("messages.zig");
const sse = @import("sse.zig");

/// Callback for receiving text deltas during streaming.
pub const TextDeltaFn = *const fn (ctx: *anyopaque, text: []const u8) void;

/// Context-carrying callback for streaming text deltas.
pub const StreamHandler = struct {
    ctx: *anyopaque,
    onTextDelta: TextDeltaFn,

    pub fn emitText(self: StreamHandler, text: []const u8) void {
        self.onTextDelta(self.ctx, text);
    }
};

pub const ApiError = error{
    InvalidApiKey,
    RateLimited,
    Overloaded,
    InvalidRequest,
    ServerError,
    NetworkError,
    ParseError,
    Timeout,
};

/// Result of a one-shot vision call. `text` is owned by the caller's allocator.
pub const VisionResult = struct {
    text: []const u8,
    input_tokens: u32,
    output_tokens: u32,
};

/// Check if a token is an OAuth token (Claude Code subscription token)
pub fn isOAuthToken(token: []const u8) bool {
    return std.mem.indexOf(u8, token, "sk-ant-oat") != null;
}

pub const AnthropicClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    default_model: []const u8,
    max_tokens: u32,
    timeout_ms: u32,
    is_oauth: bool,
    owns_api_key: bool, // Whether we allocated the api_key

    const API_VERSION = "2023-06-01";
    const CLAWFORGE_VERSION = "0.1.0";

    // OAuth requires specific beta features to be enabled
    const OAUTH_BETA_FEATURES = "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14";
    const API_KEY_BETA_FEATURES = "fine-grained-tool-streaming-2025-05-14";

    pub fn init(allocator: std.mem.Allocator, config: *const common.Config) !AnthropicClient {
        const api_key = try common.config.loadApiKey(allocator, config.api.token_file);
        const is_oauth = isOAuthToken(api_key);

        if (is_oauth) {
            std.log.info("Using OAuth token authentication (Claude Code subscription)", .{});
        } else {
            std.log.info("Using API key authentication", .{});
        }

        return .{
            .allocator = allocator,
            .api_key = api_key,
            .base_url = config.api.base_url,
            .default_model = config.api.default_model,
            .max_tokens = config.api.max_tokens,
            .timeout_ms = config.api.timeout_ms,
            .is_oauth = is_oauth,
            .owns_api_key = true,
        };
    }

    /// Initialize with a specific credential (for auth profile integration)
    pub fn initWithCredential(
        allocator: std.mem.Allocator,
        config: *const common.Config,
        credential: []const u8,
    ) AnthropicClient {
        const is_oauth = isOAuthToken(credential);

        if (is_oauth) {
            std.log.info("Using OAuth token authentication (Claude Code subscription)", .{});
        } else {
            std.log.info("Using API key authentication", .{});
        }

        return .{
            .allocator = allocator,
            .api_key = credential,
            .base_url = config.api.base_url,
            .default_model = config.api.default_model,
            .max_tokens = config.api.max_tokens,
            .timeout_ms = config.api.timeout_ms,
            .is_oauth = is_oauth,
            .owns_api_key = false, // Auth profile store owns this memory
        };
    }

    /// Update the credential (for profile switching)
    pub fn setCredential(self: *AnthropicClient, credential: []const u8) void {
        // Don't free old key if we don't own it
        if (self.owns_api_key) {
            self.allocator.free(self.api_key);
        }
        self.api_key = credential;
        self.is_oauth = isOAuthToken(credential);
        self.owns_api_key = false;
    }

    pub fn deinit(self: *AnthropicClient) void {
        if (self.owns_api_key) {
            self.allocator.free(self.api_key);
        }
    }

    pub fn createMessage(
        self: *AnthropicClient,
        request: *const messages.MessageRequest,
        _: ?*const fn (sse.SSEEvent) anyerror!void,
    ) !messages.MessageResponse {
        // Per-request arena: all response data (HTTP body, parsed JSON, string slices)
        // lives in this arena. The caller must call response.deinit() when done.
        const arena_ptr = try self.allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
        const arena = arena_ptr.allocator();

        var client = http.Client{ .allocator = arena };

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/v1/messages", .{self.base_url}) catch {
            return error.InvalidRequest;
        };

        const body = try request.toJson(arena, self.is_oauth);

        var redirect_buffer: [8 * 1024]u8 = undefined;

        // Retry loop: only for transient server-side overload. Idempotent
        // statuses 529 (overloaded_error) and 503 (service unavailable) are
        // retried with exponential backoff; everything else falls through
        // immediately so we don't mask real bugs (400s, auth errors).
        var response_writer = std.Io.Writer.Allocating.init(arena);
        var attempt: u32 = 0;
        const max_attempts: u32 = 3;
        const retry_delays_ns = [_]u64{
            2 * std.time.ns_per_s,
            5 * std.time.ns_per_s,
        };
        const result = while (true) {
            // Reset the response writer each attempt so error bodies from
            // previous attempts don't get concatenated. The arena keeps the
            // old allocation until the whole function returns, which is fine.
            response_writer = std.Io.Writer.Allocating.init(arena);

            const r = if (self.is_oauth)
                try self.fetchWithOAuth(&client, url, body, &redirect_buffer, &response_writer)
            else
                try self.fetchWithApiKey(&client, url, body, &redirect_buffer, &response_writer);

            const status_code = @intFromEnum(r.status);
            const is_transient = status_code == 529 or status_code == 503;
            if (!is_transient or attempt + 1 >= max_attempts) break r;

            const err_body = response_writer.written();
            std.log.warn(
                "API {d} transient — retry {d}/{d} in {d}s. Body: {s}",
                .{
                    status_code,
                    attempt + 1,
                    max_attempts,
                    retry_delays_ns[attempt] / std.time.ns_per_s,
                    err_body[0..@min(err_body.len, 200)],
                },
            );
            std.Thread.sleep(retry_delays_ns[attempt]);
            attempt += 1;
        };

        if (result.status != .ok) {
            const err_body = response_writer.written();
            if (err_body.len > 0) {
                std.log.err("API {d}: {s}", .{ @intFromEnum(result.status), err_body[0..@min(err_body.len, 1000)] });
            }
            return self.handleErrorStatus(result.status);
        }

        const response_data = response_writer.written();
        std.log.info("API raw ({d}b): {s}", .{ response_data.len, response_data[0..@min(response_data.len, 300)] });

        const parsed = json.parseFromSlice(json.Value, arena, response_data, .{}) catch {
            return error.ParseError;
        };

        const obj = parsed.value.object;

        // Extract text and tool_use content from content blocks
        var text_content: []const u8 = "";
        var tool_uses_buf: [16]messages.ToolUseInfo = undefined;
        var tool_use_count: usize = 0;

        if (obj.get("content")) |content_arr| {
            if (content_arr == .array) {
                for (content_arr.array.items) |item| {
                    if (item != .object) continue;
                    const item_type = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";

                    if (std.mem.eql(u8, item_type, "text")) {
                        if (item.object.get("text")) |txt| {
                            if (txt == .string) {
                                text_content = txt.string;
                                std.log.info("Extracted text ({d} bytes)", .{text_content.len});
                            }
                        }
                    } else if (std.mem.eql(u8, item_type, "tool_use")) {
                        if (tool_use_count < tool_uses_buf.len) {
                            const tool_id = if (item.object.get("id")) |id| (if (id == .string) id.string else "") else "";
                            const tool_name = if (item.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                            const input_val = item.object.get("input") orelse .null;

                            // Serialize input to JSON string for logging/display
                            var input_aw: std.Io.Writer.Allocating = .init(arena);
                            json.Stringify.value(input_val, .{}, &input_aw.writer) catch {};
                            const input_json_str = if (input_aw.written().len > 0) input_aw.written() else "{}";

                            tool_uses_buf[tool_use_count] = .{
                                .id = tool_id,
                                .name = tool_name,
                                .input_json = input_json_str,
                                .input = input_val,
                            };
                            tool_use_count += 1;
                        }
                    }
                }
            }
        }

        // Copy tool_use slice to arena so it outlives the stack buffer
        const tool_uses = if (tool_use_count > 0) blk: {
            const heap = arena.alloc(messages.ToolUseInfo, tool_use_count) catch break :blk &[_]messages.ToolUseInfo{};
            @memcpy(heap, tool_uses_buf[0..tool_use_count]);
            break :blk heap;
        } else &[_]messages.ToolUseInfo{};

        return .{
            .id = "",
            .model = if (obj.get("model")) |m| (if (m == .string) m.string else self.default_model) else self.default_model,
            .role = "assistant",
            .content = &.{},
            .text_content = text_content,
            .tool_use = tool_uses,
            .stop_reason = if (obj.get("stop_reason")) |sr| (if (sr == .null) null else sr.string) else null,
            .usage = blk: {
                if (obj.get("usage")) |usage| {
                    break :blk .{
                        .input_tokens = if (usage.object.get("input_tokens")) |it| @intCast(it.integer) else 0,
                        .output_tokens = if (usage.object.get("output_tokens")) |ot| @intCast(ot.integer) else 0,
                    };
                }
                break :blk .{ .input_tokens = 0, .output_tokens = 0 };
            },
            .arena = arena_ptr,
        };
    }

    /// Stream a message response, calling handler.emitText() for each text delta.
    /// Returns the final accumulated response (text + tool_use + usage).
    /// All response data lives in a per-request arena (caller must call response.deinit()).
    pub fn createMessageStreaming(
        self: *AnthropicClient,
        request: *const messages.MessageRequest,
        handler: StreamHandler,
    ) !messages.MessageResponse {
        // Per-request arena for all response data
        const arena_ptr = try self.allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
        const arena = arena_ptr.allocator();

        var client = http.Client{ .allocator = arena };

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/v1/messages", .{self.base_url}) catch {
            return error.InvalidRequest;
        };

        var stream_req = request.*;
        stream_req.stream = true;
        const body = try stream_req.toJson(arena, self.is_oauth);

        const uri = try std.Uri.parse(url);

        var auth_header_buf: [256]u8 = undefined;
        var ua_buf: [64]u8 = undefined;

        const extra_headers: []const http.Header = if (self.is_oauth) blk: {
            const bearer_value = std.fmt.bufPrint(&auth_header_buf, "Bearer {s}", .{self.api_key}) catch {
                return error.InvalidRequest;
            };
            const user_agent = std.fmt.bufPrint(&ua_buf, "clawforge/{s}", .{CLAWFORGE_VERSION}) catch "clawforge/0.1.0";
            break :blk &.{
                .{ .name = "authorization", .value = bearer_value },
                .{ .name = "anthropic-version", .value = API_VERSION },
                .{ .name = "anthropic-beta", .value = OAUTH_BETA_FEATURES },
                .{ .name = "user-agent", .value = user_agent },
                .{ .name = "x-app", .value = "cli" },
                .{ .name = "content-type", .value = "application/json" },
            };
        } else blk: {
            break :blk &.{
                .{ .name = "x-api-key", .value = self.api_key },
                .{ .name = "anthropic-version", .value = API_VERSION },
                .{ .name = "anthropic-beta", .value = API_KEY_BETA_FEATURES },
                .{ .name = "content-type", .value = "application/json" },
            };
        };

        var req = client.request(.POST, uri, .{
            .extra_headers = extra_headers,
            .redirect_behavior = .unhandled,
            .keep_alive = false,
        }) catch {
            return error.NetworkError;
        };
        // Disable compression for SSE — we need raw text lines
        req.accept_encoding = @splat(false);
        req.accept_encoding[@intFromEnum(http.ContentEncoding.identity)] = true;

        req.sendBodyComplete(@constCast(body)) catch {
            return error.NetworkError;
        };

        var redirect_buf: [1]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch {
            return error.NetworkError;
        };

        if (response.head.status != .ok) {
            // Try to read error body for logging
            var err_buf: [1024]u8 = undefined;
            const err_reader = response.reader(&err_buf);
            if (err_reader.peekDelimiterInclusive(0)) |err_data| {
                std.log.err("Stream API {d}: {s}", .{ @intFromEnum(response.head.status), err_data[0..@min(err_data.len, 500)] });
            } else |_| {}
            return self.handleErrorStatus(response.head.status);
        }

        // SSE reading — 64KB buffer to handle long data: lines (tool input JSON can be large)
        var transfer_buf: [65536]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        var sse_parser = sse.SSEParser.init(arena);

        // Accumulate text and tool_use across all events
        var text_buf: std.ArrayList(u8) = .{};
        var tool_uses: std.ArrayList(messages.ToolUseInfo) = .{};

        // Current tool input accumulator (for input_json_delta events)
        var current_tool_input: std.ArrayList(u8) = .{};
        var current_tool_id: []const u8 = "";
        var current_tool_name: []const u8 = "";

        // Read SSE stream line-by-line using peekDelimiterInclusive('\n').
        // This blocks only until the next newline arrives — perfect for SSE.
        var sse_line_count: usize = 0;
        while (true) {
            const line_with_nl = reader.peekDelimiterInclusive('\n') catch |err| {
                std.log.info("SSE read ended after {d} lines: {}", .{ sse_line_count, err });
                break;
            };
            sse_line_count += 1;
            if (sse_line_count <= 10) {
                var log_line = line_with_nl;
                if (log_line.len > 0 and log_line[log_line.len - 1] == '\n') log_line = log_line[0 .. log_line.len - 1];
                if (log_line.len > 0 and log_line[log_line.len - 1] == '\r') log_line = log_line[0 .. log_line.len - 1];
                std.log.info("SSE line {d}: [{d}b] {s}", .{ sse_line_count, log_line.len, log_line[0..@min(log_line.len, 200)] });
            }
            const line_len = line_with_nl.len;
            // Strip trailing \n and optional \r
            var line = line_with_nl;
            if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

            if (sse_parser.parseLine(line) catch null) |event| {
                switch (event.event_type) {
                    .content_block_delta => {
                        if (sse.SSEParser.extractTextDelta(event.data)) |text| {
                            handler.emitText(text);
                            text_buf.appendSlice(arena, text) catch {};
                        }
                        if (sse.SSEParser.extractInputDelta(event.data)) |partial| {
                            current_tool_input.appendSlice(arena, partial) catch {};
                        }
                    },
                    .content_block_start => {
                        if (sse.SSEParser.extractToolUse(event.data)) |tool_info| {
                            current_tool_id = arena.dupe(u8, tool_info.id) catch "";
                            current_tool_name = arena.dupe(u8, tool_info.name) catch "";
                            current_tool_input = .{};
                        }
                    },
                    .content_block_stop => {
                        if (current_tool_id.len > 0) {
                            const input_str = if (current_tool_input.items.len > 0)
                                (arena.dupe(u8, current_tool_input.items) catch "{}")
                            else
                                "{}";

                            const parsed_input = json.parseFromSlice(
                                json.Value, arena, input_str, .{},
                            ) catch null;

                            tool_uses.append(arena, .{
                                .id = current_tool_id,
                                .name = current_tool_name,
                                .input_json = input_str,
                                .input = if (parsed_input) |p| p.value else .null,
                            }) catch {};

                            current_tool_id = "";
                            current_tool_name = "";
                            current_tool_input = .{};
                        }
                    },
                    else => {},
                }
            }
            reader.toss(line_len);
        }

        // Flush parser (empty line emits final event)
        _ = sse_parser.parseLine("") catch {};

        std.log.info("SSE complete: {d} lines, text={d}b, tools={d}, stop={s}", .{
            sse_line_count,
            text_buf.items.len,
            tool_uses.items.len,
            sse_parser.stop_reason orelse "null",
        });

        return .{
            .id = sse_parser.message_id orelse "",
            .model = sse_parser.model orelse self.default_model,
            .role = "assistant",
            .content = &.{},
            .text_content = text_buf.items,
            .tool_use = tool_uses.items,
            .stop_reason = sse_parser.stop_reason,
            .usage = .{
                .input_tokens = sse_parser.input_tokens,
                .output_tokens = sse_parser.output_tokens,
            },
            .arena = arena_ptr,
        };
    }

    /// One-shot vision call: post a single image + text prompt and return
    /// the model's description. Does NOT use the tool loop or the main
    /// MessageRequest serializer — builds its own image-aware payload.
    /// Bytes are base64-encoded inline (Anthropic `image.source.type=base64`).
    pub fn describeImage(
        self: *AnthropicClient,
        model: []const u8,
        prompt: []const u8,
        image_bytes: []const u8,
        mime: []const u8,
        max_output_tokens: u32,
    ) !VisionResult {
        // Per-request arena so all intermediate strings get freed together.
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var client = http.Client{ .allocator = arena };

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/v1/messages", .{self.base_url}) catch {
            return error.InvalidRequest;
        };

        // Base64 encode the image bytes.
        const b64_len = std.base64.standard.Encoder.calcSize(image_bytes.len);
        const b64 = try arena.alloc(u8, b64_len);
        _ = std.base64.standard.Encoder.encode(b64, image_bytes);

        // Build the JSON body manually. Schema:
        // { model, max_tokens, stream:false,
        //   messages: [ { role: "user",
        //     content: [
        //       { type: "image", source: { type: "base64", media_type, data } },
        //       { type: "text", text: "..." }
        //     ] } ] }
        var body: std.ArrayList(u8) = .{};
        defer body.deinit(arena);
        try body.ensureTotalCapacity(arena, b64.len + 1024);

        const w = struct {
            fn a(o: *std.ArrayList(u8), al: std.mem.Allocator, s: []const u8) void {
                o.appendSlice(al, s) catch {};
            }
            fn escape(o: *std.ArrayList(u8), al: std.mem.Allocator, s: []const u8) void {
                // Shared UTF-8-safe escaper: rejects lone surrogates and
                // invalid sequences that Anthropic's JSON parser would 400 on.
                messages.appendJsonEscaped(o, al, s);
            }
        };

        w.a(&body, arena, "{\"model\":\"");
        w.a(&body, arena, model);
        var num_buf: [32]u8 = undefined;
        w.a(&body, arena, "\",\"max_tokens\":");
        w.a(&body, arena, std.fmt.bufPrint(&num_buf, "{d}", .{max_output_tokens}) catch "512");
        w.a(&body, arena, ",\"stream\":false");

        if (self.is_oauth) {
            // OAuth requires the Claude Code identity system prompt.
            w.a(&body, arena, ",\"system\":[{\"type\":\"text\",\"text\":\"");
            w.a(&body, arena, "You are Claude Code, Anthropic's official CLI for Claude.");
            w.a(&body, arena, "\"}]");
        }

        w.a(&body, arena, ",\"messages\":[{\"role\":\"user\",\"content\":[");
        w.a(&body, arena, "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"");
        w.escape(&body, arena, mime);
        w.a(&body, arena, "\",\"data\":\"");
        w.a(&body, arena, b64);
        w.a(&body, arena, "\"}},");
        w.a(&body, arena, "{\"type\":\"text\",\"text\":\"");
        w.escape(&body, arena, prompt);
        w.a(&body, arena, "\"}]}]}");

        var response_writer = std.Io.Writer.Allocating.init(arena);
        var redirect_buffer: [8 * 1024]u8 = undefined;

        const result = if (self.is_oauth)
            try self.fetchWithOAuth(&client, url, body.items, &redirect_buffer, &response_writer)
        else
            try self.fetchWithApiKey(&client, url, body.items, &redirect_buffer, &response_writer);

        const response_data = response_writer.written();
        if (result.status != .ok) {
            std.log.err("Vision API {d}: {s}", .{
                @intFromEnum(result.status),
                response_data[0..@min(response_data.len, 500)],
            });
            return self.handleErrorStatus(result.status);
        }

        const parsed = json.parseFromSlice(json.Value, arena, response_data, .{}) catch {
            return error.ParseError;
        };
        const obj = parsed.value.object;

        // Extract the first text block.
        var text_out: []const u8 = "";
        if (obj.get("content")) |content_arr| {
            if (content_arr == .array) {
                for (content_arr.array.items) |item| {
                    if (item != .object) continue;
                    const item_type = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                    if (std.mem.eql(u8, item_type, "text")) {
                        if (item.object.get("text")) |txt| {
                            if (txt == .string) text_out = txt.string;
                        }
                        break;
                    }
                }
            }
        }

        var in_toks: u32 = 0;
        var out_toks: u32 = 0;
        if (obj.get("usage")) |usage| {
            if (usage == .object) {
                if (usage.object.get("input_tokens")) |it| if (it == .integer) {
                    in_toks = @intCast(it.integer);
                };
                if (usage.object.get("output_tokens")) |ot| if (ot == .integer) {
                    out_toks = @intCast(ot.integer);
                };
            }
        }

        // Copy the text out of the arena so it outlives this function.
        const text_copy = try self.allocator.dupe(u8, text_out);
        return .{
            .text = text_copy,
            .input_tokens = in_toks,
            .output_tokens = out_toks,
        };
    }

    fn fetchWithOAuth(
        self: *AnthropicClient,
        client: *http.Client,
        url: []const u8,
        body: []const u8,
        redirect_buffer: *[8 * 1024]u8,
        response_writer: *std.Io.Writer.Allocating,
    ) !http.Client.FetchResult {
        // Build Bearer token header
        var auth_header_buf: [256]u8 = undefined;
        const bearer_value = std.fmt.bufPrint(&auth_header_buf, "Bearer {s}", .{self.api_key}) catch {
            return error.InvalidRequest;
        };

        // Build user-agent header
        var ua_buf: [64]u8 = undefined;
        const user_agent = std.fmt.bufPrint(&ua_buf, "clawforge/{s}", .{CLAWFORGE_VERSION}) catch "clawforge/0.1.0";

        return client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .redirect_buffer = redirect_buffer,
            .response_writer = &response_writer.writer,
            .extra_headers = &.{
                .{ .name = "authorization", .value = bearer_value },
                .{ .name = "anthropic-version", .value = API_VERSION },
                .{ .name = "anthropic-beta", .value = OAUTH_BETA_FEATURES },
                .{ .name = "user-agent", .value = user_agent },
                .{ .name = "x-app", .value = "cli" },
                .{ .name = "content-type", .value = "application/json" },
            },
            .payload = body,
        }) catch {
            return error.NetworkError;
        };
    }

    fn fetchWithApiKey(
        self: *AnthropicClient,
        client: *http.Client,
        url: []const u8,
        body: []const u8,
        redirect_buffer: *[8 * 1024]u8,
        response_writer: *std.Io.Writer.Allocating,
    ) !http.Client.FetchResult {
        return client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .redirect_buffer = redirect_buffer,
            .response_writer = &response_writer.writer,
            .extra_headers = &.{
                .{ .name = "x-api-key", .value = self.api_key },
                .{ .name = "anthropic-version", .value = API_VERSION },
                .{ .name = "anthropic-beta", .value = API_KEY_BETA_FEATURES },
                .{ .name = "content-type", .value = "application/json" },
            },
            .payload = body,
        }) catch {
            return error.NetworkError;
        };
    }

    fn handleErrorStatus(_: *AnthropicClient, status: http.Status) ApiError {
        return switch (status) {
            .unauthorized => error.InvalidApiKey,
            .too_many_requests => error.RateLimited,
            .service_unavailable => error.Overloaded,
            .bad_request => error.InvalidRequest,
            else => if (@intFromEnum(status) >= 500) error.ServerError else error.NetworkError,
        };
    }
};
