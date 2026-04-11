const std = @import("std");
const db_mod = @import("db.zig");
const api = @import("api");

/// Message CRUD backed by SQLite.
pub const MessageStore = struct {
    conn: *db_mod.Connection,
    allocator: std.mem.Allocator,

    pub fn init(conn: *db_mod.Connection, allocator: std.mem.Allocator) MessageStore {
        return .{ .conn = conn, .allocator = allocator };
    }

    /// Add a user message. Returns the message id.
    pub fn addUserMessage(self: *MessageStore, session_id: []const u8, content: []const u8) !i64 {
        const seq = try self.nextSequence(session_id);
        return try self.insertMessage(session_id, seq, "user", content, null, null, null, null, null);
    }

    /// Add an assistant message with model/routing info. Returns the message id.
    pub fn addAssistantMessage(
        self: *MessageStore,
        session_id: []const u8,
        content: []const u8,
        model_used: ?[]const u8,
        route_tier: ?[]const u8,
        route_reason: ?[]const u8,
        input_tokens: ?i64,
        output_tokens: ?i64,
    ) !i64 {
        const seq = try self.nextSequence(session_id);
        return try self.insertMessage(session_id, seq, "assistant", content, model_used, route_tier, route_reason, input_tokens, output_tokens);
    }

    fn insertMessage(
        self: *MessageStore,
        session_id: []const u8,
        sequence: i64,
        role: []const u8,
        content: []const u8,
        model_used: ?[]const u8,
        route_tier: ?[]const u8,
        route_reason: ?[]const u8,
        input_tokens: ?i64,
        output_tokens: ?i64,
    ) !i64 {
        var stmt = try self.conn.prepare(
            "INSERT INTO messages (session_id, sequence, role, content, model_used, route_tier, route_reason, input_tokens, output_tokens, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        );
        defer stmt.deinit();

        try stmt.bindText(1, session_id);
        try stmt.bindInt64(2, sequence);
        try stmt.bindText(3, role);
        try stmt.bindText(4, content);
        try stmt.bindOptionalText(5, model_used);
        try stmt.bindOptionalText(6, route_tier);
        try stmt.bindOptionalText(7, route_reason);
        try stmt.bindOptionalInt64(8, input_tokens);
        try stmt.bindOptionalInt64(9, output_tokens);
        try stmt.bindInt64(10, std.time.timestamp());
        try stmt.exec();

        return self.conn.lastInsertRowId();
    }

    fn nextSequence(self: *MessageStore, session_id: []const u8) !i64 {
        var stmt = try self.conn.prepare(
            "SELECT COALESCE(MAX(sequence), -1) + 1 FROM messages WHERE session_id = ?",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        _ = try stmt.step();
        return stmt.columnInt64(0);
    }

    /// Build API-format messages for the Anthropic Messages API.
    /// Returns messages in sequence order.
    /// Strip <tool_calls>...</tool_calls> XML from stored assistant messages.
    /// This XML is for DB persistence/introspect only — sending it to the API
    /// causes the model to mimic the format as plain text instead of using real tool_use.
    fn stripToolCallsXml(self: *MessageStore, content: []const u8) ![]const u8 {
        const start_tag = "<tool_calls>";
        const end_tag = "</tool_calls>";
        const start_idx = std.mem.indexOf(u8, content, start_tag) orelse return try self.allocator.dupe(u8, content);
        const end_idx = std.mem.indexOf(u8, content[start_idx..], end_tag) orelse return try self.allocator.dupe(u8, content);
        const after = content[start_idx + end_idx + end_tag.len ..];

        // Trim leading whitespace from the remaining text
        var trimmed = after;
        while (trimmed.len > 0 and (trimmed[0] == '\n' or trimmed[0] == '\r' or trimmed[0] == ' ')) {
            trimmed = trimmed[1..];
        }

        if (start_idx == 0) return try self.allocator.dupe(u8, trimmed);

        // Content before the tag + content after
        const before = content[0..start_idx];
        const result = try self.allocator.alloc(u8, before.len + trimmed.len);
        @memcpy(result[0..before.len], before);
        @memcpy(result[before.len..], trimmed);
        return result;
    }

    pub fn buildApiMessages(self: *MessageStore, session_id: []const u8) ![]const api.messages.Message {
        var stmt = try self.conn.prepare(
            "SELECT role, content FROM messages WHERE session_id = ? ORDER BY sequence ASC",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);

        var raw: [512]api.messages.Message = undefined;
        var count: usize = 0;

        while (try stmt.step()) {
            if (count >= raw.len) break;
            const role_str = stmt.columnText(0) orelse "user";
            const content = stmt.columnText(1) orelse "";

            const role: api.messages.Role = if (std.mem.eql(u8, role_str, "assistant"))
                .assistant
            else
                .user;

            // Strip tool_calls XML from assistant messages before sending to API
            const clean_content = if (role == .assistant)
                try self.stripToolCallsXml(content)
            else
                try self.allocator.dupe(u8, content);

            const content_slice = try self.allocator.alloc(api.messages.ContentBlock, 1);
            content_slice[0] = .{ .text = .{ .text = clean_content } };

            raw[count] = .{ .role = role, .content = content_slice };
            count += 1;
        }

        if (count == 0) return &.{};
        return try self.sanitizeMessages(raw[0..count]);
    }

    /// Build API messages for only the most recent N messages.
    /// Used when session is too long for full history — older context comes from summaries.
    pub fn buildApiMessagesRecent(self: *MessageStore, session_id: []const u8, max_messages: usize) ![]const api.messages.Message {
        var stmt = try self.conn.prepare(
            "SELECT role, content FROM (" ++
                "SELECT role, content, sequence FROM messages WHERE session_id = ? ORDER BY sequence DESC LIMIT ?" ++
                ") sub ORDER BY sequence ASC",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindInt64(2, @intCast(max_messages));

        var raw: [256]api.messages.Message = undefined;
        var count: usize = 0;

        while (try stmt.step()) {
            if (count >= raw.len) break;
            const role_str = stmt.columnText(0) orelse "user";
            const content = stmt.columnText(1) orelse "";

            const role: api.messages.Role = if (std.mem.eql(u8, role_str, "assistant"))
                .assistant
            else
                .user;

            const clean_content = if (role == .assistant)
                try self.stripToolCallsXml(content)
            else
                try self.allocator.dupe(u8, content);

            const content_slice = try self.allocator.alloc(api.messages.ContentBlock, 1);
            content_slice[0] = .{ .text = .{ .text = clean_content } };

            raw[count] = .{ .role = role, .content = content_slice };
            count += 1;
        }

        if (count == 0) return &.{};
        return try self.sanitizeMessages(raw[0..count]);
    }

    /// Build only the newest messages that fit within a hard character budget.
    /// Purpose: bound prompt size even when the "recent window" contains giant tool-heavy turns.
    pub fn buildApiMessagesRecentBudgeted(
        self: *MessageStore,
        session_id: []const u8,
        max_messages: usize,
        max_chars: usize,
    ) ![]const api.messages.Message {
        var stmt = try self.conn.prepare(
            "SELECT role, content FROM (" ++
                "SELECT role, content, sequence FROM messages WHERE session_id = ? ORDER BY sequence DESC LIMIT ?" ++
                ") sub ORDER BY sequence DESC",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindInt64(2, @intCast(max_messages));

        var raw_desc: [256]api.messages.Message = undefined;
        var raw_count: usize = 0;
        var used_chars: usize = 0;

        while (try stmt.step()) {
            if (raw_count >= raw_desc.len) break;

            const role_str = stmt.columnText(0) orelse "user";
            const content = stmt.columnText(1) orelse "";
            const role: api.messages.Role = if (std.mem.eql(u8, role_str, "assistant")) .assistant else .user;

            const clean_content = if (role == .assistant)
                try self.stripToolCallsXml(content)
            else
                try self.allocator.dupe(u8, content);

            const content_len = clean_content.len;
            const would_overflow = used_chars > 0 and used_chars + content_len > max_chars;
            if (would_overflow) {
                self.allocator.free(clean_content);
                break;
            }

            const content_slice = try self.allocator.alloc(api.messages.ContentBlock, 1);
            content_slice[0] = .{ .text = .{ .text = clean_content } };

            raw_desc[raw_count] = .{ .role = role, .content = content_slice };
            raw_count += 1;
            used_chars += content_len;
        }

        if (raw_count == 0) return &.{};

        var raw: [256]api.messages.Message = undefined;
        for (0..raw_count) |i| {
            raw[i] = raw_desc[raw_count - 1 - i];
        }
        return try self.sanitizeMessages(raw[0..raw_count]);
    }

    /// Sanitize messages for the Anthropic API:
    /// - Skip empty messages
    /// - Merge consecutive same-role messages (API requires strict alternation)
    /// - Ensure first message is role=user
    fn sanitizeMessages(self: *MessageStore, raw: []const api.messages.Message) ![]const api.messages.Message {
        var out: [512]api.messages.Message = undefined;
        var n: usize = 0;

        for (raw) |msg| {
            // Skip empty content
            const text = if (msg.content.len > 0) switch (msg.content[0]) {
                .text => |t| t.text,
                else => "",
            } else "";
            if (text.len == 0) continue;

            // Merge consecutive same-role by concatenating text
            if (n > 0 and out[n - 1].role == msg.role) {
                // Build merged text: prev + \n\n + current
                const prev_text = switch (out[n - 1].content[0]) {
                    .text => |t| t.text,
                    else => "",
                };
                const merged_len = prev_text.len + 2 + text.len;
                const merged = try self.allocator.alloc(u8, merged_len);
                @memcpy(merged[0..prev_text.len], prev_text);
                merged[prev_text.len] = '\n';
                merged[prev_text.len + 1] = '\n';
                @memcpy(merged[prev_text.len + 2 ..], text);

                // Allocate new content slice (can't mutate const)
                const new_content = try self.allocator.alloc(api.messages.ContentBlock, 1);
                new_content[0] = .{ .text = .{ .text = merged } };
                out[n - 1].content = new_content;
                continue;
            }

            out[n] = msg;
            n += 1;
        }

        if (n == 0) return &.{};

        // Ensure first message is user role (API requirement)
        if (out[0].role != .user) {
            // Prepend a placeholder user message
            var shifted: [513]api.messages.Message = undefined;
            const placeholder = try self.allocator.alloc(api.messages.ContentBlock, 1);
            placeholder[0] = .{ .text = .{ .text = "[session resumed]" } };
            shifted[0] = .{ .role = .user, .content = placeholder };
            @memcpy(shifted[1..][0..n], out[0..n]);
            n += 1;
            const result = try self.allocator.alloc(api.messages.Message, n);
            @memcpy(result, shifted[0..n]);
            return result;
        }

        const result = try self.allocator.alloc(api.messages.Message, n);
        @memcpy(result, out[0..n]);
        return result;
    }

    /// Get recent messages as lightweight structs (for summarization, not API calls).
    pub fn getRecentMessages(self: *MessageStore, session_id: []const u8, limit: usize) ![]const MessageInfo {
        var stmt = try self.conn.prepare(
            "SELECT id, role, content, created_at FROM messages WHERE session_id = ? ORDER BY sequence DESC LIMIT ?",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindInt64(2, @intCast(limit));

        // Read into temp buffer, then reverse for chronological order
        var buf: [200]MessageInfo = undefined;
        var count: usize = 0;
        while (try stmt.step()) {
            if (count >= buf.len) break;
            buf[count] = .{
                .id = stmt.columnOptionalInt64(0),
                .role = try self.allocator.dupe(u8, stmt.columnText(1) orelse "user"),
                .content = try self.allocator.dupe(u8, stmt.columnText(2) orelse ""),
                .created_at = stmt.columnInt64(3),
            };
            count += 1;
        }
        if (count == 0) return &.{};

        // Reverse to chronological order
        const result = try self.allocator.alloc(MessageInfo, count);
        for (0..count) |i| {
            result[i] = buf[count - 1 - i];
        }
        return result;
    }

    /// Get messages in a specific ID range. Used for drilling down from summaries
    /// back into the exact conversation history that was summarized.
    pub fn getMessageRange(self: *MessageStore, session_id: []const u8, start_id: i64, end_id: i64) ![]const MessageInfo {
        var stmt = try self.conn.prepare(
            "SELECT id, role, content, created_at FROM messages " ++
                "WHERE session_id = ? AND id >= ? AND id <= ? ORDER BY sequence ASC",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        try stmt.bindInt64(2, start_id);
        try stmt.bindInt64(3, end_id);

        var buf: [500]MessageInfo = undefined;
        var count: usize = 0;
        while (try stmt.step()) {
            if (count >= buf.len) break;
            buf[count] = .{
                .id = stmt.columnOptionalInt64(0),
                .role = try self.allocator.dupe(u8, stmt.columnText(1) orelse "user"),
                .content = try self.allocator.dupe(u8, stmt.columnText(2) orelse ""),
                .created_at = stmt.columnInt64(3),
            };
            count += 1;
        }
        if (count == 0) return &.{};
        const result = try self.allocator.alloc(MessageInfo, count);
        @memcpy(result, buf[0..count]);
        return result;
    }

    /// Get ALL messages for a session as lightweight structs (full history export).
    /// Messages are NEVER deleted — this is the permanent record.
    pub fn getFullHistory(self: *MessageStore, session_id: []const u8) ![]const MessageInfo {
        var count_stmt = try self.conn.prepare(
            "SELECT COUNT(*) FROM messages WHERE session_id = ?",
        );
        defer count_stmt.deinit();
        try count_stmt.bindText(1, session_id);
        _ = try count_stmt.step();
        const total: usize = @intCast(count_stmt.columnInt64(0));
        if (total == 0) return &.{};

        const result = try self.allocator.alloc(MessageInfo, total);

        var stmt = try self.conn.prepare(
            "SELECT id, role, content, created_at FROM messages " ++
                "WHERE session_id = ? ORDER BY sequence ASC",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);

        var i: usize = 0;
        while (try stmt.step()) {
            if (i >= total) break;
            result[i] = .{
                .id = stmt.columnOptionalInt64(0),
                .role = try self.allocator.dupe(u8, stmt.columnText(1) orelse "user"),
                .content = try self.allocator.dupe(u8, stmt.columnText(2) orelse ""),
                .created_at = stmt.columnInt64(3),
            };
            i += 1;
        }
        return result[0..i];
    }

    /// Get message count for a session.
    pub fn messageCount(self: *MessageStore, session_id: []const u8) !usize {
        var stmt = try self.conn.prepare(
            "SELECT COUNT(*) FROM messages WHERE session_id = ?",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        _ = try stmt.step();
        return @intCast(stmt.columnInt64(0));
    }

    /// Total content length in bytes for all messages in a session.
    /// Used for token-based compaction decisions.
    pub fn totalContentLength(self: *MessageStore, session_id: []const u8) !usize {
        var stmt = try self.conn.prepare(
            "SELECT COALESCE(SUM(LENGTH(content)), 0) FROM messages WHERE session_id = ?",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);
        _ = try stmt.step();
        return @intCast(stmt.columnInt64(0));
    }

    /// Estimate the actual conversation bytes that would be sent back to the API.
    /// Purpose: compaction decisions should use API-visible content, not stored tool log XML.
    pub fn totalApiVisibleContentLength(self: *MessageStore, session_id: []const u8) !usize {
        var stmt = try self.conn.prepare(
            "SELECT role, content FROM messages WHERE session_id = ? ORDER BY sequence ASC",
        );
        defer stmt.deinit();
        try stmt.bindText(1, session_id);

        var total: usize = 0;
        while (try stmt.step()) {
            const role = stmt.columnText(0) orelse "user";
            const content = stmt.columnText(1) orelse "";
            if (std.mem.eql(u8, role, "assistant")) {
                const clean = try self.stripToolCallsXml(content);
                total += clean.len;
                self.allocator.free(clean);
            } else {
                total += content.len;
            }
        }
        return total;
    }
};

/// Lightweight message info for summarization and display.
pub const MessageInfo = struct {
    id: ?i64,
    role: []const u8,
    content: []const u8,
    created_at: i64,
};
