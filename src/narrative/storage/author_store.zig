//! Author Room threads and bounded message history.

const std = @import("std");
const common = @import("common");
const storage = @import("storage");
const domain = @import("../domain/root.zig");

pub const AuthorStore = struct {
    allocator: std.mem.Allocator,
    conn: *storage.Connection,

    pub fn init(allocator: std.mem.Allocator, conn: *storage.Connection) AuthorStore {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn ensureThread(
        self: *AuthorStore,
        story_id: []const u8,
        thread_type: []const u8,
    ) ![]u8 {
        if (!std.mem.eql(u8, thread_type, "author_room") and
            !std.mem.eql(u8, thread_type, "discovery")) return error.InvalidThreadType;
        var find = try self.conn.prepare(
            "SELECT id FROM narrative_author_threads WHERE story_id = ? AND thread_type = ? ORDER BY updated_at DESC LIMIT 1",
        );
        defer find.deinit();
        try find.bindText(1, story_id);
        try find.bindText(2, thread_type);
        if (try find.step()) {
            return try self.allocator.dupe(u8, find.columnText(0) orelse "");
        }

        var id: [36]u8 = undefined;
        generateUuid(&id);
        const now = common.sync.timestamp();
        var insert = try self.conn.prepare(
            "INSERT INTO narrative_author_threads (id, story_id, title, thread_type, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
        );
        defer insert.deinit();
        try insert.bindText(1, &id);
        try insert.bindText(2, story_id);
        try insert.bindText(3, if (std.mem.eql(u8, thread_type, "discovery")) "Guided Discovery" else "Author Room");
        try insert.bindText(4, thread_type);
        try insert.bindInt64(5, now);
        try insert.bindInt64(6, now);
        try insert.exec();
        return try self.allocator.dupe(u8, &id);
    }

    pub fn addMessage(
        self: *AuthorStore,
        thread_id: []const u8,
        role: []const u8,
        content: []const u8,
        model_used: ?[]const u8,
    ) !domain.AuthorMessage {
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant"))
            return error.InvalidRole;
        if (std.mem.trim(u8, content, " \t\r\n").len == 0) return error.EmptyMessage;
        var id: [36]u8 = undefined;
        generateUuid(&id);
        const sequence = try self.nextSequence(thread_id);
        const now = common.sync.timestamp();
        var statement = try self.conn.prepare(
            "INSERT INTO narrative_author_messages (id, thread_id, sequence, role, content, model_used, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        );
        defer statement.deinit();
        try statement.bindText(1, &id);
        try statement.bindText(2, thread_id);
        try statement.bindInt64(3, sequence);
        try statement.bindText(4, role);
        try statement.bindText(5, content);
        try statement.bindOptionalText(6, model_used);
        try statement.bindInt64(7, now);
        try statement.exec();
        var touch = try self.conn.prepare(
            "UPDATE narrative_author_threads SET updated_at = ? WHERE id = ?",
        );
        defer touch.deinit();
        try touch.bindInt64(1, now);
        try touch.bindText(2, thread_id);
        try touch.exec();
        return .{
            .id = try self.allocator.dupe(u8, &id),
            .thread_id = try self.allocator.dupe(u8, thread_id),
            .sequence = sequence,
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
            .model_used = if (model_used) |value| try self.allocator.dupe(u8, value) else null,
            .created_at = now,
        };
    }

    pub fn listMessages(self: *AuthorStore, thread_id: []const u8, limit: i64) ![]domain.AuthorMessage {
        var result: std.ArrayList(domain.AuthorMessage) = .empty;
        errdefer {
            for (result.items) |*message| message.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        var statement = try self.conn.prepare(
            \\SELECT id, thread_id, sequence, role, content, model_used, created_at
            \\FROM (
            \\  SELECT id, thread_id, sequence, role, content, model_used, created_at
            \\  FROM narrative_author_messages
            \\  WHERE thread_id = ? ORDER BY sequence DESC LIMIT ?
            \\) ORDER BY sequence
        );
        defer statement.deinit();
        try statement.bindText(1, thread_id);
        try statement.bindInt64(2, limit);
        while (try statement.step()) {
            try result.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, statement.columnText(0) orelse ""),
                .thread_id = try self.allocator.dupe(u8, statement.columnText(1) orelse ""),
                .sequence = statement.columnInt64(2),
                .role = try self.allocator.dupe(u8, statement.columnText(3) orelse ""),
                .content = try self.allocator.dupe(u8, statement.columnText(4) orelse ""),
                .model_used = if (statement.columnOptionalText(5)) |value|
                    try self.allocator.dupe(u8, value)
                else
                    null,
                .created_at = statement.columnInt64(6),
            });
        }
        return try result.toOwnedSlice(self.allocator);
    }

    fn nextSequence(self: *AuthorStore, thread_id: []const u8) !i64 {
        var statement = try self.conn.prepare(
            "SELECT COALESCE(MAX(sequence), 0) + 1 FROM narrative_author_messages WHERE thread_id = ?",
        );
        defer statement.deinit();
        try statement.bindText(1, thread_id);
        _ = try statement.step();
        return statement.columnInt64(0);
    }
};

fn generateUuid(buffer: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    std.Io.random(common.config.runtimeIo(), &bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var source: usize = 0;
    var destination: usize = 0;
    while (source < bytes.len) : (source += 1) {
        if (source == 4 or source == 6 or source == 8 or source == 10) {
            buffer[destination] = '-';
            destination += 1;
        }
        buffer[destination] = hex[bytes[source] >> 4];
        buffer[destination + 1] = hex[bytes[source] & 0x0f];
        destination += 2;
    }
}
