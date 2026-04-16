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

    mutex: std.Thread.Mutex = .{},
    /// Runtime override set via /api/vision. Takes precedence over config.model.
    /// Owned (allocated) when non-null.
    model_override: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const common.VisionConfig,
        client: *api.AnthropicClient,
        store: *storage.ArtifactStore,
    ) VisionPipeline {
        return .{
            .allocator = allocator,
            .config = config,
            .client = client,
            .store = store,
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
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "[image unreadable: {s}]",
                .{@errorName(err)},
            );
            return .{ .description = msg, .from_cache = false, .model_used = try self.allocator.dupe(u8, "") };
        };
        defer file.close();

        const bytes = file.readToEndAlloc(self.allocator, self.config.max_image_bytes + 1) catch |err| {
            if (err == error.FileTooBig) {
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

        const vision_result = self.client.describeImage(
            model_name,
            self.config.prompt,
            bytes,
            mime,
            self.config.max_output_tokens,
        ) catch |err| {
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
