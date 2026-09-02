const std = @import("std");
const common = @import("common");
const api = @import("api");
const storage = @import("storage");

/// Vision pipeline: hash image → lookup cache → call vision model on miss →
/// cache → return a text description. Caller injects the description into the
/// main model's system prompt as plain text; the original image is NEVER
/// re-sent to the main LLM (same-hash = same-cache forever, by design).
///
/// Thread safety: the pipeline's own state (model_override) is mutex-guarded.
/// The ArtifactStore is owned per-instance so each engine gets its own DB
/// connection — callers should not share one pipeline between engines.
pub const VisionPipeline = struct {
    allocator: std.mem.Allocator,
    config: *const common.VisionConfig,
    client: *api.AnthropicClient,
    store: *storage.ArtifactStore,
    ollama_base_url: []const u8,

    mutex: common.sync.Mutex = .{},
    /// Runtime override set via /api/vision. Takes precedence over config.model.
    /// Owned (allocated) when non-null.
    model_override: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const common.VisionConfig,
        client: *api.AnthropicClient,
        store: *storage.ArtifactStore,
        ollama_base_url: []const u8,
    ) VisionPipeline {
        return .{
            .allocator = allocator,
            .config = config,
            .client = client,
            .store = store,
            .ollama_base_url = ollama_base_url,
        };
    }

    pub fn deinit(self: *VisionPipeline) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.model_override) |m| self.allocator.free(m);
        self.model_override = null;
    }

    /// Returns the effective model name (override > config). Borrowed slice;
    /// valid until setModelOverride is called. Copy if you need to outlive.
    pub fn effectiveModel(self: *VisionPipeline) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.model_override orelse self.config.model;
    }

    /// Update the runtime model override. Pass null to clear (fall back to config).
    pub fn setModelOverride(self: *VisionPipeline, new_model: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.model_override) |old| self.allocator.free(old);
        self.model_override = if (new_model) |m| try self.allocator.dupe(u8, m) else null;
    }

    /// Describe an image on disk. Checks the SHA-256 cache first; on miss,
    /// calls the vision model, stores the artifact + cached analysis, and
    /// returns the allocated description text. Caller owns the returned slice.
    pub fn describePath(
        self: *VisionPipeline,
        session_id: ?[]const u8,
        name: []const u8,
        mime: []const u8,
        path: []const u8,
    ) !DescribeResult {
        if (!self.config.enabled) {
            return .{
                .description = try self.allocator.dupe(u8, "[vision disabled in config]"),
                .from_cache = false,
                .model_used = try self.allocator.dupe(u8, ""),
            };
        }

        // Read file bytes.
        const io = common.config.runtimeIo();
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "[image unreadable: {s}]",
                .{@errorName(err)},
            );
            return .{ .description = msg, .from_cache = false, .model_used = try self.allocator.dupe(u8, "") };
        };
        defer file.close(io);

        var file_reader = file.reader(io, &.{});
        const bytes = file_reader.interface.allocRemaining(self.allocator, .limited(self.config.max_image_bytes + 1)) catch |err| {
            if (err == error.StreamTooLong) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "[image skipped: exceeds {d} byte limit]",
                    .{self.config.max_image_bytes},
                );
                return .{ .description = msg, .from_cache = false, .model_used = try self.allocator.dupe(u8, "") };
            }
            return err;
        };
        defer self.allocator.free(bytes);

        // Hash the image for cache lookup.
        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash_bytes, .{});
        var hex_hash: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (hash_bytes, 0..) |b, i| {
            hex_hash[i * 2] = hex_chars[b >> 4];
            hex_hash[i * 2 + 1] = hex_chars[b & 0x0f];
        }

        // Cache lookup.
        if (try self.store.lookupAnalysis(&hex_hash, "image_description", "low")) |cached| {
            // Duplicate strings so caller can free with its own allocator;
            // free the store-owned copies afterwards.
            const description = try self.allocator.dupe(u8, cached.description);
            const model_used = try self.allocator.dupe(u8, cached.model_used);
            self.store.freeAnalysis(cached);
            std.log.info("Vision cache HIT: {s} ({s})", .{ name, hex_hash[0..12] });
            return .{ .description = description, .from_cache = true, .model_used = model_used };
        }

        // Cache miss — call vision model.
        const model_name = self.effectiveModel();
        std.log.info("Vision cache MISS: {s} ({s}) → {s}", .{ name, hex_hash[0..12], model_name });

        const vision_result = (if (std.mem.startsWith(u8, model_name, "ollama:"))
            self.describeWithOllama(
                model_name["ollama:".len..],
                self.config.prompt,
                bytes,
                mime,
                self.config.max_output_tokens,
            )
        else
            self.client.describeImage(
                model_name,
                self.config.prompt,
                bytes,
                mime,
                self.config.max_output_tokens,
            )) catch |err| {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "[vision call failed: {s}]",
                .{@errorName(err)},
            );
            return .{ .description = msg, .from_cache = false, .model_used = try self.allocator.dupe(u8, model_name) };
        };
        // vision_result.text is allocated via self.client.allocator (which is
        // the same shared allocator). We'll free it after caching below.
        defer self.allocator.free(vision_result.text);

        // Store the artifact and the cached analysis. We store the content
        // path if we have one; inline binary is too large for SQLite rows.
        const artifact_id = self.store.insertArtifact(.{
            .session_id = session_id,
            .name = name,
            .artifact_type = "image",
            .mime_type = mime,
            .content_path = path,
            .content_size = bytes.len,
            .content_hash = &hex_hash,
            .description = null, // human description is in artifact_analysis
            .source = "user_upload",
        }) catch |err| {
            std.log.err("Vision: failed to insert artifact: {s}", .{@errorName(err)});
            // Still return the analysis even if we couldn't cache it.
            const description = try self.allocator.dupe(u8, vision_result.text);
            return .{ .description = description, .from_cache = false, .model_used = try self.allocator.dupe(u8, model_name) };
        };

        self.store.insertAnalysis(.{
            .artifact_id = artifact_id,
            .content_hash = &hex_hash,
            .analysis_type = "image_description",
            .detail_level = "low",
            .description = vision_result.text,
            .structured_data = null,
            .model_used = model_name,
            .input_tokens = vision_result.input_tokens,
            .output_tokens = vision_result.output_tokens,
            .prompt_used = self.config.prompt,
        }) catch |err| {
            std.log.err("Vision: failed to insert analysis: {s}", .{@errorName(err)});
        };

        const description = try self.allocator.dupe(u8, vision_result.text);
        return .{
            .description = description,
            .from_cache = false,
            .model_used = try self.allocator.dupe(u8, model_name),
        };
    }

    fn describeWithOllama(
        self: *VisionPipeline,
        model: []const u8,
        prompt: []const u8,
        image_bytes: []const u8,
        mime: []const u8,
        max_output_tokens: u32,
    ) !api.VisionResult {
        _ = mime;

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var client = std.http.Client{ .allocator = arena, .io = common.config.runtimeIo() };

        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/api/chat", .{self.ollama_base_url}) catch {
            return error.InvalidRequest;
        };

        const b64_len = std.base64.standard.Encoder.calcSize(image_bytes.len);
        const b64 = try arena.alloc(u8, b64_len);
        _ = std.base64.standard.Encoder.encode(b64, image_bytes);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(arena);
        try body.ensureTotalCapacity(arena, b64.len + prompt.len + 512);

        try body.appendSlice(arena, "{\"model\":\"");
        api.messages.appendJsonEscaped(&body, arena, model);
        try body.appendSlice(arena, "\",\"stream\":false,\"keep_alive\":0,\"options\":{\"num_ctx\":8192,\"num_predict\":");
        var num_buf: [32]u8 = undefined;
        try body.appendSlice(arena, std.fmt.bufPrint(&num_buf, "{d}", .{max_output_tokens}) catch "512");
        try body.appendSlice(arena, "},\"messages\":[{\"role\":\"user\",\"content\":\"");
        api.messages.appendJsonEscaped(&body, arena, prompt);
        try body.appendSlice(arena, "\",\"images\":[\"");
        try body.appendSlice(arena, b64);
        try body.appendSlice(arena, "\"]}]}");

        var response_writer = std.Io.Writer.Allocating.init(arena);
        var redirect_buf: [8 * 1024]u8 = undefined;

        const headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .redirect_buffer = &redirect_buf,
            .response_writer = &response_writer.writer,
            .extra_headers = &headers,
            .payload = body.items,
        }) catch return error.NetworkError;

        const response_data = response_writer.written();
        if (result.status != .ok) {
            std.log.err("Ollama vision API {d}: {s}", .{
                @intFromEnum(result.status),
                response_data[0..@min(response_data.len, 800)],
            });
            return error.ServerError;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, arena, response_data, .{}) catch {
            return error.ParseError;
        };
        const obj = if (parsed.value == .object) parsed.value.object else return error.ParseError;

        var text_out: []const u8 = "";
        if (obj.get("message")) |msg| {
            if (msg == .object) {
                if (msg.object.get("content")) |content| {
                    if (content == .string) text_out = content.string;
                }
            }
        }

        var in_toks: u32 = 0;
        var out_toks: u32 = 0;
        if (obj.get("prompt_eval_count")) |it| if (it == .integer) {
            in_toks = @intCast(it.integer);
        };
        if (obj.get("eval_count")) |ot| if (ot == .integer) {
            out_toks = @intCast(ot.integer);
        };

        return .{
            .text = try self.allocator.dupe(u8, text_out),
            .input_tokens = in_toks,
            .output_tokens = out_toks,
        };
    }
};

pub const DescribeResult = struct {
    description: []const u8, // allocated; caller frees
    from_cache: bool,
    model_used: []const u8, // allocated; caller frees

    pub fn deinit(self: DescribeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        allocator.free(self.model_used);
    }
};
