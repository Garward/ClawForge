// Enhanced handleApiMessages function with pagination support
// Drop-in replacement for lines 718-776 in web_adapter.zig

    // Helper function for parsing query parameters
    fn parseQueryParam(path: []const u8, param: []const u8) ?[]const u8 {
        var pattern_buf: [64]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pattern_buf, "{s}=", .{param}) catch return null;
        
        if (std.mem.indexOf(u8, path, pattern)) |idx| {
            const start = idx + pattern.len;
            const rest = path[start..];
            const end = std.mem.indexOf(u8, rest, "&") orelse rest.len;
            return if (end > 0) rest[0..end] else null;
        }
        return null;
    }

    fn handleApiMessages(self: *WebAdapter, stream: std.net.Stream, path: []const u8) !void {
        // Parse session_id (preserve existing logic)
        const session_id = blk: {
            if (std.mem.indexOf(u8, path, "session_id=")) |idx| {
                const param_start = idx + "session_id=".len;
                const rest = path[param_start..];
                const end = std.mem.indexOf(u8, rest, "&") orelse rest.len;
                if (end >= 36) break :blk rest[0..36];
            }
            break :blk @as(?[]const u8, null);
        };
        
        // Parse pagination parameters
        const limit_str = parseQueryParam(path, "limit") orelse "50";
        const offset_str = parseQueryParam(path, "offset") orelse "0";
        const order = parseQueryParam(path, "order") orelse "asc";
        
        const limit = std.fmt.parseInt(u32, limit_str, 10) catch 50;
        const offset = std.fmt.parseInt(u32, offset_str, 10) catch 0;
        const safe_limit = std.math.clamp(limit, 1, 200); // Prevent abuse
        
        const order_clause = if (std.mem.eql(u8, order, "desc")) "DESC" else "ASC";

        const db_path = "/home/garward/Scripts/Tools/ClawForge/data/workspace.db";
        var query_buf: [1024]u8 = undefined; // Increased buffer size
        
        // Enhanced query with pagination and total count
        const query = if (session_id) |sid|
            std.fmt.bufPrint(&query_buf,
                "SELECT role, content, datetime(created_at, 'unixepoch') as created_at, " ++
                "model_used, input_tokens, output_tokens, sequence, " ++
                "(SELECT COUNT(*) FROM messages WHERE session_id = '{s}') as total_count " ++
                "FROM messages WHERE session_id = '{s}' " ++
                "ORDER BY sequence {s} LIMIT {d} OFFSET {d};",
                .{ sid, sid, order_clause, safe_limit, offset }
            ) catch ""
        else
            std.fmt.bufPrint(&query_buf,
                "WITH latest_session AS (" ++
                    "SELECT id FROM sessions WHERE status='active' " ++
                    "ORDER BY updated_at DESC LIMIT 1" ++
                ") " ++
                "SELECT role, content, datetime(created_at, 'unixepoch') as created_at, " ++
                "model_used, input_tokens, output_tokens, sequence, " ++
                "(SELECT COUNT(*) FROM messages WHERE session_id IN (SELECT id FROM latest_session)) as total_count " ++
                "FROM messages WHERE session_id IN (SELECT id FROM latest_session) " ++
                "ORDER BY sequence {s} LIMIT {d} OFFSET {d};",
                .{ order_clause, safe_limit, offset }
            ) catch "";

        if (query.len == 0) {
            try self.sendHttp(stream, "400 Bad Request", "application/json", "{\"error\":\"Invalid query\"}");
            return;
        }

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "sqlite3", "-json", "-readonly", db_path, query },
            .max_output_bytes = 2 * 1024 * 1024, // Increased for larger datasets
        }) catch {
            try self.sendHttp(stream, "500 Internal Server Error", "application/json", "{\"error\":\"DB query failed\"}");
            return;
        };

        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);

        if (result.stdout.len == 0) {
            // Empty result with pagination metadata
            const empty_response = 
                "{\"messages\":[],\"pagination\":{" ++
                "\"offset\":" ++ offset_str ++ "," ++
                "\"limit\":\"" ++ limit_str ++ "\"," ++
                "\"total_count\":0," ++
                "\"has_more\":false}}";
            try self.sendHttp(stream, "200 OK", "application/json", empty_response);
            return;
        }

        // Check if this is a backwards compatibility request (no pagination params)
        const has_pagination_params = parseQueryParam(path, "limit") != null or parseQueryParam(path, "offset") != null;
        
        if (!has_pagination_params) {
            // Legacy mode: return raw JSON array for backwards compatibility
            try self.sendHttp(stream, "200 OK", "application/json", result.stdout);
            return;
        }

        // New mode: wrap in pagination response
        // For simplicity, we'll construct a simple wrapper rather than full JSON parsing
        var response_buf: [4 * 1024 * 1024]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf,
            "{{\"messages\":{s},\"pagination\":{{" ++
            "\"offset\":{d}," ++
            "\"limit\":{d}," ++
            "\"total_count\":0," ++  // TODO: Extract from result if needed
            "\"has_more\":false" ++   // TODO: Calculate based on offset+limit vs total
            "}}}}",
            .{ result.stdout, offset, safe_limit }
        ) catch {
            // Fallback to raw output if formatting fails
            try self.sendHttp(stream, "200 OK", "application/json", result.stdout);
            return;
        };

        try self.sendHttp(stream, "200 OK", "application/json", response);
    }