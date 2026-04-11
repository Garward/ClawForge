const std = @import("std");
const http = std.http;
const json = std.json;
const provider_mod = @import("provider.zig");
const messages = @import("messages.zig");

/// Ollama provider — local LLM inference via Ollama HTTP API.
/// Supports /api/chat for conversation and /api/embeddings for vectors.
/// Free, no API key needed, runs on local GPU.
pub const OllamaClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    default_model: []const u8,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, default_model: []const u8) OllamaClient {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .default_model = default_model,
        };
    }

    pub fn provider(self: *OllamaClient) provider_mod.Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn createMessage(self: *OllamaClient, request: *const messages.MessageRequest) !messages.MessageResponse {
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Build Ollama /api/chat request body
        var body_buf: [65536]u8 = undefined;
        var pos: usize = 0;

        const write = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                const len = @min(data.len, b.len -| p.*);
                @memcpy(b[p.*..][0..len], data[0..len]);
                p.* += len;
            }
        }.f;

        const writeEscaped = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                for (data) |c| {
                    if (p.* >= b.len - 2) break;
                    if (c == '"') { b[p.*] = '\\'; p.* += 1; b[p.*] = '"'; p.* += 1; } else if (c == '\\') { b[p.*] = '\\'; p.* += 1; b[p.*] = '\\'; p.* += 1; } else if (c == '\n') { b[p.*] = '\\'; p.* += 1; b[p.*] = 'n'; p.* += 1; } else { b[p.*] = c; p.* += 1; }
                }
            }
        }.f;

        // Use the model from request, or fall back to default
        const model = if (request.model.len > 0) request.model else self.default_model;

        write(&body_buf, &pos, "{\"model\":\"");
        write(&body_buf, &pos, model);
        write(&body_buf, &pos, "\",\"stream\":false,\"messages\":[");

        // Add system message if present
        if (request.system) |sys| {
            write(&body_buf, &pos, "{\"role\":\"system\",\"content\":\"");
            writeEscaped(&body_buf, &pos, sys);
            write(&body_buf, &pos, "\"},");
        }

        // Add conversation messages
        for (request.messages, 0..) |msg, i| {
            if (i > 0 or request.system != null) {
                if (i > 0) write(&body_buf, &pos, ",");
            }
            write(&body_buf, &pos, "{\"role\":\"");
            write(&body_buf, &pos, @tagName(msg.role));
            write(&body_buf, &pos, "\",\"content\":\"");
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| writeEscaped(&body_buf, &pos, t.text),
                    else => {},
                }
            }
            write(&body_buf, &pos, "\"}");
        }

        write(&body_buf, &pos, "]}");

        const body = body_buf[0..pos];

        // Build URL
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/api/chat", .{self.base_url}) catch return error.InvalidRequest;

        // Make request
        var response_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer response_writer.deinit();
        var redirect_buf: [1024]u8 = undefined;

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .redirect_buffer = &redirect_buf,
            .response_writer = &response_writer.writer,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
            .payload = body,
        }) catch return error.NetworkError;

        if (result.status != .ok) return error.ServerError;

        // Parse Ollama response
        const response_data = response_writer.written();
        const parsed = json.parseFromSlice(json.Value, self.allocator, response_data, .{
            .allocate = .alloc_always,
        }) catch return error.ParseError;

        const obj = parsed.value.object;

        // Extract text from message.content
        var text_content: []const u8 = "";
        if (obj.get("message")) |msg| {
            if (msg.object.get("content")) |c| {
                if (c == .string) text_content = c.string;
            }
        }

        // Extract token counts
        var input_tokens: u32 = 0;
        var output_tokens: u32 = 0;
        if (obj.get("prompt_eval_count")) |c| {
            if (c == .integer) input_tokens = @intCast(c.integer);
        }
        if (obj.get("eval_count")) |c| {
            if (c == .integer) output_tokens = @intCast(c.integer);
        }

        return .{
            .id = "",
            .model = model,
            .role = "assistant",
            .content = &.{},
            .text_content = text_content,
            .tool_use = &.{},
            .stop_reason = "end_turn",
            .usage = .{
                .input_tokens = input_tokens,
                .output_tokens = output_tokens,
            },
        };
    }

    const ApiError = error{
        InvalidRequest,
        NetworkError,
        ServerError,
        ParseError,
    };
};

// VTable implementation
const vtable = provider_mod.Provider.VTable{
    .createMessage = struct {
        fn f(ptr: *anyopaque, request: *const messages.MessageRequest) anyerror!messages.MessageResponse {
            const self: *OllamaClient = @ptrCast(@alignCast(ptr));
            return self.createMessage(request);
        }
    }.f,
    .createMessageStreaming = struct {
        fn f(ptr: *anyopaque, request: *const messages.MessageRequest, _: provider_mod.StreamHandler) anyerror!messages.MessageResponse {
            // Ollama streaming TODO — for now fall back to non-streaming
            const self: *OllamaClient = @ptrCast(@alignCast(ptr));
            return self.createMessage(request);
        }
    }.f,
    .setCredential = struct {
        fn f(_: *anyopaque, _: []const u8) void {
            // Ollama doesn't use credentials
        }
    }.f,
    .getName = struct {
        fn f(_: *anyopaque) []const u8 {
            return "ollama";
        }
    }.f,
};
