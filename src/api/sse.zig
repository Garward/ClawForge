const std = @import("std");
const json = std.json;

pub const EventType = enum {
    message_start,
    content_block_start,
    content_block_delta,
    content_block_stop,
    message_delta,
    message_stop,
    ping,
    @"error",

    pub fn fromString(s: []const u8) ?EventType {
        const map = std.StaticStringMap(EventType).initComptime(.{
            .{ "message_start", .message_start },
            .{ "content_block_start", .content_block_start },
            .{ "content_block_delta", .content_block_delta },
            .{ "content_block_stop", .content_block_stop },
            .{ "message_delta", .message_delta },
            .{ "message_stop", .message_stop },
            .{ "ping", .ping },
            .{ "error", .@"error" },
        });
        return map.get(s);
    }
};

pub const SSEEvent = struct {
    event_type: EventType,
    data: json.Value,
};

pub const SSEParser = struct {
    allocator: std.mem.Allocator,
    current_event: ?[]const u8,
    data_buffer: std.array_list.AlignedManaged(u8, null),

    // Accumulated state for building final response
    message_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    stop_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) SSEParser {
        return .{
            .allocator = allocator,
            .current_event = null,
            .data_buffer = std.array_list.AlignedManaged(u8, null).init(allocator),
        };
    }

    pub fn deinit(self: *SSEParser) void {
        self.data_buffer.deinit();
        if (self.message_id) |id| self.allocator.free(id);
        if (self.model) |m| self.allocator.free(m);
        if (self.stop_reason) |sr| self.allocator.free(sr);
    }

    /// Parse a single line of SSE input. Returns an event if one is complete.
    pub fn parseLine(self: *SSEParser, line: []const u8) !?SSEEvent {
        // Empty line = end of event
        if (line.len == 0 or (line.len == 1 and line[0] == '\r')) {
            return try self.emitEvent();
        }

        // Remove trailing \r if present
        const clean_line = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;

        if (std.mem.startsWith(u8, clean_line, "event: ")) {
            self.current_event = clean_line[7..];
        } else if (std.mem.startsWith(u8, clean_line, "data: ")) {
            if (self.data_buffer.items.len > 0) {
                try self.data_buffer.append('\n');
            }
            try self.data_buffer.appendSlice(clean_line[6..]);
        }
        // Ignore other lines (comments starting with :, etc.)

        return null;
    }

    fn emitEvent(self: *SSEParser) !?SSEEvent {
        if (self.current_event == null or self.data_buffer.items.len == 0) {
            self.current_event = null;
            self.data_buffer.clearRetainingCapacity();
            return null;
        }

        const event_type = EventType.fromString(self.current_event.?) orelse {
            self.current_event = null;
            self.data_buffer.clearRetainingCapacity();
            return null;
        };

        const parsed = json.parseFromSlice(json.Value, self.allocator, self.data_buffer.items, .{}) catch {
            self.current_event = null;
            self.data_buffer.clearRetainingCapacity();
            return null;
        };

        // Accumulate metadata
        try self.accumulate(event_type, parsed.value);

        // Reset for next event
        self.current_event = null;
        self.data_buffer.clearRetainingCapacity();

        return .{
            .event_type = event_type,
            .data = parsed.value,
        };
    }

    fn accumulate(self: *SSEParser, event_type: EventType, data: json.Value) !void {
        switch (event_type) {
            .message_start => {
                if (data.object.get("message")) |msg| {
                    if (msg.object.get("id")) |id| {
                        if (self.message_id) |old| self.allocator.free(old);
                        self.message_id = try self.allocator.dupe(u8, id.string);
                    }
                    if (msg.object.get("model")) |m| {
                        if (self.model) |old| self.allocator.free(old);
                        self.model = try self.allocator.dupe(u8, m.string);
                    }
                    if (msg.object.get("usage")) |usage| {
                        if (usage.object.get("input_tokens")) |it| {
                            self.input_tokens = @intCast(it.integer);
                        }
                    }
                }
            },
            .message_delta => {
                if (data.object.get("delta")) |delta| {
                    if (delta.object.get("stop_reason")) |sr| {
                        if (sr != .null) {
                            if (self.stop_reason) |old| self.allocator.free(old);
                            self.stop_reason = try self.allocator.dupe(u8, sr.string);
                        }
                    }
                }
                if (data.object.get("usage")) |usage| {
                    if (usage.object.get("output_tokens")) |ot| {
                        self.output_tokens = @intCast(ot.integer);
                    }
                }
            },
            else => {},
        }
    }

    /// Extract text delta from a content_block_delta event
    pub fn extractTextDelta(data: json.Value) ?[]const u8 {
        const delta = data.object.get("delta") orelse return null;
        if (delta.object.get("type")) |t| {
            if (std.mem.eql(u8, t.string, "text_delta")) {
                if (delta.object.get("text")) |text| {
                    return text.string;
                }
            }
        }
        return null;
    }

    /// Extract tool use info from a content_block_start event
    pub fn extractToolUse(data: json.Value) ?struct { id: []const u8, name: []const u8 } {
        const content_block = data.object.get("content_block") orelse return null;
        if (content_block.object.get("type")) |t| {
            if (std.mem.eql(u8, t.string, "tool_use")) {
                const id = content_block.object.get("id") orelse return null;
                const name = content_block.object.get("name") orelse return null;
                return .{ .id = id.string, .name = name.string };
            }
        }
        return null;
    }

    /// Extract tool input delta
    pub fn extractInputDelta(data: json.Value) ?[]const u8 {
        const delta = data.object.get("delta") orelse return null;
        if (delta.object.get("type")) |t| {
            if (std.mem.eql(u8, t.string, "input_json_delta")) {
                if (delta.object.get("partial_json")) |pj| {
                    return pj.string;
                }
            }
        }
        return null;
    }
};

test "SSEParser parses text delta" {
    const allocator = std.testing.allocator;

    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    _ = try parser.parseLine("event: content_block_delta");
    _ = try parser.parseLine("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}");
    const event = try parser.parseLine("");

    try std.testing.expect(event != null);
    try std.testing.expectEqual(EventType.content_block_delta, event.?.event_type);

    const text = SSEParser.extractTextDelta(event.?.data);
    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("Hello", text.?);
}
