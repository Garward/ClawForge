const std = @import("std");
const storage = @import("storage");

/// Embedding worker. Generates vector embeddings via local Ollama API.
///
/// Uses Ollama's /api/embeddings endpoint for local, GPU-accelerated embeddings.
/// Generates contextual chunk headers (Anthropic's approach) before embedding
/// to improve retrieval quality.
///
/// Public API callable by engine hooks, adapters, or background workers.
pub const Embedder = struct {
    allocator: std.mem.Allocator,
    embedding_store: *storage.EmbeddingStore,
    /// Ollama API endpoint for embeddings
    ollama_url: []const u8 = "http://127.0.0.1:11434/api/embeddings",
    /// Embedding model name
    model: []const u8 = "nomic-embed-text",

    pub fn init(
        allocator: std.mem.Allocator,
        embedding_store: *storage.EmbeddingStore,
    ) Embedder {
        return .{
            .allocator = allocator,
            .embedding_store = embedding_store,
        };
    }

    // ================================================================
    // PUBLIC API
    // ================================================================

    /// Embed a single text and store it. Returns the embedding id.
    pub fn embedAndStore(
        self: *Embedder,
        source_type: []const u8,
        source_id: i64,
        text: []const u8,
        context_header: ?[]const u8,
    ) !i64 {
        // Build contextual chunk: header + text (Anthropic's approach — 49% fewer failed retrievals)
        var chunk_buf: [8192]u8 = undefined;
        var chunk_len: usize = 0;

        if (context_header) |header| {
            const h_len = @min(header.len, 500);
            @memcpy(chunk_buf[0..h_len], header[0..h_len]);
            chunk_len = h_len;
            chunk_buf[chunk_len] = '\n';
            chunk_len += 1;
        }

        const t_len = @min(text.len, chunk_buf.len - chunk_len - 1);
        @memcpy(chunk_buf[chunk_len..][0..t_len], text[0..t_len]);
        chunk_len += t_len;

        const chunk_text = chunk_buf[0..chunk_len];

        // Generate embedding via Ollama
        const vector = try self.generateEmbedding(chunk_text);
        defer self.allocator.free(vector);

        // Store in DB
        return try self.embedding_store.store(
            source_type,
            source_id,
            chunk_text,
            context_header,
            vector,
            self.model,
        );
    }

    /// Embed a query text (no storage, just returns the vector).
    /// Used for search queries.
    pub fn embedQuery(self: *Embedder, text: []const u8) ![]f32 {
        return try self.generateEmbedding(text);
    }

    /// Build a contextual header for a message.
    /// Anthropic's approach: prepend context before embedding for better retrieval.
    pub fn buildContextHeader(
        allocator: std.mem.Allocator,
        source_type: []const u8,
        project_name: ?[]const u8,
        session_name: ?[]const u8,
    ) ![]const u8 {
        var buf: [256]u8 = undefined;
        var pos: usize = 0;

        const write = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                const len = @min(data.len, b.len -| p.*);
                @memcpy(b[p.*..][0..len], data[0..len]);
                p.* += len;
            }
        }.f;

        write(&buf, &pos, "From a ");
        write(&buf, &pos, source_type);

        if (project_name) |pn| {
            write(&buf, &pos, " in project ");
            write(&buf, &pos, pn);
        }

        if (session_name) |sn| {
            write(&buf, &pos, " (session: ");
            write(&buf, &pos, sn);
            write(&buf, &pos, ")");
        }

        write(&buf, &pos, ":");

        return try allocator.dupe(u8, buf[0..pos]);
    }

    // ================================================================
    // INTERNAL — Ollama API call
    // ================================================================

    fn generateEmbedding(self: *Embedder, text: []const u8) ![]f32 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Build request body: {"model": "...", "prompt": "..."}
        var body_buf: [16384]u8 = undefined;
        var pos: usize = 0;

        const write = struct {
            fn f(b: []u8, p: *usize, data: []const u8) void {
                const len = @min(data.len, b.len -| p.*);
                @memcpy(b[p.*..][0..len], data[0..len]);
                p.* += len;
            }
        }.f;

        write(&body_buf, &pos, "{\"model\":\"");
        write(&body_buf, &pos, self.model);
        write(&body_buf, &pos, "\",\"prompt\":\"");
        // Escape text for JSON
        for (text) |ch| {
            if (pos >= body_buf.len - 10) break;
            if (ch == '"') {
                body_buf[pos] = '\\';
                pos += 1;
                body_buf[pos] = '"';
                pos += 1;
            } else if (ch == '\\') {
                body_buf[pos] = '\\';
                pos += 1;
                body_buf[pos] = '\\';
                pos += 1;
            } else if (ch == '\n') {
                body_buf[pos] = '\\';
                pos += 1;
                body_buf[pos] = 'n';
                pos += 1;
            } else if (ch == '\r') {
                // skip
            } else {
                body_buf[pos] = ch;
                pos += 1;
            }
        }
        write(&body_buf, &pos, "\"}");

        const body = body_buf[0..pos];

        // Make HTTP request to Ollama
        var response_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer response_writer.deinit();

        var redirect_buffer: [1024]u8 = undefined;

        const result = client.fetch(.{
            .location = .{ .url = self.ollama_url },
            .method = .POST,
            .redirect_buffer = &redirect_buffer,
            .response_writer = &response_writer.writer,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
            .payload = body,
        }) catch {
            return error.NetworkError;
        };

        if (result.status != .ok) {
            std.log.warn("Ollama embedding request failed: {}", .{result.status});
            return error.NetworkError;
        }

        // Parse response: {"embedding": [0.1, 0.2, ...]}
        const response_data = response_writer.written();
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_data, .{
            .allocate = .alloc_always,
        }) catch {
            return error.ParseError;
        };

        const embedding_val = parsed.value.object.get("embedding") orelse {
            return error.ParseError;
        };

        if (embedding_val != .array) return error.ParseError;

        const dims = embedding_val.array.items.len;
        const vector = try self.allocator.alloc(f32, dims);

        for (embedding_val.array.items, 0..) |item, i| {
            vector[i] = switch (item) {
                .float => @floatCast(item.float),
                .integer => @floatFromInt(item.integer),
                else => 0.0,
            };
        }

        return vector;
    }

    const EmbedError = error{
        NetworkError,
        ParseError,
        OutOfMemory,
    };
};
