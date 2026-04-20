const std = @import("std");
const json = std.json;
const common = @import("common");
const registry = @import("registry.zig");

pub const definition = registry.ToolDefinition{
    .name = "introspect",
    .description = "Query ClawForge's full database: conversations, knowledge base, summaries, projects, tools." ++
        " USE THIS for ANY question about past conversations, learned facts, project state, or your own behavior." ++
        " Modes: 'message_search' (FTS across all messages), 'message_history' (recent messages)," ++
        " 'knowledge_search' (search learned facts by text), 'knowledge_browse' (list by category)," ++
        " 'summary_search' (search conversation summaries), 'summary_history' (summaries for session/project)," ++
        " 'projects' (list projects with status), 'project_context' (rolling context for a project)," ++
        " 'semantic_search' (hybrid FTS+vector via Ollama embeddings — best for meaning-based recall)," ++
        " 'project_tree' (browse the ClawForge source tree — use query to filter by path/name, e.g. 'src/tools' or '*.zig')," ++
        " 'sessions', 'tool_stats', 'tool_history', 'session_stats', 'metrics'." ++
        " For finding relevant past context, prefer 'semantic_search' over 'message_search' — it finds meaning, not just keywords." ++
        " For locating files quickly, use 'project_tree' — faster than bash find and respects .gitignore.",
    .input_schema_json =
        \\{"type":"object","properties":{"mode":{"type":"string","enum":["semantic_search","message_search","message_history","knowledge_search","knowledge_browse","summary_search","summary_history","projects","project_context","project_tree","sessions","tool_stats","tool_history","session_stats","metrics"],"description":"What to query. Use semantic_search for meaning-based recall across all data. Use project_tree to browse/search the source tree."},"query":{"type":"string","description":"Search term (required for *_search modes). For project_tree: optional filter — a subdirectory path (e.g. 'src/tools') or glob pattern (e.g. '*.zig')."},"source_type":{"type":"string","description":"Filter semantic_search by source: 'message', 'summary', or 'knowledge'"},"category":{"type":"string","description":"Filter knowledge by category"},"session_id":{"type":"string","description":"Filter by session ID"},"project_id":{"type":"string","description":"Filter by project ID or name"},"role":{"type":"string","description":"Filter by role: 'user' or 'assistant'"},"date":{"type":"string","description":"Filter by date (YYYY-MM-DD)"},"tool_name":{"type":"string","description":"Filter by tool name"},"limit":{"type":"integer","description":"Max rows (default 20, for project_tree: max depth, default 4)"}},"required":["mode"]}
    ,
    .requires_confirmation = false,
    .handler = &execute,
};


fn execute(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    if (input != .object) {
        return .{ .content = "Expected JSON object with 'mode'", .is_error = true };
    }

    const mode = blk: {
        if (input.object.get("mode")) |m| {
            if (m == .string) break :blk m.string;
        }
        return .{ .content = "Missing 'mode' parameter", .is_error = true };
    };

    const date_filter = if (input.object.get("date")) |d| (if (d == .string) d.string else null) else null;
    const tool_filter = if (input.object.get("tool_name")) |t| (if (t == .string) t.string else null) else null;
    const query_filter = if (input.object.get("query")) |q| (if (q == .string) q.string else null) else null;
    const session_filter = if (input.object.get("session_id")) |s| (if (s == .string) s.string else null) else null;
    const role_filter = if (input.object.get("role")) |r| (if (r == .string) r.string else null) else null;
    const category_filter = if (input.object.get("category")) |c| (if (c == .string) c.string else null) else null;
    const project_filter = if (input.object.get("project_id")) |p| (if (p == .string) p.string else null) else null;

    var limit_buf: [16]u8 = undefined;
    const limit_str = if (input.object.get("limit")) |l| (if (l == .integer)
        (std.fmt.bufPrint(&limit_buf, "{d}", .{l.integer}) catch "50")
    else
        "50") else "50";

    // Semantic search uses the Python hybrid search script (Ollama + FTS + RRF)
    if (std.mem.eql(u8, mode, "semantic_search")) {
        return executeSemanticSearch(allocator, input);
    }

    // Project tree uses git ls-files / find — not SQL
    if (std.mem.eql(u8, mode, "project_tree")) {
        return executeProjectTree(allocator, query_filter, limit_str);
    }

    // Build SQL query based on mode
    const sql = if (std.mem.eql(u8, mode, "message_search"))
        buildMessageSearchQuery(allocator, query_filter, role_filter, date_filter, limit_str)
    else if (std.mem.eql(u8, mode, "message_history"))
        buildMessageHistoryQuery(allocator, session_filter, role_filter, date_filter, limit_str)
    else if (std.mem.eql(u8, mode, "sessions"))
        buildSessionsQuery(allocator, date_filter, limit_str)
    else if (std.mem.eql(u8, mode, "knowledge_search"))
        buildKnowledgeSearchQuery(allocator, query_filter, category_filter, limit_str)
    else if (std.mem.eql(u8, mode, "knowledge_browse"))
        buildKnowledgeBrowseQuery(allocator, category_filter, limit_str)
    else if (std.mem.eql(u8, mode, "summary_search"))
        buildSummarySearchQuery(allocator, query_filter, date_filter, limit_str)
    else if (std.mem.eql(u8, mode, "summary_history"))
        buildSummaryHistoryQuery(allocator, session_filter, project_filter, limit_str)
    else if (std.mem.eql(u8, mode, "projects"))
        buildProjectsQuery(allocator, limit_str)
    else if (std.mem.eql(u8, mode, "project_context"))
        buildProjectContextQuery(allocator, project_filter)
    else if (std.mem.eql(u8, mode, "tool_stats"))
        buildToolStatsQuery(allocator, date_filter, tool_filter)
    else if (std.mem.eql(u8, mode, "tool_history"))
        buildToolHistoryQuery(allocator, date_filter, tool_filter, limit_str)
    else if (std.mem.eql(u8, mode, "session_stats"))
        buildSessionStatsQuery(allocator, date_filter)
    else if (std.mem.eql(u8, mode, "metrics"))
        buildMetricsQuery(allocator, session_filter)
    else
        return .{ .content = "Unknown mode.", .is_error = true };

    const query = sql orelse return .{ .content = "Failed to build query", .is_error = true };

    const db_path = common.config.getDbPath(allocator) catch
        return .{ .content = "Failed to resolve DB path", .is_error = true };
    defer allocator.free(db_path);

    // Run sqlite3 with the query
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sqlite3", "-json", "-readonly", db_path, query },
        .max_output_bytes = 256 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "SQLite query failed: {s}", .{@errorName(err)}) catch
            return .{ .content = "SQLite query failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        defer allocator.free(result.stdout);
        const msg = if (result.stderr.len > 0)
            std.fmt.allocPrint(allocator, "Query error: {s}", .{result.stderr}) catch "Query error"
        else
            "Query returned non-zero exit";
        return .{ .content = msg, .is_error = true };
    }

    if (result.stdout.len == 0) {
        return .{ .content = "[]", .is_error = false };
    }

    return .{ .content = result.stdout, .is_error = false };
}

fn executeSemanticSearch(allocator: std.mem.Allocator, input: json.Value) registry.ToolResult {
    // Serialize input to JSON for the Python script
    var input_aw: std.Io.Writer.Allocating = .init(allocator);
    json.Stringify.value(input, .{}, &input_aw.writer) catch {
        return .{ .content = "Failed to serialize input", .is_error = true };
    };
    const input_str = input_aw.written();

    const python = common.config.getPython(allocator) catch
        return .{ .content = "Failed to resolve python", .is_error = true };
    defer allocator.free(python);
    const script = common.config.getToolScript(allocator, "hybrid_search.py") catch
        return .{ .content = "Failed to resolve search script", .is_error = true };
    defer allocator.free(script);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ python, script, input_str },
        .max_output_bytes = 512 * 1024,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Semantic search failed: {s}", .{@errorName(err)}) catch
            return .{ .content = "Semantic search failed", .is_error = true };
        return .{ .content = msg, .is_error = true };
    };

    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        defer allocator.free(result.stdout);
        const msg = if (result.stderr.len > 0)
            std.fmt.allocPrint(allocator, "Search error: {s}", .{result.stderr}) catch "Search error"
        else
            "Search script error";
        return .{ .content = msg, .is_error = true };
    }

    return .{ .content = result.stdout, .is_error = false };
}

fn executeProjectTree(allocator: std.mem.Allocator, query: ?[]const u8, limit_str: []const u8) registry.ToolResult {
    // Parse depth limit from limit_str (default 4)
    const max_depth = std.fmt.parseInt(u8, limit_str, 10) catch 4;
    const depth_str = std.fmt.allocPrint(allocator, "{d}", .{@min(max_depth, 8)}) catch "4";

    const project_root = common.config.getProjectRoot(allocator) catch
        return .{ .content = "Failed to resolve project root", .is_error = true };
    defer allocator.free(project_root);

    if (query) |q| {
        // Safety: reject anything with shell metacharacters
        for (q) |c| {
            switch (c) {
                '|', ';', '&', '>', '<', '`', '$', '(', ')', '{', '}', '!', '\\' => {
                    return .{ .content = "Invalid characters in query", .is_error = true };
                },
                else => {},
            }
        }

        // Check if query looks like a subdir path (contains / or no wildcards)
        const is_subdir = std.mem.indexOf(u8, q, "*") == null and
            std.mem.indexOf(u8, q, "?") == null;

        if (is_subdir) {
            // Treat as subdirectory — list that subtree
            const target = std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, q }) catch
                return .{ .content = "Path too long", .is_error = true };

            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{
                    "find", target,
                    "-maxdepth", depth_str,
                    "-not", "-path", "*/.zig-cache/*",
                    "-not", "-path", "*/__pycache__/*",
                    "-not", "-path", "*/.git/*",
                    "-not", "-path", "*/data/*",
                    "-not", "-name", "*.o",
                    "-not", "-name", "*.pyc",
                },
                .max_output_bytes = 128 * 1024,
            }) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "find error: {s}", .{@errorName(err)}) catch
                    return .{ .content = "find failed", .is_error = true };
                return .{ .content = msg, .is_error = true };
            };
            defer allocator.free(result.stderr);

            if (result.stdout.len == 0) {
                return .{ .content = "No files found (directory may not exist)", .is_error = false };
            }

            // Strip the project root prefix from each line for cleaner output
            return .{ .content = stripProjectRoot(allocator, project_root, result.stdout) orelse result.stdout, .is_error = false };
        } else {
            // Glob pattern — use find with -name
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{
                    "find", project_root,
                    "-maxdepth", depth_str,
                    "-name", q,
                    "-not", "-path", "*/.zig-cache/*",
                    "-not", "-path", "*/__pycache__/*",
                    "-not", "-path", "*/.git/*",
                    "-not", "-path", "*/data/*",
                },
                .max_output_bytes = 128 * 1024,
            }) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "find error: {s}", .{@errorName(err)}) catch
                    return .{ .content = "find failed", .is_error = true };
                return .{ .content = msg, .is_error = true };
            };
            defer allocator.free(result.stderr);

            if (result.stdout.len == 0) {
                return .{ .content = "No files matching pattern", .is_error = false };
            }

            return .{ .content = stripProjectRoot(allocator, project_root, result.stdout) orelse result.stdout, .is_error = false };
        }
    } else {
        // No query — show full project tree with default depth
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "find", project_root,
                "-maxdepth", depth_str,
                "-not", "-path", "*/.zig-cache/*",
                "-not", "-path", "*/__pycache__/*",
                "-not", "-path", "*/.git/*",
                "-not", "-path", "*/data/*",
                "-not", "-name", "*.o",
                "-not", "-name", "*.pyc",
                "-type", "f",
            },
            .max_output_bytes = 128 * 1024,
        }) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "find error: {s}", .{@errorName(err)}) catch
                return .{ .content = "find failed", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
        defer allocator.free(result.stderr);

        if (result.stdout.len == 0) {
            return .{ .content = "No files found", .is_error = false };
        }

        // Sort the output for readability
        return .{ .content = stripProjectRoot(allocator, project_root, result.stdout) orelse result.stdout, .is_error = false };
    }
}

/// Strip the project root prefix from each line of find output for cleaner display.
fn stripProjectRoot(allocator: std.mem.Allocator, project_root: []const u8, raw: []const u8) ?[]const u8 {
    const prefix = std.fmt.allocPrint(allocator, "{s}/", .{project_root}) catch return null;
    defer allocator.free(prefix);
    var out: std.ArrayList(u8) = .{};
    var iter = std.mem.splitScalar(u8, raw, '\n');
    var first = true;
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (!first) out.append(allocator, '\n') catch return null;
        first = false;
        if (std.mem.startsWith(u8, line, prefix)) {
            out.appendSlice(allocator, line[prefix.len..]) catch return null;
        } else if (std.mem.eql(u8, line, project_root)) {
            out.appendSlice(allocator, ".") catch return null;
        } else {
            out.appendSlice(allocator, line) catch return null;
        }
    }
    out.append(allocator, '\n') catch return null;
    return out.items;
}

fn buildToolStatsQuery(allocator: std.mem.Allocator, date: ?[]const u8, tool: ?[]const u8) ?[]const u8 {
    var parts: std.ArrayList(u8) = .{};
    parts.appendSlice(allocator,
        "SELECT tool_name, COUNT(*) as call_count, " ++
        "date(created_at, 'unixepoch') as day, " ++
        "SUM(CASE WHEN status='success' THEN 1 ELSE 0 END) as successes, " ++
        "SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) as errors, " ++
        "SUM(CASE WHEN status='rejected' THEN 1 ELSE 0 END) as rejected " ++
        "FROM tool_calls WHERE 1=1",
    ) catch return null;

    if (date) |d| {
        parts.appendSlice(allocator, " AND date(created_at, 'unixepoch') = '") catch return null;
        parts.appendSlice(allocator, d) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    if (tool) |t| {
        parts.appendSlice(allocator, " AND tool_name = '") catch return null;
        parts.appendSlice(allocator, t) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    parts.appendSlice(allocator, " GROUP BY tool_name, day ORDER BY call_count DESC;") catch return null;
    return parts.items;
}

fn buildToolHistoryQuery(allocator: std.mem.Allocator, date: ?[]const u8, tool: ?[]const u8, limit: []const u8) ?[]const u8 {
    var parts: std.ArrayList(u8) = .{};
    parts.appendSlice(allocator,
        "SELECT tool_name, tool_input, " ++
        "SUBSTR(tool_result, 1, 500) as result_preview, " ++
        "status, datetime(created_at, 'unixepoch') as called_at " ++
        "FROM tool_calls WHERE 1=1",
    ) catch return null;

    if (date) |d| {
        parts.appendSlice(allocator, " AND date(created_at, 'unixepoch') = '") catch return null;
        parts.appendSlice(allocator, d) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    if (tool) |t| {
        parts.appendSlice(allocator, " AND tool_name = '") catch return null;
        parts.appendSlice(allocator, t) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    parts.appendSlice(allocator, " ORDER BY created_at DESC LIMIT ") catch return null;
    parts.appendSlice(allocator, limit) catch return null;
    parts.appendSlice(allocator, ";") catch return null;
    return parts.items;
}

fn buildSessionStatsQuery(allocator: std.mem.Allocator, date: ?[]const u8) ?[]const u8 {
    var parts: std.ArrayList(u8) = .{};
    const date_clause = "WHERE date(created_at, 'unixepoch') = '";

    parts.appendSlice(allocator, "SELECT (SELECT COUNT(*) FROM sessions") catch return null;
    if (date) |d| {
        parts.appendSlice(allocator, " ") catch return null;
        parts.appendSlice(allocator, date_clause) catch return null;
        parts.appendSlice(allocator, d) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    parts.appendSlice(allocator, ") as total_sessions, (SELECT COUNT(*) FROM messages") catch return null;
    if (date) |d| {
        parts.appendSlice(allocator, " ") catch return null;
        parts.appendSlice(allocator, date_clause) catch return null;
        parts.appendSlice(allocator, d) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    parts.appendSlice(allocator, ") as total_messages, (SELECT COUNT(*) FROM tool_calls") catch return null;
    if (date) |d| {
        parts.appendSlice(allocator, " ") catch return null;
        parts.appendSlice(allocator, date_clause) catch return null;
        parts.appendSlice(allocator, d) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    parts.appendSlice(allocator, ") as total_tool_calls;") catch return null;
    return parts.items;
}

fn buildMessageSearchQuery(allocator: std.mem.Allocator, query: ?[]const u8, role: ?[]const u8, date: ?[]const u8, limit: []const u8) ?[]const u8 {
    const search_term = query orelse return buildMessageHistoryQuery(allocator, null, role, date, limit);

    var parts: std.ArrayList(u8) = .{};
    // Use FTS5 for full-text search across all messages
    parts.appendSlice(allocator,
        "SELECT m.role, SUBSTR(m.content, 1, 500) as content_preview, " ++
        "m.session_id, datetime(m.created_at, 'unixepoch') as sent_at, " ++
        "m.model_used " ++
        "FROM messages_fts fts " ++
        "JOIN messages m ON m.rowid = fts.rowid " ++
        "WHERE messages_fts MATCH '",
    ) catch return null;
    // Escape single quotes in search term
    for (search_term) |ch| {
        if (ch == '\'') {
            parts.appendSlice(allocator, "''") catch return null;
        } else {
            parts.append(allocator, ch) catch return null;
        }
    }
    parts.appendSlice(allocator, "'") catch return null;

    if (role) |r| {
        parts.appendSlice(allocator, " AND m.role = '") catch return null;
        parts.appendSlice(allocator, r) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    if (date) |d| {
        parts.appendSlice(allocator, " AND date(m.created_at, 'unixepoch') = '") catch return null;
        parts.appendSlice(allocator, d) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    parts.appendSlice(allocator, " ORDER BY m.created_at DESC LIMIT ") catch return null;
    parts.appendSlice(allocator, limit) catch return null;
    parts.appendSlice(allocator, ";") catch return null;
    return parts.items;
}

fn buildMessageHistoryQuery(allocator: std.mem.Allocator, session_id: ?[]const u8, role: ?[]const u8, date: ?[]const u8, limit: []const u8) ?[]const u8 {
    var parts: std.ArrayList(u8) = .{};
    parts.appendSlice(allocator,
        "SELECT role, SUBSTR(content, 1, 500) as content_preview, " ++
        "session_id, datetime(created_at, 'unixepoch') as sent_at, " ++
        "model_used " ++
        "FROM messages WHERE 1=1",
    ) catch return null;

    if (session_id) |sid| {
        parts.appendSlice(allocator, " AND session_id = '") catch return null;
        parts.appendSlice(allocator, sid) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    if (role) |r| {
        parts.appendSlice(allocator, " AND role = '") catch return null;
        parts.appendSlice(allocator, r) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    if (date) |d| {
        parts.appendSlice(allocator, " AND date(created_at, 'unixepoch') = '") catch return null;
        parts.appendSlice(allocator, d) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    parts.appendSlice(allocator, " ORDER BY created_at DESC LIMIT ") catch return null;
    parts.appendSlice(allocator, limit) catch return null;
    parts.appendSlice(allocator, ";") catch return null;
    return parts.items;
}

fn appendEscaped(parts: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) void {
    for (text) |ch| {
        if (ch == '\'') {
            parts.appendSlice(allocator, "''") catch return;
        } else {
            parts.append(allocator, ch) catch return;
        }
    }
}

fn buildKnowledgeSearchQuery(allocator: std.mem.Allocator, query: ?[]const u8, category: ?[]const u8, limit: []const u8) ?[]const u8 {
    var parts: std.ArrayList(u8) = .{};

    if (query) |q| {
        // FTS search on knowledge
        parts.appendSlice(allocator,
            "SELECT k.title, k.content, k.category, k.subcategory, " ++
            "k.confidence, k.mention_count, k.tags, " ++
            "datetime(k.first_seen, 'unixepoch') as first_seen, " ++
            "datetime(k.last_reinforced, 'unixepoch') as last_reinforced " ++
            "FROM knowledge_fts fts " ++
            "JOIN knowledge k ON k.rowid = fts.rowid " ++
            "WHERE knowledge_fts MATCH '",
        ) catch return null;
        appendEscaped(&parts, allocator, q);
        parts.appendSlice(allocator, "'") catch return null;
        if (category) |c| {
            parts.appendSlice(allocator, " AND k.category = '") catch return null;
            appendEscaped(&parts, allocator, c);
            parts.appendSlice(allocator, "'") catch return null;
        }
    } else {
        // No search term — list recent knowledge
        parts.appendSlice(allocator,
            "SELECT title, content, category, subcategory, " ++
            "confidence, mention_count, tags, " ++
            "datetime(first_seen, 'unixepoch') as first_seen, " ++
            "datetime(last_reinforced, 'unixepoch') as last_reinforced " ++
            "FROM knowledge WHERE 1=1",
        ) catch return null;
        if (category) |c| {
            parts.appendSlice(allocator, " AND category = '") catch return null;
            appendEscaped(&parts, allocator, c);
            parts.appendSlice(allocator, "'") catch return null;
        }
    }
    parts.appendSlice(allocator, " ORDER BY confidence DESC, mention_count DESC LIMIT ") catch return null;
    parts.appendSlice(allocator, limit) catch return null;
    parts.appendSlice(allocator, ";") catch return null;
    return parts.items;
}

fn buildKnowledgeBrowseQuery(allocator: std.mem.Allocator, category: ?[]const u8, limit: []const u8) ?[]const u8 {
    var parts: std.ArrayList(u8) = .{};

    if (category) |c| {
        // List entries in a specific category
        parts.appendSlice(allocator,
            "SELECT title, SUBSTR(content, 1, 300) as content_preview, " ++
            "subcategory, confidence, mention_count, tags " ++
            "FROM knowledge WHERE category = '",
        ) catch return null;
        appendEscaped(&parts, allocator, c);
        parts.appendSlice(allocator, "' ORDER BY confidence DESC LIMIT ") catch return null;
        parts.appendSlice(allocator, limit) catch return null;
        parts.appendSlice(allocator, ";") catch return null;
    } else {
        // List all categories with counts
        parts.appendSlice(allocator,
            "SELECT category, COUNT(*) as entry_count, " ++
            "ROUND(AVG(confidence), 2) as avg_confidence, " ++
            "SUM(mention_count) as total_mentions " ++
            "FROM knowledge GROUP BY category ORDER BY entry_count DESC;",
        ) catch return null;
    }
    return parts.items;
}

fn buildSummarySearchQuery(allocator: std.mem.Allocator, query: ?[]const u8, date: ?[]const u8, limit: []const u8) ?[]const u8 {
    var parts: std.ArrayList(u8) = .{};

    if (query) |q| {
        parts.appendSlice(allocator,
            "SELECT s.scope, s.summary, s.topics, s.recall, " ++
            "s.message_count, s.session_id, s.project_id, " ++
            "datetime(s.start_time, 'unixepoch') as period_start, " ++
            "datetime(s.end_time, 'unixepoch') as period_end " ++
            "FROM summaries_fts fts " ++
            "JOIN summaries s ON s.rowid = fts.rowid " ++
            "WHERE summaries_fts MATCH '",
        ) catch return null;
        appendEscaped(&parts, allocator, q);
        parts.appendSlice(allocator, "'") catch return null;
    } else {
        parts.appendSlice(allocator,
            "SELECT scope, summary, topics, recall, " ++
            "message_count, session_id, project_id, " ++
            "datetime(start_time, 'unixepoch') as period_start, " ++
            "datetime(end_time, 'unixepoch') as period_end " ++
            "FROM summaries WHERE 1=1",
        ) catch return null;
    }
    if (date) |d| {
        parts.appendSlice(allocator, " AND date(") catch return null;
        parts.appendSlice(allocator, if (query != null) "s." else "") catch return null;
        parts.appendSlice(allocator, "end_time, 'unixepoch') = '") catch return null;
        parts.appendSlice(allocator, d) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    parts.appendSlice(allocator, " ORDER BY ") catch return null;
    parts.appendSlice(allocator, if (query != null) "s." else "") catch return null;
    parts.appendSlice(allocator, "end_time DESC LIMIT ") catch return null;
    parts.appendSlice(allocator, limit) catch return null;
    parts.appendSlice(allocator, ";") catch return null;
    return parts.items;
}

fn buildSummaryHistoryQuery(allocator: std.mem.Allocator, session_id: ?[]const u8, project_id: ?[]const u8, limit: []const u8) ?[]const u8 {
    var parts: std.ArrayList(u8) = .{};
    parts.appendSlice(allocator,
        "SELECT scope, SUBSTR(summary, 1, 500) as summary_preview, topics, recall, " ++
        "message_count, session_id, project_id, " ++
        "datetime(start_time, 'unixepoch') as period_start, " ++
        "datetime(end_time, 'unixepoch') as period_end " ++
        "FROM summaries WHERE 1=1",
    ) catch return null;

    if (session_id) |sid| {
        parts.appendSlice(allocator, " AND session_id = '") catch return null;
        appendEscaped(&parts, allocator, sid);
        parts.appendSlice(allocator, "'") catch return null;
    }
    if (project_id) |pid| {
        // Allow searching by project name or ID
        parts.appendSlice(allocator, " AND (project_id = '") catch return null;
        appendEscaped(&parts, allocator, pid);
        parts.appendSlice(allocator,
            "' OR project_id IN (SELECT id FROM projects WHERE name = '",
        ) catch return null;
        appendEscaped(&parts, allocator, pid);
        parts.appendSlice(allocator, "'))") catch return null;
    }
    parts.appendSlice(allocator, " ORDER BY end_time DESC LIMIT ") catch return null;
    parts.appendSlice(allocator, limit) catch return null;
    parts.appendSlice(allocator, ";") catch return null;
    return parts.items;
}

fn buildProjectsQuery(allocator: std.mem.Allocator, limit: []const u8) ?[]const u8 {
    var parts: std.ArrayList(u8) = .{};
    parts.appendSlice(allocator,
        "SELECT p.id, p.name, p.description, p.status, " ++
        "SUBSTR(p.rolling_summary, 1, 300) as summary_preview, " ++
        "datetime(p.created_at, 'unixepoch') as created, " ++
        "datetime(p.updated_at, 'unixepoch') as last_updated, " ++
        "(SELECT COUNT(*) FROM sessions WHERE project_id = p.id) as session_count, " ++
        "(SELECT COUNT(*) FROM summaries WHERE project_id = p.id) as summary_count " ++
        "FROM projects p ORDER BY p.updated_at DESC LIMIT ",
    ) catch return null;
    parts.appendSlice(allocator, limit) catch return null;
    parts.appendSlice(allocator, ";") catch return null;
    return parts.items;
}

fn buildProjectContextQuery(allocator: std.mem.Allocator, project_id: ?[]const u8) ?[]const u8 {
    const pid = project_id orelse return null;
    var parts: std.ArrayList(u8) = .{};
    // Get full rolling context + recent summaries for a project
    parts.appendSlice(allocator,
        "SELECT p.name, p.description, p.status, " ++
        "p.rolling_summary, p.rolling_state, " ++
        "datetime(p.created_at, 'unixepoch') as created, " ++
        "datetime(p.updated_at, 'unixepoch') as last_updated " ++
        "FROM projects p WHERE p.id = '",
    ) catch return null;
    appendEscaped(&parts, allocator, pid);
    parts.appendSlice(allocator, "' OR p.name = '") catch return null;
    appendEscaped(&parts, allocator, pid);
    parts.appendSlice(allocator, "' LIMIT 1;") catch return null;
    return parts.items;
}

fn buildSessionsQuery(allocator: std.mem.Allocator, date: ?[]const u8, limit: []const u8) ?[]const u8 {
    var parts: std.ArrayList(u8) = .{};
    parts.appendSlice(allocator,
        "SELECT s.id, s.name, s.model, s.message_count, s.status, " ++
        "datetime(s.created_at, 'unixepoch') as created, " ++
        "datetime(s.updated_at, 'unixepoch') as last_active, " ++
        "(SELECT SUBSTR(content, 1, 100) FROM messages WHERE session_id = s.id AND role = 'user' ORDER BY sequence ASC LIMIT 1) as first_message " ++
        "FROM sessions s WHERE 1=1",
    ) catch return null;

    if (date) |d| {
        parts.appendSlice(allocator, " AND date(s.updated_at, 'unixepoch') = '") catch return null;
        parts.appendSlice(allocator, d) catch return null;
        parts.appendSlice(allocator, "'") catch return null;
    }
    parts.appendSlice(allocator, " ORDER BY s.updated_at DESC LIMIT ") catch return null;
    parts.appendSlice(allocator, limit) catch return null;
    parts.appendSlice(allocator, ";") catch return null;
    return parts.items;
}

fn buildMetricsQuery(allocator: std.mem.Allocator, session_filter: ?[]const u8) ?[]const u8 {
    var parts: std.ArrayList(u8) = .{};
    
    parts.appendSlice(allocator, "SELECT ") catch return null;
    parts.appendSlice(allocator, "'session_id' as metric, s.session_id as value, ") catch return null;
    parts.appendSlice(allocator, "'token_usage' as details, ") catch return null;
    parts.appendSlice(allocator, "COALESCE(SUM(m.input_tokens), 0) as input_tokens, ") catch return null;
    parts.appendSlice(allocator, "COALESCE(SUM(m.output_tokens), 0) as output_tokens, ") catch return null;
    parts.appendSlice(allocator, "COALESCE(SUM(m.input_tokens + m.output_tokens), 0) as total_tokens, ") catch return null;
    parts.appendSlice(allocator, "COUNT(m.id) as message_count ") catch return null;
    parts.appendSlice(allocator, "FROM sessions s ") catch return null;
    parts.appendSlice(allocator, "LEFT JOIN messages m ON s.session_id = m.session_id ") catch return null;
    
    if (session_filter) |sf| {
        parts.appendSlice(allocator, "WHERE s.session_id = '") catch return null;
        appendEscaped(&parts, allocator, sf);
        parts.appendSlice(allocator, "' ") catch return null;
    } else {
        // Get current session by default
        parts.appendSlice(allocator, "WHERE s.session_id = (SELECT session_id FROM sessions ORDER BY updated_at DESC LIMIT 1) ") catch return null;
    }
    
    parts.appendSlice(allocator, "GROUP BY s.session_id ") catch return null;
    parts.appendSlice(allocator, "ORDER BY s.updated_at DESC;") catch return null;
    
    return parts.items;
}
