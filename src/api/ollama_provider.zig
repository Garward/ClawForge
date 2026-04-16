const std = @import("std");
const http = std.http;
const provider_mod = @import("provider.zig");
const messages = @import("messages.zig");
const openai_provider = @import("openai_provider.zig");

/// Ollama provider — local LLM inference via Ollama's OpenAI-compatible
/// endpoint at `{base_url}/v1/chat/completions`. Reuses the same body
/// builder and response parser as the OpenAI provider, so tool calls,
/// image content blocks, and tool_result follow-up rounds all work the
/// same way against any local model that supports them (Qwen 3, Llama
/// 3.1/3.2, Mistral, etc.). No API key, runs on local GPU.
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
    ) OllamaClient {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .default_model = default_model,
            .num_ctx_max = num_ctx_max,
        };
    }

    /// Estimate how much context the request needs and pick the smallest
    /// standard num_ctx size that fits, clamped to [FLOOR, num_ctx_max].
    /// Rounding to standard sizes prevents Ollama from rebuilding the KV
    /// cache on every request when prompt sizes fluctuate slightly.
    fn pickNumCtx(self: *const OllamaClient, request: *const messages.MessageRequest) u32 {
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
            chosen = self.num_ctx_max;
        }

        // Clamp to [FLOOR, num_ctx_max].
        if (chosen < NUM_CTX_FLOOR) chosen = NUM_CTX_FLOOR;
        if (chosen > self.num_ctx_max) chosen = self.num_ctx_max;
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

        var client = http.Client{ .allocator = arena };

        const effective_model = if (request.model.len > 0) request.model else self.default_model;

        // Dynamic num_ctx: scale per-request up to the configured VRAM
        // ceiling, so short prompts don't waste KV cache and long agent
        // loops don't silently truncate. See pickNumCtx for the math.
        const chosen_ctx = self.pickNumCtx(request);
        std.log.info(
            "Ollama: model={s} num_ctx={d} (cap {d})",
            .{ effective_model, chosen_ctx, self.num_ctx_max },
        );

        // Build an Ollama-specific extra field: `,"options":{"num_ctx":N}`.
        // This gets appended verbatim at the end of the JSON body. Ollama
        // recognizes it on its OpenAI-compat endpoint and sizes the KV
        // cache accordingly; strict OpenAI would ignore it as an unknown
        // field (we'd never send it to OpenAI anyway).
        var extra_buf: [64]u8 = undefined;
        const extras = std.fmt.bufPrint(&extra_buf, ",\"options\":{{\"num_ctx\":{d}}}", .{chosen_ctx}) catch null;

        const body = try openai_provider.buildChatCompletionsBody(arena, request, effective_model, extras);

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/v1/chat/completions", .{self.base_url}) catch return error.InvalidRequest;

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

        return openai_provider.parseChatCompletionsResponse(arena, arena_ptr, response_data, effective_model);
    }
};

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
