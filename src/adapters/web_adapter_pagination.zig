// Enhanced handleApiMessages function with pagination support
// Drop-in replacement for the existing function in web_adapter.zig

fn parseQueryParam(allocator: std.mem.Allocator, path: []const u8, param: []const u8) ?[]const u8 {
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "{s}=", .{param}) catch return null;
    
    if (std.mem.indexOf(u8, path, pattern)) |idx| {
        const start = idx + pattern.len;
        const rest = path[start..];
        const end = std.mem.indexOf(u8, rest, "&") orelse rest.len;
        // URL decode the parameter value if needed
        return if (end > 0) rest[0..end] else null;
    }
    return null;
}

fn handleApiMessages(self: *WebAdapter, stream: std.net.Stream, path: []const u8) !void {
    // Parse query parameters
    const session_id = blk: {
        if (parseQueryParam(self.allocator, path, "session_id")) |sid| {
            if (sid.len >= 36) break :blk sid[0..36];
        }
        break :blk @as(?[]const u8, null);
    };
    
    const limit_str = parseQueryParam(self.allocator, path, "limit") orelse "50";
    const offset_str = parseQueryParam(self.allocator, path, "offset") orelse "0";
    const order = parseQueryParam(self.allocator, path, "order") orelse "asc";
    
    const limit = std.fmt.parseInt(u32, limit_str, 10) catch 50;
    const offset = std.fmt.parseInt(u32, offset_str, 10) catch 0;
    
    // Clamp limit to reasonable bounds (1-200)
    const safe_limit = std.math.clamp(limit, 1, 200);
    
    // Determine sort order
    const order_clause = if (std.mem.eql(u8, order, "desc")) "DESC" else "ASC";

    // Query messages with pagination
    const db_path = "/home/garward/Scripts/Tools/ClawForge/data/workspace.db";
    var query_buf: [1024]u8 = undefined;
    
    const query = if (session_id) |sid| blk: {
        // Query specific session with pagination and total count
        break :blk std.fmt.bufPrint(&query_buf,
            "WITH session_messages AS (" ++
                "SELECT role, content, datetime(created_at, 'unixepoch') as created_at, " ++
                "model_used, input_tokens, output_tokens, sequence, " ++
                "COUNT(*) OVER() as total_count " ++
                "FROM messages WHERE session_id = '{s}' " ++
                "ORDER BY sequence {s} " ++
                "LIMIT {d} OFFSET {d}" ++
            ") SELECT *, total_count FROM session_messages;",
            .{ sid, order_clause, safe_limit, offset }
        ) catch "";
    } else blk: {
        // Query latest active session with pagination
        break :blk std.fmt.bufPrint(&query_buf,
            "WITH latest_session AS (" ++
                "SELECT id FROM sessions WHERE status='active' " ++
                "ORDER BY updated_at DESC LIMIT 1" ++
            "), session_messages AS (" ++
                "SELECT role, content, datetime(created_at, 'unixepoch') as created_at, " ++
                "model_used, input_tokens, output_tokens, sequence, " ++
                "COUNT(*) OVER() as total_count " ++
                "FROM messages WHERE session_id IN (SELECT id FROM latest_session) " ++
                "ORDER BY sequence {s} " ++
                "LIMIT {d} OFFSET {d}" ++
            ") SELECT *, total_count FROM session_messages;",
            .{ order_clause, safe_limit, offset }
        ) catch "";
    };

    if (query.len == 0) {
        try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid query parameters\"}");
        return;
    }

    // Execute paginated query
    const result = std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = &.{ "sqlite3", "-json", "-readonly", db_path, query },
        .max_output_bytes = 2 * 1024 * 1024, // Increased for larger result sets
    }) catch {
        try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"Database query failed\"}");
        return;
    };

    defer self.allocator.free(result.stderr);

    if (result.stdout.len == 0) {
        // Return empty result with pagination metadata
        const empty_response = 
            "{\"messages\":[],\"pagination\":{" ++
            "\"offset\":" ++ offset_str ++ "," ++
            "\"limit\":" ++ limit_str ++ "," ++
            "\"total_count\":0," ++
            "\"has_more\":false" ++
            "}}";
        try self.sendHttp(stream, "200 OK", "application/json", empty_response);
        self.allocator.free(result.stdout);
        return;
    }

    // Parse the JSON result to extract total_count and format response
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    
    const parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, result.stdout) catch {
        // Fallback: return raw result if parsing fails
        try self.sendHttp(stream, "200 OK", "application/json", result.stdout);
        self.allocator.free(result.stdout);
        return;
    };
    
    var total_count: u32 = 0;
    var messages = std.ArrayList(std.json.Value).init(arena_allocator);
    
    // Extract messages and total_count
    if (parsed.value == .array and parsed.value.array.items.len > 0) {
        for (parsed.value.array.items) |item| {
            if (item == .object) {
                // Extract total_count from first message
                if (total_count == 0) {
                    if (item.object.get("total_count")) |tc| {
                        if (tc == .integer) {
                            total_count = @intCast(tc.integer);
                        }
                    }
                }
                
                // Create message object without total_count field
                var msg_obj = std.json.ObjectMap.init(arena_allocator);
                var it = item.object.iterator();
                while (it.next()) |entry| {
                    if (!std.mem.eql(u8, entry.key_ptr.*, "total_count")) {
                        try msg_obj.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
                try messages.append(std.json.Value{ .object = msg_obj });
            }
        }
    }

    // Build response with pagination metadata
    var response_obj = std.json.ObjectMap.init(arena_allocator);
    try response_obj.put("messages", std.json.Value{ .array = messages.items });
    
    var pagination_obj = std.json.ObjectMap.init(arena_allocator);
    try pagination_obj.put("offset", std.json.Value{ .integer = @intCast(offset) });
    try pagination_obj.put("limit", std.json.Value{ .integer = @intCast(safe_limit) });
    try pagination_obj.put("total_count", std.json.Value{ .integer = @intCast(total_count) });
    try pagination_obj.put("has_more", std.json.Value{ .bool = (offset + safe_limit) < total_count });
    
    try response_obj.put("pagination", std.json.Value{ .object = pagination_obj });
    
    // Serialize response
    var response_buf = std.ArrayList(u8).init(arena_allocator);
    std.json.stringify(std.json.Value{ .object = response_obj }, .{}, response_buf.writer()) catch {
        // Fallback to raw output
        try self.sendHttp(stream, "200 OK", "application/json", result.stdout);
        self.allocator.free(result.stdout);
        return;
    };
    
    try self.sendHttp(stream, "200 OK", "application/json", response_buf.items);
    self.allocator.free(result.stdout);
}

// EXAMPLE USAGE:
// 
// GET /api/messages?session_id=ABC123&limit=50&offset=0&order=asc
// Returns:
// {
//   "messages": [
//     {
//       "role": "user",
//       "content": "Hello",
//       "created_at": "2024-01-01 12:00:00",
//       "model_used": null,
//       "input_tokens": null,
//       "output_tokens": null,
//       "sequence": 1
//     },
//     ...
//   ],
//   "pagination": {
//     "offset": 0,
//     "limit": 50,
//     "total_count": 247,
//     "has_more": true
//   }
// }