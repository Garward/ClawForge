const std = @import("std");
const posix = std.posix;
const common = @import("common");
const core = @import("core");

/// HTTP adapter: translates HTTP requests to Engine calls, formats responses as JSON.
pub const WebServer = struct {
    allocator: std.mem.Allocator,
    config: *const common.Config,
    engine: *core.Engine,
    server: ?std.net.Server,
    running: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const common.Config,
        engine_ptr: *core.Engine,
    ) WebServer {
        return .{
            .allocator = allocator,
            .config = config,
            .engine = engine_ptr,
            .server = null,
            .running = false,
        };
    }

    pub fn start(self: *WebServer) !void {
        const address = std.net.Address.parseIp4(self.config.web.host, self.config.web.port) catch {
            std.log.err("Invalid web server address: {s}:{d}", .{ self.config.web.host, self.config.web.port });
            return error.InvalidAddress;
        };

        self.server = try address.listen(.{
            .reuse_address = true,
        });

        self.running = true;
        std.log.info("Web server listening on http://{s}:{d}", .{ self.config.web.host, self.config.web.port });
    }

    pub fn stop(self: *WebServer) void {
        self.running = false;
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }
    }

    pub fn acceptOne(self: *WebServer) !void {
        if (self.server) |*server| {
            const conn = server.accept() catch |err| {
                if (!self.running) return;
                return err;
            };

            self.handleConnection(conn) catch |err| {
                std.log.debug("Web request error: {}", .{err});
            };
        }
    }

    fn handleConnection(self: *WebServer, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();

        // Read HTTP request
        var buf: [8192]u8 = undefined;
        const n = conn.stream.read(&buf) catch return;
        if (n == 0) return;

        const request = buf[0..n];

        // Parse first line
        const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
        const first_line = request[0..first_line_end];

        // Parse method and path
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        // Find body (after \r\n\r\n)
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n");
        const body = if (body_start) |s| request[s + 4 ..] else "";

        // Route
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            try self.serveIndex(conn.stream);
        } else if (std.mem.eql(u8, path, "/api/chat/stream")) {
            try self.handleApiChatStream(conn.stream, method, body);
        } else if (std.mem.startsWith(u8, path, "/api/chat")) {
            try self.handleApiChat(conn.stream, method, body);
        } else if (std.mem.eql(u8, path, "/api/sessions")) {
            try self.handleApiSessions(conn.stream);
        } else if (std.mem.eql(u8, path, "/api/status")) {
            try self.handleApiStatus(conn.stream);
        } else {
            try self.serve404(conn.stream);
        }
    }

    fn sendHttpResponse(self: *WebServer, stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
        _ = self;
        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
            .{ status, content_type, body.len },
        ) catch return;

        _ = stream.write(header) catch return;
        _ = stream.write(body) catch return;
    }

    fn serveIndex(self: *WebServer, stream: std.net.Stream) !void {
        const html = @embedFile("web/index.html");
        try self.sendHttpResponse(stream, "200 OK", "text/html; charset=utf-8", html);
    }

    fn handleApiChat(self: *WebServer, stream: std.net.Stream, method: []const u8, body: []const u8) !void {
        if (!std.mem.eql(u8, method, "POST")) {
            try self.sendHttpResponse(stream, "405 Method Not Allowed", "text/plain", "Method Not Allowed");
            return;
        }

        // Parse JSON body
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_always,
        }) catch {
            try self.sendHttpResponse(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid JSON\"}");
            return;
        };
        defer parsed.deinit();

        const message = if (parsed.value.object.get("message")) |m| m.string else {
            try self.sendHttpResponse(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing message\"}");
            return;
        };

        // Delegate to engine (non-streaming for regular POST)
        const result = self.engine.process(.{ .chat = .{
            .message = message,
        } }, null, null);

        switch (result) {
            .chat => |chat| {
                // Build JSON response
                var json_buf: [65536]u8 = undefined;
                var pos: usize = 0;

                const write = struct {
                    fn f(buf: []u8, p: *usize, data: []const u8) void {
                        @memcpy(buf[p.*..][0..data.len], data);
                        p.* += data.len;
                    }
                }.f;

                write(&json_buf, &pos, "{\"ok\":true,\"text\":\"");

                // Escape text content
                for (chat.text) |c| {
                    if (c == '"') {
                        write(&json_buf, &pos, "\\\"");
                    } else if (c == '\\') {
                        write(&json_buf, &pos, "\\\\");
                    } else if (c == '\n') {
                        write(&json_buf, &pos, "\\n");
                    } else if (c == '\r') {
                        write(&json_buf, &pos, "\\r");
                    } else if (c == '\t') {
                        write(&json_buf, &pos, "\\t");
                    } else {
                        json_buf[pos] = c;
                        pos += 1;
                    }
                }

                write(&json_buf, &pos, "\",\"usage\":{\"input_tokens\":");

                var num_buf: [32]u8 = undefined;
                const in_str = std.fmt.bufPrint(&num_buf, "{d}", .{chat.input_tokens}) catch "0";
                write(&json_buf, &pos, in_str);

                write(&json_buf, &pos, ",\"output_tokens\":");
                const out_str = std.fmt.bufPrint(&num_buf, "{d}", .{chat.output_tokens}) catch "0";
                write(&json_buf, &pos, out_str);

                write(&json_buf, &pos, "},\"model\":\"");
                write(&json_buf, &pos, chat.model);

                write(&json_buf, &pos, "\",\"stop_reason\":\"");
                write(&json_buf, &pos, chat.stop_reason orelse "unknown");
                write(&json_buf, &pos, "\"}");

                try self.sendHttpResponse(stream, "200 OK", "application/json", json_buf[0..pos]);
            },
            .response => |resp| {
                // Error response from engine
                switch (resp) {
                    .error_resp => |err| {
                        var err_buf: [256]u8 = undefined;
                        const err_json = std.fmt.bufPrint(&err_buf, "{{\"error\":\"{s}: {s}\"}}", .{ err.code, err.message }) catch "{\"error\":\"Internal error\"}";
                        try self.sendHttpResponse(stream, "500 Internal Server Error", "application/json", err_json);
                    },
                    else => {
                        try self.sendHttpResponse(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Unexpected response\"}");
                    },
                }
            },
        }
    }

    /// SSE streaming chat endpoint. Streams text deltas as SSE events.
    fn handleApiChatStream(self: *WebServer, stream: std.net.Stream, method: []const u8, body: []const u8) !void {
        if (!std.mem.eql(u8, method, "POST")) {
            try self.sendHttpResponse(stream, "405 Method Not Allowed", "text/plain", "Method Not Allowed");
            return;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_always,
        }) catch {
            try self.sendHttpResponse(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid JSON\"}");
            return;
        };
        defer parsed.deinit();

        const message = if (parsed.value.object.get("message")) |m| m.string else {
            try self.sendHttpResponse(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing message\"}");
            return;
        };

        // Send SSE headers
        const header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n";
        _ = stream.write(header) catch return;

        // Create emitter that writes SSE events to the HTTP stream
        const SseCtx = struct {
            net_stream: std.net.Stream,

            fn emitSse(ctx: *anyopaque, response: common.Response) void {
                const self_ctx: *@This() = @ptrCast(@alignCast(ctx));
                switch (response) {
                    .stream_text => |text| {
                        // SSE format: data: <json>\n\n
                        var buf: [16384]u8 = undefined;
                        var pos: usize = 0;
                        const prefix = "data: {\"type\":\"text\",\"text\":\"";
                        @memcpy(buf[pos..][0..prefix.len], prefix);
                        pos += prefix.len;

                        // Escape text for JSON
                        for (text) |c| {
                            if (c == '"') {
                                buf[pos] = '\\';
                                pos += 1;
                                buf[pos] = '"';
                                pos += 1;
                            } else if (c == '\\') {
                                buf[pos] = '\\';
                                pos += 1;
                                buf[pos] = '\\';
                                pos += 1;
                            } else if (c == '\n') {
                                buf[pos] = '\\';
                                pos += 1;
                                buf[pos] = 'n';
                                pos += 1;
                            } else {
                                buf[pos] = c;
                                pos += 1;
                            }
                            if (pos >= buf.len - 10) break;
                        }

                        const suffix = "\"}\n\n";
                        @memcpy(buf[pos..][0..suffix.len], suffix);
                        pos += suffix.len;

                        _ = self_ctx.net_stream.write(buf[0..pos]) catch {};
                    },
                    else => {},
                }
            }
        };

        var sse_ctx = SseCtx{ .net_stream = stream };
        const emitter = core.Engine.StreamEmitter{
            .ctx = @ptrCast(&sse_ctx),
            .emitFn = SseCtx.emitSse,
        };

        const result = self.engine.process(.{ .chat = .{
            .message = message,
        } }, emitter, null);

        // Send final event with metadata
        switch (result) {
            .chat => |chat| {
                var end_buf: [512]u8 = undefined;
                var num_buf: [32]u8 = undefined;
                var pos: usize = 0;

                const p1 = "data: {\"type\":\"done\",\"model\":\"";
                @memcpy(end_buf[pos..][0..p1.len], p1);
                pos += p1.len;
                @memcpy(end_buf[pos..][0..chat.model.len], chat.model);
                pos += chat.model.len;
                const p2 = "\",\"input_tokens\":";
                @memcpy(end_buf[pos..][0..p2.len], p2);
                pos += p2.len;
                const in_str = std.fmt.bufPrint(&num_buf, "{d}", .{chat.input_tokens}) catch "0";
                @memcpy(end_buf[pos..][0..in_str.len], in_str);
                pos += in_str.len;
                const p3 = ",\"output_tokens\":";
                @memcpy(end_buf[pos..][0..p3.len], p3);
                pos += p3.len;
                const out_str = std.fmt.bufPrint(&num_buf, "{d}", .{chat.output_tokens}) catch "0";
                @memcpy(end_buf[pos..][0..out_str.len], out_str);
                pos += out_str.len;
                const p4 = "}\n\n";
                @memcpy(end_buf[pos..][0..p4.len], p4);
                pos += p4.len;

                _ = stream.write(end_buf[0..pos]) catch {};
            },
            .response => |resp| {
                switch (resp) {
                    .error_resp => |err| {
                        var err_buf: [256]u8 = undefined;
                        const err_event = std.fmt.bufPrint(&err_buf, "data: {{\"type\":\"error\",\"code\":\"{s}\",\"message\":\"{s}\"}}\n\n", .{ err.code, err.message }) catch "data: {\"type\":\"error\"}\n\n";
                        _ = stream.write(err_event) catch {};
                    },
                    else => {},
                }
            },
        }
    }

    fn handleApiSessions(self: *WebServer, stream: std.net.Stream) !void {
        const result = self.engine.process(.{ .session_list = {} }, null, null);

        switch (result) {
            .response => |resp| switch (resp) {
                .session_list => |sessions| {
                    var json_buf: [16384]u8 = undefined;
                    var pos: usize = 0;

                    json_buf[pos] = '[';
                    pos += 1;

                    for (sessions, 0..) |sess, i| {
                        if (i > 0) {
                            json_buf[pos] = ',';
                            pos += 1;
                        }

                        const name_str = if (sess.name) |n| n else "";
                        const has_name = sess.name != null;

                        const entry = std.fmt.bufPrint(json_buf[pos..],
                            \\{{"id":"{s}","name":{s}"{s}"{s},"message_count":{d},"updated_at":{d}}}
                        , .{
                            sess.id,
                            if (has_name) "" else "null",
                            if (has_name) name_str else "",
                            if (has_name) "" else "",
                            sess.message_count,
                            sess.updated_at,
                        }) catch break;
                        pos += entry.len;
                    }

                    json_buf[pos] = ']';
                    pos += 1;

                    try self.sendHttpResponse(stream, "200 OK", "application/json", json_buf[0..pos]);
                },
                .error_resp => |err| {
                    var err_buf: [256]u8 = undefined;
                    const err_json = std.fmt.bufPrint(&err_buf, "{{\"error\":\"{s}\"}}", .{err.message}) catch "{\"error\":\"List error\"}";
                    try self.sendHttpResponse(stream, "500 Internal Server Error", "application/json", err_json);
                },
                else => {
                    try self.sendHttpResponse(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Unexpected response\"}");
                },
            },
            .chat => {
                try self.sendHttpResponse(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Unexpected response\"}");
            },
        }
    }

    fn handleApiStatus(self: *WebServer, stream: std.net.Stream) !void {
        const result = self.engine.process(.{ .status = {} }, null, null);

        switch (result) {
            .response => |resp| switch (resp) {
                .status => |status| {
                    var json_buf: [512]u8 = undefined;
                    const json_response = std.fmt.bufPrint(&json_buf,
                        \\{{"version":"{s}","active_sessions":{d},"uptime_seconds":{d}}}
                    , .{
                        status.version,
                        status.active_sessions,
                        status.uptime_seconds,
                    }) catch "{\"error\":\"Status error\"}";

                    try self.sendHttpResponse(stream, "200 OK", "application/json", json_response);
                },
                else => {
                    try self.sendHttpResponse(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Status error\"}");
                },
            },
            .chat => {
                try self.sendHttpResponse(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Unexpected response\"}");
            },
        }
    }

    fn serve404(self: *WebServer, stream: std.net.Stream) !void {
        try self.sendHttpResponse(stream, "404 Not Found", "text/plain", "Not Found");
    }
};
