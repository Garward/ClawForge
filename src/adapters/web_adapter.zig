const std = @import("std");
const common = @import("common");
const core = @import("core");
const storage = @import("storage");
const adapter_mod = @import("adapter.zig");

/// Web adapter: HTTP server with JSON API and SSE streaming.
/// Serves the web UI at / and API at /api/*.
pub const WebAdapter = struct {
    allocator: std.mem.Allocator,
    config: *const common.Config,
    engine: *core.Engine,
    /// Optional background-chat engine. When present, runtime config changes
    /// (e.g., /api/vision POST) are applied to both engines so subagents
    /// inherit the user's runtime choices.
    bg_engine: ?*core.Engine = null,
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
            .bg_engine = null,
            .server = null,
            .running = false,
        };
    }

    /// Attach a background-chat engine so /api/vision and other runtime
    /// config endpoints update both engines at once.
    pub fn setBgEngine(self: *WebAdapter, bg: *core.Engine) void {
        self.bg_engine = bg;
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

        // Read headers (first chunk — headers always fit in 8KB)
        var hdr_buf: [8192]u8 = undefined;
        const n = conn.stream.read(&hdr_buf) catch return;
        if (n == 0) return;

        const request = hdr_buf[0..n];
        const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
        const first_line = request[0..first_line_end];

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        const hdr_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return;
        const body_offset = hdr_end + 4;
        const initial_body = request[body_offset..];

        // Parse Content-Length from headers (case-insensitive)
        const content_length = parseContentLength(request[0..hdr_end]);

        // If the entire body arrived in the first read, use the stack buffer directly
        if (content_length <= initial_body.len) {
            const body = initial_body[0..@min(content_length, initial_body.len)];
            return self.dispatchRequest(conn.stream, method, path, body);
        }

        // Large body — allocate heap buffer, read remaining bytes
        const max_body: usize = 20 * 1024 * 1024; // 20 MB hard cap
        if (content_length > max_body) {
            try self.sendHttp(conn.stream, "413 Payload Too Large", "text/plain", "Body too large");
            return;
        }
        const full_body = self.allocator.alloc(u8, content_length) catch {
            try self.sendHttp(conn.stream, "500 Internal Server Error", "text/plain", "Out of memory");
            return;
        };
        defer self.allocator.free(full_body);

        @memcpy(full_body[0..initial_body.len], initial_body);
        var received: usize = initial_body.len;
        while (received < content_length) {
            const chunk = conn.stream.read(full_body[received..]) catch break;
            if (chunk == 0) break;
            received += chunk;
        }

        return self.dispatchRequest(conn.stream, method, path, full_body[0..received]);
    }

    fn parseContentLength(headers: []const u8) usize {
        var line_it = std.mem.splitSequence(u8, headers, "\r\n");
        while (line_it.next()) |line| {
            // Quick check: line must start with C/c and be long enough
            if (line.len < 16) continue;
            if (line[0] != 'C' and line[0] != 'c') continue;
            // Case-insensitive comparison of first 15/16 chars
            const prefix_with_space = "content-length: ";
            const prefix_no_space = "content-length:";
            var lower: [16]u8 = undefined;
            for (line[0..16], 0..) |ch, i| {
                lower[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            }
            if (std.mem.startsWith(u8, &lower, prefix_with_space)) {
                return std.fmt.parseInt(usize, std.mem.trim(u8, line[16..], " \t"), 10) catch 0;
            }
            if (std.mem.startsWith(u8, &lower, prefix_no_space)) {
                return std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \t"), 10) catch 0;
            }
        }
        return 0;
    }

    fn dispatchRequest(self: *WebAdapter, stream: std.net.Stream, method: []const u8, path: []const u8, body: []const u8) !void {
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            try self.serveIndex(stream);
        } else if (std.mem.eql(u8, path, "/api/chat/stream")) {
            try self.handleApiChatStream(stream, method, body);
        } else if (std.mem.eql(u8, path, "/api/chat/background")) {
            try self.handleApiChatBackground(stream, method, body);
        } else if (std.mem.startsWith(u8, path, "/api/background")) {
            try self.handleApiBackground(stream, method, path, body);
        } else if (std.mem.startsWith(u8, path, "/api/chat")) {
            try self.handleApiChat(stream, method, body);
        } else if (std.mem.startsWith(u8, path, "/api/messages")) {
            try self.handleApiMessages(stream, path);
        } else if (std.mem.startsWith(u8, path, "/api/sessions")) {
            try self.handleApiSessions(stream, method, path, body);
        } else if (std.mem.startsWith(u8, path, "/api/skills")) {
            try self.handleApiSkills(stream, method, body);
        } else if (std.mem.eql(u8, path, "/api/status")) {
            try self.handleApiStatus(stream);
        } else if (std.mem.eql(u8, path, "/api/projects")) {
            try self.handleApiProjects(stream);
        } else if (std.mem.startsWith(u8, path, "/api/tools/register")) {
            try self.handleApiToolRegister(stream, body);
        } else if (std.mem.eql(u8, path, "/api/tools/autoapprove")) {
            try self.handleApiToolAutoApprove(stream, method, body);
        } else if (std.mem.eql(u8, path, "/api/tools")) {
            if (std.mem.eql(u8, method, "POST")) {
                try self.handleApiToolToggle(stream, body);
            } else {
                try self.handleApiTools(stream);
            }
        } else if (std.mem.startsWith(u8, path, "/api/persona")) {
            try self.handleApiPersona(stream, method, path, body);
        } else if (std.mem.eql(u8, path, "/api/vision")) {
            try self.handleApiVision(stream, method, body);
        } else if (std.mem.eql(u8, path, "/api/models")) {
            try self.handleApiModels(stream);
        } else if (std.mem.eql(u8, path, "/api/upload")) {
            try self.handleApiUpload(stream, method, body);
        } else {
            try self.serve404(stream);
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

        const no_tools = if (parsed.value.object.get("no_tools")) |v| (v == .bool and v.bool) else false;
        const session_id = if (parsed.value.object.get("session_id")) |v| (if (v == .string) v.string else null) else null;
        const model_override = if (parsed.value.object.get("model_override")) |v| (if (v == .string) v.string else null) else null;
        const allowed_tools = if (parsed.value.object.get("allowed_tools")) |v| (if (v == .string) v.string else null) else null;
        const adapter_context = if (parsed.value.object.get("adapter_context")) |v| (if (v == .string) v.string else null) else null;
        const attachments = parseAttachments(self.allocator, parsed.value);
        defer if (attachments) |a| self.allocator.free(a);

        const result = self.engine.process(.{ .chat = .{
            .message = message,
            .session_id = session_id,
            .model_override = model_override,
            .no_tools = no_tools,
            .allowed_tools = allowed_tools,
            .adapter_context = adapter_context,
            .attachments = attachments,
        } }, null, null);

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
                if (chat.cache_read_tokens > 0 or chat.cache_creation_tokens > 0) {
                    json_out.appendSlice(self.allocator, ",\"cache_read_tokens\":") catch {};
                    json_out.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{chat.cache_read_tokens}) catch "0") catch {};
                    json_out.appendSlice(self.allocator, ",\"cache_creation_tokens\":") catch {};
                    json_out.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{chat.cache_creation_tokens}) catch "0") catch {};
                }
                json_out.appendSlice(self.allocator, "}") catch {};

                // Surface spawned subagent job IDs so adapters can poll them.
                if (chat.spawned_jobs) |jobs_csv| {
                    json_out.appendSlice(self.allocator, ",\"spawned_jobs\":[") catch {};
                    var first_job = true;
                    var iter = std.mem.splitScalar(u8, jobs_csv, ',');
                    while (iter.next()) |jid| {
                        if (jid.len == 0) continue;
                        if (!first_job) json_out.append(self.allocator, ',') catch {};
                        first_job = false;
                        json_out.append(self.allocator, '"') catch {};
                        json_out.appendSlice(self.allocator, jid) catch {};
                        json_out.append(self.allocator, '"') catch {};
                    }
                    json_out.append(self.allocator, ']') catch {};
                }
                json_out.append(self.allocator, '}') catch {};

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

    fn handleApiChatBackground(self: *WebAdapter, stream: std.net.Stream, method: []const u8, body: []const u8) !void {
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

        const message = if (parsed.value.object.get("message")) |m| (if (m == .string) m.string else null) else null;
        if (message == null) {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing message\"}");
            return;
        }

        const session_id = if (parsed.value.object.get("session_id")) |v| (if (v == .string) v.string else null) else null;
        const model_override = if (parsed.value.object.get("model_override")) |v| (if (v == .string) v.string else null) else null;
        const callback_channel = if (parsed.value.object.get("callback_channel")) |v| (if (v == .string) v.string else null) else null;
        const allowed_tools = if (parsed.value.object.get("allowed_tools")) |v| (if (v == .string) v.string else null) else null;
        const attachments = parseAttachments(self.allocator, parsed.value);
        defer if (attachments) |a| self.allocator.free(a);

        const result = self.engine.process(.{ .chat = .{
            .message = message.?,
            .session_id = session_id,
            .model_override = model_override,
            .callback_channel = callback_channel,
            .allowed_tools = allowed_tools,
            .background = true,
            .attachments = attachments,
        } }, null, null);

        switch (result) {
            .response => |resp| switch (resp) {
                .background_queued => |bg| {
                    var out: [256]u8 = undefined;
                    const json_resp = std.fmt.bufPrint(&out, "{{\"ok\":true,\"job_id\":\"{s}\",\"session_id\":\"{s}\"}}", .{ bg.job_id, bg.session_id }) catch "{\"ok\":true}";
                    try self.sendHttp(stream, "200 OK", "application/json", json_resp);
                },
                .error_resp => |err| {
                    var err_buf: [256]u8 = undefined;
                    const err_json = std.fmt.bufPrint(&err_buf, "{{\"error\":\"{s}\"}}", .{err.message}) catch "{\"error\":\"Internal error\"}";
                    try self.sendHttp(stream, "500 Internal Server Error", "application/json", err_json);
                },
                else => try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Unexpected response\"}"),
            },
            else => try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Unexpected result\"}"),
        }
    }

    fn handleApiBackground(self: *WebAdapter, stream: std.net.Stream, method: []const u8, path: []const u8, body: []const u8) !void {
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

        const job_id_str = if (parsed.value.object.get("job_id")) |v| (if (v == .string) v.string else null) else null;
        if (job_id_str == null or job_id_str.?.len != 36) {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing or invalid job_id\"}");
            return;
        }
        var job_id: [36]u8 = undefined;
        @memcpy(&job_id, job_id_str.?[0..36]);

        if (std.mem.endsWith(u8, path, "/cancel")) {
            // Cancel endpoint
            const wp = self.engine.worker_pool orelse {
                try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"No worker pool\"}");
                return;
            };
            _ = wp.cancelBackgroundJob(&job_id);
            try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
            return;
        }

        if (std.mem.endsWith(u8, path, "/confirm")) {
            const wp = self.engine.worker_pool orelse {
                try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"No worker pool\"}");
                return;
            };
            const tool_id_str = if (parsed.value.object.get("tool_id")) |v| (if (v == .string) v.string else null) else null;
            if (tool_id_str == null) {
                try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing tool_id\"}");
                return;
            }
            const approved_val = if (parsed.value.object.get("approved")) |v| (if (v == .bool) v.bool else null) else null;
            if (approved_val == null) {
                try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Missing approved (bool)\"}");
                return;
            }
            const resolved = wp.resolveConfirmation(&job_id, tool_id_str.?, approved_val.?);
            if (resolved) {
                try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
            } else {
                try self.sendHttp(stream, "404 Not Found", "application/json", "{\"error\":\"No matching pending confirmation\"}");
            }
            return;
        }

        // Status endpoint (default)
        const wp = self.engine.worker_pool orelse {
            try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"No worker pool\"}");
            return;
        };

        if (wp.getBackgroundResult(&job_id)) |result| {
            var out: std.ArrayList(u8) = .{};
            defer out.deinit(self.allocator);

            const status_str = switch (result.status) {
                .completed => "completed",
                .failed => "failed",
                .cancelled => "cancelled",
            };

            out.appendSlice(self.allocator, "{\"status\":\"") catch {};
            out.appendSlice(self.allocator, status_str) catch {};
            out.appendSlice(self.allocator, "\",\"text\":") catch {};
            if (result.text) |t| {
                out.appendSlice(self.allocator, "\"") catch {};
                for (t) |ch| {
                    switch (ch) {
                        '"' => out.appendSlice(self.allocator, "\\\"") catch {},
                        '\\' => out.appendSlice(self.allocator, "\\\\") catch {},
                        '\n' => out.appendSlice(self.allocator, "\\n") catch {},
                        '\r' => out.appendSlice(self.allocator, "\\r") catch {},
                        else => out.append(self.allocator, ch) catch {},
                    }
                }
                out.appendSlice(self.allocator, "\"") catch {};
            } else {
                out.appendSlice(self.allocator, "null") catch {};
            }
            out.appendSlice(self.allocator, ",\"model\":") catch {};
            if (result.model) |m| {
                out.appendSlice(self.allocator, "\"") catch {};
                out.appendSlice(self.allocator, m) catch {};
                out.appendSlice(self.allocator, "\"") catch {};
            } else {
                out.appendSlice(self.allocator, "null") catch {};
            }
            var num_buf: [32]u8 = undefined;
            out.appendSlice(self.allocator, ",\"input_tokens\":") catch {};
            out.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{result.input_tokens}) catch "0") catch {};
            out.appendSlice(self.allocator, ",\"output_tokens\":") catch {};
            out.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{result.output_tokens}) catch "0") catch {};
            out.appendSlice(self.allocator, "}") catch {};
            try self.sendHttp(stream, "200 OK", "application/json", out.items);
        } else {
            // No result yet — check for pending tool confirmation
            if (wp.getPendingConfirmation(&job_id)) |conf| {
                var out: std.ArrayList(u8) = .{};
                defer out.deinit(self.allocator);
                out.appendSlice(self.allocator, "{\"status\":\"pending\",\"pending_confirmation\":{\"tool_name\":\"") catch {};
                out.appendSlice(self.allocator, conf.tool_name) catch {};
                out.appendSlice(self.allocator, "\",\"tool_id\":\"") catch {};
                out.appendSlice(self.allocator, conf.tool_id) catch {};
                out.appendSlice(self.allocator, "\",\"input_preview\":") catch {};
                out.appendSlice(self.allocator, "\"") catch {};
                for (conf.input_preview) |ch| {
                    switch (ch) {
                        '"' => out.appendSlice(self.allocator, "\\\"") catch {},
                        '\\' => out.appendSlice(self.allocator, "\\\\") catch {},
                        '\n' => out.appendSlice(self.allocator, "\\n") catch {},
                        '\r' => out.appendSlice(self.allocator, "\\r") catch {},
                        else => out.append(self.allocator, ch) catch {},
                    }
                }
                out.appendSlice(self.allocator, "\"}}") catch {};
                try self.sendHttp(stream, "200 OK", "application/json", out.items);
            } else {
                // No confirmation pending — return tool events if any
                const cursor = blk: {
                    if (parsed.value.object.get("cursor")) |cv| {
                        if (cv == .integer) break :blk @as(usize, @intCast(@max(0, cv.integer)));
                    }
                    break :blk @as(usize, 0);
                };
                const te = wp.getToolEvents(&job_id, cursor);
                if (te.events.len > 0 or te.new_cursor > 0) {
                    var out2: std.ArrayList(u8) = .{};
                    defer out2.deinit(self.allocator);
                    out2.appendSlice(self.allocator, "{\"status\":\"pending\",\"tool_events\":[") catch {};
                    var first = true;
                    for (te.events) |maybe_evt| {
                        const evt = maybe_evt orelse continue;
                        if (!first) out2.appendSlice(self.allocator, ",") catch {};
                        first = false;
                        out2.appendSlice(self.allocator, "{\"type\":\"") catch {};
                        out2.appendSlice(self.allocator, if (evt.event_type == .tool_use) "tool_use" else "tool_result") catch {};
                        out2.appendSlice(self.allocator, "\",\"tool\":\"") catch {};
                        out2.appendSlice(self.allocator, evt.tool_name) catch {};
                        out2.appendSlice(self.allocator, "\",\"content\":\"") catch {};
                        for (evt.content) |ch| {
                            switch (ch) {
                                '"' => out2.appendSlice(self.allocator, "\\\"") catch {},
                                '\\' => out2.appendSlice(self.allocator, "\\\\") catch {},
                                '\n' => out2.appendSlice(self.allocator, "\\n") catch {},
                                '\r' => out2.appendSlice(self.allocator, "\\r") catch {},
                                '\t' => out2.appendSlice(self.allocator, "\\t") catch {},
                                else => {
                                    if (ch < 0x20) {
                                        out2.appendSlice(self.allocator, "\\u00") catch {};
                                        const hex = "0123456789abcdef";
                                        out2.append(self.allocator, hex[ch >> 4]) catch {};
                                        out2.append(self.allocator, hex[ch & 0xf]) catch {};
                                    } else {
                                        out2.append(self.allocator, ch) catch {};
                                    }
                                },
                            }
                        }
                        out2.appendSlice(self.allocator, "\"") catch {};
                        if (evt.is_error) {
                            out2.appendSlice(self.allocator, ",\"is_error\":true") catch {};
                        }
                        out2.appendSlice(self.allocator, "}") catch {};
                    }
                    var num_buf2: [32]u8 = undefined;
                    out2.appendSlice(self.allocator, "],\"cursor\":") catch {};
                    out2.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf2, "{d}", .{te.new_cursor}) catch "0") catch {};
                    out2.appendSlice(self.allocator, "}") catch {};
                    try self.sendHttp(stream, "200 OK", "application/json", out2.items);
                } else {
                    try self.sendHttp(stream, "200 OK", "application/json", "{\"status\":\"pending\"}");
                }
            }
        }
    }

    /// SSE emitter context — holds the HTTP stream and allocator for building SSE events.
    const SSEContext = struct {
        stream: std.net.Stream,
        allocator: std.mem.Allocator,
        cancelled: bool = false,
    };

    /// Callback that writes Response events as SSE to the HTTP stream in real time.
    /// Sets cancelled=true on the context when a write fails (client disconnected).
    fn sseEmitCallback(ctx: *anyopaque, response: common.Response) void {
        const sse_ctx: *SSEContext = @ptrCast(@alignCast(ctx));
        if (sse_ctx.cancelled) return;

        switch (response) {
            .stream_text => |text| {
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
                sse_ctx.stream.writeAll(buf.items) catch {
                    sse_ctx.cancelled = true;
                };
            },
            .stream_tool_use => |tool| {
                var buf: std.ArrayList(u8) = .{};
                defer buf.deinit(sse_ctx.allocator);
                buf.appendSlice(sse_ctx.allocator, "data: {\"type\":\"tool_use\",\"tool_name\":\"") catch return;
                buf.appendSlice(sse_ctx.allocator, tool.tool_name) catch return;
                buf.appendSlice(sse_ctx.allocator, "\",\"tool_id\":\"") catch return;
                buf.appendSlice(sse_ctx.allocator, tool.tool_id) catch return;
                buf.appendSlice(sse_ctx.allocator, "\",\"input\":\"") catch return;
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
                sse_ctx.stream.writeAll(buf.items) catch {
                    sse_ctx.cancelled = true;
                };
            },
            .stream_tool_result => |result| {
                var buf: std.ArrayList(u8) = .{};
                defer buf.deinit(sse_ctx.allocator);
                buf.appendSlice(sse_ctx.allocator, "data: {\"type\":\"tool_result\",\"tool_id\":\"") catch return;
                buf.appendSlice(sse_ctx.allocator, result.tool_id) catch return;
                buf.appendSlice(sse_ctx.allocator, "\",\"is_error\":") catch return;
                buf.appendSlice(sse_ctx.allocator, if (result.is_error) "true" else "false") catch return;
                buf.appendSlice(sse_ctx.allocator, ",\"result\":\"") catch return;
                const max_result = @min(result.result.len, 2000);
                for (result.result[0..max_result]) |ch| {
                    switch (ch) {
                        '"' => buf.appendSlice(sse_ctx.allocator, "\\\"") catch {},
                        '\\' => buf.appendSlice(sse_ctx.allocator, "\\\\") catch {},
                        '\n' => buf.appendSlice(sse_ctx.allocator, "\\n") catch {},
                        '\r' => buf.appendSlice(sse_ctx.allocator, "\\r") catch {},
                        else => if (ch >= 0x20) {
                            buf.append(sse_ctx.allocator, ch) catch {};
                        },
                    }
                }
                buf.appendSlice(sse_ctx.allocator, "\"}\n\n") catch return;
                sse_ctx.stream.writeAll(buf.items) catch {
                    sse_ctx.cancelled = true;
                };
            },
            else => {},
        }
    }

    fn sseIsCancelled(ctx: *anyopaque) bool {
        const sse_ctx: *SSEContext = @ptrCast(@alignCast(ctx));
        return sse_ctx.cancelled;
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

        // Mirror the non-streaming handler's field set so the streaming
        // endpoint honors model_override / allowed_tools / attachments etc.
        // The old body only pulled `message` + `session_id`, which meant
        // web UI model swaps silently fell back to the daemon default on
        // every streaming turn.
        const no_tools = if (parsed.value.object.get("no_tools")) |v| (v == .bool and v.bool) else false;
        const session_id = if (parsed.value.object.get("session_id")) |v| (if (v == .string) v.string else null) else null;
        const model_override = if (parsed.value.object.get("model_override")) |v| (if (v == .string) v.string else null) else null;
        const allowed_tools = if (parsed.value.object.get("allowed_tools")) |v| (if (v == .string) v.string else null) else null;
        const adapter_context = if (parsed.value.object.get("adapter_context")) |v| (if (v == .string) v.string else null) else null;
        const attachments = parseAttachments(self.allocator, parsed.value);
        defer if (attachments) |a| self.allocator.free(a);

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
            .isCancelledFn = &sseIsCancelled,
        };

        self.engine.beginStreaming();
        const result = self.engine.process(.{ .chat = .{
            .message = message,
            .session_id = session_id,
            .model_override = model_override,
            .no_tools = no_tools,
            .allowed_tools = allowed_tools,
            .adapter_context = adapter_context,
            .attachments = attachments,
        } }, emitter, null);

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
                if (chat.cache_read_tokens > 0 or chat.cache_creation_tokens > 0) {
                    end_buf.appendSlice(self.allocator, ",\"cache_read_tokens\":") catch {};
                    end_buf.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{chat.cache_read_tokens}) catch "0") catch {};
                    end_buf.appendSlice(self.allocator, ",\"cache_creation_tokens\":") catch {};
                    end_buf.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{chat.cache_creation_tokens}) catch "0") catch {};
                }

                // Include spawned subagent job IDs so the web UI can poll them
                if (chat.spawned_jobs) |jobs_csv| {
                    end_buf.appendSlice(self.allocator, ",\"spawned_jobs\":[") catch {};
                    var first_job = true;
                    var job_iter = std.mem.splitScalar(u8, jobs_csv, ',');
                    while (job_iter.next()) |jid| {
                        if (jid.len == 0) continue;
                        if (!first_job) end_buf.append(self.allocator, ',') catch {};
                        first_job = false;
                        end_buf.append(self.allocator, '"') catch {};
                        end_buf.appendSlice(self.allocator, jid) catch {};
                        end_buf.append(self.allocator, '"') catch {};
                    }
                    end_buf.append(self.allocator, ']') catch {};
                }

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
            } else if (std.mem.endsWith(u8, path, "/model")) {
                return self.handleSessionAction(stream, body, "model");
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
            // Return session model + persona so the UI can restore them
            const sess = self.engine.session_store.getSession(id) catch {
                try self.sendHttp(stream, "200 OK", "application/json", "{\"ok\":true}");
                return;
            };
            defer {
                if (sess.name) |n| self.allocator.free(n);
                self.allocator.free(sess.model);
                if (sess.system_prompt) |s| self.allocator.free(s);
            }
            var out: std.ArrayList(u8) = .{};
            defer out.deinit(self.allocator);
            out.appendSlice(self.allocator, "{\"ok\":true,\"model\":\"") catch {};
            out.appendSlice(self.allocator, sess.model) catch {};
            out.appendSlice(self.allocator, "\",\"persona\":") catch {};
            if (sess.system_prompt) |sp| {
                out.append(self.allocator, '"') catch {};
                out.appendSlice(self.allocator, sp) catch {};
                out.append(self.allocator, '"') catch {};
            } else {
                out.appendSlice(self.allocator, "null") catch {};
            }
            out.append(self.allocator, '}') catch {};
            try self.sendHttp(stream, "200 OK", "application/json", out.items);
            return;
        } else if (std.mem.eql(u8, action, "model")) {
            const raw_model = if (parsed.value.object.get("model")) |v| (if (v == .string) v.string else null) else null;
            // Empty string means "reset to daemon default"
            const model = if (raw_model) |m| (if (m.len == 0) self.engine.session_store.default_model else m) else self.engine.session_store.default_model;
            self.engine.session_store.updateModel(id, model) catch {};
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

    /// POST /api/upload — accept base64-encoded file, save to disk, return {path, mime, name}
    fn handleApiUpload(self: *WebAdapter, stream: std.net.Stream, method: []const u8, body: []const u8) !void {
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

        const data_str = if (obj.get("data")) |v| (if (v == .string) v.string else null) else null;
        const mime_str = if (obj.get("mime")) |v| (if (v == .string) v.string else null) else null;
        const name_str = if (obj.get("name")) |v| (if (v == .string) v.string else null) else null;

        if (data_str == null or mime_str == null or name_str == null) {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Need data, mime, name\"}");
            return;
        }

        // Validate MIME type
        const allowed_mimes = [_][]const u8{ "image/png", "image/jpeg", "image/gif", "image/webp" };
        var mime_ok = false;
        for (&allowed_mimes) |m| {
            if (std.mem.eql(u8, mime_str.?, m)) { mime_ok = true; break; }
        }
        if (!mime_ok) {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Unsupported image type\"}");
            return;
        }

        // Decode base64
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_str.?) catch {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid base64\"}");
            return;
        };
        const buf = self.allocator.alloc(u8, decoded_len) catch {
            try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Out of memory\"}");
            return;
        };
        defer self.allocator.free(buf);
        std.base64.standard.Decoder.decode(buf, data_str.?) catch {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid base64\"}");
            return;
        };

        // Ensure upload directory exists
        const upload_dir = "/tmp/clawforge_attachments";
        std.fs.makeDirAbsolute(upload_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Cannot create upload dir\"}");
                return;
            },
        };

        // Generate unique filename
        const ts = std.time.timestamp();
        const ext = if (std.mem.eql(u8, mime_str.?, "image/png")) ".png"
            else if (std.mem.eql(u8, mime_str.?, "image/jpeg")) ".jpg"
            else if (std.mem.eql(u8, mime_str.?, "image/gif")) ".gif"
            else if (std.mem.eql(u8, mime_str.?, "image/webp")) ".webp"
            else ".bin";

        // Strip existing extension from name to avoid double-extension
        const name_raw = name_str.?;
        const dot_pos = std.mem.lastIndexOfScalar(u8, name_raw, '.') orelse name_raw.len;
        const name_stem = name_raw[0..dot_pos];

        var path_buf: [256]u8 = undefined;
        const file_path = std.fmt.bufPrint(&path_buf, "{s}/{d}_{s}{s}", .{
            upload_dir, ts, name_stem, ext,
        }) catch {
            try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Path too long\"}");
            return;
        };

        // Write file
        const file = std.fs.createFileAbsolute(file_path, .{}) catch {
            try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Cannot write file\"}");
            return;
        };
        defer file.close();
        file.writeAll(buf[0..decoded_len]) catch {
            try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Write failed\"}");
            return;
        };

        // Return JSON with path, mime, name
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(self.allocator);
        out.appendSlice(self.allocator, "{\"path\":\"") catch {};
        out.appendSlice(self.allocator, file_path) catch {};
        out.appendSlice(self.allocator, "\",\"mime\":\"") catch {};
        out.appendSlice(self.allocator, mime_str.?) catch {};
        out.appendSlice(self.allocator, "\",\"name\":\"") catch {};
        // JSON-escape name
        for (name_str.?) |ch| {
            switch (ch) {
                '"' => out.appendSlice(self.allocator, "\\\"") catch {},
                '\\' => out.appendSlice(self.allocator, "\\\\") catch {},
                else => out.append(self.allocator, ch) catch {},
            }
        }
        out.appendSlice(self.allocator, "\"}") catch {};
        try self.sendHttp(stream, "200 OK", "application/json", out.items);
    }

    /// Parse the `attachments` array from a chat JSON body into a slice of
    /// `common.Request.Attachment` structs. Returns null if the field is
    /// missing or empty. All returned slices point into `parsed_root`'s arena
    /// so the caller must keep the parse alive for the duration of the request.
    fn parseAttachments(
        allocator: std.mem.Allocator,
        parsed_root: std.json.Value,
    ) ?[]const common.Request.Attachment {
        const field = parsed_root.object.get("attachments") orelse return null;
        if (field != .array) return null;
        const items = field.array.items;
        if (items.len == 0) return null;

        var list: std.ArrayList(common.Request.Attachment) = .{};
        list.ensureTotalCapacity(allocator, items.len) catch return null;
        for (items) |item| {
            if (item != .object) continue;
            const path_v = item.object.get("path") orelse continue;
            if (path_v != .string) continue;
            const mime_v = item.object.get("mime") orelse continue;
            if (mime_v != .string) continue;
            const name_v = item.object.get("name") orelse path_v;
            const name_str = if (name_v == .string) name_v.string else path_v.string;
            list.append(allocator, .{
                .path = path_v.string,
                .mime = mime_v.string,
                .name = name_str,
            }) catch return null;
        }
        if (list.items.len == 0) return null;
        return list.toOwnedSlice(allocator) catch null;
    }

    /// GET /api/vision  → returns current effective model + config
    /// POST /api/vision → { "model": "claude-opus-4-6" } sets runtime override
    /// POST /api/vision → { "model": null } clears the override
    fn handleApiVision(self: *WebAdapter, stream: std.net.Stream, method: []const u8, body: []const u8) !void {
        if (std.mem.eql(u8, method, "GET")) {
            const vp = self.engine.vision_pipeline orelse {
                try self.sendHttp(stream, "503 Service Unavailable", "application/json",
                    "{\"error\":\"Vision pipeline not wired\"}");
                return;
            };
            const effective = vp.effectiveModel();
            var out_buf: [512]u8 = undefined;
            const json_resp = std.fmt.bufPrint(&out_buf,
                "{{\"enabled\":{s},\"model\":\"{s}\",\"default_model\":\"{s}\",\"max_image_bytes\":{d},\"max_images_per_turn\":{d}}}",
                .{
                    if (self.config.vision.enabled) "true" else "false",
                    effective,
                    self.config.vision.model,
                    self.config.vision.max_image_bytes,
                    self.config.vision.max_images_per_turn,
                },
            ) catch "{\"error\":\"format error\"}";
            try self.sendHttp(stream, "200 OK", "application/json", json_resp);
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

        // Resolve requested model: explicit string → override, JSON null → clear.
        const model_val = parsed.value.object.get("model");
        const new_model: ?[]const u8 = blk: {
            if (model_val) |v| {
                if (v == .string) break :blk v.string;
                if (v == .null) break :blk null;
            }
            break :blk null;
        };

        const vp = self.engine.vision_pipeline orelse {
            try self.sendHttp(stream, "503 Service Unavailable", "application/json",
                "{\"error\":\"Vision pipeline not wired\"}");
            return;
        };

        vp.setModelOverride(new_model) catch {
            try self.sendHttp(stream, "500 Internal Server Error", "application/json",
                "{\"error\":\"Failed to set vision model\"}");
            return;
        };
        if (self.bg_engine) |bg| {
            if (bg.vision_pipeline) |bg_vp| {
                bg_vp.setModelOverride(new_model) catch {};
            }
        }

        std.log.info("Vision model override set to: {s}", .{new_model orelse "(cleared)"});

        var ok_buf: [256]u8 = undefined;
        const ok_resp = std.fmt.bufPrint(&ok_buf,
            "{{\"ok\":true,\"model\":\"{s}\"}}",
            .{vp.effectiveModel()},
        ) catch "{\"ok\":true}";
        try self.sendHttp(stream, "200 OK", "application/json", ok_resp);
    }

    /// GET /api/models → enumerate models grouped by provider.
    /// Shape:
    ///   { "providers": [
    ///       { "name": "anthropic", "models": ["anthropic:claude-sonnet-4-6", ...] },
    ///       { "name": "ollama",    "models": ["ollama:qwen3:8b", ...] },
    ///       { "name": "openai",    "models": ["openai:gpt-4o", ...] }
    ///   ] }
    /// Model strings are pre-prefixed with `provider:` so clients can send
    /// them back unchanged as a `model_override` and the engine resolver
    /// will dispatch them correctly. Anthropic + OpenAI lists are static;
    /// Ollama is queried live via `{base_url}/api/tags`.
    fn handleApiModels(self: *WebAdapter, stream: std.net.Stream) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var out: std.ArrayList(u8) = .{};
        out.ensureTotalCapacity(arena, 4096) catch {};

        out.appendSlice(arena, "{\"providers\":[") catch {};

        // Anthropic — static list. Current generation + stable snapshots.
        const anthropic_models = [_][]const u8{
            "anthropic:claude-opus-4-6",
            "anthropic:claude-sonnet-4-6",
            "anthropic:claude-haiku-4-5-20251001",
            "anthropic:claude-opus-4-20250514",
            "anthropic:claude-sonnet-4-20250514",
        };
        out.appendSlice(arena, "{\"name\":\"anthropic\",\"models\":[") catch {};
        for (anthropic_models, 0..) |m, i| {
            if (i > 0) out.appendSlice(arena, ",") catch {};
            out.appendSlice(arena, "\"") catch {};
            out.appendSlice(arena, m) catch {};
            out.appendSlice(arena, "\"") catch {};
        }
        out.appendSlice(arena, "]}") catch {};

        // Ollama — query `{base_url}/api/tags` for the live local list.
        // Best-effort: on failure we emit an empty models array instead
        // of dropping the provider entry, so clients can still show it.
        if (self.engine.config.ollama.enabled) {
            out.appendSlice(arena, ",{\"name\":\"ollama\",\"models\":[") catch {};
            self.appendOllamaTags(&out, arena, self.engine.config.ollama.base_url) catch {};
            out.appendSlice(arena, "]}") catch {};
        }

        // OpenAI — static list. Users can type anything else as a free
        // string via `/model openai:<whatever>` — this list just primes
        // the UI dropdown.
        if (self.engine.config.openai.enabled) {
            const openai_models = [_][]const u8{
                "openai:gpt-4o",
                "openai:gpt-4o-mini",
                "openai:gpt-4.1",
                "openai:gpt-4.1-mini",
                "openai:o1",
                "openai:o1-mini",
            };
            out.appendSlice(arena, ",{\"name\":\"openai\",\"models\":[") catch {};
            for (openai_models, 0..) |m, i| {
                if (i > 0) out.appendSlice(arena, ",") catch {};
                out.appendSlice(arena, "\"") catch {};
                out.appendSlice(arena, m) catch {};
                out.appendSlice(arena, "\"") catch {};
            }
            out.appendSlice(arena, "]}") catch {};
        }

        // OpenRouter — fetch live model list with pricing from the API.
        // Falls back to empty on any error so the UI stays functional.
        if (self.engine.config.openrouter.enabled) {
            out.appendSlice(arena, ",{\"name\":\"openrouter\",\"models\":[") catch {};
            self.appendOpenRouterModels(&out, arena) catch {};
            out.appendSlice(arena, "]}") catch {};
        }

        out.appendSlice(arena, "]}") catch {};

        try self.sendHttp(stream, "200 OK", "application/json", out.items);
    }

    /// Helper: fetch `{base_url}/api/tags` from Ollama and append each
    /// model name (quoted, comma-separated, with `ollama:` prefix) into
    /// `out`. Silently succeeds with nothing appended on any error so
    /// the caller's surrounding JSON stays well-formed.
    fn appendOllamaTags(
        self: *WebAdapter,
        out: *std.ArrayList(u8),
        arena: std.mem.Allocator,
        base_url: []const u8,
    ) !void {
        _ = self;
        var client = std.http.Client{ .allocator = arena };

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/api/tags", .{base_url}) catch return;

        var response_writer = std.Io.Writer.Allocating.init(arena);
        var redirect_buf: [4096]u8 = undefined;

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .redirect_buffer = &redirect_buf,
            .response_writer = &response_writer.writer,
        }) catch return;

        if (result.status != .ok) return;
        const data = response_writer.written();

        const parsed = std.json.parseFromSlice(std.json.Value, arena, data, .{
            .allocate = .alloc_always,
        }) catch return;

        if (parsed.value != .object) return;
        const obj = parsed.value.object;
        const models = obj.get("models") orelse return;
        if (models != .array) return;

        var first = true;
        for (models.array.items) |entry| {
            if (entry != .object) continue;
            const name_val = entry.object.get("name") orelse continue;
            if (name_val != .string) continue;
            const name = name_val.string;
            if (name.len == 0) continue;
            if (!first) out.appendSlice(arena, ",") catch {};
            first = false;
            out.appendSlice(arena, "\"ollama:") catch {};
            out.appendSlice(arena, name) catch {};
            out.appendSlice(arena, "\"") catch {};
        }
    }

    /// Fetch models from OpenRouter's `/api/v1/models` endpoint and append
    /// them as JSON objects with pricing info. Each entry is:
    ///   {"id":"openrouter:vendor/model","input_cost":"0.20","output_cost":"0.50"}
    /// The web UI reads these to show $/M in the dropdown.
    /// Silently succeeds with nothing appended on error.
    fn appendOpenRouterModels(
        self: *WebAdapter,
        out: *std.ArrayList(u8),
        arena: std.mem.Allocator,
    ) !void {
        const base_url = self.engine.config.openrouter.base_url;

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/models", .{base_url}) catch return;

        // Shell out to curl — Zig's HTTP client crashes on large compressed
        // responses from OpenRouter (~5MB gzipped). curl handles this natively.
        const result = std.process.Child.run(.{
            .allocator = arena,
            .argv = &.{ "curl", "-s", "--max-time", "15", "-H", "Accept: application/json", url },
            .max_output_bytes = 16 * 1024 * 1024,
        }) catch |err| {
            std.log.warn("OpenRouter /models curl failed: {}", .{err});
            return;
        };
        if (result.stderr.len > 0) arena.free(result.stderr);
        if (result.term.Exited != 0 or result.stdout.len == 0) {
            std.log.warn("OpenRouter /models: curl exited {d}, {d}b", .{ result.term.Exited, result.stdout.len });
            return;
        }
        const data = result.stdout;

        const parsed = std.json.parseFromSlice(std.json.Value, arena, data, .{
            .allocate = .alloc_always,
        }) catch return;

        if (parsed.value != .object) return;
        const models_arr = parsed.value.object.get("data") orelse return;
        if (models_arr != .array) return;

        var count: usize = 0;
        for (models_arr.array.items) |entry| {
            if (entry != .object) continue;
            const id_val = entry.object.get("id") orelse continue;
            if (id_val != .string) continue;
            const model_id = id_val.string;
            if (model_id.len == 0) continue;

            // Extract pricing (strings like "0.0000002" = per-token cost)
            var input_cost: []const u8 = "";
            var output_cost: []const u8 = "";
            if (entry.object.get("pricing")) |pricing| {
                if (pricing == .object) {
                    if (pricing.object.get("prompt")) |p| {
                        if (p == .string) input_cost = p.string;
                    }
                    if (pricing.object.get("completion")) |c| {
                        if (c == .string) output_cost = c.string;
                    }
                }
            }

            if (count > 0) out.appendSlice(arena, ",") catch {};
            count += 1;

            // Emit as JSON object: {"id":"openrouter:vendor/model","input_cost":"...","output_cost":"..."}
            out.appendSlice(arena, "{\"id\":\"openrouter:") catch {};
            out.appendSlice(arena, model_id) catch {};
            out.appendSlice(arena, "\"") catch {};
            if (input_cost.len > 0) {
                out.appendSlice(arena, ",\"input_cost\":\"") catch {};
                out.appendSlice(arena, input_cost) catch {};
                out.appendSlice(arena, "\"") catch {};
            }
            if (output_cost.len > 0) {
                out.appendSlice(arena, ",\"output_cost\":\"") catch {};
                out.appendSlice(arena, output_cost) catch {};
                out.appendSlice(arena, "\"") catch {};
            }
            out.appendSlice(arena, "}") catch {};
        }

        std.log.info("OpenRouter: fetched {d} models with pricing", .{count});
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

    /// GET returns {enabled: bool}. POST {enabled: bool} sets the flag.
    fn handleApiToolAutoApprove(self: *WebAdapter, stream: std.net.Stream, method: []const u8, body: []const u8) !void {
        if (std.mem.eql(u8, method, "GET")) {
            const is_on = self.engine.tool_registry.isAutoApprove();
            const out = if (is_on) "{\"enabled\":true}" else "{\"enabled\":false}";
            try self.sendHttp(stream, "200 OK", "application/json", out);
            return;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{
            .allocate = .alloc_always,
        }) catch {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid JSON\"}");
            return;
        };
        defer parsed.deinit();

        const enabled = if (parsed.value.object.get("enabled")) |e| (if (e == .bool) e.bool else null) else null;
        if (enabled == null) {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Need enabled field\"}");
            return;
        }

        self.engine.tool_registry.setAutoApprove(enabled.?);
        std.log.info("Tool auto-approve set to {s} via web", .{if (enabled.?) "ON" else "OFF"});

        const out = if (enabled.?) "{\"ok\":true,\"enabled\":true}" else "{\"ok\":true,\"enabled\":false}";
        try self.sendHttp(stream, "200 OK", "application/json", out);
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

    /// GET /api/persona[?session_id=UUID] — list personas + active persona for the session
    /// POST /api/persona {action, name, content?, session_id?}
    ///   action=select: set active persona for the given session (or active session if none)
    ///   action=create: create new persona file
    ///   action=delete: delete persona file
    fn handleApiPersona(self: *WebAdapter, stream: std.net.Stream, method: []const u8, path: []const u8, body: []const u8) !void {
        const prompt_mod = @import("core").prompt;

        if (std.mem.eql(u8, method, "GET")) {
            // Optional ?session_id=UUID query param scopes the "active persona" lookup
            const query_session_id: ?[]const u8 = blk: {
                if (std.mem.indexOf(u8, path, "session_id=")) |idx| {
                    const sid_start = idx + "session_id=".len;
                    const rest = path[sid_start..];
                    const end = std.mem.indexOfAny(u8, rest, "&") orelse rest.len;
                    if (end > 0) break :blk rest[0..end];
                }
                break :blk null;
            };

            const personas = try prompt_mod.listPersonas(self.allocator);
            defer {
                for (personas) |name| self.allocator.free(name);
                self.allocator.free(personas);
            }

            // Resolve active persona: explicit session_id wins, else daemon active session
            var active_name: []const u8 = "default";
            var _sess_info: ?storage.SessionInfo = null;
            if (query_session_id) |sid| {
                _sess_info = self.engine.session_store.getSession(sid) catch null;
            } else if (self.engine.session_store.active_session_id) |sid| {
                _sess_info = self.engine.session_store.getSession(&sid) catch null;
            }
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
        const body_session_id: ?[]const u8 = if (obj.get("session_id")) |s| (if (s == .string) s.string else null) else null;

        if (std.mem.eql(u8, action, "select")) {
            // Resolve target session: explicit session_id from body, else daemon active session
            const persona_name: ?[]const u8 = if (name) |n| (if (std.mem.eql(u8, n, "default")) null else n) else null;
            if (body_session_id) |sid| {
                self.engine.session_store.updateSystemPrompt(sid, persona_name) catch {
                    try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Failed to update\"}");
                    return;
                };
            } else {
                const session_id = self.engine.session_store.active_session_id orelse {
                    try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"No active session\"}");
                    return;
                };
                self.engine.session_store.updateSystemPrompt(&session_id, persona_name) catch {
                    try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Failed to update\"}");
                    return;
                };
            }
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
