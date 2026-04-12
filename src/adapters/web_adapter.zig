const std = @import("std");
const common = @import("common");
const core = @import("core");
const adapter_mod = @import("adapter.zig");

/// Web adapter: HTTP server with JSON API and SSE streaming.
/// Serves the web UI at / and API at /api/*.
pub const WebAdapter = struct {
    allocator: std.mem.Allocator,
    config: *const common.Config,
    engine: *core.Engine,
    server: ?std.net.Server,
    running: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const common.Config,
        engine_ptr: *core.Engine,
    ) WebAdapter {
        return .{
            .allocator = allocator,
            .config = config,
            .engine = engine_ptr,
            .server = null,
            .running = false,
        };
    }

    pub fn adapter(self: *WebAdapter) adapter_mod.Adapter {
        return .{
            .name = "web",
            .display_name = "Web UI",
            .version = "0.2.0",
            .ptr = @ptrCast(self),
            .vtable = &.{
                .start = start,
                .run = run,
                .stop = stop,
            },
        };
    }

    fn start(ptr: *anyopaque) !void {
        const self: *WebAdapter = @ptrCast(@alignCast(ptr));

        const address = std.net.Address.parseIp4(self.config.web.host, self.config.web.port) catch {
            std.log.err("Invalid web server address: {s}:{d}", .{ self.config.web.host, self.config.web.port });
            return error.InvalidAddress;
        };

        self.server = try address.listen(.{ .reuse_address = true });
        self.running = true;

        std.log.info("Web adapter listening on http://{s}:{d}", .{ self.config.web.host, self.config.web.port });
    }

    fn run(ptr: *anyopaque) void {
        const self: *WebAdapter = @ptrCast(@alignCast(ptr));
        while (self.running) {
            if (self.server) |*server| {
                const conn = server.accept() catch |err| {
                    if (!self.running) return;
                    std.log.debug("Web accept error: {}", .{err});
                    continue;
                };
                self.handleConnection(conn) catch |err| {
                    std.log.debug("Web request error: {}", .{err});
                };
            } else return;
        }
    }

    fn stop(ptr: *anyopaque) void {
        const self: *WebAdapter = @ptrCast(@alignCast(ptr));
        self.running = false;
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }
    }

    // -- HTTP handling (same as daemon/web.zig, refactored here) --

    fn handleConnection(self: *WebAdapter, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();

        var buf: [8192]u8 = undefined;
        const n = conn.stream.read(&buf) catch return;
        if (n == 0) return;

        const request = buf[0..n];
        const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
        const first_line = request[0..first_line_end];

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n");
        const body = if (body_start) |s| request[s + 4 ..] else "";

        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            try self.serveIndex(conn.stream);
        } else if (std.mem.eql(u8, path, "/api/chat/stream")) {
            try self.handleApiChatStream(conn.stream, method, body);
        } else if (std.mem.startsWith(u8, path, "/api/chat")) {
            try self.handleApiChat(conn.stream, method, body);
        } else if (std.mem.startsWith(u8, path, "/api/messages")) {
            try self.handleApiMessages(conn.stream, path);
        } else if (std.mem.startsWith(u8, path, "/api/sessions")) {
            try self.handleApiSessions(conn.stream, method, path, body);
        } else if (std.mem.startsWith(u8, path, "/api/skills")) {
            try self.handleApiSkills(conn.stream, method, body);
        } else if (std.mem.eql(u8, path, "/api/status")) {
            try self.handleApiStatus(conn.stream);
        } else if (std.mem.eql(u8, path, "/api/projects")) {
            try self.handleApiProjects(conn.stream);
        } else if (std.mem.startsWith(u8, path, "/api/tools/register")) {
            try self.handleApiToolRegister(conn.stream, body);
        } else if (std.mem.eql(u8, path, "/api/tools")) {
            if (std.mem.eql(u8, method, "POST")) {
                try self.handleApiToolToggle(conn.stream, body);
            } else {
                try self.handleApiTools(conn.stream);
            }
        } else if (std.mem.eql(u8, path, "/api/persona")) {
            try self.handleApiPersona(conn.stream, method, body);
        } else {
            try self.serve404(conn.stream);
        }
    }

    fn sendHttp(self: *WebAdapter, stream: std.net.Stream, status: []const u8, content_type: []const u8, http_body: []const u8) !void {
        _ = self;
        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
            .{ status, content_type, http_body.len },
        ) catch return;
        _ = stream.write(header) catch return;
        _ = stream.write(http_body) catch return;
    }

    fn serveIndex(self: *WebAdapter, stream: std.net.Stream) !void {
        const html = @embedFile("web/index.html");
        try self.sendHttp(stream, "200 OK", "text/html; charset=utf-8", html);
    }

    fn handleApiChat(self: *WebAdapter, stream: std.net.Stream, method: []const u8, body: []const u8) !void {
        if (!std.mem.eql(u8, method, "POST")) {
            try self.sendHttp(stream, "405 Method Not Allowed", "text/plain", "Method Not Allowed");
            return;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_always,
        }) catch {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid JSON\"}");
            return;
        };
        defer parsed.deinit();

        const message = if (parsed.value.object.get("message")) |m| m.string else {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing message\"}");
            return;
        };

        const result = self.engine.process(.{ .chat = .{ .message = message } }, null, null);

        switch (result) {
            .chat => |chat| {
                // Dynamic buffer: text can be arbitrarily large
                var json_out: std.ArrayList(u8) = .{};
                defer json_out.deinit(self.allocator);

                // Reserve estimated capacity: text + JSON overhead
                json_out.ensureTotalCapacity(self.allocator, chat.text.len * 2 + 256) catch {};

                json_out.appendSlice(self.allocator, "{\"ok\":true,\"text\":\"") catch {};
                for (chat.text) |c| {
                    switch (c) {
                        '"' => json_out.appendSlice(self.allocator, "\\\"") catch {},
                        '\\' => json_out.appendSlice(self.allocator, "\\\\") catch {},
                        '\n' => json_out.appendSlice(self.allocator, "\\n") catch {},
                        '\r' => json_out.appendSlice(self.allocator, "\\r") catch {},
                        '\t' => json_out.appendSlice(self.allocator, "\\t") catch {},
                        else => json_out.append(self.allocator, c) catch {},
                    }
                }
                json_out.appendSlice(self.allocator, "\",\"model\":\"") catch {};
                json_out.appendSlice(self.allocator, chat.model) catch {};
                var num_buf: [32]u8 = undefined;
                json_out.appendSlice(self.allocator, "\",\"usage\":{\"input_tokens\":") catch {};
                const in_str = std.fmt.bufPrint(&num_buf, "{d}", .{chat.input_tokens}) catch "0";
                json_out.appendSlice(self.allocator, in_str) catch {};
                json_out.appendSlice(self.allocator, ",\"output_tokens\":") catch {};
                const out_str = std.fmt.bufPrint(&num_buf, "{d}", .{chat.output_tokens}) catch "0";
                json_out.appendSlice(self.allocator, out_str) catch {};
                json_out.appendSlice(self.allocator, ",\"context_tokens\":") catch {};
                const ctx_str = std.fmt.bufPrint(&num_buf, "{d}", .{chat.context_tokens}) catch "0";
                json_out.appendSlice(self.allocator, ctx_str) catch {};
                json_out.appendSlice(self.allocator, "}}") catch {};

                try self.sendHttp(stream, "200 OK", "application/json", json_out.items);
            },
            .response => |resp| {
                switch (resp) {
                    .error_resp => |err| {
                        var err_buf: [256]u8 = undefined;
                        const err_json = std.fmt.bufPrint(&err_buf, "{{\"error\":\"{s}\"}}", .{err.message}) catch "{\"error\":\"Internal error\"}";
                        try self.sendHttp(stream, "500 Internal Server Error", "application/json", err_json);
                    },
                    else => try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Unexpected response\"}"),
                }
            },
        }
    }

    /// SSE emitter context — holds the HTTP stream and allocator for building SSE events.
    const SSEContext = struct {
        stream: std.net.Stream,
        allocator: std.mem.Allocator,
    };

    /// Callback that writes Response events as SSE to the HTTP stream in real time.
    fn sseEmitCallback(ctx: *anyopaque, response: common.Response) void {
        const sse_ctx: *SSEContext = @ptrCast(@alignCast(ctx));

        switch (response) {
            .stream_text => |text| {
                // Build SSE event: data: {"type":"text","text":"...delta..."}\n\n
                var buf: std.ArrayList(u8) = .{};
                defer buf.deinit(sse_ctx.allocator);
                buf.appendSlice(sse_ctx.allocator, "data: {\"type\":\"text\",\"text\":\"") catch return;
                for (text) |ch| {
                    switch (ch) {
                        '"' => buf.appendSlice(sse_ctx.allocator, "\\\"") catch {},
                        '\\' => buf.appendSlice(sse_ctx.allocator, "\\\\") catch {},
                        '\n' => buf.appendSlice(sse_ctx.allocator, "\\n") catch {},
                        '\r' => buf.appendSlice(sse_ctx.allocator, "\\r") catch {},
                        else => buf.append(sse_ctx.allocator, ch) catch {},
                    }
                }
                buf.appendSlice(sse_ctx.allocator, "\"}\n\n") catch return;
                _ = sse_ctx.stream.write(buf.items) catch {};
            },
            .stream_tool_use => |tool| {
                var buf: std.ArrayList(u8) = .{};
                defer buf.deinit(sse_ctx.allocator);
                buf.appendSlice(sse_ctx.allocator, "data: {\"type\":\"tool_use\",\"tool_name\":\"") catch return;
                buf.appendSlice(sse_ctx.allocator, tool.tool_name) catch return;
                buf.appendSlice(sse_ctx.allocator, "\",\"tool_id\":\"") catch return;
                buf.appendSlice(sse_ctx.allocator, tool.tool_id) catch return;
                buf.appendSlice(sse_ctx.allocator, "\",\"input\":\"") catch return;
                // JSON-escape the input
                for (tool.input) |ch| {
                    switch (ch) {
                        '"' => buf.appendSlice(sse_ctx.allocator, "\\\"") catch {},
                        '\\' => buf.appendSlice(sse_ctx.allocator, "\\\\") catch {},
                        '\n' => buf.appendSlice(sse_ctx.allocator, "\\n") catch {},
                        '\r' => buf.appendSlice(sse_ctx.allocator, "\\r") catch {},
                        else => buf.append(sse_ctx.allocator, ch) catch {},
                    }
                }
                buf.appendSlice(sse_ctx.allocator, "\"}\n\n") catch return;
                _ = sse_ctx.stream.write(buf.items) catch {};
            },
            .stream_tool_result => |result| {
                var buf: std.ArrayList(u8) = .{};
                defer buf.deinit(sse_ctx.allocator);
                buf.appendSlice(sse_ctx.allocator, "data: {\"type\":\"tool_result\",\"tool_id\":\"") catch return;
                buf.appendSlice(sse_ctx.allocator, result.tool_id) catch return;
                buf.appendSlice(sse_ctx.allocator, "\",\"is_error\":") catch return;
                buf.appendSlice(sse_ctx.allocator, if (result.is_error) "true" else "false") catch return;
                // Include truncated result for dropdown
                buf.appendSlice(sse_ctx.allocator, ",\"result\":\"") catch return;
                const max_result = @min(result.result.len, 2000);
                for (result.result[0..max_result]) |ch| {
                    switch (ch) {
                        '"' => buf.appendSlice(sse_ctx.allocator, "\\\"") catch {},
                        '\\' => buf.appendSlice(sse_ctx.allocator, "\\\\") catch {},
                        '\n' => buf.appendSlice(sse_ctx.allocator, "\\n") catch {},
                        '\r' => buf.appendSlice(sse_ctx.allocator, "\\r") catch {},
                        else => if (ch >= 0x20) { buf.append(sse_ctx.allocator, ch) catch {}; },
                    }
                }
                buf.appendSlice(sse_ctx.allocator, "\"}\n\n") catch return;
                _ = sse_ctx.stream.write(buf.items) catch {};
            },
            else => {},
        }
    }

    fn handleApiChatStream(self: *WebAdapter, stream: std.net.Stream, method: []const u8, body: []const u8) !void {
        if (!std.mem.eql(u8, method, "POST")) {
            try self.sendHttp(stream, "405 Method Not Allowed", "text/plain", "Method Not Allowed");
            return;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_always,
        }) catch {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid JSON\"}");
            return;
        };
        defer parsed.deinit();

        const message = if (parsed.value.object.get("message")) |m| m.string else {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing message\"}");
            return;
        };

        // Disable Nagle buffering — SSE events must flush immediately
        const fd: std.posix.fd_t = stream.handle;
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.os.linux.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

        // SSE headers
        const header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nX-Accel-Buffering: no\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n";
        _ = stream.write(header) catch return;

        // Real streaming: emitter writes SSE events to the HTTP stream as text deltas arrive.
        var sse_ctx = SSEContext{ .stream = stream, .allocator = self.allocator };
        const emitter = core.Engine.StreamEmitter{
            .ctx = @ptrCast(&sse_ctx),
            .emitFn = &sseEmitCallback,
        };

        // Hold the compaction gate open for the entire SSE session so background
        // summarization cannot mutate the message store while we are still streaming.
        self.engine.beginStreaming();
        const result = self.engine.process(.{ .chat = .{ .message = message } }, emitter, null);

        // After streaming completes, send done event with final metadata
        switch (result) {
            .chat => |chat| {
                var end_buf: std.ArrayList(u8) = .{};
                defer end_buf.deinit(self.allocator);
                var num_buf: [32]u8 = undefined;

                end_buf.appendSlice(self.allocator, "data: {\"type\":\"done\",\"model\":\"") catch {};
                end_buf.appendSlice(self.allocator, chat.model) catch {};
                end_buf.appendSlice(self.allocator, "\",\"input_tokens\":") catch {};
                const in_s = std.fmt.bufPrint(&num_buf, "{d}", .{chat.input_tokens}) catch "0";
                end_buf.appendSlice(self.allocator, in_s) catch {};
                end_buf.appendSlice(self.allocator, ",\"output_tokens\":") catch {};
                const out_s = std.fmt.bufPrint(&num_buf, "{d}", .{chat.output_tokens}) catch "0";
                end_buf.appendSlice(self.allocator, out_s) catch {};
                end_buf.appendSlice(self.allocator, ",\"context_tokens\":") catch {};
                const ctx_s = std.fmt.bufPrint(&num_buf, "{d}", .{chat.context_tokens}) catch "0";
                end_buf.appendSlice(self.allocator, ctx_s) catch {};
                end_buf.appendSlice(self.allocator, "}\n\n") catch {};
                _ = stream.write(end_buf.items) catch {};
            },
            .response => |resp| switch (resp) {
                .error_resp => |err| {
                    var err_buf: [256]u8 = undefined;
                    const err_event = std.fmt.bufPrint(&err_buf, "data: {{\"type\":\"error\",\"message\":\"{s}\"}}\n\n", .{err.message}) catch "";
                    _ = stream.write(err_event) catch {};
                },
                else => {},
            },
        }

        // Release the compaction gate — deferred summarizations can now run.
        self.engine.endStreaming();
    }

    fn handleApiSessions(self: *WebAdapter, stream: std.net.Stream, method: []const u8, path: []const u8, body: []const u8) !void {
        // POST sub-routes
        if (std.mem.eql(u8, method, "POST")) {
            if (std.mem.endsWith(u8, path, "/rename")) {
                return self.handleSessionAction(stream, body, "rename");
            } else if (std.mem.endsWith(u8, path, "/close")) {
                return self.handleSessionAction(stream, body, "close");
            } else if (std.mem.endsWith(u8, path, "/reopen")) {
                return self.handleSessionAction(stream, body, "reopen");
            } else if (std.mem.endsWith(u8, path, "/new")) {
                return self.handleSessionAction(stream, body, "new");
            } else if (std.mem.endsWith(u8, path, "/delete")) {
                return self.handleSessionAction(stream, body, "delete");
            } else if (std.mem.endsWith(u8, path, "/switch")) {
                return self.handleSessionAction(stream, body, "switch");
            }
        }

        // GET /api/sessions or /api/sessions?status=closed
        const status = blk: {
            if (std.mem.indexOf(u8, path, "status=closed")) |_| break :blk "closed";
            break :blk "active";
        };

        const sessions = self.engine.session_store.listSessionsByStatus(status) catch &.{};
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(self.allocator);
        out.append(self.allocator, '[') catch {};
        for (sessions, 0..) |sess, i| {
            if (i > 0) out.append(self.allocator, ',') catch {};
            out.appendSlice(self.allocator, "{\"id\":\"") catch {};
            out.appendSlice(self.allocator, sess.id) catch {};
            out.appendSlice(self.allocator, "\",\"name\":") catch {};
            if (sess.name) |n| {
                out.append(self.allocator, '"') catch {};
                // JSON-escape name
                for (n) |ch| {
                    switch (ch) {
                        '"' => out.appendSlice(self.allocator, "\\\"") catch {},
                        '\\' => out.appendSlice(self.allocator, "\\\\") catch {},
                        '\n' => out.appendSlice(self.allocator, "\\n") catch {},
                        else => out.append(self.allocator, ch) catch {},
                    }
                }
                out.append(self.allocator, '"') catch {};
            } else {
                out.appendSlice(self.allocator, "null") catch {};
            }
            var num_buf: [32]u8 = undefined;
            out.appendSlice(self.allocator, ",\"message_count\":") catch {};
            out.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{sess.message_count}) catch "0") catch {};
            out.appendSlice(self.allocator, ",\"updated_at\":") catch {};
            out.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{sess.updated_at}) catch "0") catch {};
            out.append(self.allocator, '}') catch {};
        }
        out.append(self.allocator, ']') catch {};
        try self.sendHttp(stream, "200 OK", "application/json", out.items);
    }

    fn handleSessionAction(self: *WebAdapter, stream: std.net.Stream, body: []const u8, action: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_always,
        }) catch {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid JSON\"}");
            return;
        };
        defer parsed.deinit();

        if (std.mem.eql(u8, action, "new")) {
            const name = if (parsed.value.object.get("name")) |n| (if (n == .string) n.string else null) else null;
            const new_sess = self.engine.session_store.createSession(name) catch {
                try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Failed to create session\"}");
                return;
            };
            // Return the new session ID so the UI can switch to it
            var resp_buf: [128]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf, "{{\"ok\":true,\"id\":\"{s}\"}}", .{new_sess.id}) catch "{\"ok\":true}";
            try self.sendHttp(stream, "200 OK", "application/json", resp);
            return;
        }

        const id = if (parsed.value.object.get("id")) |v| v.string else {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing id\"}");
            return;
        };

        if (std.mem.eql(u8, action, "rename")) {
            const name = if (parsed.value.object.get("name")) |v| v.string else {
                try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing name\"}");
                return;
            };
            self.engine.session_store.renameSession(id, name) catch {};
        } else if (std.mem.eql(u8, action, "close")) {
            self.engine.session_store.setSessionStatus(id, "closed") catch {};
        } else if (std.mem.eql(u8, action, "reopen")) {
            self.engine.session_store.setSessionStatus(id, "active") catch {};
        } else if (std.mem.eql(u8, action, "delete")) {
            self.engine.session_store.deleteSession(id) catch {};
        } else if (std.mem.eql(u8, action, "switch")) {
            self.engine.session_store.switchSession(id) catch {};
        }

        try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
    }

    fn handleApiSkills(self: *WebAdapter, stream: std.net.Stream, method: []const u8, body: []const u8) !void {
        if (std.mem.eql(u8, method, "POST")) {
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
                .allocate = .alloc_always,
            }) catch {
                try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid JSON\"}");
                return;
            };
            defer parsed.deinit();

            // Check sub-action
            if (parsed.value.object.get("action")) |act| {
                if (std.mem.eql(u8, act.string, "toggle")) {
                    const id = if (parsed.value.object.get("id")) |v| @as(i64, @intFromFloat(v.float)) else {
                        try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing id\"}");
                        return;
                    };
                    const enabled = if (parsed.value.object.get("enabled")) |v| v.bool else true;
                    if (self.engine.skill_store) |ss| {
                        ss.setEnabled(id, enabled) catch {};
                    }
                    try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
                    return;
                } else if (std.mem.eql(u8, act.string, "delete")) {
                    const id = if (parsed.value.object.get("id")) |v| @as(i64, @intFromFloat(v.float)) else {
                        try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing id\"}");
                        return;
                    };
                    if (self.engine.skill_store) |ss| {
                        ss.delete(id) catch {};
                    }
                    try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
                    return;
                }
            }

            // Create new skill
            const name = if (parsed.value.object.get("name")) |v| v.string else {
                try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing name\"}");
                return;
            };
            const instruction = if (parsed.value.object.get("instruction")) |v| v.string else {
                try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing instruction\"}");
                return;
            };

            if (self.engine.skill_store) |ss| {
                _ = ss.create(.{
                    .name = name,
                    .category = if (parsed.value.object.get("category")) |v| v.string else "general",
                    .trigger_type = if (parsed.value.object.get("trigger_type")) |v| v.string else "always",
                    .trigger_value = if (parsed.value.object.get("trigger_value")) |v| v.string else null,
                    .instruction = instruction,
                    .priority = if (parsed.value.object.get("priority")) |v| @as(i64, @intFromFloat(v.float)) else 0,
                }) catch {
                    try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Failed to create skill\"}");
                    return;
                };
            }
            try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
            return;
        }

        // GET — list all skills
        if (self.engine.skill_store) |ss| {
            const skills = ss.list(100) catch &.{};
            var out: std.ArrayList(u8) = .{};
            defer out.deinit(self.allocator);
            out.append(self.allocator, '[') catch {};
            for (skills, 0..) |skill, i| {
                if (i > 0) out.append(self.allocator, ',') catch {};
                var num_buf: [32]u8 = undefined;
                out.appendSlice(self.allocator, "{\"id\":") catch {};
                out.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{skill.id}) catch "0") catch {};
                out.appendSlice(self.allocator, ",\"name\":\"") catch {};
                out.appendSlice(self.allocator, skill.name) catch {};
                out.appendSlice(self.allocator, "\",\"category\":\"") catch {};
                out.appendSlice(self.allocator, skill.category) catch {};
                out.appendSlice(self.allocator, "\",\"trigger_type\":\"") catch {};
                out.appendSlice(self.allocator, skill.trigger_type) catch {};
                out.appendSlice(self.allocator, "\",\"trigger_value\":") catch {};
                if (skill.trigger_value) |tv| {
                    out.append(self.allocator, '"') catch {};
                    out.appendSlice(self.allocator, tv) catch {};
                    out.append(self.allocator, '"') catch {};
                } else {
                    out.appendSlice(self.allocator, "null") catch {};
                }
                out.appendSlice(self.allocator, ",\"instruction\":\"") catch {};
                // JSON-escape instruction
                for (skill.instruction) |ch| {
                    switch (ch) {
                        '"' => out.appendSlice(self.allocator, "\\\"") catch {},
                        '\\' => out.appendSlice(self.allocator, "\\\\") catch {},
                        '\n' => out.appendSlice(self.allocator, "\\n") catch {},
                        '\r' => {},
                        else => out.append(self.allocator, ch) catch {},
                    }
                }
                out.appendSlice(self.allocator, "\",\"priority\":") catch {};
                out.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{skill.priority}) catch "0") catch {};
                out.appendSlice(self.allocator, ",\"enabled\":") catch {};
                out.appendSlice(self.allocator, if (skill.enabled) "true" else "false") catch {};
                out.append(self.allocator, '}') catch {};
            }
            out.append(self.allocator, ']') catch {};
            try self.sendHttp(stream, "200 OK", "application/json", out.items);
        } else {
            try self.sendHttp(stream, "200 OK", "application/json", "[]");
        }
    }

    fn handleApiStatus(self: *WebAdapter, stream: std.net.Stream) !void {
        const result = self.engine.process(.{ .status = {} }, null, null);
        switch (result) {
            .response => |resp| switch (resp) {
                .status => |status| {
                    var json_buf: [512]u8 = undefined;
                    const json_resp = std.fmt.bufPrint(&json_buf,
                        \\{{"version":"{s}","active_sessions":{d},"uptime_seconds":{d}}}
                    , .{ status.version, status.active_sessions, status.uptime_seconds }) catch "{\"error\":\"Status error\"}";
                    try self.sendHttp(stream, "200 OK", "application/json", json_resp);
                },
                else => try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Unexpected\"}"),
            },
            else => try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Unexpected\"}"),
        }
    }

    fn handleApiProjects(self: *WebAdapter, stream: std.net.Stream) !void {
        const result = self.engine.process(.{ .project_list = {} }, null, null);
        switch (result) {
            .response => |resp| switch (resp) {
                .project_list => |projects| {
                    var json_buf: [8192]u8 = undefined;
                    var pos: usize = 0;
                    json_buf[pos] = '[';
                    pos += 1;
                    for (projects, 0..) |proj, i| {
                        if (i > 0) { json_buf[pos] = ','; pos += 1; }
                        var num_buf: [32]u8 = undefined;
                        const id_str = std.fmt.bufPrint(&num_buf, "{d}", .{proj.id}) catch "0";
                        const entry = std.fmt.bufPrint(json_buf[pos..],
                            \\{{"id":{s},"name":"{s}","status":"{s}"}}
                        , .{ id_str, proj.name, proj.status }) catch break;
                        pos += entry.len;
                    }
                    json_buf[pos] = ']';
                    pos += 1;
                    try self.sendHttp(stream, "200 OK", "application/json", json_buf[0..pos]);
                },
                else => try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Unexpected\"}"),
            },
            else => try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Unexpected\"}"),
        }
    }

    fn handleApiToolToggle(self: *WebAdapter, stream: std.net.Stream, body: []const u8) !void {
        // Parse {"name": "tool_name", "enabled": true/false}
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_always,
        }) catch {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid JSON\"}");
            return;
        };
        defer parsed.deinit();

        const name = if (parsed.value.object.get("name")) |n| (if (n == .string) n.string else null) else null;
        const enabled = if (parsed.value.object.get("enabled")) |e| (if (e == .bool) e.bool else null) else null;

        if (name == null or enabled == null) {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Need name and enabled fields\"}");
            return;
        }

        if (enabled.?) {
            self.engine.tool_registry.enable(name.?) catch {};
            std.log.info("Tool enabled via web: {s}", .{name.?});
        } else {
            self.engine.tool_registry.disable(name.?);
            std.log.info("Tool disabled via web: {s}", .{name.?});
        }

        try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
    }

    fn handleApiTools(self: *WebAdapter, stream: std.net.Stream) !void {
        // Return all registered tools with live enabled status from the registry
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(self.allocator);

        out.appendSlice(self.allocator, "[") catch {};
        var it = self.engine.tool_registry.tools.keyIterator();
        var first = true;
        while (it.next()) |name| {
            if (!first) out.appendSlice(self.allocator, ",") catch {};
            first = false;
            const is_enabled = self.engine.tool_registry.isEnabled(name.*);
            const needs_confirm = self.engine.tool_registry.requiresConfirmation(name.*);
            out.appendSlice(self.allocator, "{\"name\":\"") catch {};
            out.appendSlice(self.allocator, name.*) catch {};
            out.appendSlice(self.allocator, "\",\"enabled\":") catch {};
            out.appendSlice(self.allocator, if (is_enabled) "true" else "false") catch {};
            out.appendSlice(self.allocator, ",\"requires_confirmation\":") catch {};
            out.appendSlice(self.allocator, if (needs_confirm) "true" else "false") catch {};
            out.appendSlice(self.allocator, "}") catch {};
        }
        out.appendSlice(self.allocator, "]") catch {};

        try self.sendHttp(stream, "200 OK", "application/json", out.items);
    }

    /// Register a script-based tool at runtime (no rebuild needed).
    /// POST /api/tools/register {name, description, input_schema, script_path, language, requires_confirmation}
    fn handleApiToolRegister(self: *WebAdapter, stream: std.net.Stream, body: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_always,
        }) catch {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid JSON\"}");
            return;
        };
        defer parsed.deinit();

        const name = if (parsed.value.object.get("name")) |v| v.string else {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing name\"}");
            return;
        };
        const description = if (parsed.value.object.get("description")) |v| v.string else "A generated tool";
        const script_path = if (parsed.value.object.get("script_path")) |v| v.string else {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing script_path\"}");
            return;
        };
        const language = if (parsed.value.object.get("language")) |v| v.string else "python";
        const schema = if (parsed.value.object.get("input_schema")) |v| v.string else
            \\{"type":"object","properties":{}}
        ;
        const needs_confirm = if (parsed.value.object.get("requires_confirmation")) |v| v.bool else true;

        // Dupe strings to outlive parsed JSON
        const d_name = self.allocator.dupe(u8, name) catch {
            try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Alloc failed\"}");
            return;
        };
        const d_desc = self.allocator.dupe(u8, description) catch d_name;
        const d_path = self.allocator.dupe(u8, script_path) catch d_name;
        const d_lang = self.allocator.dupe(u8, language) catch "python";
        const d_schema = self.allocator.dupe(u8, schema) catch "{}";

        self.engine.tool_registry.register(.{
            .name = d_name,
            .description = d_desc,
            .input_schema_json = d_schema,
            .requires_confirmation = needs_confirm,
            .handler = null,
            .script_path = d_path,
            .script_lang = d_lang,
        }) catch {
            try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Registration failed\"}");
            return;
        };
        self.engine.tool_registry.enable(d_name) catch {};

        std.log.info("Registered runtime tool: {s} -> {s}", .{ d_name, d_path });
        try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
    }

    /// GET /api/persona — list personas + current session's active persona name
    /// POST /api/persona {action, name, content?}
    ///   action=select: set active persona for session
    ///   action=create: create new persona file
    ///   action=delete: delete persona file
    fn handleApiPersona(self: *WebAdapter, stream: std.net.Stream, method: []const u8, body: []const u8) !void {
        const prompt_mod = @import("core").prompt;

        if (std.mem.eql(u8, method, "GET")) {
            // Return list of available personas + which one is active
            const personas = try prompt_mod.listPersonas(self.allocator);
            defer {
                for (personas) |name| self.allocator.free(name);
                self.allocator.free(personas);
            }

            // Get active persona name from session
            var active_name: []const u8 = "default";
            var _sess_info = if (self.engine.session_store.active_session_id) |sid|
                (self.engine.session_store.getSession(&sid) catch null)
            else
                null;
            if (_sess_info) |si| {
                if (si.system_prompt) |sp| active_name = sp;
            }
            defer if (_sess_info) |*si| self.engine.session_store.freeSessionInfo(si);

            var out: std.ArrayList(u8) = .{};
            defer out.deinit(self.allocator);
            out.appendSlice(self.allocator, "{\"active\":\"") catch {};
            out.appendSlice(self.allocator, active_name) catch {};
            out.appendSlice(self.allocator, "\"") catch {};
            out.appendSlice(self.allocator, ",\"personas\":[") catch {};
            for (personas, 0..) |name, i| {
                if (i > 0) out.appendSlice(self.allocator, ",") catch {};
                out.appendSlice(self.allocator, "\"") catch {};
                out.appendSlice(self.allocator, name) catch {};
                out.appendSlice(self.allocator, "\"") catch {};
            }
            out.appendSlice(self.allocator, "]}") catch {};
            try self.sendHttp(stream, "200 OK", "application/json", out.items);
            return;
        }

        if (!std.mem.eql(u8, method, "POST")) {
            try self.sendHttp(stream, "405 Method Not Allowed", "text/plain", "Method Not Allowed");
            return;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_always,
        }) catch {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid JSON\"}");
            return;
        };
        defer parsed.deinit();

        const obj = if (parsed.value == .object) parsed.value.object else {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Expected object\"}");
            return;
        };

        const action = if (obj.get("action")) |a| (if (a == .string) a.string else "select") else "select";
        const name = if (obj.get("name")) |n| (if (n == .string) n.string else null) else null;

        if (std.mem.eql(u8, action, "select")) {
            // Set active persona for current session (null or "default" = default)
            const session_id = self.engine.session_store.active_session_id orelse {
                try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"No active session\"}");
                return;
            };
            const persona_name: ?[]const u8 = if (name) |n| (if (std.mem.eql(u8, n, "default")) null else n) else null;
            self.engine.session_store.updateSystemPrompt(&session_id, persona_name) catch {
                try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Failed to update\"}");
                return;
            };
            try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
        } else if (std.mem.eql(u8, action, "create")) {
            const content = if (obj.get("content")) |c| (if (c == .string) c.string else null) else null;
            if (name == null or content == null) {
                try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Need name and content\"}");
                return;
            }
            prompt_mod.savePersona(self.allocator, name.?, content.?) catch {
                try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Failed to save\"}");
                return;
            };
            try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
        } else if (std.mem.eql(u8, action, "delete")) {
            if (name == null) {
                try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Need name\"}");
                return;
            }
            prompt_mod.deletePersona(self.allocator, name.?) catch {
                try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Cannot delete\"}");
                return;
            };
            try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
        } else {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Unknown action\"}");
        }
    }

    fn handleApiMessages(self: *WebAdapter, stream: std.net.Stream, path: []const u8) !void {
        // Parse session_id from query string: /api/messages?session_id=UUID
        const session_id = blk: {
            if (std.mem.indexOf(u8, path, "session_id=")) |idx| {
                const param_start = idx + "session_id=".len;
                const rest = path[param_start..];
                // Take until & or end
                const end = std.mem.indexOf(u8, rest, "&") orelse rest.len;
                if (end >= 36) break :blk rest[0..36];
            }
            // No session_id — return messages from current/latest session
            break :blk @as(?[]const u8, null);
        };

        // Query messages via sqlite3
        const db_path = "/home/garward/Scripts/Tools/ClawForge/data/workspace.db";
        var query_buf: [512]u8 = undefined;
        const query = if (session_id) |sid|
            std.fmt.bufPrint(&query_buf,
                "SELECT role, content, datetime(created_at, 'unixepoch') as created_at, " ++
                "model_used, input_tokens, output_tokens " ++
                "FROM messages WHERE session_id = '{s}' ORDER BY sequence ASC;",
                .{sid},
            ) catch ""
        else
            std.fmt.bufPrint(&query_buf,
                "SELECT role, content, datetime(created_at, 'unixepoch') as created_at, " ++
                "model_used, input_tokens, output_tokens " ++
                "FROM messages WHERE session_id = (" ++
                "SELECT id FROM sessions WHERE status='active' ORDER BY updated_at DESC LIMIT 1" ++
                ") ORDER BY sequence ASC;",
                .{},
            ) catch "";

        if (query.len == 0) {
            try self.sendHttp(stream, "200 OK", "application/json", "[]");
            return;
        }

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "sqlite3", "-json", "-readonly", db_path, query },
            .max_output_bytes = 1024 * 1024,
        }) catch {
            try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"DB query failed\"}");
            return;
        };

        defer self.allocator.free(result.stderr);

        if (result.stdout.len == 0) {
            try self.sendHttp(stream, "200 OK", "application/json", "[]");
            self.allocator.free(result.stdout);
            return;
        }

        try self.sendHttp(stream, "200 OK", "application/json", result.stdout);
        self.allocator.free(result.stdout);
    }

    fn serve404(self: *WebAdapter, stream: std.net.Stream) !void {
        try self.sendHttp(stream, "404 Not Found", "text/plain", "Not Found");
    }
};
