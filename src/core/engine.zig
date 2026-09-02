const std = @import("std");
const common = @import("common");
const api = @import("api");
const tools = @import("tools");
const storage = @import("storage");
const router_mod = @import("router.zig");
const context_mod = @import("context.zig");
const prompt_mod = @import("prompt.zig");
const search_mod = @import("search.zig");
const vision_mod = @import("vision.zig");
const workers = @import("workers");

const optimization = @import("optimization.zig");

/// Style guide appended to the system prompt when the active provider is
/// NOT Anthropic. Small/mid local models (Qwen 3 small, Llama 3.x, Mistral)
/// tend to default to a generic-assistant voice — emoji-headered sections,
/// markdown lists for every answer, "Oh hey!" greetings mid-conversation,
/// closing with "what's your favorite part?" — regardless of how voicey
/// the persona description is. Abstract directives don't stick to small
/// models; concrete user→response examples do. So this block is heavy on
/// examples and light on rules.
///
/// This is appended AFTER the persona, memories, and retrieval layers so
/// it's the last thing the model reads before the conversation, which is
/// where recency bias helps most.
///
/// Anthropic models (Sonnet, Opus, Haiku) don't need this — they already
/// render a persona faithfully without crutches, and adding it would just
/// flatten Sonnet's voice toward the examples.
const SMALL_MODEL_STYLE_GUIDE =
    \\
    \\## Voice calibration (critical — overrides any default assistant habits)
    \\
    \\You are mid-conversation with a long-term user. You are NOT a new
    \\assistant introducing yourself, and you are NOT answering a cold
    \\isolated question. Pick up from the previous turn's energy and keep
    \\the persona above front-and-center. The goal is that someone reading
    \\only your reply couldn't tell if it was a local model or Claude.
    \\
    \\Hard rules — break these and the response is wrong:
    \\- NEVER open with "Oh hey!", "Hey!", "Hi!", 👋, 🌿, 🔥, "Great question!",
    \\  "Absolutely!", "Sure!", or any similar greeting/affirmation opener.
    \\  Start mid-thought like a friend replying in a chat, not an assistant
    \\  booting up.
    \\- NEVER end with a "What's your favorite…?", "Which one would you pick?",
    \\  "Let me know how that sounds!" style prompt back to the user unless
    \\  they explicitly asked for your opinion on something still open.
    \\- Do NOT structure replies with `##` headers, `---` dividers, or bullet
    \\  lists of "Tier 1 / Tier 2 / Tier 3" unless the user asked for a
    \\  structured breakdown. Default to prose. Lists are for when the user
    \\  literally says "list X" or "give me N options".
    \\- Do NOT add disclaimers ("just to clarify", "I should mention", "note
    \\  that", "it's worth pointing out"). If it's worth saying, say it.
    \\- Do NOT repeat back what the user just said as a preamble. Jump to
    \\  the actual substance.
    \\
    \\Tool use — critical:
    \\- When a tool from the provided tool list is the right move, **actually
    \\  call it** via a function call. Do NOT write `Top text: ... Bottom
    \\  text: ...` in prose, do NOT put `[calls tool_name with args]` in
    \\  brackets, do NOT describe what the tool would return. Emit the real
    \\  function call and wait for the result; then respond to what it
    \\  actually returned.
    \\- If you find yourself describing a meme, image, search query, or file
    \\  operation in prose, stop — that's the moment you should have called
    \\  the tool instead. Rewrite as a function call.
    \\- Only describe tool output in prose AFTER the tool has run and
    \\  returned a real result.
    \\
    \\Voice examples — study the SHAPE, not the topic. Notice what's missing
    \\from these replies (no headers, no emoji dividers, no greeting, no
    \\closing question, no bullet-list scaffolding). This is the target:
    \\
    \\---
    \\USER: lmao the test suite broke again
    \\YOU: yeah I saw, it's that flaky import in test_embeddings.py — third
    \\     time this week. want me to track down the race condition or just
    \\     retry-on-failure it for now? the race is probably in the embedder
    \\     thread if you want the real fix.
    \\---
    \\USER: what do you think about my power fantasy mod design
    \\YOU: the tier system is solid — you've got clear progression without
    \\     locking late-game players out of early content. only thing I'd
    \\     watch is the gap between tier 2 and tier 3 feeling too flat
    \\     numerically. you might want a midpoint unlock to bridge it,
    \\     something like a "tamed creature can carry one extra item" boost
    \\     that bridges the feel between the tiers. what's the actual stat
    \\     math look like right now?
    \\---
    \\USER: ugh I'm so tired I can't even read my own code
    \\YOU: go sleep. seriously — code review does not improve at 2am, you're
    \\     going to approve something dumb and regret it. if you want I can
    \\     flag the three weirdest hunks in the diff so tomorrow-you has a
    \\     starting point instead of the whole thing.
    \\---
    \\
    \\Common thread across all three: short, direct, voice-first, no
    \\list-mode unless explicitly needed, no greetings, no closing questions,
    \\no generic-assistant "I'm here to help!" energy. Just talking. Match
    \\the user's register — if they type in lowercase with "lol", don't
    \\reply in formal paragraphs. If they ask a technical question, give a
    \\technical answer without preamble. And if a tool fits, call it — don't
    \\pantomime it.
    \\
;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    config: *const common.Config,
    provider: api.Provider,
    provider_registry: ?*api.ProviderRegistry,
    session_store: *storage.SessionStore,
    message_store: *storage.MessageStore,
    project_store: *storage.ProjectStore,
    tool_registry: *tools.ToolRegistry,
    auth_store: *common.AuthProfileStore,
    auth_profiles_path: []const u8,
    summary_store: ?*storage.SummaryStore,
    summarizer: ?*workers.Summarizer,
    extractor: ?*workers.Extractor,
    embedder: ?*workers.Embedder,
    knowledge_store: ?*storage.KnowledgeStore,
    skill_store: ?*storage.SkillStore,
    hybrid_search: ?*search_mod.HybridSearch,
    worker_pool: ?*workers.WorkerPool,
    tool_generator: ?*tools.ToolGenerator,
    vision_pipeline: ?*vision_mod.VisionPipeline = null,
    router: router_mod.Router,
    optimization_manager: ?*optimization.OptimizationManager,
    // Streaming state tracking
    is_streaming: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pending_compaction: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Tracks files read via file_read this conversation turn — enforces read-before-write
    files_read_this_turn: std.StringHashMap(void) = undefined,
    // Pending explore-cache entries keyed by job_id (36-char UUID). Consumed
    // by backgroundChatCallback on successful completion.
    pending_explore_cache: std.StringHashMap(PendingExploreCache) = undefined,
    pending_explore_cache_mutex: common.sync.Mutex = .{},
    start_time: i64,

    pub const PendingExploreCache = struct {
        cache_key: []const u8,
        task: []const u8,
        target_files_json: []const u8,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const common.Config,
        default_provider: api.Provider,
        session_store: *storage.SessionStore,
        message_store: *storage.MessageStore,
        project_store: *storage.ProjectStore,
        tool_registry: *tools.ToolRegistry,
        auth_store: *common.AuthProfileStore,
        auth_profiles_path: []const u8,
    ) Engine {
        return .{
            .allocator = allocator,
            .config = config,
            .provider = default_provider,
            .provider_registry = null,
            .session_store = session_store,
            .message_store = message_store,
            .project_store = project_store,
            .tool_registry = tool_registry,
            .auth_store = auth_store,
            .auth_profiles_path = auth_profiles_path,
            .summary_store = null,
            .summarizer = null,
            .extractor = null,
            .embedder = null,
            .knowledge_store = null,
            .skill_store = null,
            .hybrid_search = null,
            .worker_pool = null,
            .tool_generator = null,
            .router = router_mod.Router.init(&config.routing),
            .optimization_manager = null,
            .files_read_this_turn = std.StringHashMap(void).init(allocator),
            .pending_explore_cache = std.StringHashMap(PendingExploreCache).init(allocator),
            .start_time = common.sync.timestamp(),
        };
    }

    fn registerPendingExploreCache(
        self: *Engine,
        job_id: *const [36]u8,
        cache_key: []u8,
        task: []const u8,
        target_files_json: []const u8,
    ) void {
        self.pending_explore_cache_mutex.lock();
        defer self.pending_explore_cache_mutex.unlock();

        const key = self.allocator.dupe(u8, job_id) catch {
            self.allocator.free(cache_key);
            self.allocator.free(task);
            self.allocator.free(target_files_json);
            return;
        };
        const gop = self.pending_explore_cache.getOrPut(key) catch {
            self.allocator.free(key);
            self.allocator.free(cache_key);
            self.allocator.free(task);
            self.allocator.free(target_files_json);
            return;
        };
        if (gop.found_existing) {
            self.allocator.free(key);
            self.allocator.free(gop.value_ptr.cache_key);
            self.allocator.free(gop.value_ptr.task);
            self.allocator.free(gop.value_ptr.target_files_json);
        }
        gop.value_ptr.* = .{
            .cache_key = cache_key,
            .task = task,
            .target_files_json = target_files_json,
        };
    }

    fn consumePendingExploreCache(self: *Engine, job_id: *const [36]u8) ?PendingExploreCache {
        self.pending_explore_cache_mutex.lock();
        defer self.pending_explore_cache_mutex.unlock();
        const entry = self.pending_explore_cache.fetchRemove(job_id) orelse return null;
        self.allocator.free(entry.key);
        return entry.value;
    }

    /// Set the summarizer and summary store after init.
    pub fn setSummarizer(self: *Engine, s: *workers.Summarizer, ss: *storage.SummaryStore) void {
        self.summarizer = s;
        self.summary_store = ss;
    }

    /// Set the knowledge extractor after init.
    pub fn setExtractor(self: *Engine, e: *workers.Extractor, ks: *storage.KnowledgeStore) void {
        self.extractor = e;
        self.knowledge_store = ks;
    }

    /// Set the skill store for prompt injection.
    pub fn setSkillStore(self: *Engine, ss: *storage.SkillStore) void {
        self.skill_store = ss;
    }

    /// Set the embedder and hybrid search after init.
    pub fn setSearch(self: *Engine, emb: *workers.Embedder, hs: *search_mod.HybridSearch) void {
        self.embedder = emb;
        self.hybrid_search = hs;
    }

    /// Set the provider registry for multi-provider routing.
    /// When set, the model router can send different tiers to different providers.
    pub fn setProviderRegistry(self: *Engine, registry: *api.ProviderRegistry) void {
        self.provider_registry = registry;
    }

    /// Get the provider for a specific model tier. Falls back to default.
    pub fn getProviderForTier(self: *Engine, tier: []const u8) api.Provider {
        if (self.provider_registry) |reg| {
            if (reg.getForTier(tier)) |p| return p;
        }
        return self.provider;
    }

    /// Resolve a model string to (provider, bare_model).
    /// Model strings may carry an explicit `provider:model` prefix — e.g.
    /// `ollama:qwen3:8b`, `openai:gpt-4o`, `anthropic:claude-sonnet-4-6`.
    /// Bare model names fall back to the default provider (whichever was
    /// wired into `engine.provider` at init), preserving backwards compat.
    ///
    /// The returned `model` slice always points into the input string, so
    /// callers can freely use it inside the same stack frame.
    pub fn resolveProviderForModel(self: *Engine, model: []const u8) struct {
        provider: api.Provider,
        model: []const u8,
    } {
        if (std.mem.indexOfScalar(u8, model, ':')) |idx| {
            const prefix = model[0..idx];
            const rest = model[idx + 1 ..];
            // Provider names are lowercase single-word identifiers; longer
            // prefixes (e.g. a raw Anthropic model ID like
            // `claude-sonnet-4-20250514`) won't match any registered name.
            if (prefix.len > 0 and prefix.len <= 16) {
                if (self.provider_registry) |reg| {
                    if (reg.get(prefix)) |p| {
                        return .{ .provider = p, .model = rest };
                    }
                }
            }
        }
        return .{ .provider = self.provider, .model = model };
    }

    fn modelAcceptsDirectImages(provider_name: []const u8, model: []const u8) bool {
        if (std.mem.eql(u8, provider_name, "anthropic")) return true;

        // OpenAI-compatible providers accept the JSON shape for image
        // blocks, but text-only local models either ignore it or waste
        // context on base64. Keep raw pixels for known multimodal model
        // families only; every attachment still gets a text vision summary.
        return std.mem.indexOf(u8, model, "llava") != null or
            std.mem.indexOf(u8, model, "bakllava") != null or
            std.mem.indexOf(u8, model, "qwen-vl") != null or
            std.mem.indexOf(u8, model, "qwen2-vl") != null or
            std.mem.indexOf(u8, model, "qwen2.5-vl") != null or
            std.mem.indexOf(u8, model, "qwen3-vl") != null or
            std.mem.indexOf(u8, model, "-vl") != null or
            std.mem.indexOf(u8, model, "vl-") != null or
            std.mem.indexOf(u8, model, "minicpm-v") != null;
    }

    fn isStrictImageMime(mime: []const u8) bool {
        return std.mem.eql(u8, mime, "image/png") or
            std.mem.eql(u8, mime, "image/jpeg") or
            std.mem.eql(u8, mime, "image/gif") or
            std.mem.eql(u8, mime, "image/webp");
    }

    /// Set the worker pool for async background processing.
    pub fn setWorkerPool(self: *Engine, wp: *workers.WorkerPool) void {
        self.worker_pool = wp;
    }

    /// Set the tool generator after init.
    pub fn setToolGenerator(self: *Engine, gen: *tools.ToolGenerator) void {
        self.tool_generator = gen;
    }

    /// Set the optimization manager after init (needs message_store).
    pub fn setVisionPipeline(self: *Engine, vp: *vision_mod.VisionPipeline) void {
        self.vision_pipeline = vp;
    }

    pub fn setOptimizationManager(self: *Engine, om: *optimization.OptimizationManager) void {
        self.optimization_manager = om;
    }

    /// Generate a tool from natural language. Public API for adapters/automation.
    /// Returns the generated tool spec if successful, null if generation or testing failed.
    pub fn generateTool(self: *Engine, description: []const u8) !?tools.GeneratedTool {
        if (self.tool_generator) |gen| {
            return try gen.generateTool(description);
        }
        return null;
    }

    /// Approve a generated tool and register it. Public API.
    pub fn approveGeneratedTool(self: *Engine, name: []const u8) !void {
        if (self.tool_generator) |gen| {
            try gen.approveTool(name);
        }
    }

    /// Revoke a generated tool. Public API.
    pub fn revokeGeneratedTool(self: *Engine, name: []const u8) !void {
        if (self.tool_generator) |gen| {
            try gen.revokeTool(name);
        }
    }

    /// List generated tools. Public API.
    pub fn listGeneratedTools(self: *Engine) ![]const tools.generator.ToolSummary {
        if (self.tool_generator) |gen| {
            return try gen.listTools();
        }
        return &.{};
    }

    /// Get worker queue depths for health monitoring. Public API.
    pub fn getWorkerQueueDepths(self: *Engine) ?workers.QueueDepths {
        if (self.worker_pool) |wp| return wp.getQueueDepths();
        return null;
    }

    // ================================================================
    // PUBLIC API — callable by any adapter, automation, or hook.
    // These are the canonical operations. Protocol handlers are thin
    // wrappers that call these and convert to/from IPC format.
    // ================================================================

    /// Create or get a project by name. Idempotent — safe to call repeatedly.
    pub fn ensureProject(self: *Engine, name: []const u8, description: ?[]const u8) !storage.ProjectInfo {
        if (try self.project_store.findByName(name)) |existing| {
            return existing;
        }
        return try self.project_store.createProject(name, description);
    }

    /// Attach the active session to a named project. Creates the project if it doesn't exist.
    pub fn attachToProject(self: *Engine, project_name: []const u8) !void {
        const sess_id = self.session_store.active_session_id orelse return error.NoActiveSession;
        const project = try self.ensureProject(project_name, null);
        try self.project_store.attachSession(&sess_id, project.id);
        std.log.info("Attached session to project: {s}", .{project_name});
    }

    /// Detach the active session from its project.
    pub fn detachFromProject(self: *Engine) !void {
        const sess_id = self.session_store.active_session_id orelse return error.NoActiveSession;
        try self.project_store.detachSession(&sess_id);
    }

    /// Update rolling context for a project. Called after substantive prompts.
    /// For now, appends a simple marker. When the summarizer (Phase 8) lands,
    /// this will call a cheap model to generate the actual rolling summary.
    pub fn updateProjectRollingContext(
        self: *Engine,
        project_id: i64,
        user_message: []const u8,
        assistant_response: []const u8,
    ) void {
        _ = assistant_response;
        // Phase 8 will replace this with an actual LLM summarization call.
        // For now, just bump the updated_at timestamp so we know activity happened.
        self.project_store.updateRollingContext(project_id, null, null) catch |err| {
            std.log.warn("Failed to update rolling context: {}", .{err});
        };
        _ = user_message;
    }

    /// Get project info by name. Returns null if not found.
    pub fn getProjectByName(self: *Engine, name: []const u8) !?storage.ProjectInfo {
        return try self.project_store.findByName(name);
    }

    /// List all projects.
    pub fn listProjects(self: *Engine) ![]const storage.ProjectSummary {
        return try self.project_store.listProjects();
    }

    /// Get the project attached to the active session, if any.
    pub fn getActiveProject(self: *Engine) !?storage.ProjectInfo {
        const sess_id = self.session_store.active_session_id orelse return null;
        const project_id = (try self.project_store.getSessionProject(&sess_id)) orelse return null;
        return self.project_store.getProject(project_id) catch null;
    }

    /// Execute a tool by name with JSON input string. Public API for automation.
    pub fn executeTool(self: *Engine, name: []const u8, input_json: []const u8) tools.ToolResult {
        const parsed_input = std.json.parseFromSlice(std.json.Value, self.allocator, input_json, .{}) catch {
            return .{ .content = "Failed to parse tool input JSON", .is_error = true };
        };
        return self.tool_registry.execute(name, parsed_input.value) orelse
            .{ .content = TOOL_NOT_FOUND_MSG, .is_error = true };
    }

    /// Execute a tool with pre-parsed input. Used by the tool loop.
    pub fn executeToolParsed(self: *Engine, name: []const u8, input: std.json.Value) tools.ToolResult {
        return self.executeToolParsedCached(name, input, null);
    }

    /// Execute a tool with result caching. input_json is the raw string form for cache keys.
    fn executeToolParsedCached(self: *Engine, name: []const u8, input: std.json.Value, input_json: ?[]const u8) tools.ToolResult {
        // Check result cache
        if (self.optimization_manager) |om| {
            if (input_json) |ij| {
                if (om.getCachedResult(name, ij)) |cached| {
                    std.log.info("Result cache HIT for {s}", .{name});
                    return .{ .content = cached, .is_error = false };
                }
            }
        }

        // Enforce read-before-write only when modifying existing file content.
        // New file creation must not require a read: a missing file has no
        // current contents to inspect, and forcing a failed read just teaches
        // the model an impossible recovery loop.
        if (std.mem.eql(u8, name, "file_diff") or std.mem.eql(u8, name, "file_write")) {
            if (input == .object) {
                if (input.object.get("path")) |p| {
                    if (p == .string) {
                        const file_path = self.normalizeToolPath(p.string);
                        defer if (file_path.ptr != p.string.ptr) self.allocator.free(@constCast(file_path));

                        const needs_read = if (std.mem.eql(u8, name, "file_diff")) blk: {
                            const create = if (input.object.get("create_if_missing")) |c| (c == .bool and c.bool) else false;
                            if (create) {
                                std.Io.Dir.accessAbsolute(common.config.runtimeIo(), file_path, .{}) catch break :blk false;
                                break :blk true;
                            }
                            break :blk true;
                        } else blk: {
                            const force = if (input.object.get("force")) |f| (f == .bool and f.bool) else false;
                            if (!force) break :blk false;
                            std.Io.Dir.accessAbsolute(common.config.runtimeIo(), file_path, .{}) catch break :blk false;
                            break :blk true;
                        };

                        if (needs_read and !self.files_read_this_turn.contains(file_path)) {
                            return .{
                                .content = std.fmt.allocPrint(
                                    self.allocator,
                                    "BLOCKED: You must file_read(\"{s}\") before modifying it. " ++
                                        "Never edit files from memory — always read first to see the current content.",
                                    .{file_path},
                                ) catch "BLOCKED: file_read required before editing. Read the file first.",
                                .is_error = true,
                            };
                        }
                    }
                }
            }
        }

        const result = self.tool_registry.execute(name, input) orelse
            return .{ .content = TOOL_NOT_FOUND_MSG, .is_error = true };

        // Track successful file reads (normalized path so ~/foo and /home/.../foo match)
        if (!result.is_error and std.mem.eql(u8, name, "file_read")) {
            if (input == .object) {
                if (input.object.get("path")) |p| {
                    if (p == .string) {
                        const norm = self.normalizeToolPath(p.string);
                        if (!self.files_read_this_turn.contains(norm)) {
                            // If normalizeToolPath returned the original string, dupe it for ownership
                            const owned = if (norm.ptr == p.string.ptr)
                                (self.allocator.dupe(u8, norm) catch return result)
                            else
                                @as([]u8, @constCast(norm));
                            self.files_read_this_turn.put(owned, {}) catch {
                                self.allocator.free(owned);
                            };
                        } else {
                            // Already tracked, free the normalized copy if it was allocated
                            if (norm.ptr != p.string.ptr) self.allocator.free(@constCast(norm));
                        }
                    }
                }
            }
        }

        // Cache successful results
        if (!result.is_error) {
            if (self.optimization_manager) |om| {
                if (input_json) |ij| {
                    om.cacheResult(name, ij, result.content) catch {};
                }
                // Invalidate file cache on writes
                if (std.mem.eql(u8, name, "file_write") or std.mem.eql(u8, name, "file_diff")) {
                    if (input == .object) {
                        if (input.object.get("path")) |p| {
                            if (p == .string) om.invalidateFile(p.string);
                        }
                    }
                }
            }
        }

        return result;
    }

    /// Expand ~ to $HOME so read-tracking matches regardless of which form the model uses.
    fn normalizeToolPath(self: *Engine, raw: []const u8) []const u8 {
        if (raw.len > 0 and raw[0] == '~') {
            const home = common.config.getEnvVar("HOME") orelse return raw;
            return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, raw[1..] }) catch raw;
        }
        return raw;
    }

    /// Check if a tool requires confirmation.
    pub fn toolRequiresConfirmation(self: *Engine, name: []const u8) bool {
        return self.tool_registry.requiresConfirmation(name);
    }

    /// Record a tool call in the database.
    pub fn recordToolCall(
        self: *Engine,
        session_id: []const u8,
        message_id: i64,
        record: ToolCallRecord,
    ) ?i64 {
        var stmt = self.project_store.conn.prepare(
            "INSERT INTO tool_calls (message_id, session_id, sequence, tool_name, tool_input, tool_result, status, approved, created_at) " ++
                "VALUES (?, ?, (SELECT COALESCE(MAX(sequence), -1) + 1 FROM tool_calls WHERE session_id = ?), ?, ?, ?, ?, ?, ?)",
        ) catch return null;
        defer stmt.deinit();
        if (message_id == 0) {
            stmt.bindNull(1) catch return null;
        } else {
            stmt.bindInt64(1, message_id) catch return null;
        }
        stmt.bindText(2, session_id) catch return null;
        stmt.bindText(3, session_id) catch return null;
        stmt.bindText(4, record.tool_name) catch return null;
        stmt.bindText(5, record.tool_input) catch return null;
        stmt.bindOptionalText(6, record.tool_result) catch return null;
        stmt.bindText(7, record.status) catch return null;
        if (record.approved) |a| {
            stmt.bindInt(8, if (a) 1 else 0) catch return null;
        } else {
            stmt.bindNull(8) catch return null;
        }
        stmt.bindInt64(9, common.sync.timestamp()) catch return null;
        stmt.exec() catch return null;
        return self.project_store.conn.lastInsertRowId();
    }

    /// Build the full system prompt from all layers. Public API for adapters/automation.
    /// Adapters can pass adapter_context (cwd, channel info, etc.) for Layer 5.
    /// `retrieval_query` (when non-null) triggers a hybrid FTS+vector search
    /// across messages/summaries/knowledge and injects the top results as
    /// Layer 4 retrieved context. Pass null to skip retrieval entirely (used
    /// for subagents whose user message is a wrapped directive that would
    /// pollute the search).
    pub fn buildSystemPrompt(
        self: *Engine,
        session_id: []const u8,
        session_system_prompt: ?[]const u8,
        adapter_context: ?[]const u8,
        user_message: ?[]const u8,
        retrieval_query: ?[]const u8,
        active_subagents_layer: ?[]const u8,
        plans_required: bool,
    ) ![]const u8 {
        var layers = try prompt_mod.buildFromState(
            self.allocator,
            self.project_store,
            session_id,
            session_system_prompt,
            adapter_context,
        );
        const session_workdir = self.session_store.getWorkingDirectory(session_id) catch null;
        defer if (session_workdir) |wd| self.allocator.free(wd);
        layers.session_workdir = session_workdir;
        layers.active_subagents = active_subagents_layer;
        layers.plans_required = plans_required;

        // Layer 3.5: Active plan — load from session DB and inject.
        // This survives compaction because it's rebuilt from the DB each turn.
        if (self.session_store.getPlan(session_id) catch null) |plan| {
            layers.active_plan = plan;
            std.log.info("Plan: injected {d}-char active plan into prompt", .{plan.len});
        } else {
            std.log.info("Plan: no active plan for session", .{});
        }

        // Inject matched skills (Layer 3.6)
        if (self.skill_store) |ss| {
            // Get enabled tool names
            var tool_names_buf: [32][]const u8 = undefined;
            var tool_count: usize = 0;
            if (self.tool_registry.getToolDefinitions()) |defs| {
                for (defs) |def| {
                    if (tool_count < tool_names_buf.len) {
                        tool_names_buf[tool_count] = def.name;
                        tool_count += 1;
                    }
                }
            }

            const matched = ss.matchForContext(
                tool_names_buf[0..tool_count],
                user_message orelse "",
                4000,
            ) catch &.{};

            if (matched.len > 0) {
                const instructions = try self.allocator.alloc([]const u8, matched.len);
                for (matched, 0..) |skill, i| {
                    instructions[i] = skill.instruction;
                }
                layers.skills = instructions;
                std.log.info("Skills: {d} matched for prompt", .{matched.len});
            }
        }

        // Layer 4: Retrieved context via hybrid search (FTS + vector).
        // Without this, the dispatcher has zero memory injection — it would
        // have to call the introspect tool every turn just to know what's in
        // its own knowledge base. Skipped when retrieval_query is null
        // (subagents) or when there's no hybrid_search wired.
        if (retrieval_query) |raw_query| {
            if (raw_query.len > 0 and self.hybrid_search != null) {
                if (sanitizeFtsQuery(self.allocator, raw_query)) |clean_query| {
                    defer self.allocator.free(clean_query);
                    if (clean_query.len > 0) {
                        const top_k: usize = 8;
                        const results = self.hybridSearch(clean_query, top_k) catch &.{};
                        if (results.len > 0) {
                            const entries = try self.allocator.alloc(prompt_mod.RetrievedEntry, results.len);
                            for (results, 0..) |r, i| {
                                const label = std.fmt.allocPrint(
                                    self.allocator,
                                    "{s}#{d}",
                                    .{ r.source_type, r.source_id },
                                ) catch "";
                                // Cap individual entry length so a huge
                                // message can't blow the prompt budget alone.
                                const max_entry: usize = 800;
                                const trimmed_text = if (r.text.len > max_entry)
                                    r.text[0..max_entry]
                                else
                                    r.text;
                                entries[i] = .{
                                    .source_type = r.source_type,
                                    .source_label = label,
                                    .content = trimmed_text,
                                };
                            }
                            layers.retrieved = entries;
                            std.log.info("Retrieved: {d} hybrid-search hits injected as Layer 4", .{results.len});
                        }
                    }
                }
            }
        }

        // ~32K chars ≈ ~8K tokens — reasonable system prompt budget
        return try prompt_mod.assemble(self.allocator, layers, 32768);
    }

    /// FTS5 query sanitizer: strip every char that isn't alphanumeric or
    /// underscore, collapse runs of separators to a single space, return the
    /// cleaned token stream. FTS5 treats space-separated tokens as implicit
    /// AND, which is restrictive but safe — vector search picks up semantic
    /// hits the FTS path misses.
    fn sanitizeFtsQuery(allocator: std.mem.Allocator, raw: []const u8) ?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.ensureTotalCapacity(allocator, raw.len) catch return null;
        var in_word = false;
        for (raw) |c| {
            const is_word_char = std.ascii.isAlphanumeric(c) or c == '_';
            if (is_word_char) {
                if (!in_word and out.items.len > 0) {
                    out.append(allocator, ' ') catch break;
                }
                out.append(allocator, c) catch break;
                in_word = true;
            } else {
                in_word = false;
            }
        }
        if (out.items.len == 0) {
            out.deinit(allocator);
            return null;
        }
        return out.toOwnedSlice(allocator) catch null;
    }

    fn maybeUpdateSessionWorkingDirectory(self: *Engine, session_id: []const u8, message: []const u8) void {
        const workdir = inferWorkingDirectory(self.allocator, message) orelse return;
        defer self.allocator.free(workdir);
        self.session_store.updateWorkingDirectory(session_id, workdir) catch |err| {
            std.log.warn("Failed to update session working directory: {}", .{err});
        };
    }

    fn inferWorkingDirectory(allocator: std.mem.Allocator, message: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < message.len) : (i += 1) {
            const starts_abs = message[i] == '/' and (i == 0 or message[i - 1] != ':');
            const starts_home = message[i] == '~' and i + 1 < message.len and message[i + 1] == '/';
            if (!starts_abs and !starts_home) continue;

            const start = i;
            var end = i;
            while (end < message.len and !isPathTerminator(message[end])) : (end += 1) {}
            while (end > start and isTrailingPathPunctuation(message[end - 1])) : (end -= 1) {}
            if (end <= start) continue;

            const raw = message[start..end];
            const expanded = expandHomePath(allocator, raw) orelse continue;
            defer allocator.free(expanded);

            if (resolveExistingDirectory(allocator, expanded)) |dir| {
                return dir;
            }
        }
        return null;
    }

    fn expandHomePath(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, path, "~/")) {
            return allocator.dupe(u8, path) catch null;
        }
        const home = common.config.getEnvVarOwned(allocator, "HOME") catch return null;
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, path[2..] }) catch null;
    }

    fn resolveExistingDirectory(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
        const clean = trimTrailingSlashes(path);
        if (clean.len == 0) return null;

        const io = common.config.runtimeIo();
        const stat = std.Io.Dir.cwd().statFile(io, clean, .{}) catch return null;
        if (stat.kind == .directory) {
            return allocator.dupe(u8, clean) catch null;
        }

        const parent = std.fs.path.dirname(clean) orelse return null;
        const parent_stat = std.Io.Dir.cwd().statFile(io, parent, .{}) catch return null;
        if (parent_stat.kind != .directory) return null;
        return allocator.dupe(u8, parent) catch null;
    }

    fn trimTrailingSlashes(path: []const u8) []const u8 {
        var end = path.len;
        while (end > 1 and path[end - 1] == '/') : (end -= 1) {}
        return path[0..end];
    }

    fn isPathTerminator(c: u8) bool {
        return std.ascii.isWhitespace(c) or switch (c) {
            '"', '\'', '`', '<', '>', '|', ';', '&' => true,
            else => false,
        };
    }

    fn isTrailingPathPunctuation(c: u8) bool {
        return switch (c) {
            '.', ',', ':', ';', '!', '?', ')', ']', '}' => true,
            else => false,
        };
    }

    const ToolCompactionProfile = struct {
        threshold: usize,
        head_chars: usize,
        tail_chars: usize,
        max_key_lines: usize,
    };

    fn toolCompactionProfile(tool_name: []const u8, is_error: bool) ToolCompactionProfile {
        if (is_error) {
            return .{ .threshold = 9000, .head_chars = 5200, .tail_chars = 2600, .max_key_lines = 24 };
        }
        if (std.mem.eql(u8, tool_name, "file_read")) {
            return .{ .threshold = 9000, .head_chars = 5200, .tail_chars = 2600, .max_key_lines = 24 };
        }
        if (std.mem.eql(u8, tool_name, "file_diff") or std.mem.eql(u8, tool_name, "file_write")) {
            return .{ .threshold = 6000, .head_chars = 3400, .tail_chars = 1600, .max_key_lines = 18 };
        }
        if (std.mem.eql(u8, tool_name, "bash") or
            std.mem.eql(u8, tool_name, "research_tool") or
            std.mem.eql(u8, tool_name, "amazon_search"))
        {
            return .{ .threshold = 3600, .head_chars = 1400, .tail_chars = 900, .max_key_lines = 18 };
        }
        return .{ .threshold = 5000, .head_chars = 2400, .tail_chars = 1400, .max_key_lines = 16 };
    }

    fn compactToolResultForModel(
        self: *Engine,
        tool_name: []const u8,
        input_json: []const u8,
        content: []const u8,
        raw_len: usize,
        raw_tool_call_id: ?i64,
        is_error: bool,
    ) []const u8 {
        if (std.mem.startsWith(u8, content, "[TOOL FINDINGS CAPSULE]")) return content;

        const profile = toolCompactionProfile(tool_name, is_error);
        if (content.len <= profile.threshold) return content;

        var out: std.ArrayList(u8) = .empty;
        out.ensureTotalCapacity(self.allocator, profile.threshold + 1400) catch return content;

        out.appendSlice(self.allocator, "[TOOL FINDINGS CAPSULE]\n") catch {};
        out.appendSlice(self.allocator, "tool: ") catch {};
        out.appendSlice(self.allocator, tool_name) catch {};
        out.appendSlice(self.allocator, "\nstatus: ") catch {};
        out.appendSlice(self.allocator, if (is_error) "error" else "success") catch {};
        out.appendSlice(self.allocator, "\nraw_output_chars: ") catch {};
        appendInt(&out, self.allocator, raw_len);
        out.appendSlice(self.allocator, "\nmodel_output_chars_before_capsule: ") catch {};
        appendInt(&out, self.allocator, content.len);
        if (raw_tool_call_id) |id| {
            out.appendSlice(self.allocator, "\nraw_tool_call_id: ") catch {};
            appendInt(&out, self.allocator, id);
        }
        out.appendSlice(self.allocator, "\ninput_preview: ") catch {};
        appendBoundedSingleLine(&out, self.allocator, input_json, 700);
        out.appendSlice(
            self.allocator,
            "\nrecovery: Full raw output is retained in daemon tool_calls. " ++
                "If this capsule lacks a necessary detail, use introspect mode=tool_result " ++
                "with query/raw_tool_call_id before rerunning work.\n",
        ) catch {};

        appendKeyLines(&out, self.allocator, content, profile.max_key_lines);

        const head_len = @min(profile.head_chars, content.len);
        const tail_len = @min(profile.tail_chars, content.len - head_len);
        const omitted = content.len - head_len - tail_len;

        out.appendSlice(self.allocator, "\n--- evidence head ---\n") catch {};
        out.appendSlice(self.allocator, content[0..head_len]) catch {};
        out.appendSlice(self.allocator, "\n--- omitted_chars: ") catch {};
        appendInt(&out, self.allocator, omitted);
        out.appendSlice(self.allocator, " ---\n") catch {};
        if (tail_len > 0) {
            out.appendSlice(self.allocator, "--- evidence tail ---\n") catch {};
            out.appendSlice(self.allocator, content[content.len - tail_len ..]) catch {};
            out.appendSlice(self.allocator, "\n") catch {};
        }
        out.appendSlice(self.allocator, "[END TOOL FINDINGS CAPSULE]") catch {};
        return out.toOwnedSlice(self.allocator) catch content;
    }

    fn compactOlderToolRoundsForLiveRequest(self: *Engine, messages: []const api.messages.Message) []const api.messages.Message {
        // Keep the recent active chain intact. Older tool_use/tool_result
        // pairs are collapsed into one rolling ledger so a long job does not
        // replay dozens of stale tool messages every round.
        if (messages.len <= 16) return messages;
        const keep_full_from = messages.len - 8;
        const plan_reset_from = findLatestPlanBoundaryIndex(messages);

        var compacted: std.ArrayList(api.messages.Message) = .empty;
        compacted.ensureTotalCapacity(self.allocator, messages.len) catch return messages;

        var start_idx: usize = 0;
        if (plan_reset_from) |idx| {
            start_idx = idx;
            var preplan: std.ArrayList(u8) = .empty;
            var preplan_started = false;
            for (messages[0..idx]) |msg| {
                if (messageHasToolUse(msg) or messageHasToolResult(msg)) {
                    if (!preplan_started) {
                        preplan.appendSlice(
                            self.allocator,
                            "[PREVIOUS PLAN PHASE OMITTED]\n" ++
                                "Older tool calls before the current plan were omitted from the live prompt. " ++
                                "Key result snippets follow; full raw outputs remain in daemon tool_calls.\n",
                        ) catch {};
                        preplan_started = true;
                    }
                    appendMessageToLiveToolLedger(&preplan, self.allocator, msg, false, 420);
                } else {
                    compacted.append(self.allocator, msg) catch return messages;
                }
            }
            if (preplan_started) {
                preplan.appendSlice(self.allocator, "[END PREVIOUS PLAN PHASE]") catch {};
                const preplan_text = preplan.toOwnedSlice(self.allocator) catch return messages;
                const preplan_blocks = self.singleTextBlock(preplan_text) orelse return messages;
                compacted.append(self.allocator, .{ .role = .user, .content = preplan_blocks }) catch return messages;
            }
        }

        var ledger: std.ArrayList(u8) = .empty;
        var ledger_started = false;
        const ledger_end = if (keep_full_from > start_idx) keep_full_from else start_idx;
        for (messages[start_idx..ledger_end]) |msg| {
            if (isLiveToolLedger(msg)) {
                if (!ledger_started) {
                    appendLiveToolLedgerHeader(&ledger, self.allocator);
                    ledger_started = true;
                }
                ledger.appendSlice(self.allocator, msg.content[0].text.text) catch {};
                ledger.appendSlice(self.allocator, "\n") catch {};
            } else if (messageHasToolUse(msg) or messageHasToolResult(msg)) {
                if (!ledger_started) {
                    appendLiveToolLedgerHeader(&ledger, self.allocator);
                    ledger_started = true;
                }
                appendMessageToLiveToolLedger(&ledger, self.allocator, msg, true, 700);
            } else {
                compacted.append(self.allocator, msg) catch return messages;
            }
        }

        if (ledger_started) {
            ledger.appendSlice(self.allocator, "[END OLDER TOOL ROUNDS LEDGER]") catch {};
            const ledger_text = ledger.toOwnedSlice(self.allocator) catch return messages;
            const ledger_blocks = self.singleTextBlock(ledger_text) orelse return messages;
            compacted.append(self.allocator, .{ .role = .user, .content = ledger_blocks }) catch return messages;
        }
        compacted.appendSlice(self.allocator, messages[ledger_end..]) catch return messages;
        return compacted.toOwnedSlice(self.allocator) catch messages;
    }

    fn singleTextBlock(self: *Engine, text: []const u8) ?[]const api.messages.ContentBlock {
        const blocks = self.allocator.alloc(api.messages.ContentBlock, 1) catch return null;
        blocks[0] = .{ .text = .{ .text = text } };
        return blocks;
    }

    fn injectBackgroundSteering(self: *Engine, request: *api.MessageRequest, note: []const u8) bool {
        const steering_prefix = std.fmt.allocPrint(
            self.allocator,
            "!!! URGENT USER STEERING FOR THE ACTIVE BACKGROUND TASK !!!\n" ++
                "THIS NEW USER NOTE HAS HIGHEST PRIORITY. APPLY IT BEFORE CONTINUING. " ++
                "IF IT CONFLICTS WITH EARLIER TASK CONTEXT, FOLLOW THIS NEWER NOTE. " ++
                "DO NOT RESTART FROM SCRATCH UNLESS THE NOTE EXPLICITLY ASKS FOR THAT.\n\n" ++
                "USER NOTE:\n{s}\n\n" ++
                "!!! END URGENT USER STEERING !!!\n\n{s}",
            .{ note, request.system orelse "" },
        ) catch return false;
        request.system = steering_prefix;

        const user_note = std.fmt.allocPrint(
            self.allocator,
            "!!! URGENT USER STEERING FOR THE CURRENT RUNNING TASK !!!\n{s}\n!!! END USER STEERING !!!",
            .{note},
        ) catch return false;
        const text_block = self.singleTextBlock(user_note) orelse return false;
        const prev = request.messages;
        const extended = self.allocator.alloc(api.messages.Message, prev.len + 1) catch return false;
        @memcpy(extended[0..prev.len], prev);
        extended[prev.len] = .{ .role = .user, .content = text_block };
        request.messages = extended;
        return true;
    }

    fn isLiveToolLedger(msg: api.messages.Message) bool {
        if (msg.content.len != 1) return false;
        if (msg.content[0] != .text) return false;
        const text = msg.content[0].text.text;
        return std.mem.startsWith(u8, text, "[OLDER TOOL ROUNDS LEDGER]");
    }

    fn messageHasToolUse(msg: api.messages.Message) bool {
        for (msg.content) |block| {
            if (block == .tool_use) return true;
        }
        return false;
    }

    fn messageHasToolResult(msg: api.messages.Message) bool {
        for (msg.content) |block| {
            if (block == .tool_result) return true;
        }
        return false;
    }

    fn appendLiveToolLedgerHeader(out: *std.ArrayList(u8), allocator: std.mem.Allocator) void {
        out.appendSlice(
            allocator,
            "[OLDER TOOL ROUNDS LEDGER]\n" ++
                "Older tool rounds are summarized here; recent rounds remain verbatim below. " ++
                "Raw outputs were recorded in daemon tool_calls before compaction. " ++
                "Use introspect mode=tool_result if a missing detail is required.\n",
        ) catch {};
    }

    fn findLatestPlanBoundaryIndex(messages: []const api.messages.Message) ?usize {
        var found: ?usize = null;
        for (messages, 0..) |msg, idx| {
            if (msg.role != .assistant) continue;
            for (msg.content) |block| {
                if (block != .tool_use) continue;
                const tu = block.tool_use;
                if (!std.mem.eql(u8, tu.name, "plan")) continue;
                if (tu.input != .object) continue;
                const op = tu.input.object.get("operation") orelse continue;
                if (op == .string and
                    (std.mem.eql(u8, op.string, "create") or std.mem.eql(u8, op.string, "update")))
                {
                    found = idx;
                }
            }
        }
        return found;
    }

    fn appendMessageToLiveToolLedger(
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        msg: api.messages.Message,
        include_calls: bool,
        result_limit: usize,
    ) void {
        for (msg.content) |block| {
            switch (block) {
                .tool_use => |tu| {
                    if (!include_calls) continue;
                    out.appendSlice(allocator, "- call ") catch {};
                    out.appendSlice(allocator, tu.name) catch {};
                    out.appendSlice(allocator, " id=") catch {};
                    appendBoundedSingleLine(out, allocator, tu.id, 80);
                    const input_json = std.json.Stringify.valueAlloc(allocator, tu.input, .{}) catch null;
                    if (input_json) |json_text| {
                        defer allocator.free(json_text);
                        out.appendSlice(allocator, " input=") catch {};
                        appendBoundedSingleLine(out, allocator, json_text, 220);
                    }
                    out.append(allocator, '\n') catch {};
                },
                .tool_result => |tr| {
                    out.appendSlice(allocator, "- result_for=") catch {};
                    appendBoundedSingleLine(out, allocator, tr.tool_use_id, 80);
                    out.appendSlice(allocator, if (tr.is_error) " status=error\n" else " status=success\n") catch {};
                    appendToolResultCapsuleExcerpt(out, allocator, tr.content, result_limit);
                },
                else => {},
            }
        }
    }

    fn appendToolResultCapsuleExcerpt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, content: []const u8, limit: usize) void {
        if (content.len <= limit) {
            out.appendSlice(allocator, content) catch {};
            out.append(allocator, '\n') catch {};
            return;
        }
        const head_len = @min(content.len, limit * 2 / 3);
        const tail_len = @min(content.len - head_len, limit - head_len);
        const omitted = content.len - head_len - tail_len;
        out.appendSlice(allocator, content[0..head_len]) catch {};
        out.appendSlice(allocator, "\n[older result excerpt omitted_chars=") catch {};
        appendInt(out, allocator, omitted);
        out.appendSlice(allocator, "]\n") catch {};
        if (tail_len > 0) {
            out.appendSlice(allocator, content[content.len - tail_len ..]) catch {};
            out.append(allocator, '\n') catch {};
        }
    }

    fn appendKeyLines(out: *std.ArrayList(u8), allocator: std.mem.Allocator, content: []const u8, max_lines: usize) void {
        var emitted: usize = 0;
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |raw_line| {
            if (emitted >= max_lines) break;
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (!isHighSignalToolLine(line)) continue;
            if (emitted == 0) out.appendSlice(allocator, "\nkey_lines:\n") catch {};
            out.appendSlice(allocator, "- ") catch {};
            appendBoundedSingleLine(out, allocator, line, 240);
            out.append(allocator, '\n') catch {};
            emitted += 1;
        }
        if (emitted == 0) {
            out.appendSlice(allocator, "\nkey_lines: none extracted deterministically\n") catch {};
        }
    }

    fn isHighSignalToolLine(line: []const u8) bool {
        return std.mem.indexOf(u8, line, "/home/") != null or
            std.mem.indexOf(u8, line, "src/") != null or
            std.mem.indexOf(u8, line, ".zig") != null or
            std.mem.indexOf(u8, line, ".py") != null or
            std.mem.indexOf(u8, line, ".cs") != null or
            std.mem.indexOf(u8, line, ".cpp") != null or
            containsAsciiIgnoreCase(line, "error") or
            containsAsciiIgnoreCase(line, "warning") or
            containsAsciiIgnoreCase(line, "failed") or
            containsAsciiIgnoreCase(line, "missing") or
            containsAsciiIgnoreCase(line, "exists") or
            containsAsciiIgnoreCase(line, "created") or
            containsAsciiIgnoreCase(line, "success") or
            containsAsciiIgnoreCase(line, "OpenVR") or
            containsAsciiIgnoreCase(line, "Overlay") or
            containsAsciiIgnoreCase(line, "SetOverlay") or
            containsAsciiIgnoreCase(line, "CreateOverlay");
    }

    fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var j: usize = 0;
            while (j < needle.len) : (j += 1) {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
            }
            if (j == needle.len) return true;
        }
        return false;
    }

    fn appendBoundedSingleLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, max_chars: usize) void {
        const n = @min(text.len, max_chars);
        for (text[0..n]) |c| {
            switch (c) {
                '\n', '\r', '\t' => out.append(allocator, ' ') catch {},
                else => out.append(allocator, c) catch {},
            }
        }
        if (text.len > n) out.appendSlice(allocator, "...") catch {};
    }

    fn appendInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) void {
        var num_buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch "0";
        out.appendSlice(allocator, s) catch {};
    }

    /// Build prompt layers manually for custom assembly. Public API.
    pub fn buildPromptLayers(
        self: *Engine,
        session_id: []const u8,
        session_system_prompt: ?[]const u8,
        adapter_context: ?[]const u8,
    ) !prompt_mod.PromptLayers {
        return prompt_mod.buildFromState(
            self.allocator,
            self.project_store,
            session_id,
            session_system_prompt,
            adapter_context,
        );
    }

    /// Trigger session summarization if threshold is met. Public API.
    pub fn maybeSummarizeSession(self: *Engine, session_id: []const u8) void {
        if (self.worker_pool) |wp| {
            if (session_id.len == 36) {
                var fixed: [36]u8 = undefined;
                @memcpy(fixed[0..], session_id[0..36]);
                if (wp.compaction_gate.deferIfStreaming(fixed)) return;
            }
        }
        if (self.summarizer) |s| {
            s.maybeSummarizeSession(session_id);
        }
    }

    /// Extract knowledge from recent summaries. Public API for automation.
    pub fn extractKnowledge(self: *Engine, session_id: []const u8) !usize {
        if (self.extractor) |e| {
            return try e.extractFromRecentSummaries(session_id, null);
        }
        return 0;
    }

    /// Search knowledge entries. Public API for prompt assembly and adapters.
    pub fn searchKnowledge(self: *Engine, query: []const u8, limit: usize) ![]const storage.KnowledgeEntry {
        if (self.knowledge_store) |ks| {
            return try ks.search(query, limit);
        }
        return &.{};
    }

    /// Get knowledge by category. Public API.
    pub fn getKnowledgeByCategory(self: *Engine, category: []const u8, limit: usize) ![]const storage.KnowledgeEntry {
        if (self.knowledge_store) |ks| {
            return try ks.getByCategory(category, limit);
        }
        return &.{};
    }

    /// Hybrid search across all content. Public API for adapters, prompt assembly.
    /// Returns results ranked by Reciprocal Rank Fusion of FTS + vector scores.
    pub fn hybridSearch(self: *Engine, query: []const u8, limit: usize) ![]const search_mod.HybridResult {
        if (self.hybrid_search) |hs| {
            // Try to embed the query for vector search
            const query_vec = if (self.embedder) |emb|
                (emb.embedQuery(query) catch null)
            else
                null;

            return try hs.search(query, query_vec, limit);
        }
        return &.{};
    }

    /// Embed and store content. Public API for automation.
    pub fn embedContent(
        self: *Engine,
        source_type: []const u8,
        source_id: i64,
        text: []const u8,
        context_header: ?[]const u8,
    ) !void {
        if (self.embedder) |emb| {
            _ = try emb.embedAndStore(source_type, source_id, text, context_header);
        }
    }

    /// Get full raw message history for a session. Messages are NEVER deleted.
    /// Public API for adapters, export, or when the user wants exact history.
    pub fn getFullHistory(self: *Engine, session_id: []const u8) ![]const storage.MessageInfo {
        return try self.message_store.getFullHistory(session_id);
    }

    /// Drill down from a summary to the raw messages it covers.
    /// Public API — "show me the exact conversation from that summary."
    pub fn drillDownSummary(self: *Engine, summary_id: i64) !?[]const storage.MessageInfo {
        if (self.summary_store) |ss| {
            const range = (try ss.getSummaryRange(summary_id)) orelse return null;
            return try self.message_store.getMessageRange(range.session_id, range.start, range.end);
        }
        return null;
    }

    /// Get messages in a specific ID range. Public API.
    pub fn getMessageRange(self: *Engine, session_id: []const u8, start_id: i64, end_id: i64) ![]const storage.MessageInfo {
        return try self.message_store.getMessageRange(session_id, start_id, end_id);
    }

    /// Force-summarize a session. Public API for automation/adapters.
    pub fn summarizeSession(self: *Engine, session_id: []const u8) !void {
        if (self.summarizer) |s| {
            try s.summarizeSession(session_id);
        }
    }

    /// Get rolling context for the active project.
    pub fn getActiveProjectContext(self: *Engine) !context_mod.PromptContext {
        const sess_id = self.session_store.active_session_id orelse
            return context_mod.PromptContext{ .project_summary = null, .project_state = null, .project_name = null };
        return try context_mod.loadProjectContext(self.project_store, &sess_id);
    }

    // ================================================================
    // CHAT RESULT TYPES
    // ================================================================

    pub const ChatResult = struct {
        text: []const u8,
        model: []const u8,
        stop_reason: ?[]const u8,
        input_tokens: u32,
        output_tokens: u32,
        /// Peak single-round input tokens (actual context window size).
        /// input_tokens is cumulative across all tool rounds.
        context_tokens: u32,
        /// Prompt cache stats (OpenRouter/Anthropic). Cumulative across tool rounds.
        cache_read_tokens: u32 = 0,
        cache_creation_tokens: u32 = 0,
        /// Comma-separated background job IDs spawned via summon_subagent during this turn.
        /// null when nothing was spawned. Caller owns the allocation.
        spawned_jobs: ?[]const u8 = null,
    };

    pub const ToolCallRecord = struct {
        tool_id: []const u8,
        tool_name: []const u8,
        tool_input: []const u8,
        tool_result: ?[]const u8,
        status: []const u8, // "success", "error", "rejected", "timeout"
        approved: ?bool,
    };

    pub const Result = union(enum) {
        response: common.Response,
        chat: ChatResult,
    };

    /// Adapter-provided callback for streaming responses to the client.
    pub const StreamEmitter = struct {
        ctx: *anyopaque,
        emitFn: *const fn (ctx: *anyopaque, response: common.Response) void,
        isCancelledFn: ?*const fn (ctx: *anyopaque) bool = null,

        pub fn emit(self: StreamEmitter, response: common.Response) void {
            self.emitFn(self.ctx, response);
        }

        pub fn isCancelled(self: StreamEmitter) bool {
            if (self.isCancelledFn) |f| return f(self.ctx);
            return false;
        }
    };

    /// Adapter-provided callback for tool confirmation.
    /// Called when a tool requires user approval. Returns true if approved.
    pub const ToolConfirmCallback = struct {
        ctx: *anyopaque,
        confirmFn: *const fn (ctx: *anyopaque, tool_name: []const u8, tool_id: []const u8, input_preview: []const u8) bool,

        pub fn confirm(self: ToolConfirmCallback, tool_name: []const u8, tool_id: []const u8, input_preview: []const u8) bool {
            return self.confirmFn(self.ctx, tool_name, tool_id, input_preview);
        }
    };

    // Anti-hallucination messages for tool failures.
    // These are injected as tool_result content so the LLM knows NOT to fabricate.
    const TOOL_DECLINED_MSG = "USER DECLINED this tool call. You have NO output from this tool. " ++
        "Do NOT fabricate, guess, or invent a result. Acknowledge the tool was not run and offer alternatives.";
    const TOOL_ERROR_MSG = "TOOL ERROR. The tool failed to execute. You have NO output. " ++
        "Do NOT fabricate a result. Report the error and suggest next steps.";
    const TOOL_NOT_FOUND_MSG = "TOOL NOT FOUND. This tool does not exist. You have NO output. " ++
        "Do NOT fabricate a result. List available tools if asked.";

    // ================================================================
    // PROTOCOL DISPATCH — thin wrappers over the public API.
    // Each adapter calls process(), which dispatches here.
    // ================================================================

    pub fn process(self: *Engine, request: common.Request, emitter: ?StreamEmitter, confirmer: ?ToolConfirmCallback) Result {
        return switch (request) {
            .chat => |req| if (req.background) self.enqueueBackgroundChat(req) else self.processChat(req, emitter, confirmer),
            .session_list => self.processSessionList(),
            .session_create => |req| self.processSessionCreate(req),
            .session_switch => |id| self.processSessionSwitch(id),
            .session_delete => |id| self.processSessionDelete(id),
            .model_list => self.processModelList(),
            .model_set => |model| self.processModelSet(model),
            .system_set => |system| self.processSystemSet(system),
            .status => self.processStatus(),
            .tool_confirm => |confirm| self.processToolConfirm(confirm),
            .auth_list => self.processAuthList(),
            .auth_add => |req| self.processAuthAdd(req),
            .auth_remove => |id| self.processAuthRemove(id),
            .auth_switch => |id| self.processAuthSwitch(id),
            .auth_status => self.processAuthStatus(),
            .project_list => self.processProjectList(),
            .project_create => |req| self.processProjectCreate(req),
            .project_info => |name| self.processProjectInfo(name),
            .project_attach => |name| self.processProjectAttach(name),
            .project_detach => self.processProjectDetach(),
            .stop => .{ .response = .{ .ok = {} } },
        };
    }

    // ================================================================
    // CHAT — the core loop. Hooks fire after each response.
    // ================================================================

    fn processChat(self: *Engine, chat_req: common.Request.ChatRequest, emitter: ?StreamEmitter, confirmer: ?ToolConfirmCallback) Result {
        // Reset read-tracking for this conversation turn (free duped keys)
        {
            var it = self.files_read_this_turn.keyIterator();
            while (it.next()) |key| self.allocator.free(@constCast(key.*));
            self.files_read_this_turn.clearRetainingCapacity();
        }

        // Get session: explicit session_id > active session > create new
        var sess = blk: {
            if (chat_req.session_id) |sid| {
                if (self.session_store.getSession(sid) catch null) |s| break :blk s;
            }
            if (self.session_store.getActiveSession()) |s| break :blk s;
            break :blk self.session_store.createSession(null) catch {
                return .{ .response = .{ .error_resp = .{
                    .code = "SESSION_ERROR",
                    .message = "Failed to create session",
                } } };
            };
        };

        if (!chat_req.is_subagent) {
            self.maybeUpdateSessionWorkingDirectory(&sess.id, chat_req.message);
        }

        // Add user message to DB. Skipped for subagents — their wrapped
        // task is a machine-generated instruction from the dispatcher, not
        // a real user turn, and persisting it pollutes the dispatcher's
        // session history with directive boilerplate.
        var user_msg_id: ?i64 = null;
        if (!chat_req.is_subagent) {
            user_msg_id = self.message_store.addUserMessage(&sess.id, chat_req.message) catch {
                return .{ .response = .{ .error_resp = .{
                    .code = "MESSAGE_ERROR",
                    .message = "Failed to add message",
                } } };
            };
        }

        // Plan enforcement: track whether an active plan exists for this session.
        // When false, the tool gate blocks all non-plan tool calls, forcing the
        // model to create a plan before it can do any work.
        var has_active_plan = if (self.session_store.getPlan(&sess.id) catch null) |p| blk: {
            self.allocator.free(p);
            break :blk true;
        } else false;

        // Determine model: explicit override > auto-routing > session model
        const model = if (chat_req.model_override) |override|
            override
        else if (std.mem.eql(u8, sess.model, "auto") and self.config.routing.enabled) blk: {
            const route = self.router.route(chat_req.message, sess.message_count);
            std.log.info("Router: {s} -> {s} ({s})", .{ route.tier.label(), route.model, route.reason });
            break :blk route.model;
        } else sess.model;

        // Resolve the model string to a concrete provider + bare model name.
        // Strings like `ollama:qwen3:8b` or `openai:gpt-4o` switch providers
        // per-turn; bare names (`claude-sonnet-4-6`) stay on the default
        // provider for backwards compat.
        const resolved = self.resolveProviderForModel(model);
        const active_provider = resolved.provider;
        if (!std.mem.eql(u8, active_provider.getName(), self.provider.getName())) {
            std.log.info("Provider switch: {s} → {s} (model={s})", .{
                self.provider.getName(),
                active_provider.getName(),
                resolved.model,
            });
        }

        // Build API messages. Subagents get a FRESH one-message context
        // containing only their wrapped task directive — no session history
        // at all. This is load-bearing: the old behavior (loading 90+ turns
        // of Discord chat via buildCompactedMessages) caused the subagent
        // to pattern-match the dispatcher's "Let me...", "Dispatching..."
        // style and reply with chat instead of calling tools.
        const msgs: []const api.messages.Message = if (chat_req.is_subagent) blk: {
            const content = self.allocator.alloc(api.messages.ContentBlock, 1) catch {
                return .{ .response = .{ .error_resp = .{
                    .code = "BUILD_ERROR",
                    .message = "Failed to allocate subagent message",
                } } };
            };
            content[0] = .{ .text = .{ .text = chat_req.message } };
            const msg = self.allocator.alloc(api.messages.Message, 1) catch {
                self.allocator.free(content);
                return .{ .response = .{ .error_resp = .{
                    .code = "BUILD_ERROR",
                    .message = "Failed to allocate subagent message",
                } } };
            };
            msg[0] = .{ .role = .user, .content = content };
            std.log.info("Subagent: fresh 1-message context (no session history)", .{});
            break :blk msg;
        } else context_mod.buildCompactedMessages(
            self.allocator,
            self.message_store,
            self.summary_store,
            &sess.id,
            context_mod.CompactConfig{
                .compact_threshold = self.config.context.compact_threshold,
                .recent_window = self.config.context.recent_window,
                .max_context_chars = self.config.context.max_context_chars,
            },
        ) catch |err| {
            std.log.err("Build messages failed: {}", .{err});
            return .{ .response = .{ .error_resp = .{
                .code = "BUILD_ERROR",
                .message = "Failed to build messages",
            } } };
        };
        defer self.allocator.free(msgs);
        std.log.info("Chat: {d} messages, model={s}", .{ msgs.len, model });

        // Process image attachments. The main model receives real image
        // content blocks on the current user turn (so it can actually see
        // pixels), while the vision pipeline still runs in parallel to
        // produce a cached text description — that description is appended
        // to adapter_context as a supplement (useful for OCR-heavy content
        // and for subagents that don't get the image blocks).
        var vision_arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer vision_arena_state.deinit();
        const vision_arena = vision_arena_state.allocator();

        var user_turn_images: std.ArrayList(api.messages.ContentBlock) = .empty;
        var user_turn_suffix_blocks: std.ArrayList(api.messages.ContentBlock) = .empty;

        const effective_adapter_context: ?[]const u8 = blk: {
            const attachments = chat_req.attachments orelse break :blk chat_req.adapter_context;
            if (attachments.len == 0) break :blk chat_req.adapter_context;
            const vp = self.vision_pipeline orelse {
                std.log.warn("Attachments provided but no vision pipeline is wired; ignoring.", .{});
                break :blk chat_req.adapter_context;
            };

            const vision_cfg = &self.config.vision;
            const limit = @min(attachments.len, vision_cfg.max_images_per_turn);
            // Subagents run with a synthetic 1-message context and don't
            // carry the user's attachments, so skip the main-model image
            // injection on that path.
            const attach_to_main_turn = !chat_req.is_subagent and
                modelAcceptsDirectImages(active_provider.getName(), resolved.model);
            if (!attach_to_main_turn and !chat_req.is_subagent) {
                std.log.info(
                    "Skipping raw image blocks for text-only provider/model {s}/{s}; using vision text only",
                    .{ active_provider.getName(), resolved.model },
                );
            }

            var overlay: std.ArrayList(u8) = .empty;
            var user_image_text: std.ArrayList(u8) = .empty;
            if (chat_req.adapter_context) |ctx| {
                overlay.appendSlice(vision_arena, ctx) catch {};
                overlay.appendSlice(vision_arena, "\n\n") catch {};
            }
            overlay.appendSlice(vision_arena, "--- Attached images (auto-described via vision model) ---\n") catch {};
            user_image_text.appendSlice(vision_arena, "[Attached image descriptions]\n") catch {};

            var i: usize = 0;
            while (i < limit) : (i += 1) {
                const att = attachments[i];
                if (!isStrictImageMime(att.mime)) continue;

                // Read the image bytes and base64-encode them for the main
                // model's user turn. Bounded by max_image_bytes. On any
                // failure we fall through to the vision-description path so
                // the model still sees *something*.
                img_read: {
                    if (!attach_to_main_turn) break :img_read;
                    const io = common.config.runtimeIo();
                    const file = std.Io.Dir.openFileAbsolute(io, att.path, .{}) catch |err| {
                        std.log.warn("Main-turn image read failed for {s}: {s}", .{ att.name, @errorName(err) });
                        break :img_read;
                    };
                    defer file.close(io);
                    var file_reader = file.reader(io, &.{});
                    const bytes = file_reader.interface.allocRemaining(vision_arena, .limited(vision_cfg.max_image_bytes + 1)) catch |err| {
                        std.log.warn("Main-turn image unreadable for {s}: {s}", .{ att.name, @errorName(err) });
                        break :img_read;
                    };
                    if (bytes.len == 0) break :img_read;
                    const b64_len = std.base64.standard.Encoder.calcSize(bytes.len);
                    const b64 = vision_arena.alloc(u8, b64_len) catch break :img_read;
                    _ = std.base64.standard.Encoder.encode(b64, bytes);
                    user_turn_images.append(vision_arena, .{
                        .image = .{ .media_type = att.mime, .data = b64 },
                    }) catch break :img_read;
                }

                const result = vp.describePath(&sess.id, att.name, att.mime, att.path) catch |err| {
                    std.log.err("Vision describe failed for {s}: {s}", .{ att.name, @errorName(err) });
                    var err_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&err_buf, "[vision error: {s}]", .{@errorName(err)}) catch "[vision error]";
                    overlay.appendSlice(vision_arena, "\nImage: ") catch {};
                    overlay.appendSlice(vision_arena, att.name) catch {};
                    overlay.appendSlice(vision_arena, "\n") catch {};
                    overlay.appendSlice(vision_arena, msg) catch {};
                    overlay.appendSlice(vision_arena, "\n") catch {};
                    user_image_text.appendSlice(vision_arena, "\nImage: ") catch {};
                    user_image_text.appendSlice(vision_arena, att.name) catch {};
                    user_image_text.appendSlice(vision_arena, "\n") catch {};
                    user_image_text.appendSlice(vision_arena, msg) catch {};
                    user_image_text.appendSlice(vision_arena, "\n") catch {};
                    continue;
                };
                defer result.deinit(self.allocator);

                overlay.appendSlice(vision_arena, "\nImage: ") catch {};
                overlay.appendSlice(vision_arena, att.name) catch {};
                overlay.appendSlice(vision_arena, " [") catch {};
                overlay.appendSlice(vision_arena, att.mime) catch {};
                overlay.appendSlice(vision_arena, if (result.from_cache) ", cached" else ", fresh") catch {};
                overlay.appendSlice(vision_arena, ", model=") catch {};
                overlay.appendSlice(vision_arena, result.model_used) catch {};
                overlay.appendSlice(vision_arena, "]\n") catch {};
                overlay.appendSlice(vision_arena, result.description) catch {};
                overlay.appendSlice(vision_arena, "\n") catch {};

                user_image_text.appendSlice(vision_arena, "\nImage: ") catch {};
                user_image_text.appendSlice(vision_arena, att.name) catch {};
                user_image_text.appendSlice(vision_arena, " [") catch {};
                user_image_text.appendSlice(vision_arena, att.mime) catch {};
                user_image_text.appendSlice(vision_arena, if (result.from_cache) ", cached" else ", fresh") catch {};
                user_image_text.appendSlice(vision_arena, ", model=") catch {};
                user_image_text.appendSlice(vision_arena, result.model_used) catch {};
                user_image_text.appendSlice(vision_arena, "]\n") catch {};
                user_image_text.appendSlice(vision_arena, result.description) catch {};
                user_image_text.appendSlice(vision_arena, "\n") catch {};
            }

            if (attachments.len > limit) {
                var trim_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&trim_buf, "\n[{d} additional attachments omitted: over per-turn limit of {d}]\n", .{
                    attachments.len - limit,
                    limit,
                }) catch "\n[additional attachments omitted]\n";
                overlay.appendSlice(vision_arena, msg) catch {};
                user_image_text.appendSlice(vision_arena, msg) catch {};
            }
            overlay.appendSlice(vision_arena, "--- End images ---") catch {};
            user_image_text.appendSlice(vision_arena, "[End attached image descriptions]") catch {};

            if (!attach_to_main_turn and !chat_req.is_subagent and user_image_text.items.len > 0) {
                user_turn_images.append(vision_arena, .{
                    .text = .{ .text = user_image_text.items },
                }) catch {};
                std.log.info("Attached image description text to user turn", .{});
            }

            break :blk overlay.items;
        };

        if (!chat_req.is_subagent and std.mem.eql(u8, active_provider.getName(), "ollama")) {
            const persona_text = if (sess.system_prompt) |name|
                prompt_mod.loadPersona(vision_arena, name) orelse prompt_mod.DEFAULT_PERSONA
            else
                prompt_mod.DEFAULT_PERSONA;
            const max_persona_tail: usize = 2400;
            const persona_tail = persona_text[0..@min(persona_text.len, max_persona_tail)];
            const reminder = std.fmt.allocPrint(
                vision_arena,
                "\n\n[Local Ollama instruction: answer the user's message above in the active persona voice. " ++
                    "This is style/context only; do not mention this instruction. Active persona excerpt follows.]\n{s}\n" ++
                    "[End local Ollama persona reminder]",
                .{persona_tail},
            ) catch null;
            if (reminder) |text| {
                user_turn_suffix_blocks.append(vision_arena, .{
                    .text = .{ .text = text },
                }) catch {};
                std.log.info("Attached {d}b Ollama persona reminder to user turn tail", .{text.len});
            }
        }

        // Inject collected image/text blocks into the current user turn.
        // Multimodal models get raw image blocks; text-only local models
        // get vision/OCR text here so it is not buried in the system prompt.
        // Ollama also gets a compact persona reminder after the user's text,
        // because its OpenAI-compatible endpoint is effectively preserving
        // only ~4k prompt tokens in current testing.
        if ((user_turn_images.items.len > 0 or user_turn_suffix_blocks.items.len > 0) and msgs.len > 0) {
            const last_idx = msgs.len - 1;
            if (msgs[last_idx].role == .user) {
                const orig_content = msgs[last_idx].content;
                const new_len = user_turn_images.items.len + orig_content.len + user_turn_suffix_blocks.items.len;
                if (vision_arena.alloc(api.messages.ContentBlock, new_len)) |new_content| {
                    var content_pos: usize = 0;
                    @memcpy(new_content[0..user_turn_images.items.len], user_turn_images.items);
                    content_pos += user_turn_images.items.len;
                    @memcpy(new_content[content_pos..][0..orig_content.len], orig_content);
                    content_pos += orig_content.len;
                    @memcpy(new_content[content_pos..][0..user_turn_suffix_blocks.items.len], user_turn_suffix_blocks.items);
                    const msgs_mut = @constCast(msgs);
                    msgs_mut[last_idx] = .{ .role = .user, .content = new_content };
                    std.log.info(
                        "Attached {d} prefix block(s) and {d} suffix block(s) to user turn",
                        .{ user_turn_images.items.len, user_turn_suffix_blocks.items.len },
                    );
                } else |_| {}
            }
        }

        // Build layered system prompt: persona + user context + project + retrieved + adapter + session
        // For subagents, skip retrieval — their user_message is a wrapped
        // directive ("[SUBAGENT EXECUTION MODE]...") that would pollute the
        // FTS query. The dispatcher (the actual user-facing turn) is where
        // memory injection matters.
        const retrieval_query: ?[]const u8 = if (chat_req.is_subagent) null else chat_req.message;

        // Active subagents layer: dispatcher only. Auto-injects per-session
        // status of background jobs spawned via summon_subagent so the
        // dispatcher can answer "how's that going" without tool-calling.
        const active_subagents_layer: ?[]const u8 = blk_sa: {
            if (chat_req.is_subagent) break :blk_sa null;
            const wp = self.worker_pool orelse break :blk_sa null;
            break :blk_sa wp.formatActiveSubagentsLayer(self.allocator, &sess.id);
        };
        defer if (active_subagents_layer) |s| self.allocator.free(s);

        const system_prompt: ?[]const u8 = self.buildSystemPrompt(
            &sess.id,
            sess.system_prompt,
            effective_adapter_context,
            chat_req.message,
            retrieval_query,
            active_subagents_layer,
            chat_req.plans_required,
        ) catch sess.system_prompt;

        var owned_tool_defs: std.ArrayList([]const api.messages.ToolDefinition) = .empty;
        defer {
            for (owned_tool_defs.items) |defs| self.allocator.free(defs);
            owned_tool_defs.deinit(self.allocator);
        }

        // Subagents must not recursively summon more subagents or manage
        // other subagents — nested job IDs aren't tracked by adapters and
        // stop/redirect from a child would race with the dispatcher. This
        // must be the request flag, not "confirmer != null": normal
        // background jobs also use a confirmer for adapter approval prompts.
        const is_subagent = chat_req.is_subagent;

        // Tool selection: allowed_tools filter > all enabled tools
        const initial_tools = if (chat_req.allowed_tools) |at|
            self.selectAllowedToolDefinitions(at, is_subagent)
        else if (is_subagent)
            self.tool_registry.getToolDefinitionsExcludingMany(&tools.ToolRegistry.SUBAGENT_HIDDEN_TOOLS)
        else if (chat_req.compact_tool_schemas)
            self.selectToolDefinitionsForMessage(chat_req.message)
        else
            self.tool_registry.getToolDefinitions();

        if (initial_tools) |defs| {
            owned_tool_defs.append(self.allocator, defs) catch {};
        }

        if (!chat_req.is_subagent and isToolManifestQuestion(self.allocator, chat_req.message)) {
            if (initial_tools) |defs| {
                var manifest: std.ArrayList(u8) = .empty;
                manifest.appendSlice(vision_arena, "\n\n[Active tool manifest]\ncount: ") catch {};
                var num_buf: [32]u8 = undefined;
                manifest.appendSlice(vision_arena, std.fmt.bufPrint(&num_buf, "{d}", .{defs.len}) catch "0") catch {};
                manifest.appendSlice(vision_arena, "\nnames: ") catch {};
                for (defs, 0..) |def, i| {
                    if (i > 0) manifest.appendSlice(vision_arena, ", ") catch {};
                    manifest.appendSlice(vision_arena, def.name) catch {};
                }
                manifest.appendSlice(vision_arena, "\nInstruction: If the user asks how many tools are available, answer from this manifest. Do not estimate.\n[End active tool manifest]") catch {};
                user_turn_suffix_blocks.append(vision_arena, .{
                    .text = .{ .text = manifest.items },
                }) catch {};
                if (msgs.len > 0) {
                    const last_idx = msgs.len - 1;
                    if (msgs[last_idx].role == .user) {
                        const orig_content = msgs[last_idx].content;
                        if (vision_arena.alloc(api.messages.ContentBlock, orig_content.len + 1)) |new_content| {
                            @memcpy(new_content[0..orig_content.len], orig_content);
                            new_content[orig_content.len] = .{ .text = .{ .text = manifest.items } };
                            const msgs_mut = @constCast(msgs);
                            msgs_mut[last_idx] = .{ .role = .user, .content = new_content };
                        } else |_| {}
                    }
                }
                std.log.info("Attached active tool manifest for {d} selected tool(s)", .{defs.len});
            }
        }

        // Append the voice-calibration style guide to the system prompt
        // when targeting a non-Anthropic provider. The goal is to pin
        // small local models (qwen3, llama3.x, mistral) to the persona
        // voice instead of defaulting to generic-assistant cadence.
        const active_persona_anchor: ?[]const u8 = blk_persona_anchor: {
            if (std.mem.eql(u8, active_provider.getName(), "anthropic")) break :blk_persona_anchor null;
            const persona_text = if (sess.system_prompt) |name|
                prompt_mod.loadPersona(vision_arena, name) orelse prompt_mod.DEFAULT_PERSONA
            else
                prompt_mod.DEFAULT_PERSONA;
            const max_persona_anchor: usize = 3200;
            break :blk_persona_anchor persona_text[0..@min(persona_text.len, max_persona_anchor)];
        };
        const effective_system: ?[]const u8 = blk_sys: {
            const base = system_prompt orelse break :blk_sys null;
            if (std.mem.eql(u8, active_provider.getName(), "anthropic")) {
                break :blk_sys base;
            }
            // Concatenate onto the vision_arena so lifetime matches the
            // rest of the request (the arena deinits at function exit).
            const persona_anchor_header =
                "\n\n## Active persona reminder (local model recency anchor)\n" ++
                "The selected persona is still active for this reply. Render that voice directly:\n\n";
            const persona_anchor = active_persona_anchor orelse "";
            const combined_len = base.len + SMALL_MODEL_STYLE_GUIDE.len +
                persona_anchor_header.len + persona_anchor.len;
            const combined = vision_arena.alloc(u8, combined_len) catch break :blk_sys base;
            var combined_pos: usize = 0;
            @memcpy(combined[combined_pos..][0..base.len], base);
            combined_pos += base.len;
            @memcpy(combined[combined_pos..][0..SMALL_MODEL_STYLE_GUIDE.len], SMALL_MODEL_STYLE_GUIDE);
            combined_pos += SMALL_MODEL_STYLE_GUIDE.len;
            @memcpy(combined[combined_pos..][0..persona_anchor_header.len], persona_anchor_header);
            combined_pos += persona_anchor_header.len;
            @memcpy(combined[combined_pos..][0..persona_anchor.len], persona_anchor);
            std.log.info(
                "Appended {d}b style guide + {d}b persona anchor for non-Anthropic provider ({s})",
                .{ SMALL_MODEL_STYLE_GUIDE.len, persona_anchor.len, active_provider.getName() },
            );
            break :blk_sys combined;
        };

        const api_request = api.MessageRequest{
            .model = resolved.model,
            .max_tokens = self.config.api.max_tokens,
            .messages = msgs,
            .system = effective_system,
            .tools = if (chat_req.no_tools) null else initial_tools,
            .stream = true,
        };

        // Track which profile we're using
        const active_profile_id = self.auth_store.active_profile;

        // ============================================================
        // API CALL + TOOL EXECUTION LOOP
        // The LLM may request tool calls. We execute them (with confirmation
        // if needed), send results back, and loop until the LLM gives a
        // final text response (stop_reason != "tool_use").
        // Max 10 tool rounds to prevent infinite loops.
        // ============================================================
        var total_input_tokens: u32 = 0;
        var total_output_tokens: u32 = 0;
        var total_cache_read: u32 = 0;
        var total_cache_creation: u32 = 0;
        var context_tokens: u32 = 0; // Peak single-round input (actual context window)
        var final_stop_reason: ?[]const u8 = null;
        var current_request = api_request;

        // Accumulate text across tool rounds (API may send text preamble + tool_use)
        var text_parts: std.ArrayList(u8) = .empty;
        defer text_parts.deinit(self.allocator);

        // Track tool calls for persistence in message history
        var tool_log: std.ArrayList(u8) = .empty;
        defer tool_log.deinit(self.allocator);

        // Background job IDs spawned via summon_subagent during this chat turn.
        // Each entry is exactly 36 chars (a UUID).
        var spawned_subagent_ids: std.ArrayList([36]u8) = .empty;
        defer spawned_subagent_ids.deinit(self.allocator);

        // Collect response arenas — freed after the tool loop is done.
        // Each API call returns a response with an arena; we can't free it
        // until the next round has consumed the tool_use data from it.
        var response_arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty;
        defer {
            for (response_arenas.items) |arena| {
                arena.deinit();
                self.allocator.destroy(arena);
            }
            response_arenas.deinit(self.allocator);
        }

        // File-read gate for file_diff: track which file paths the model has
        // actually read during this chat turn (plus any read earlier in the
        // session via history). file_diff requires the target path to be in
        // this set so the model isn't editing a file it hasn't seen. Exception:
        // `create_if_missing: true` skips the check since the file may not exist.
        var read_paths: std.StringHashMap(void) = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = read_paths.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            read_paths.deinit();
        }
        // Seed from prior history: any file_read tool_use block in the current
        // request's messages counts as "read in this session".
        for (current_request.messages) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .tool_use => |tu| {
                        if (std.mem.eql(u8, tu.name, "file_read") and tu.input == .object) {
                            if (tu.input.object.get("path")) |p| {
                                if (p == .string and p.string.len > 0) {
                                    const dup = self.allocator.dupe(u8, p.string) catch continue;
                                    const gop = read_paths.getOrPut(dup) catch {
                                        self.allocator.free(dup);
                                        continue;
                                    };
                                    if (gop.found_existing) self.allocator.free(dup);
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        var cancelled = false;
        var permission_denied = false;
        var denied_tool_buf: [64]u8 = undefined;
        var denied_tool_len: usize = 0;
        var stopped_by_dispatcher = false;
        var stop_reason_buf: [80]u8 = undefined;
        var stop_reason_len: usize = 0;
        var tool_round: usize = 0;
        while (tool_round < 100) : (tool_round += 1) {
            // Check if the client disconnected (SSE write failed)
            if (emitter) |em| {
                if (em.isCancelled()) {
                    std.log.info("Stream cancelled by client at tool round {d}", .{tool_round});
                    cancelled = true;
                    break;
                }
            }

            // Background jobs are daemon-owned. Browser/Discord adapters may
            // cancel or steer a task while it is running; apply those controls
            // at round boundaries so we never corrupt an in-flight tool call.
            if (self.worker_pool) |wp| {
                if (wp.active_job_id) |jid_val| {
                    if (wp.isBackgroundJobCancelled(&jid_val)) {
                        std.log.info("Background job cancellation requested at tool round {d}", .{tool_round});
                        cancelled = true;
                        break;
                    }

                    var steering_buf: [4096]u8 = undefined;
                    const steering_len = wp.consumeBackgroundSteering(&jid_val, &steering_buf);
                    if (steering_len > 0) {
                        if (self.injectBackgroundSteering(&current_request, steering_buf[0..steering_len])) {
                            wp.pushToolEvent(.{
                                .event_type = .control,
                                .tool_name = "steer",
                                .content = "User steering note injected before the next model request.",
                                .timestamp = common.sync.timestamp(),
                            });
                            std.log.info("Background steering injected at tool round {d}: {d} chars", .{ tool_round, steering_len });
                        }
                    }

                    // Subagent cooperative stop: dispatcher invoked subagent_stop.
                    // Polled at the round boundary so the subagent emits accumulated
                    // state instead of being killed mid-API-call.
                    if (is_subagent) {
                        if (wp.isSubagentStopRequested(&jid_val)) {
                            std.log.info("Subagent stop requested by dispatcher at tool round {d} — halting", .{tool_round});
                            cancelled = true;
                            stopped_by_dispatcher = true;
                            if (wp.getSubagent(&jid_val)) |rec| {
                                const r = rec.stopReasonSlice();
                                const n = @min(r.len, stop_reason_buf.len);
                                @memcpy(stop_reason_buf[0..n], r[0..n]);
                                stop_reason_len = n;
                            }
                            break;
                        }

                        // Pending redirect: append a synthetic user message at
                        // this seam so the next API call sees the new directive.
                        var redirect_buf: [512]u8 = undefined;
                        const redirect_len = wp.consumeSubagentRedirect(&jid_val, &redirect_buf);
                        if (redirect_len > 0) {
                            const wrapped = std.fmt.allocPrint(
                                self.allocator,
                                "=== URGENT REDIRECT FROM YOUR DISPATCHER ===\n" ++
                                    "Your previous instructions are SUPERSEDED. Stop whatever you were doing. " ++
                                    "Discard the original task plan. Do NOT continue the prior work. " ++
                                    "Your new and ONLY task is below — follow it exactly:\n\n" ++
                                    "{s}\n\n" ++
                                    "=== END REDIRECT ===\n" ++
                                    "Acknowledge briefly, then execute the new task. Do not return to the old one.",
                                .{redirect_buf[0..redirect_len]},
                            ) catch null;
                            if (wrapped) |wtext| {
                                const text_block = self.allocator.alloc(api.messages.ContentBlock, 1) catch null;
                                if (text_block) |tb| {
                                    tb[0] = .{ .text = .{ .text = wtext } };
                                    const prev = current_request.messages;
                                    const extended = self.allocator.alloc(api.messages.Message, prev.len + 1) catch null;
                                    if (extended) |ex| {
                                        @memcpy(ex[0..prev.len], prev);
                                        ex[prev.len] = .{ .role = .user, .content = tb };
                                        current_request.messages = ex;
                                        std.log.info(
                                            "Subagent redirect injected at tool round {d}: {d} chars",
                                            .{ tool_round, redirect_len },
                                        );
                                    } else {
                                        self.allocator.free(wtext);
                                        self.allocator.free(tb);
                                    }
                                } else {
                                    self.allocator.free(wtext);
                                }
                            }
                        }
                    }
                }
            }

            std.log.info("Tool round {d}, emitter={}, msgs={d}", .{ tool_round, emitter != null, current_request.messages.len });
            self.logPromptBudget(tool_round, current_request);

            // Make API call — stream ALL rounds if emitter present
            const is_stream_round = emitter != null and current_request.stream;
            self.emitModelWaitEvent(
                tool_round,
                active_provider.getName(),
                current_request.model,
                current_request.messages.len,
                current_request,
            );
            if (is_stream_round) self.beginStreaming();
            const api_response = blk: {
                if (emitter) |em| {
                    const stream_handler = api.provider.StreamHandler{
                        .ctx = @ptrCast(@constCast(&em)),
                        .onTextDelta = struct {
                            fn cb(ctx: *anyopaque, text: []const u8) void {
                                const e: *const StreamEmitter = @ptrCast(@alignCast(ctx));
                                e.emit(.{ .stream_text = text });
                            }
                        }.cb,
                    };
                    break :blk active_provider.createMessageStreaming(&current_request, stream_handler);
                }
                // Non-streaming fallback (no emitter — CLI adapter or non-stream mode)
                var non_stream = current_request;
                non_stream.stream = false;
                break :blk active_provider.createMessage(&non_stream);
            } catch |err| {
                if (is_stream_round) self.endStreaming();
                std.log.err("API error: {}", .{err});
                if (active_profile_id) |profile_id| {
                    if (self.config.auth.cooldown_enabled) {
                        self.auth_store.markFailed(profile_id);
                        if (self.auth_store.getActiveCredential("anthropic")) |fallback| {
                            self.provider.setCredential(fallback.credential);
                        }
                    }
                }
                return .{ .response = .{ .error_resp = .{
                    .code = "API_ERROR",
                    .message = @errorName(err),
                } } };
            };
            if (is_stream_round) self.endStreaming();

            // Mark profile as successfully used
            if (active_profile_id) |profile_id| {
                self.auth_store.markUsed(profile_id);
            }

            // Track arena for deferred cleanup (response data lives until tool loop ends)
            if (api_response.arena) |arena| {
                response_arenas.append(self.allocator, arena) catch {};
            }

            total_input_tokens += api_response.usage.input_tokens;
            total_output_tokens += api_response.usage.output_tokens;
            total_cache_read += api_response.usage.cache_read_tokens;
            total_cache_creation += api_response.usage.cache_creation_tokens;
            context_tokens = @max(context_tokens, api_response.usage.input_tokens);

            if (self.worker_pool) |wp| {
                if (wp.active_job_id) |jid_val| {
                    if (wp.isBackgroundJobCancelled(&jid_val)) {
                        std.log.info("Background job cancellation requested after model round {d}", .{tool_round});
                        cancelled = true;
                        break;
                    }

                    var steering_buf: [4096]u8 = undefined;
                    const steering_len = wp.consumeBackgroundSteering(&jid_val, &steering_buf);
                    if (steering_len > 0) {
                        if (self.injectBackgroundSteering(&current_request, steering_buf[0..steering_len])) {
                            wp.pushToolEvent(.{
                                .event_type = .control,
                                .tool_name = "steer",
                                .content = "User steering note arrived during a model call; stale tool calls were skipped and the note will lead the next request.",
                                .timestamp = common.sync.timestamp(),
                            });
                            std.log.info(
                                "Background steering injected after model round {d}; skipping stale response tool calls",
                                .{tool_round},
                            );
                            continue;
                        }
                    }
                }
            }

            // Always capture text from this round (API sends text preamble even with tool_use)
            if (api_response.text_content.len > 0) {
                if (text_parts.items.len > 0) {
                    text_parts.appendSlice(self.allocator, "\n\n") catch {};
                }
                text_parts.appendSlice(self.allocator, api_response.text_content) catch {};
            }
            final_stop_reason = api_response.stop_reason;

            // Check cancellation after API call (text delta writes may have failed mid-stream)
            if (emitter) |em| {
                if (em.isCancelled()) {
                    std.log.info("Stream cancelled after API response at tool round {d}", .{tool_round});
                    cancelled = true;
                    break;
                }
            }

            // Check if the response has tool use requests
            const is_tool_use = api_response.stop_reason != null and
                std.mem.eql(u8, api_response.stop_reason.?, "tool_use") and
                api_response.tool_use.len > 0;

            if (!is_tool_use) {
                break;
            }

            if (api_response.text_content.len > 0) {
                if (self.worker_pool) |wp| {
                    const max_model_text_event = 1200;
                    const event_content = if (api_response.text_content.len > max_model_text_event)
                        api_response.text_content[0..max_model_text_event]
                    else
                        api_response.text_content;
                    wp.pushToolEvent(.{
                        .event_type = .model_text,
                        .tool_name = "assistant",
                        .content = event_content,
                        .timestamp = common.sync.timestamp(),
                    });
                }
            }

            // Build messages for next API round: assistant(tool_use) → user(tool_results)
            // Execute each tool, emit events, record in DB, and build result messages.
            {
                // Assistant message: text preamble + reasoning items + tool_use blocks.
                // Reasoning items are codex-only encrypted blobs; replaying them in
                // the next request preserves chain-of-thought across tool rounds.
                // Other providers' serializers skip the .reasoning variant.
                var assistant_blocks: std.ArrayList(api.messages.ContentBlock) = .empty;
                if (api_response.text_content.len > 0) {
                    assistant_blocks.append(self.allocator, .{ .text = .{ .text = api_response.text_content } }) catch {};
                }
                for (api_response.reasoning_items) |r| {
                    assistant_blocks.append(self.allocator, .{ .reasoning = .{
                        .id = r.id,
                        .encrypted_content = r.encrypted_content,
                    } }) catch {};
                }
                for (api_response.tool_use) |tu| {
                    assistant_blocks.append(self.allocator, .{ .tool_use = .{
                        .id = tu.id,
                        .name = tu.name,
                        .input = tu.input,
                    } }) catch {};
                }

                // User message: tool_result for each tool call
                var result_blocks: std.ArrayList(api.messages.ContentBlock) = .empty;

                // Dedup identical tool_uses within a single round. The model
                // sometimes emits two or more parallel calls with the same
                // name+input (e.g. the same file_diff twice) — executing both
                // wastes rounds and, worse, when both fail the model sees "the
                // error happened twice" and retries again. Instead we run each
                // unique call once and return the SAME result for every
                // duplicate id. Key = "name\x00input_json".
                const DedupEntry = struct { content: []const u8, is_error: bool };
                var dedup: std.StringHashMap(DedupEntry) = std.StringHashMap(DedupEntry).init(self.allocator);
                defer {
                    var dit = dedup.keyIterator();
                    while (dit.next()) |k| self.allocator.free(k.*);
                    dedup.deinit();
                }

                for (api_response.tool_use) |tool_call| {
                    // Check cancellation before each tool execution
                    if (emitter) |em| {
                        if (em.isCancelled()) {
                            std.log.info("Stream cancelled before executing tool {s}", .{tool_call.name});
                            cancelled = true;
                            break;
                        }
                    }
                    if (self.worker_pool) |wp| {
                        if (wp.active_job_id) |jid_val| {
                            if (wp.isBackgroundJobCancelled(&jid_val)) {
                                std.log.info("Background job cancelled before executing tool {s}", .{tool_call.name});
                                cancelled = true;
                                break;
                            }
                        }
                    }

                    // Emit tool use info
                    if (emitter) |em| {
                        em.emit(.{ .stream_tool_use = .{
                            .tool_id = tool_call.id,
                            .tool_name = tool_call.name,
                            .input = tool_call.input_json,
                        } });
                    }

                    // Dedup: if this exact (name, input_json) already ran in
                    // this round, reuse the result instead of re-executing.
                    const dedup_key = std.fmt.allocPrint(
                        self.allocator,
                        "{s}\x00{s}",
                        .{ tool_call.name, tool_call.input_json },
                    ) catch null;
                    if (dedup_key) |key| {
                        if (dedup.get(key)) |prior| {
                            self.allocator.free(key);
                            std.log.info("Dedup: skipping duplicate {s} call, reusing prior result", .{tool_call.name});
                            const note = std.fmt.allocPrint(
                                self.allocator,
                                "[DEDUPLICATED: this exact call already ran earlier in the same round. " ++
                                    "Result reused below. Do not emit duplicate tool_use blocks — they " ++
                                    "waste context and delay the response.]\n\n{s}",
                                .{prior.content},
                            ) catch prior.content;
                            if (emitter) |em| {
                                em.emit(.{ .stream_tool_result = .{
                                    .tool_id = tool_call.id,
                                    .result = note,
                                    .is_error = prior.is_error,
                                } });
                            }
                            result_blocks.append(self.allocator, .{ .tool_result = .{
                                .tool_use_id = tool_call.id,
                                .content = note,
                                .is_error = prior.is_error,
                            } }) catch {};
                            continue;
                        }
                    }

                    // Push tool_use event for background job transparency.
                    // Normal background jobs have a confirmation callback too,
                    // but they are not subagents; the web/Discord adapters
                    // still need their tool cards.
                    if (self.worker_pool) |wp| {
                        wp.pushToolEvent(.{
                            .event_type = .tool_use,
                            .tool_name = tool_call.name,
                            .content = tool_call.input_json,
                            .timestamp = common.sync.timestamp(),
                        });
                        if (is_subagent) {
                            if (wp.active_job_id) |jid_val| {
                                wp.markSubagentLastTool(&jid_val, tool_call.name);
                            }
                        }
                    }

                    // Confirmation check
                    var declined = false;
                    if (self.tool_registry.requiresConfirmation(tool_call.name)) {
                        if (confirmer) |c| {
                            if (!c.confirm(tool_call.name, tool_call.id, tool_call.input_json)) {
                                if (self.worker_pool) |wp| {
                                    if (wp.active_job_id) |jid_val| {
                                        if (wp.isBackgroundJobCancelled(&jid_val)) {
                                            std.log.info("Background job cancelled while waiting for approval of {s}", .{tool_call.name});
                                            cancelled = true;
                                            break;
                                        }
                                    }
                                }
                                declined = true;
                            }
                        }
                        // No confirmer → auto-approve
                    }

                    if (declined) {
                        std.log.info("Tool {s} denied by user; stopping task", .{tool_call.name});
                        permission_denied = true;
                        denied_tool_len = @min(tool_call.name.len, denied_tool_buf.len);
                        @memcpy(denied_tool_buf[0..denied_tool_len], tool_call.name[0..denied_tool_len]);
                        if (self.worker_pool) |wp| {
                            wp.pushToolEvent(.{
                                .event_type = .control,
                                .tool_name = "permission_denied",
                                .content = "User denied a required tool permission. Task stopped before running the tool.",
                                .is_error = true,
                                .timestamp = common.sync.timestamp(),
                            });
                        }
                        break;
                    }

                    // Plan enforcement gate: block heavyweight tool calls when
                    // no active plan exists. Lightweight (read-only) tools are
                    // allowed so the dispatcher can answer quick questions
                    // directly without creating a full plan.
                    const is_plan_tool = std.mem.eql(u8, tool_call.name, "plan");
                    const is_lightweight = isLightweightTool(tool_call.name) or
                        isSafeBashCommand(tool_call.name, tool_call.input);
                    // Explore-mode summon_subagent is read-only recon; bypass plan gate.
                    const is_explore_summon = std.mem.eql(u8, tool_call.name, "summon_subagent") and
                        isExploreSummon(tool_call.input);
                    const plan_gate_active = chat_req.plans_required and !has_active_plan and !is_plan_tool and !is_subagent and
                        !is_lightweight and !is_explore_summon;
                    const tool_res = if (plan_gate_active) blk: {
                        std.log.info("Plan gate: blocked {s} — no active plan", .{tool_call.name});
                        break :blk tools.ToolResult{
                            .content = "BLOCKED: This tool requires an active execution plan. Call the `plan` " ++
                                "tool with operation \"create\" first. Inline tools that work without a plan: " ++
                                "file_find, file_read, introspect, calc, research_tool, meme_tool, amazon_search, " ++
                                "visual_audit, playwright_mcp, vision_read, file_diff " ++
                                "(single-file edits), and safe bash (ls, tree, git log/status/diff, head, tail, " ++
                                "cat, find, pwd). For multi-step/multi-file work, create a plan and delegate " ++
                                "via summon_subagent.",
                            .is_error = true,
                        };
                    } else if (is_plan_tool) blk: {
                        std.log.info("Special tool: plan", .{});
                        const res = self.handlePlanTool(tool_call.input, &sess.id, is_subagent);
                        // Update plan state so subsequent tools in this turn aren't blocked
                        if (!res.is_error) {
                            if (tool_call.input == .object) {
                                if (tool_call.input.object.get("operation")) |op| {
                                    if (op == .string) {
                                        if (std.mem.eql(u8, op.string, "create")) {
                                            has_active_plan = true;
                                        } else if (std.mem.eql(u8, op.string, "clear")) {
                                            has_active_plan = false;
                                        }
                                    }
                                }
                            }
                        }
                        break :blk res;
                    } else if (std.mem.eql(u8, tool_call.name, "summon_subagent")) blk: {
                        std.log.info("Special tool: summon_subagent", .{});
                        break :blk self.handleSummonSubagent(tool_call.input, &sess.id, &spawned_subagent_ids, model, chat_req.delegated_model_override, chat_req.allowed_tools, chat_req.plans_required);
                    } else if (std.mem.eql(u8, tool_call.name, "subagent_inspect")) blk: {
                        std.log.info("Special tool: subagent_inspect", .{});
                        break :blk self.handleSubagentInspect(tool_call.input, &sess.id);
                    } else if (std.mem.eql(u8, tool_call.name, "subagent_stop")) blk: {
                        std.log.info("Special tool: subagent_stop", .{});
                        break :blk self.handleSubagentStop(tool_call.input, &sess.id);
                    } else if (std.mem.eql(u8, tool_call.name, "subagent_redirect")) blk: {
                        std.log.info("Special tool: subagent_redirect", .{});
                        break :blk self.handleSubagentRedirect(tool_call.input, &sess.id);
                    } else if (std.mem.eql(u8, tool_call.name, "vision_read")) blk: {
                        std.log.info("Special tool: vision_read", .{});
                        break :blk self.handleVisionRead(tool_call.input, &sess.id);
                    } else if (std.mem.eql(u8, tool_call.name, "file_diff") and
                        !fileDiffHasBeenRead(tool_call.input, &read_paths))
                    blk: {
                        const gated_path = if (tool_call.input == .object)
                            (if (tool_call.input.object.get("path")) |p|
                                (if (p == .string) p.string else "<unknown>")
                            else
                                "<unknown>")
                        else
                            "<unknown>";
                        std.log.info("file_diff gate: blocked — path '{s}' not read yet", .{gated_path});
                        const msg = std.fmt.allocPrint(
                            self.allocator,
                            "BLOCKED: file_diff requires you to file_read the target file first so " ++
                                "you can see its actual contents before proposing a change. Call file_read " ++
                                "on '{s}', then retry the diff. " ++
                                "(If this is a new file that doesn't exist yet, set create_if_missing: true.)",
                            .{gated_path},
                        ) catch "BLOCKED: file_diff requires you to file_read the target file first.";
                        break :blk tools.ToolResult{ .content = msg, .is_error = true };
                    } else blk: {
                        std.log.info("Executing tool: {s}", .{tool_call.name});
                        break :blk self.executeToolParsedCached(tool_call.name, tool_call.input, tool_call.input_json);
                    };

                    // Record successful file_read paths so subsequent file_diff
                    // calls in this turn can see the file.
                    if (!tool_res.is_error and std.mem.eql(u8, tool_call.name, "file_read")) {
                        recordReadPath(self.allocator, &read_paths, tool_call.input);
                    }

                    // Emit result
                    if (emitter) |em| {
                        em.emit(.{ .stream_tool_result = .{
                            .tool_id = tool_call.id,
                            .result = tool_res.content,
                            .is_error = tool_res.is_error,
                        } });
                    }

                    // Push tool_result event for background job transparency.
                    if (self.worker_pool) |wp| {
                        // Truncate content for the event log (keep it reasonable)
                        const max_event_content = 1000;
                        const event_content = if (tool_res.content.len > max_event_content)
                            tool_res.content[0..max_event_content]
                        else
                            tool_res.content;
                        wp.pushToolEvent(.{
                            .event_type = .tool_result,
                            .tool_name = tool_call.name,
                            .content = event_content,
                            .is_error = tool_res.is_error,
                            .timestamp = common.sync.timestamp(),
                        });
                    }

                    // Log tool call for message history persistence
                    {
                        // Truncate tool output for the log (keep full in API messages)
                        const max_result_log = 2000;
                        const result_preview = if (tool_res.content.len > max_result_log)
                            tool_res.content[0..max_result_log]
                        else
                            tool_res.content;

                        tool_log.appendSlice(self.allocator, "\n<tool_call name=\"") catch {};
                        tool_log.appendSlice(self.allocator, tool_call.name) catch {};
                        tool_log.appendSlice(self.allocator, "\">\n<input>") catch {};
                        tool_log.appendSlice(self.allocator, tool_call.input_json) catch {};
                        tool_log.appendSlice(self.allocator, "</input>\n<output") catch {};
                        if (tool_res.is_error) {
                            tool_log.appendSlice(self.allocator, " error=\"true\"") catch {};
                        }
                        tool_log.appendSlice(self.allocator, ">") catch {};
                        tool_log.appendSlice(self.allocator, result_preview) catch {};
                        if (tool_res.content.len > max_result_log) {
                            tool_log.appendSlice(self.allocator, "...(truncated)") catch {};
                        }
                        tool_log.appendSlice(self.allocator, "</output>\n</tool_call>") catch {};
                    }

                    // Record raw output in DB before any model-facing compaction.
                    const raw_tool_call_id = self.recordToolCall(&sess.id, 0, .{
                        .tool_id = tool_call.id,
                        .tool_name = tool_call.name,
                        .tool_input = tool_call.input_json,
                        .tool_result = tool_res.content,
                        .status = if (declined) "rejected" else if (tool_res.is_error) "error" else "success",
                        .approved = if (declined) false else !tool_res.is_error,
                    });

                    // For failed tool calls, augment the error with recovery guidance
                    const model_content = self.compactToolResultForModel(
                        tool_call.name,
                        tool_call.input_json,
                        tool_res.modelContent(),
                        tool_res.content.len,
                        raw_tool_call_id,
                        tool_res.is_error,
                    );
                    const result_content = if (tool_res.is_error and !declined) blk: {
                        var err_msg: std.ArrayList(u8) = .empty;
                        err_msg.appendSlice(self.allocator, model_content) catch break :blk model_content;
                        err_msg.appendSlice(
                            self.allocator,
                            "\n\n[RECOVERY HINT: This tool call FAILED. " ++
                                "DO NOT retry with the same input — you will get the same error. " ++
                                "Read the error text above and change what caused it (path, argument, " ++
                                "parameter, or prerequisite step). If the error says a prerequisite " ++
                                "is missing (e.g. 'file_read first'), satisfy it before retrying. " ++
                                "If you don't understand the error, ask the user rather than guessing.]",
                        ) catch {};
                        break :blk err_msg.items;
                    } else model_content;

                    // Record in dedup map so later duplicates in this round reuse the result.
                    if (dedup_key) |key| {
                        const gop = dedup.getOrPut(key) catch {
                            self.allocator.free(key);
                            result_blocks.append(self.allocator, .{ .tool_result = .{
                                .tool_use_id = tool_call.id,
                                .content = result_content,
                                .is_error = tool_res.is_error,
                            } }) catch {};
                            continue;
                        };
                        if (gop.found_existing) {
                            self.allocator.free(key);
                        } else {
                            gop.value_ptr.* = .{ .content = result_content, .is_error = tool_res.is_error };
                        }
                    }

                    result_blocks.append(self.allocator, .{ .tool_result = .{
                        .tool_use_id = tool_call.id,
                        .content = result_content,
                        .is_error = tool_res.is_error,
                    } }) catch {};
                }

                if (cancelled or permission_denied) break;

                // Extend messages for next API round
                const prev = current_request.messages;
                const extended = self.allocator.alloc(api.messages.Message, prev.len + 2) catch break;
                @memcpy(extended[0..prev.len], prev);
                extended[prev.len] = .{ .role = .assistant, .content = assistant_blocks.items };
                extended[prev.len + 1] = .{ .role = .user, .content = result_blocks.items };

                // Compact older tool_result blocks to prevent unbounded growth.
                // Keep last 3 rounds (6 messages) at full size.
                // Older results keep both the beginning and the end so paths and the
                // actual trailing compiler/runtime errors remain visible to the model.
                if (extended.len > 8) {
                    const keep_full_from = if (extended.len > 6) extended.len - 6 else 0;
                    for (extended[0..keep_full_from]) |*msg| {
                        if (msg.role != .user) continue;
                        const blocks = @constCast(msg.content);
                        for (blocks) |*block| {
                            switch (block.*) {
                                .tool_result => |tr| {
                                    if (std.mem.startsWith(u8, tr.content, "[TOOL FINDINGS CAPSULE]")) {
                                        continue;
                                    }
                                    if (tr.content.len > 2400) {
                                        const head_len = @min(tr.content.len, 1200);
                                        const tail_len = @min(tr.content.len - head_len, 800);
                                        const omitted = tr.content.len - head_len - tail_len;
                                        const summary = std.fmt.allocPrint(
                                            self.allocator,
                                            "{s}\n\n[older raw tool_result compacted: {d} chars omitted; exact raw output is in daemon tool_calls]\n\n{s}",
                                            .{
                                                tr.content[0..head_len],
                                                omitted,
                                                tr.content[tr.content.len - tail_len ..],
                                            },
                                        ) catch continue;
                                        block.* = .{ .tool_result = .{
                                            .tool_use_id = tr.tool_use_id,
                                            .content = summary,
                                            .is_error = tr.is_error,
                                        } };
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
                current_request.messages = self.compactOlderToolRoundsForLiveRequest(extended);
                current_request.tools = self.selectNextRoundToolDefinitions(chat_req, api_response.tool_use, is_subagent);
                if (current_request.tools) |defs| {
                    owned_tool_defs.append(self.allocator, defs) catch {};
                }
                // Keep persona/system flavor available for local providers.
                // Small OpenAI-compatible models drift hard after tool
                // results if the follow-up answer round has no system
                // prompt, so keep the recency-anchored effective prompt.
                // Anthropic already follows the conversation voice well and
                // benefits more from lean tool-work rounds.
                // Exception: codex (OpenAI Responses API) requires `instructions` on every
                // request — dropping it returns 400 "Instructions are required".
                if (std.mem.eql(u8, active_provider.getName(), "anthropic")) {
                    current_request.system = null;
                } else if (std.mem.eql(u8, active_provider.getName(), "codex")) {
                    current_request.system = effective_system;
                } else {
                    current_request.system = effective_system;
                }
                // Keep streaming enabled so tool use progress is visible to the user.
                // current_request.stream stays as-is (true if emitter present).
            }
        }

        if (permission_denied) {
            final_stop_reason = "permission_denied";
            const denied_tool = denied_tool_buf[0..denied_tool_len];
            if (denied_tool.len > 0) {
                text_parts.appendSlice(self.allocator, "[Tool permission denied: ") catch {};
                text_parts.appendSlice(self.allocator, denied_tool) catch {};
                text_parts.appendSlice(self.allocator, ". Task stopped before running the tool.]") catch {};
            } else {
                text_parts.appendSlice(self.allocator, "[Tool permission denied. Task stopped before running the tool.]") catch {};
            }
        }

        if (cancelled) {
            final_stop_reason = "cancelled";
            // Append cancellation note so the stored message is self-documenting
            const stopped_note: []const u8 = if (stopped_by_dispatcher) blk: {
                if (stop_reason_len > 0) {
                    break :blk std.fmt.allocPrint(
                        self.allocator,
                        "[Subagent stopped by dispatcher: {s}]",
                        .{stop_reason_buf[0..stop_reason_len]},
                    ) catch "[Subagent stopped by dispatcher]";
                }
                break :blk "[Subagent stopped by dispatcher]";
            } else "[Response stopped by user]";
            const stopped_note_in_run: []const u8 = if (stopped_by_dispatcher)
                "[Subagent stopped by dispatcher during tool execution]"
            else
                "[Response stopped by user during tool execution]";
            if (text_parts.items.len > 0) {
                text_parts.appendSlice(self.allocator, "\n\n") catch {};
                text_parts.appendSlice(self.allocator, stopped_note) catch {};
            } else if (tool_log.items.len > 0) {
                text_parts.appendSlice(self.allocator, stopped_note_in_run) catch {};
            }
        }

        // If we exhausted tool rounds without a final text response, make one more
        // API call with tools disabled to force a text summary of everything so far.
        // Route through `active_provider` — `self.provider` is always the
        // default (Anthropic), so calling it with a bare Ollama model name
        // like `qwen3:30b` returns 404 and the whole chat dies with no
        // response. `final_req.model` already holds the bare name from the
        // earlier resolve, so `active_provider` is the right target.
        if (!cancelled and !permission_denied and text_parts.items.len == 0 and tool_log.items.len > 0) {
            std.log.info(
                "Tool loop exhausted without text — forcing final summary call via {s}",
                .{active_provider.getName()},
            );
            var final_req = current_request;
            final_req.tools = null; // No tools → model must respond with text
            final_req.system = effective_system; // Reapply persona/system prompt for the final user-facing response.
            if (active_provider.createMessage(&final_req)) |final_resp| {
                if (final_resp.arena) |a| {
                    response_arenas.append(self.allocator, a) catch {};
                }
                total_input_tokens += final_resp.usage.input_tokens;
                total_output_tokens += final_resp.usage.output_tokens;
                total_cache_read += final_resp.usage.cache_read_tokens;
                total_cache_creation += final_resp.usage.cache_creation_tokens;
                if (final_resp.text_content.len > 0) {
                    text_parts.appendSlice(self.allocator, final_resp.text_content) catch {};
                }
                final_stop_reason = final_resp.stop_reason;
            } else |_| {}
        }

        // Use accumulated text from all rounds — take ownership so defer doesn't free it
        const final_text = if (text_parts.items.len > 0)
            (text_parts.toOwnedSlice(self.allocator) catch text_parts.items)
        else
            @as([]const u8, "");

        // Build stored message: tool log (if any) + final text.
        // This ensures the model can see its own tool calls in conversation history.
        const stored_text = if (tool_log.items.len > 0) blk: {
            var stored: std.ArrayList(u8) = .empty;
            stored.appendSlice(self.allocator, "<tool_calls>") catch {};
            stored.appendSlice(self.allocator, tool_log.items) catch {};
            stored.appendSlice(self.allocator, "\n</tool_calls>\n\n") catch {};
            stored.appendSlice(self.allocator, final_text) catch {};
            break :blk stored.toOwnedSlice(self.allocator) catch final_text;
        } else final_text;

        // Store assistant response in DB
        const assistant_msg_id: ?i64 = self.message_store.addAssistantMessage(
            &sess.id,
            stored_text,
            model,
            null,
            null,
            @as(?i64, @intCast(total_input_tokens)),
            @as(?i64, @intCast(total_output_tokens)),
        ) catch |err| blk: {
            std.log.warn("Failed to save assistant message: {}", .{err});
            break :blk null;
        };

        // POST-RESPONSE HOOKS
        self.postResponseHooks(&sess.id, chat_req.message, final_text, user_msg_id, assistant_msg_id);

        // Dupe model string before freeing session info (model may alias sess.model)
        const result_model = self.allocator.dupe(u8, model) catch "unknown";
        self.session_store.freeSessionInfo(&sess);

        // Serialize spawned subagent IDs as a comma-joined string for the response payload.
        const spawned_jobs_str: ?[]const u8 = if (spawned_subagent_ids.items.len > 0) blk: {
            const total_len = spawned_subagent_ids.items.len * 37; // 36 + comma
            var out: std.ArrayList(u8) = .empty;
            out.ensureTotalCapacity(self.allocator, total_len) catch break :blk null;
            for (spawned_subagent_ids.items, 0..) |id, i| {
                if (i > 0) out.append(self.allocator, ',') catch {};
                out.appendSlice(self.allocator, &id) catch {};
            }
            break :blk out.toOwnedSlice(self.allocator) catch null;
        } else null;

        return .{ .chat = .{
            .text = final_text,
            .model = result_model,
            .stop_reason = final_stop_reason,
            .input_tokens = total_input_tokens,
            .context_tokens = context_tokens,
            .output_tokens = total_output_tokens,
            .cache_read_tokens = total_cache_read,
            .cache_creation_tokens = total_cache_creation,
            .spawned_jobs = spawned_jobs_str,
        } };
    }

    /// Handle plan tool calls. Reads/writes the session's active_plan column.
    /// The plan is a JSON blob with goal + steps that persists across turns
    /// and survives compaction via prompt injection.
    fn handlePlanTool(self: *Engine, input: std.json.Value, session_id: *const [36]u8, caller_is_subagent: bool) tools.ToolResult {
        if (input != .object) return .{
            .content = "plan tool requires an object input with 'operation' field",
            .is_error = true,
        };

        const op = if (input.object.get("operation")) |v| (if (v == .string) v.string else null) else null;
        if (op == null) return .{
            .content = "plan tool requires 'operation' field (create, update, view, clear)",
            .is_error = true,
        };

        // Subagents can only view and update the plan — not create or clear it.
        // The dispatcher owns plan lifecycle; subagents just report progress.
        if (caller_is_subagent) {
            if (!std.mem.eql(u8, op.?, "update") and !std.mem.eql(u8, op.?, "view")) {
                return .{
                    .content = "Subagents can only use plan 'view' and 'update'. " ++
                        "The dispatcher manages plan creation and clearing.",
                    .is_error = true,
                };
            }
        }

        if (std.mem.eql(u8, op.?, "view")) {
            const plan = self.session_store.getPlan(session_id) catch |err| {
                const msg = std.fmt.allocPrint(self.allocator, "Failed to read plan: {s}", .{@errorName(err)}) catch return .{
                    .content = "Failed to read plan",
                    .is_error = true,
                };
                return .{ .content = msg, .is_error = true };
            };
            return .{ .content = plan orelse "No active plan." };
        }

        if (std.mem.eql(u8, op.?, "clear")) {
            self.session_store.setPlan(session_id, null) catch |err| {
                const msg = std.fmt.allocPrint(self.allocator, "Failed to clear plan: {s}", .{@errorName(err)}) catch return .{
                    .content = "Failed to clear plan",
                    .is_error = true,
                };
                return .{ .content = msg, .is_error = true };
            };
            std.log.info("Plan: cleared for session", .{});
            return .{ .content = "Plan cleared." };
        }

        if (std.mem.eql(u8, op.?, "create")) {
            // Build plan JSON from goal + steps
            const goal = if (input.object.get("goal")) |v| (if (v == .string) v.string else null) else null;
            if (goal == null) return .{
                .content = "plan 'create' requires a 'goal' field",
                .is_error = true,
            };

            // Serialize the full plan input as the stored plan
            const plan_json = std.json.Stringify.valueAlloc(self.allocator, input, .{}) catch return .{
                .content = "Failed to serialize plan",
                .is_error = true,
            };
            defer self.allocator.free(plan_json);

            self.session_store.setPlan(session_id, plan_json) catch |err| {
                const msg = std.fmt.allocPrint(self.allocator, "Failed to save plan: {s}", .{@errorName(err)}) catch return .{
                    .content = "Failed to save plan",
                    .is_error = true,
                };
                return .{ .content = msg, .is_error = true };
            };

            std.log.info("Plan: created for session ({d} chars)", .{plan_json.len});
            const result = std.fmt.allocPrint(
                self.allocator,
                "Plan created. Goal: {s}\n\nPlan is now active and will persist across turns.",
                .{goal.?},
            ) catch return .{ .content = "Plan created." };
            return .{ .content = result };
        }

        if (std.mem.eql(u8, op.?, "update")) {
            // Load existing plan, apply step updates
            const existing = self.session_store.getPlan(session_id) catch null;
            if (existing == null) return .{
                .content = "No active plan to update. Use 'create' first.",
                .is_error = true,
            };
            defer self.allocator.free(existing.?);

            // Parse existing plan
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, existing.?, .{}) catch return .{
                .content = "Failed to parse existing plan. Consider re-creating it.",
                .is_error = true,
            };
            defer parsed.deinit();
            const plan_allocator = parsed.arena.allocator();
            var plan_obj = parsed.value;

            if (plan_obj != .object) return .{
                .content = "Existing plan is corrupt. Use 'create' to make a new one.",
                .is_error = true,
            };

            // Update goal if provided
            if (input.object.get("goal")) |new_goal| {
                if (new_goal == .string) {
                    _ = plan_obj.object.fetchPut(plan_allocator, "goal", new_goal) catch {};
                }
            }

            // Merge step updates: match by id, update status/description
            if (input.object.get("steps")) |new_steps_val| {
                if (new_steps_val == .array) {
                    const existing_steps_val = plan_obj.object.get("steps");
                    if (existing_steps_val != null and existing_steps_val.? == .array) {
                        var existing_steps = existing_steps_val.?.array;
                        for (new_steps_val.array.items) |new_step| {
                            if (new_step != .object) continue;
                            const new_id = if (new_step.object.get("id")) |id_val| switch (id_val) {
                                .integer => |i| i,
                                .number_string, .string => null,
                                else => null,
                            } else null;

                            if (new_id) |nid| {
                                // Find and update existing step
                                var found = false;
                                for (existing_steps.items) |*es| {
                                    if (es.* != .object) continue;
                                    const es_id = if (es.*.object.get("id")) |id_val| switch (id_val) {
                                        .integer => |i| i,
                                        else => null,
                                    } else null;
                                    if (es_id != null and es_id.? == nid) {
                                        // Update fields
                                        if (new_step.object.get("status")) |s| {
                                            _ = es.*.object.fetchPut(plan_allocator, "status", s) catch {};
                                        }
                                        if (new_step.object.get("description")) |d| {
                                            _ = es.*.object.fetchPut(plan_allocator, "description", d) catch {};
                                        }
                                        // notes: subagents attach findings, discoveries,
                                        // warnings here so the next subagent inherits context.
                                        if (new_step.object.get("notes")) |n| {
                                            _ = es.*.object.fetchPut(plan_allocator, "notes", n) catch {};
                                        }
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    // New step — append
                                    existing_steps.append(new_step) catch {};
                                }
                            }
                        }
                        // ArrayList is stored by value in std.json.Value. If
                        // append reallocated it, persist the updated slice and
                        // capacity back into the plan object before stringify.
                        plan_obj.object.getPtr("steps").?.array = existing_steps;
                    } else {
                        // No existing steps — set them
                        _ = plan_obj.object.fetchPut(plan_allocator, "steps", new_steps_val) catch {};
                    }
                }
            }

            // Serialize and save
            const updated_json = std.json.Stringify.valueAlloc(self.allocator, plan_obj, .{}) catch return .{
                .content = "Failed to serialize updated plan",
                .is_error = true,
            };

            self.session_store.setPlan(session_id, updated_json) catch |err| {
                const msg = std.fmt.allocPrint(self.allocator, "Failed to save updated plan: {s}", .{@errorName(err)}) catch return .{
                    .content = "Failed to save updated plan",
                    .is_error = true,
                };
                return .{ .content = msg, .is_error = true };
            };

            std.log.info("Plan: updated for session ({d} chars)", .{updated_json.len});
            return .{ .content = updated_json };
        }

        const msg = std.fmt.allocPrint(
            self.allocator,
            "Unknown plan operation: '{s}'. Use create, update, view, or clear.",
            .{op.?},
        ) catch return .{ .content = "Unknown plan operation", .is_error = true };
        return .{ .content = msg, .is_error = true };
    }

    fn handleVisionRead(self: *Engine, input: std.json.Value, session_id: *const [36]u8) tools.ToolResult {
        if (input != .object) return .{
            .content = "vision_read requires an object input with a 'path' field",
            .is_error = true,
        };

        const raw_path = if (input.object.get("path")) |v| (if (v == .string) v.string else null) else null;
        if (raw_path == null or std.mem.trim(u8, raw_path.?, " \t\r\n").len == 0) return .{
            .content = "vision_read requires a non-empty 'path' string",
            .is_error = true,
        };

        const vp = self.vision_pipeline orelse return .{
            .content = "vision_read is unavailable because no vision pipeline is configured",
            .is_error = true,
        };

        const path = self.resolveVisionImagePath(raw_path.?, session_id[0..]) catch |err| {
            const msg = std.fmt.allocPrint(self.allocator, "Failed to resolve image path: {s}", .{@errorName(err)}) catch
                "Failed to resolve image path";
            return .{ .content = msg, .is_error = true };
        };
        defer self.allocator.free(path);

        const mime = if (input.object.get("mime")) |v|
            (if (v == .string and v.string.len > 0) v.string else inferImageMime(path))
        else
            inferImageMime(path);
        const name = if (input.object.get("name")) |v|
            (if (v == .string and v.string.len > 0) v.string else std.fs.path.basename(path))
        else
            std.fs.path.basename(path);

        const result = vp.describePath(session_id[0..], name, mime, path) catch |err| {
            const msg = std.fmt.allocPrint(self.allocator, "vision_read failed: {s}", .{@errorName(err)}) catch
                "vision_read failed";
            return .{ .content = msg, .is_error = true };
        };
        defer self.allocator.free(result.description);
        defer self.allocator.free(result.model_used);

        const content = std.fmt.allocPrint(
            self.allocator,
            "VISION READ\nPath: {s}\nName: {s}\nMIME: {s}\nModel: {s}\nCache: {s}\n\n{s}",
            .{
                path,
                name,
                mime,
                if (result.model_used.len > 0) result.model_used else "(none)",
                if (result.from_cache) "hit" else "miss",
                result.description,
            },
        ) catch "vision_read completed, but failed to format the result";
        return .{ .content = content, .is_error = false };
    }

    fn resolveVisionImagePath(self: *Engine, raw_path: []const u8, session_id: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
        if (std.fs.path.isAbsolute(trimmed)) {
            return try self.allocator.dupe(u8, trimmed);
        }
        if (trimmed.len > 0 and trimmed[0] == '~') {
            const home = common.config.getEnvVar("HOME") orelse return error.HomeNotSet;
            return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, trimmed[1..] });
        }

        if (self.session_store.getWorkingDirectory(session_id) catch null) |workdir| {
            defer self.allocator.free(workdir);
            if (std.fs.path.isAbsolute(workdir)) {
                return try std.fs.path.join(self.allocator, &.{ workdir, trimmed });
            }
        }

        const root = try common.config.getProjectRoot(self.allocator);
        defer self.allocator.free(root);
        return try std.fs.path.join(self.allocator, &.{ root, trimmed });
    }

    fn inferImageMime(path: []const u8) []const u8 {
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
        if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
        if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
        if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
        return "image/png";
    }

    /// Compute sha256 hex cache key for an explore subagent call.
    /// Returns null if target_files is empty (caching that would over-match across
    /// unrelated codebases). Caller owns the returned bytes.
    fn computeExploreCacheKey(
        self: *Engine,
        task: []const u8,
        target_files: ?std.json.Array,
    ) ?[]u8 {
        const arr = target_files orelse return null;
        if (arr.items.len == 0) return null;

        // Collect & sort paths for stable key ordering.
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.allocator);
        for (arr.items) |item| {
            if (item == .string and item.string.len > 0) {
                paths.append(self.allocator, item.string) catch return null;
            }
        }
        if (paths.items.len == 0) return null;
        std.mem.sort([]const u8, paths.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(task);
        hasher.update("\x00");

        for (paths.items) |p| {
            hasher.update(p);
            hasher.update("\x00");

            // Hash file content (bounded). Use "MISSING" marker if unreadable.
            const content = readFileForHash(self.allocator, p) catch null;
            if (content) |c| {
                defer self.allocator.free(c);
                var file_hasher = std.crypto.hash.sha2.Sha256.init(.{});
                file_hasher.update(c);
                var file_digest: [32]u8 = undefined;
                file_hasher.final(&file_digest);
                hasher.update(&file_digest);
            } else {
                hasher.update("MISSING");
            }
            hasher.update("\x00");
        }

        var digest: [32]u8 = undefined;
        hasher.final(&digest);

        const hex = self.allocator.alloc(u8, 64) catch return null;
        const hex_chars = "0123456789abcdef";
        for (digest, 0..) |b, i| {
            hex[i * 2] = hex_chars[b >> 4];
            hex[i * 2 + 1] = hex_chars[b & 0x0F];
        }
        return hex;
    }

    /// Look up a cached explore result by key. Caller owns returned bytes.
    fn exploreCacheGet(self: *Engine, cache_key: []const u8) ?[]u8 {
        var stmt = self.session_store.conn.prepare(
            "SELECT result_json FROM explore_cache WHERE cache_key = ?",
        ) catch return null;
        defer stmt.deinit();
        stmt.bindText(1, cache_key) catch return null;
        const has = stmt.step() catch return null;
        if (!has) return null;
        const raw = stmt.columnText(0) orelse return null;
        const dup = self.allocator.dupe(u8, raw) catch return null;

        // Bump hits/last_hit_at (best effort).
        var upd = self.session_store.conn.prepare(
            "UPDATE explore_cache SET hits = hits + 1, last_hit_at = ? WHERE cache_key = ?",
        ) catch return dup;
        defer upd.deinit();
        upd.bindInt64(1, common.sync.timestamp()) catch return dup;
        upd.bindText(2, cache_key) catch return dup;
        _ = upd.step() catch return dup;
        return dup;
    }

    /// Write a successful explore result to the cache.
    pub fn exploreCachePut(
        self: *Engine,
        cache_key: []const u8,
        task: []const u8,
        target_files_json: []const u8,
        result_json: []const u8,
    ) void {
        var stmt = self.session_store.conn.prepare(
            \\INSERT OR REPLACE INTO explore_cache
            \\(cache_key, task, target_files, result_json, created_at, last_hit_at, hits)
            \\VALUES (?, ?, ?, ?, ?, ?, 0)
        ) catch return;
        defer stmt.deinit();
        const now = common.sync.timestamp();
        stmt.bindText(1, cache_key) catch return;
        stmt.bindText(2, task) catch return;
        stmt.bindText(3, target_files_json) catch return;
        stmt.bindText(4, result_json) catch return;
        stmt.bindInt64(5, now) catch return;
        stmt.bindInt64(6, now) catch return;
        _ = stmt.step() catch return;
    }

    /// Parse a job_id string from a tool input object. Returns the [36]u8 array
    /// or null with an error message in `err_out` (which is a static string).
    fn parseJobIdInput(input: std.json.Value, err_out: *[]const u8) ?[36]u8 {
        if (input != .object) {
            err_out.* = "input must be an object with a job_id field";
            return null;
        }
        const jid_val = input.object.get("job_id") orelse {
            err_out.* = "missing required 'job_id' field";
            return null;
        };
        if (jid_val != .string or jid_val.string.len != 36) {
            err_out.* = "'job_id' must be a 36-character UUID string";
            return null;
        }
        var jid: [36]u8 = undefined;
        @memcpy(&jid, jid_val.string[0..36]);
        return jid;
    }

    /// Handle a subagent_inspect tool call. Read-only view of subagent state.
    fn handleSubagentInspect(
        self: *Engine,
        input: std.json.Value,
        parent_session_id: *const [36]u8,
    ) tools.ToolResult {
        const wp = self.worker_pool orelse return .{
            .content = "subagent_inspect unavailable: no worker pool configured",
            .is_error = true,
        };

        var err: []const u8 = "";
        const job_id = parseJobIdInput(input, &err) orelse return .{
            .content = std.fmt.allocPrint(self.allocator, "subagent_inspect: {s}", .{err}) catch err,
            .is_error = true,
        };

        const rec = wp.getSubagent(&job_id) orelse return .{
            .content = "subagent_inspect: no subagent with that job_id (it may have been evicted from the registry).",
            .is_error = true,
        };

        // Scope check: only allow inspecting subagents spawned in this session.
        if (!std.mem.eql(u8, &rec.parent_session_id, parent_session_id)) {
            return .{
                .content = "subagent_inspect: that job_id belongs to a different session. You can only inspect subagents you spawned.",
                .is_error = true,
            };
        }

        const depth: []const u8 = blk: {
            if (input.object.get("depth")) |d| {
                if (d == .string) break :blk d.string;
            }
            break :blk "summary";
        };

        if (std.mem.eql(u8, depth, "summary")) {
            const txt = wp.formatSubagentSummary(self.allocator, &job_id) orelse return .{
                .content = "subagent_inspect: failed to format summary",
                .is_error = true,
            };
            return .{ .content = txt };
        }

        if (std.mem.eql(u8, depth, "full")) {
            // If a final result is stored, return that. Otherwise return current
            // status + tool count + brief.
            if (wp.getBackgroundResult(&job_id)) |res| {
                const status_str = switch (res.status) {
                    .completed => "completed",
                    .failed => "failed",
                    .cancelled => "cancelled",
                };
                const body = res.text orelse "(no output)";
                const max_body: usize = 4096;
                const body_trimmed = if (body.len > max_body) body[0..max_body] else body;
                const truncation_note: []const u8 = if (body.len > max_body) "\n…[truncated]" else "";
                const out = std.fmt.allocPrint(
                    self.allocator,
                    "Subagent {s} {s} (mode={s}). Final result:\n\n{s}{s}",
                    .{ job_id[0..8], status_str, if (rec.is_explore) "explore" else "execute", body_trimmed, truncation_note },
                ) catch "Subagent inspect (full): allocation failed.";
                return .{ .content = out };
            }
            // Still running — surface current state.
            const events = wp.getToolEvents(&job_id, 0) catch return .{
                .content = "subagent_inspect: failed to copy tool events",
                .is_error = true,
            };
            defer events.deinit();
            const summary = wp.formatSubagentSummary(self.allocator, &job_id) orelse "(no summary)";
            defer if (!std.mem.eql(u8, summary, "(no summary)")) self.allocator.free(summary);
            const out = std.fmt.allocPrint(
                self.allocator,
                "Subagent {s} not yet complete. {d} tool events recorded so far.\n\n{s}",
                .{ job_id[0..8], events.events.len, summary },
            ) catch "Subagent inspect (full): allocation failed.";
            return .{ .content = out };
        }

        if (std.mem.eql(u8, depth, "tools")) {
            const events = wp.getToolEvents(&job_id, 0) catch return .{
                .content = "subagent_inspect: failed to copy tool events",
                .is_error = true,
            };
            defer events.deinit();
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            const w = common.list_writer.init(&buf, self.allocator);
            w.print("Subagent {s} tool history ({d} events):\n", .{ job_id[0..8], events.events.len }) catch {};
            const max_events: usize = 64;
            const max_content_per_event: usize = 400;
            for (events.events, 0..) |maybe_ev, i| {
                if (i >= max_events) {
                    w.writeAll("…[older events truncated]\n") catch {};
                    break;
                }
                const ev = maybe_ev orelse continue;
                const kind: []const u8 = switch (ev.event_type) {
                    .tool_use => "→ tool_use",
                    .tool_result => "← tool_result",
                    .model_wait => "… model_wait",
                    .model_text => "note model_text",
                    .control => "* control",
                };
                const err_tag: []const u8 = if (ev.is_error) " [error]" else "";
                const content = if (ev.content.len > max_content_per_event)
                    ev.content[0..max_content_per_event]
                else
                    ev.content;
                w.print("{s} {s}{s}: {s}\n", .{ kind, ev.tool_name, err_tag, content }) catch {};
            }
            const owned = self.allocator.dupe(u8, buf.items) catch return .{
                .content = "subagent_inspect (tools): allocation failed",
                .is_error = true,
            };
            return .{ .content = owned };
        }

        return .{
            .content = "subagent_inspect: 'depth' must be one of: summary, full, tools.",
            .is_error = true,
        };
    }

    /// Handle a subagent_stop tool call. Cooperative — flips a flag the engine's
    /// round loop polls between rounds. The subagent emits accumulated state.
    fn handleSubagentStop(
        self: *Engine,
        input: std.json.Value,
        parent_session_id: *const [36]u8,
    ) tools.ToolResult {
        const wp = self.worker_pool orelse return .{
            .content = "subagent_stop unavailable: no worker pool configured",
            .is_error = true,
        };

        var err: []const u8 = "";
        const job_id = parseJobIdInput(input, &err) orelse return .{
            .content = std.fmt.allocPrint(self.allocator, "subagent_stop: {s}", .{err}) catch err,
            .is_error = true,
        };

        const rec = wp.getSubagent(&job_id) orelse return .{
            .content = "subagent_stop: no subagent with that job_id",
            .is_error = true,
        };
        if (!std.mem.eql(u8, &rec.parent_session_id, parent_session_id)) {
            return .{
                .content = "subagent_stop: that job_id belongs to a different session",
                .is_error = true,
            };
        }
        if (rec.status == .completed or rec.status == .failed or rec.status == .stopped) {
            return .{
                .content = "subagent_stop: subagent has already finished. Use subagent_inspect(depth='full') to see its result.",
            };
        }

        const reason: []const u8 = blk: {
            if (input.object.get("reason")) |r| {
                if (r == .string and r.string.len > 0) break :blk r.string;
            }
            break :blk "(no reason provided)";
        };

        if (!wp.requestSubagentStop(&job_id, reason)) {
            return .{
                .content = "subagent_stop: registry no longer tracks this job",
                .is_error = true,
            };
        }

        const out = std.fmt.allocPrint(
            self.allocator,
            "OK. Stop requested for subagent {s}; it will halt at its next round boundary. Reason recorded: {s}. " ++
                "This call SUCCEEDED — do NOT call subagent_stop again for this job_id. " ++
                "Do NOT poll. End your turn or proceed to the next user request. " ++
                "If you want the final state once it halts, call subagent_inspect once with depth='full' (not subagent_stop).",
            .{ job_id[0..8], reason },
        ) catch "OK. Stop queued. Do not call subagent_stop again for this job.";
        return .{ .content = out };
    }

    /// Handle a subagent_redirect tool call. Queues a new instruction the
    /// subagent's chat loop consumes at the next round boundary.
    fn handleSubagentRedirect(
        self: *Engine,
        input: std.json.Value,
        parent_session_id: *const [36]u8,
    ) tools.ToolResult {
        const wp = self.worker_pool orelse return .{
            .content = "subagent_redirect unavailable: no worker pool configured",
            .is_error = true,
        };

        var err: []const u8 = "";
        const job_id = parseJobIdInput(input, &err) orelse return .{
            .content = std.fmt.allocPrint(self.allocator, "subagent_redirect: {s}", .{err}) catch err,
            .is_error = true,
        };

        const rec = wp.getSubagent(&job_id) orelse return .{
            .content = "subagent_redirect: no subagent with that job_id",
            .is_error = true,
        };
        if (!std.mem.eql(u8, &rec.parent_session_id, parent_session_id)) {
            return .{
                .content = "subagent_redirect: that job_id belongs to a different session",
                .is_error = true,
            };
        }
        if (rec.status == .completed or rec.status == .failed or rec.status == .stopped) {
            return .{
                .content = "subagent_redirect: subagent has already finished. Spawn a new one with summon_subagent.",
            };
        }

        const new_instruction: []const u8 = blk: {
            if (input.object.get("new_instruction")) |v| {
                if (v == .string and v.string.len > 0) break :blk v.string;
            }
            return .{
                .content = "subagent_redirect: missing required 'new_instruction' (non-empty string).",
                .is_error = true,
            };
        };

        if (!wp.queueSubagentRedirect(&job_id, new_instruction)) {
            return .{
                .content = "subagent_redirect: registry no longer tracks this job",
                .is_error = true,
            };
        }

        const out = std.fmt.allocPrint(
            self.allocator,
            "OK. Redirect for subagent {s} is queued and will fire at its next round boundary. " ++
                "This call SUCCEEDED — do NOT call subagent_redirect again for this job_id. " ++
                "Do NOT poll. End your turn or proceed to the next user request. " ++
                "If you want to verify the redirect was consumed, call subagent_inspect once with depth='full' (not subagent_redirect).",
            .{job_id[0..8]},
        ) catch "OK. Redirect queued. Do not call subagent_redirect again for this job.";
        return .{ .content = out };
    }

    /// Handle a summon_subagent tool call by enqueueing a BackgroundChatJob.
    /// The subagent inherits the parent's session so it sees the same persona/history,
    /// and inherits the parent's model string (including any `provider:` prefix) so
    /// cross-provider swaps stay sticky — if the user picked `ollama:qwen3:30b` in
    /// the web UI or Discord, subagents it spawns run on qwen3 too instead of
    /// silently falling back to Claude. The parent LLM can still override via an
    /// explicit `model` field in the tool call input.
    fn handleSummonSubagent(
        self: *Engine,
        input: std.json.Value,
        parent_session_id: *const [36]u8,
        spawned_ids: *std.ArrayList([36]u8),
        parent_model: []const u8,
        delegated_model_override: ?[]const u8,
        parent_allowed_tools: ?[]const u8,
        parent_plans_required: bool,
    ) tools.ToolResult {
        const wp = self.worker_pool orelse return .{
            .content = "summon_subagent unavailable: no worker pool configured",
            .is_error = true,
        };

        if (input != .object) return .{
            .content = "summon_subagent: input must be an object. See the tool schema for required fields.",
            .is_error = true,
        };

        // Mode: "execute" (default) or "explore"
        const mode_str: []const u8 = if (input.object.get("mode")) |m|
            (if (m == .string and m.string.len > 0) m.string else "execute")
        else
            "execute";
        const is_explore = std.mem.eql(u8, mode_str, "explore");
        if (!is_explore and !std.mem.eql(u8, mode_str, "execute")) return .{
            .content = "summon_subagent: 'mode' must be 'execute' or 'explore'.",
            .is_error = true,
        };

        // wait: true may block a foreground caller while the background worker
        // services the child. It is forcibly converted to async when this call
        // already runs on that worker; otherwise it would wait on its own queue.
        const wait_requested: bool = if (input.object.get("wait")) |w|
            (if (w == .bool) w.bool else false)
        else
            false;
        const wait_sync = wait_requested and wp.canSynchronouslyWaitForBackgroundJob();
        const wait_forced_async = wait_requested and !wait_sync;

        // chain: when true (explore only), the worker automatically runs a
        // dispatcher continuation turn once the subagent returns, feeding the
        // 3-layer brief back into the dispatcher. The continuation's reply
        // replaces the raw brief as the stored result — so the polling adapter
        // sees a model-generated summary / next-action message. Default true
        // for explore (makes the "fire and forget" UX work naturally), ignored
        // for execute (no brief to chain on) and when wait_sync is true (the
        // dispatcher already sees the brief in-turn and can chain itself).
        const chain_async: bool = if (input.object.get("chain")) |c|
            (if (c == .bool) c.bool else is_explore)
        else
            is_explore;
        const auto_chain_effective = is_explore and chain_async and !wait_sync;

        const task_val = input.object.get("task") orelse return .{
            .content = "summon_subagent: missing required 'task' field (one-sentence goal for execute, or question for explore).",
            .is_error = true,
        };
        if (task_val != .string or task_val.string.len == 0) return .{
            .content = "summon_subagent: 'task' must be a non-empty string.",
            .is_error = true,
        };

        // Execute mode requires target_files + acceptance. Explore mode does not.
        const acceptance_val: ?[]const u8 = if (is_explore) null else blk: {
            const a = input.object.get("acceptance") orelse return .{
                .content = "summon_subagent (execute): missing required 'acceptance' field. Specify a concrete, testable stop condition. (If you just want to investigate, use mode='explore' instead.)",
                .is_error = true,
            };
            if (a != .string or a.string.len == 0) return .{
                .content = "summon_subagent (execute): 'acceptance' must be a non-empty string.",
                .is_error = true,
            };
            break :blk a.string;
        };

        const target_files_val: ?std.json.Array = blk: {
            const tf = input.object.get("target_files") orelse {
                if (is_explore) break :blk null;
                return .{
                    .content = "summon_subagent (execute): missing required 'target_files' field. Do recon first and pass the file paths.",
                    .is_error = true,
                };
            };
            if (tf != .array) return .{
                .content = "summon_subagent: 'target_files' must be an array of strings.",
                .is_error = true,
            };
            break :blk tf.array;
        };

        // Optional fields
        const context_val: ?[]const u8 = if (input.object.get("context")) |v|
            (if (v == .string and v.string.len > 0) v.string else null)
        else
            null;
        const known_facts_val: ?std.json.Array = if (input.object.get("known_facts")) |v|
            (if (v == .array) v.array else null)
        else
            null;
        const constraints_val: ?std.json.Array = if (input.object.get("constraints")) |v|
            (if (v == .array) v.array else null)
        else
            null;
        const out_of_scope_val: ?std.json.Array = if (input.object.get("out_of_scope")) |v|
            (if (v == .array) v.array else null)
        else
            null;

        // Explicit override from the parent LLM's tool call args wins; otherwise
        // inherit the parent's active model so the subagent runs on whatever the
        // user selected. Without this, any subagent spawned during an Ollama turn
        // silently falls back to Claude.
        const explicit_model: ?[]const u8 = if (input.object.get("model")) |m|
            (if (m == .string and m.string.len > 0) m.string else null)
        else
            null;
        const model_val: ?[]const u8 = explicit_model orelse delegated_model_override orelse
            (if (parent_model.len > 0) parent_model else null);

        // Load the current plan so the subagent sees what step it's working on.
        const current_plan = self.session_store.getPlan(parent_session_id) catch null;

        // Render the brief as structured sections. A subagent inherits no
        // conversation context, so every useful fact must be spelled out here.
        const has_targets = if (target_files_val) |tf| tf.items.len > 0 else false;

        var brief_buf: std.ArrayList(u8) = .empty;
        defer brief_buf.deinit(self.allocator);
        const w = common.list_writer.init(&brief_buf, self.allocator);

        if (is_explore) {
            w.writeAll(
                \\[EXPLORE SUBAGENT — READ-ONLY RESEARCH MODE]
                \\
                \\You are a research agent. Your ONLY job is to investigate the question below
                \\and return a structured 3-layer brief. You have READ-ONLY tools: file_find, file_read,
                \\vision_read, visual_audit, playwright_mcp, bash (for grep/find/cat/ls/head/tail only —
                \\do NOT use destructive commands), and introspect. You do NOT have file_write, file_diff,
                \\or summon_subagent.
                \\
                \\
            ) catch {};

            if (prompt_mod.buildEnvironmentBlock(self.allocator)) |env_block| {
                defer self.allocator.free(env_block);
                w.print("--- Environment ---\n{s}\n", .{env_block}) catch {};
            } else |_| {}

            w.writeAll(
                \\
                \\HARD RULES:
                \\1. Your FIRST response MUST contain a tool_use block. No text-only replies.
                \\2. Do recon passes. If initial findings point you elsewhere, follow the lead.
                \\3. Your FINAL response MUST be a single JSON object, no prose wrapping, matching:
                \\
                \\   {
                \\     "layer1_map": [
                \\       {"path": "src/foo.zig", "purpose": "one-line summary"}
                \\     ],
                \\     "layer2_facts": [
                \\       {
                \\         "path": "src/foo.zig",
                \\         "purpose": "what this file does",
                \\         "exports": ["fn foo(...)", "pub const Bar"],
                \\         "structs": ["Bar { field: Type, ... }"],
                \\         "inbound_deps": ["who calls / imports this"],
                \\         "outbound_deps": ["what this depends on"],
                \\         "invariants": ["non-obvious rules / assumptions"],
                \\         "edit_points": ["line 42: the switch in handleX", "fn Y: add branch here"],
                \\         "confidence": "high|medium|low"
                \\       }
                \\     ],
                \\     "layer3_evidence": [
                \\       {"path": "src/foo.zig", "anchor": "fn foo", "excerpt": "small targeted block — signatures + short relevant code only, NO whole-file dumps"}
                \\     ]
                \\   }
                \\
                \\4. Layer 1 = tiny executive map. Layer 2 = the real payload. Layer 3 = small
                \\   targeted excerpts (signatures, short blocks, anchors) — NEVER whole files.
                \\5. NEVER write "Let me...", "I'll...", or any dispatcher ack. Just use tools,
                \\   then emit the JSON.
                \\6. If you can't find something, say so in invariants/confidence — do not
                \\   fabricate.
                \\7. When using introspect semantic_search, ALWAYS pass source_type='knowledge'
                \\   or 'summary'. The default retrieves recent conversation messages, which
                \\   include this dispatch and your own announcement — useless for code recon.
                \\
                \\
            ) catch {};

            if (current_plan) |p| {
                w.print("--- CURRENT PLAN (context) ---\n{s}\n--- END PLAN ---\n\n", .{p}) catch {};
            }

            w.print("--- QUESTION ---\n{s}\n\n", .{task_val.string}) catch {};

            if (context_val) |c| {
                w.print("--- CONTEXT (why the caller is asking) ---\n{s}\n\n", .{c}) catch {};
            }

            if (has_targets) {
                w.writeAll("--- HINT PATHS (caller's starting guesses; pivot if they're wrong) ---\n") catch {};
                for (target_files_val.?.items) |item| {
                    if (item == .string) {
                        w.print("- {s}\n", .{item.string}) catch {};
                    }
                }
                w.writeAll("\n") catch {};
            }

            w.writeAll("--- REMEMBER: final response is the JSON object, nothing else ---\n") catch {};
        } else {
            // EXECUTE MODE — worker that makes changes.
            w.writeAll(
                \\[SUBAGENT EXECUTION MODE — READ BEFORE RESPONDING]
                \\
                \\You are an autonomous file/code/shell worker. You are NOT the
                \\dispatcher. Ignore any chat-style patterns from prior conversation.
                \\
                \\
            ) catch {};

            if (prompt_mod.buildEnvironmentBlock(self.allocator)) |env_block| {
                defer self.allocator.free(env_block);
                w.print("--- Environment ---\n{s}\n", .{env_block}) catch {};
            } else |_| {}

            w.writeAll(
                \\
                \\HARD RULES:
                \\1. Your FIRST response MUST contain a tool_use block. No text-only replies.
                \\2. NEVER write "Let me...", "I'll...", "Dispatching...", "Firing off...",
                \\   "Working on it..." or any dispatcher ack. You are the worker.
                \\3. You do NOT have summon_subagent. Finish the task yourself.
                \\4. When complete, give a concise factual report (≤300 words). No
                \\   emojis, no greetings, no sign-offs.
                \\5. Call `plan` with operation "update" to mark your step "done" and
                \\   include a "notes" field with key findings/paths/gotchas so later
                \\   subagents inherit context.
                \\6. Treat target_files, known_facts, constraints, out_of_scope, and
                \\   acceptance as the source of truth for this job. Do NOT invent
                \\   missing context from chat history.
                \\7. If a tool fails, is blocked, or returns empty data, you have NO
                \\   result from that tool. Do not pretend it worked. Try another
                \\   path or report the blocker plainly.
                \\8. Default execution loop: read the relevant files first, make the
                \\   smallest change that satisfies the task, then verify against the
                \\   acceptance criteria before declaring completion.
                \\9. Do not ask the user questions unless you are truly blocked and
                \\   the brief/current files cannot answer them. Prefer inference from
                \\   the brief, plan, and repository over bouncing the task back.
                \\10. Resist scope creep. If you notice unrelated issues, mention them
                \\    in the final report but do not fix them unless required by the
                \\    task or acceptance criteria.
                \\11. When using introspect semantic_search, ALWAYS pass source_type='knowledge'
                \\    or 'summary'. The default retrieves recent conversation messages,
                \\    including this dispatch — useless for code work.
                \\
                \\TOOL PRIORITY:
                \\- Use the best tool for the immediate need, not the loudest one.
                \\- Find/read/inspect first: file_find, file_read, introspect, safe bash.
                \\- Mutate only after you've seen the real file contents.
                \\- Prefer the minimum number of tool calls needed to finish well.
                \\- When acceptance mentions build/test behavior, verify it with the
                \\  relevant tool or command instead of assuming the change works.
                \\
            ) catch {};

            if (has_targets) {
                w.writeAll(
                    \\RECON GUIDANCE:
                    \\target_files is populated — the dispatcher already did recon. Read the
                    \\listed files first, then act. Do NOT re-explore the tree unless the
                    \\listed files don't contain what you need.
                    \\
                    \\
                ) catch {};
            } else {
                w.writeAll(
                    \\RECON GUIDANCE:
                    \\target_files is empty — this is a discovery task. Use file_find, bash (grep, find),
                    \\introspect, and file_read to locate what you need before acting.
                    \\
                    \\
                ) catch {};
            }

            if (current_plan) |p| {
                w.print("--- CURRENT PLAN ---\n{s}\n--- END PLAN ---\n\n", .{p}) catch {};
            }

            w.print("--- TASK ---\n{s}\n\n", .{task_val.string}) catch {};

            if (context_val) |c| {
                w.print("--- CONTEXT (why this matters / user's words) ---\n{s}\n\n", .{c}) catch {};
            }

            if (has_targets) {
                w.writeAll("--- TARGET FILES ---\n") catch {};
                for (target_files_val.?.items) |item| {
                    if (item == .string) {
                        w.print("- {s}\n", .{item.string}) catch {};
                    }
                }
                w.writeAll("\n") catch {};
            }

            if (known_facts_val) |arr| {
                if (arr.items.len > 0) {
                    w.writeAll("--- KNOWN FACTS (do NOT re-derive these) ---\n") catch {};
                    for (arr.items) |item| {
                        if (item == .string) {
                            w.print("- {s}\n", .{item.string}) catch {};
                        }
                    }
                    w.writeAll("\n") catch {};
                }
            }

            if (constraints_val) |arr| {
                if (arr.items.len > 0) {
                    w.writeAll("--- CONSTRAINTS (must NOT do) ---\n") catch {};
                    for (arr.items) |item| {
                        if (item == .string) {
                            w.print("- {s}\n", .{item.string}) catch {};
                        }
                    }
                    w.writeAll("\n") catch {};
                }
            }

            if (out_of_scope_val) |arr| {
                if (arr.items.len > 0) {
                    w.writeAll("--- OUT OF SCOPE (resist scope creep) ---\n") catch {};
                    for (arr.items) |item| {
                        if (item == .string) {
                            w.print("- {s}\n", .{item.string}) catch {};
                        }
                    }
                    w.writeAll("\n") catch {};
                }
            }

            if (acceptance_val) |a| {
                w.print("--- ACCEPTANCE (you are done when) ---\n{s}\n", .{a}) catch {};
            }

            w.writeAll(
                \\
                \\--- FINAL REPORT FORMAT ---
                \\Return a terse factual summary covering:
                \\- what changed
                \\- which files/commands were involved
                \\- how you verified the acceptance criteria
                \\- any remaining risk or blocker
                \\
            ) catch {};
        }

        // Explore cache lookup: only applies when the caller passed target_files
        // (the key is derived from sorted paths + their content hashes, so an
        // empty list would over-match across unrelated codebases).
        var cache_key_opt: ?[]u8 = null;
        if (is_explore) {
            if (self.computeExploreCacheKey(task_val.string, target_files_val)) |ck| {
                if (self.exploreCacheGet(ck)) |cached_json| {
                    defer self.allocator.free(ck);
                    std.log.info("Explore cache HIT for key {s}", .{ck[0..@min(16, ck.len)]});
                    const msg = std.fmt.allocPrint(
                        self.allocator,
                        "EXPLORE CACHE HIT (no subagent spawned). Cached result below — use directly.\n\n{s}",
                        .{cached_json},
                    ) catch cached_json;
                    if (msg.ptr != cached_json.ptr) self.allocator.free(cached_json);
                    return .{ .content = msg, .is_error = false };
                }
                cache_key_opt = ck;
                std.log.info("Explore cache MISS for key {s}", .{ck[0..@min(16, ck.len)]});
            }
        }

        const wrapped_task = self.allocator.dupe(u8, brief_buf.items) catch {
            if (cache_key_opt) |ck| self.allocator.free(ck);
            return .{ .content = "summon_subagent: out of memory", .is_error = true };
        };

        const model_dup: ?[]const u8 = if (model_val) |m|
            (self.allocator.dupe(u8, m) catch null)
        else
            null;

        var job_id: [36]u8 = undefined;
        generateUUID(&job_id);

        // Explore subagents get a read-only toolset. Execute subagents inherit
        // whatever tools are enabled on the registry.
        const allowed_dup: ?[]const u8 = if (is_explore)
            (self.allocator.dupe(u8, "file_find,file_read,vision_read,visual_audit,playwright_mcp,bash,introspect,plan") catch null)
        else
            null;

        // When auto-chain is on, duplicate the parent dispatcher's tool set so
        // the continuation has the same capabilities (file_diff, summon_subagent
        // for a follow-up execute, etc.).
        const chain_allowed_dup: ?[]const u8 = if (auto_chain_effective)
            (if (parent_allowed_tools) |pat| (self.allocator.dupe(u8, pat) catch null) else null)
        else
            null;

        // Build compact target_files JSON once, for both pending-cache metadata
        // and eventual write-back (stored on the Engine's pending_explore_cache
        // map keyed by job_id).
        if (cache_key_opt) |ck| {
            var tf_buf: std.ArrayList(u8) = .empty;
            defer tf_buf.deinit(self.allocator);
            const tfw = common.list_writer.init(&tf_buf, self.allocator);
            tfw.writeAll("[") catch {};
            if (target_files_val) |arr| {
                for (arr.items, 0..) |item, i| {
                    if (i > 0) tfw.writeAll(",") catch {};
                    if (item == .string) {
                        tfw.writeByte('"') catch {};
                        for (item.string) |ch| {
                            switch (ch) {
                                '"' => tfw.writeAll("\\\"") catch {},
                                '\\' => tfw.writeAll("\\\\") catch {},
                                '\n' => tfw.writeAll("\\n") catch {},
                                '\r' => tfw.writeAll("\\r") catch {},
                                '\t' => tfw.writeAll("\\t") catch {},
                                else => if (ch < 0x20)
                                    tfw.print("\\u{x:0>4}", .{ch}) catch {}
                                else
                                    tfw.writeByte(ch) catch {},
                            }
                        }
                        tfw.writeByte('"') catch {};
                    } else {
                        tfw.writeAll("null") catch {};
                    }
                }
            }
            tfw.writeAll("]") catch {};
            const task_dup = self.allocator.dupe(u8, task_val.string) catch "";
            const tf_dup = self.allocator.dupe(u8, tf_buf.items) catch "[]";
            self.registerPendingExploreCache(&job_id, ck, task_dup, tf_dup);
        }

        wp.registerSubagent(&job_id, parent_session_id, is_explore, task_val.string);

        wp.enqueueBackgroundChat(.{
            .job_id = job_id,
            .message = wrapped_task,
            .session_id = parent_session_id.*,
            .model_override = model_dup,
            .callback_channel = null,
            .allowed_tools = allowed_dup,
            .is_subagent = true,
            .is_explore = is_explore,
            .plans_required = parent_plans_required,
            .auto_chain = auto_chain_effective,
            .chain_allowed_tools = chain_allowed_dup,
            .cancelled = std.atomic.Value(bool).init(false),
        });

        spawned_ids.append(self.allocator, job_id) catch {};

        std.log.info("Spawned subagent job {s} (wait_requested={}, wait_effective={})", .{ job_id, wait_requested, wait_sync });

        if (wait_sync) {
            // Block until the job completes, up to a generous ceiling. Explore
            // subagents typically finish in 30-120s; we allow 10 minutes for
            // deeper investigations.
            const max_wait_ms: u64 = 10 * 60 * 1000;
            const poll_interval_ms: u64 = 500;
            var waited_ms: u64 = 0;
            while (waited_ms < max_wait_ms) {
                if (wp.getBackgroundResult(&job_id)) |res| {
                    const body = res.text orelse "(empty result)";
                    const status_str = switch (res.status) {
                        .completed => "completed",
                        .failed => "failed",
                        .cancelled => "cancelled",
                    };
                    const is_err = res.status != .completed;
                    const msg = std.fmt.allocPrint(
                        self.allocator,
                        "Subagent {s} (mode={s}, job {s}).\n\n{s}",
                        .{ status_str, mode_str, job_id, body },
                    ) catch "Subagent completed.";
                    return .{ .content = msg, .is_error = is_err };
                }
                common.sync.sleepNanoseconds(poll_interval_ms * std.time.ns_per_ms);
                waited_ms += poll_interval_ms;
            }
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Subagent timeout after {d}s (mode={s}, job {s}). The job may still be running — check back with a follow-up or poll the job id.",
                .{ max_wait_ms / 1000, mode_str, job_id },
            ) catch "Subagent timeout.";
            return .{ .content = msg, .is_error = true };
        }

        const result_text = if (wait_forced_async)
            std.fmt.allocPrint(
                self.allocator,
                "Subagent dispatched (mode={s}, async). Job ID: {s}. wait=true was converted to async because this dispatcher is already running on the background worker; blocking here would deadlock its own queue. Continue without waiting. The user will receive the result automatically.",
                .{ mode_str, job_id },
            ) catch "Subagent dispatched asynchronously to avoid a worker self-deadlock."
        else
            std.fmt.allocPrint(
                self.allocator,
                "Subagent dispatched (mode={s}, async). Job ID: {s}. The user will receive the result automatically when it completes. (A foreground caller may pass wait=true for in-turn chaining.)",
                .{ mode_str, job_id },
            ) catch "Subagent dispatched.";

        return .{ .content = result_text, .is_error = false };
    }

    /// Post-response hooks. Run after every chat response.
    /// Cheap operations only — expensive ones (summarization, extraction)
    /// will be moved to background workers in Phase 11.
    fn postResponseHooks(
        self: *Engine,
        session_id: *const [36]u8,
        user_message: []const u8,
        assistant_response: []const u8,
        user_msg_id: ?i64,
        assistant_msg_id: ?i64,
    ) void {
        if (self.worker_pool) |wp| {
            // ASYNC PATH — enqueue work items, return immediately.
            // Worker threads process these in the background.

            // Hook 1: Rolling context update for attached project
            if (self.project_store.getSessionProject(session_id) catch null) |project_id| {
                wp.enqueueRollingUpdate(project_id, session_id.*, user_message, assistant_response);
            }

            // Hook 2: Session summarization check
            wp.enqueueMaybeSummarize(session_id.*);

            // Hook 3: Knowledge extraction from substantive exchanges
            if (user_message.len > 80 or assistant_response.len > 200) {
                wp.enqueueExtract(session_id.*, user_message, assistant_response);
            }

            // Hook 4: Embed both sides of the exchange for future semantic search.
            // Each embedding row is keyed by the messages.id rowid so the
            // UNIQUE(source_type, source_id) constraint doesn't collapse every
            // message into a single overwritten slot.
            if (user_msg_id) |uid| {
                if (user_message.len > 50) {
                    wp.enqueueEmbed("message", uid, user_message, null);
                }
            }
            if (assistant_msg_id) |aid| {
                if (assistant_response.len > 50) {
                    wp.enqueueEmbed("message", aid, assistant_response, null);
                }
            }
        } else {
            // SYNC FALLBACK — call workers directly (blocks the response).
            // Used when worker pool isn't available.

            if (self.project_store.getSessionProject(session_id) catch null) |project_id| {
                if (self.summarizer) |s| {
                    s.updateRollingContext(project_id, session_id, user_message, assistant_response) catch {};
                } else {
                    self.updateProjectRollingContext(project_id, user_message, assistant_response);
                }
            }

            self.maybeSummarizeSession(session_id);

            if (self.extractor) |e| {
                if (user_message.len > 80 or assistant_response.len > 200) {
                    _ = e.extractFromExchange(session_id, user_message, assistant_response) catch {};
                }
            }
        }

        // Hook 5: Auto-detect project attachment (future — semantic detection)
        // Hook 6: Context snapshot at checkpoints (future)
    }

    // ================================================================
    // BACKGROUND CHAT — enqueue to worker pool for async processing
    // ================================================================

    fn cloneRequestAttachments(
        self: *Engine,
        attachments_opt: ?[]const common.Request.Attachment,
    ) !?[]common.Request.Attachment {
        const attachments = attachments_opt orelse return null;
        if (attachments.len == 0) return null;

        const cloned = try self.allocator.alloc(common.Request.Attachment, attachments.len);
        errdefer self.allocator.free(cloned);
        for (attachments, 0..) |att, i| {
            cloned[i] = .{
                .path = try self.allocator.dupe(u8, att.path),
                .mime = try self.allocator.dupe(u8, att.mime),
                .name = try self.allocator.dupe(u8, att.name),
            };
        }
        return cloned;
    }

    fn freeRequestAttachments(self: *Engine, attachments_opt: ?[]common.Request.Attachment) void {
        const attachments = attachments_opt orelse return;
        for (attachments) |att| {
            self.allocator.free(att.path);
            self.allocator.free(att.mime);
            self.allocator.free(att.name);
        }
        self.allocator.free(attachments);
    }

    fn enqueueBackgroundChat(self: *Engine, req: common.Request.ChatRequest) Result {
        const wp = self.worker_pool orelse {
            return .{ .response = .{ .error_resp = .{
                .code = "NO_WORKER_POOL",
                .message = "Background chat requires worker pool",
            } } };
        };

        // Resolve session: explicit > active > create new
        const session_id = blk: {
            if (req.session_id) |sid| {
                if (sid.len == 36) {
                    var buf: [36]u8 = undefined;
                    @memcpy(&buf, sid[0..36]);
                    break :blk buf;
                }
            }
            if (self.session_store.getActiveSession()) |s| break :blk s.id;
            const new_sess = self.session_store.createSession(null) catch {
                return .{ .response = .{ .error_resp = .{
                    .code = "SESSION_ERROR",
                    .message = "Failed to create session for background job",
                } } };
            };
            break :blk new_sess.id;
        };

        var job_id: [36]u8 = undefined;
        generateUUID(&job_id);

        const attachments = self.cloneRequestAttachments(req.attachments) catch {
            return .{ .response = .{ .error_resp = .{
                .code = "OOM",
                .message = "Failed to allocate background attachments",
            } } };
        };
        const adapter_context = if (req.adapter_context) |ac|
            (self.allocator.dupe(u8, ac) catch null)
        else
            null;

        wp.enqueueBackgroundChat(.{
            .job_id = job_id,
            .message = self.allocator.dupe(u8, req.message) catch {
                self.freeRequestAttachments(attachments);
                if (adapter_context) |ac| self.allocator.free(ac);
                return .{ .response = .{ .error_resp = .{
                    .code = "OOM",
                    .message = "Failed to allocate background job",
                } } };
            },
            .session_id = session_id,
            .model_override = if (req.model_override) |mo|
                (self.allocator.dupe(u8, mo) catch null)
            else
                null,
            .callback_channel = if (req.callback_channel) |cc|
                (self.allocator.dupe(u8, cc) catch null)
            else
                null,
            .allowed_tools = if (req.allowed_tools) |at|
                (self.allocator.dupe(u8, at) catch null)
            else
                null,
            .attachments = attachments,
            .adapter_context = adapter_context,
            .is_subagent = req.is_subagent,
            .compact_tool_schemas = req.compact_tool_schemas,
            .plans_required = req.plans_required,
            .cancelled = std.atomic.Value(bool).init(false),
        });

        return .{ .response = .{ .background_queued = .{
            .job_id = job_id,
            .session_id = session_id,
        } } };
    }

    fn generateUUID(buf: *[36]u8) void {
        var random_bytes: [16]u8 = undefined;
        std.Io.random(common.config.runtimeIo(), &random_bytes);
        random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40;
        random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80;
        const hex = "0123456789abcdef";
        var i: usize = 0;
        var j: usize = 0;
        while (i < 16) : (i += 1) {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                buf[j] = '-';
                j += 1;
            }
            buf[j] = hex[random_bytes[i] >> 4];
            buf[j + 1] = hex[random_bytes[i] & 0x0f];
            j += 2;
        }
    }

    /// Run a fast "voice pass" that rewrites a subagent's terse, factual
    /// report in the parent session's persona voice for Discord delivery.
    /// Returns an allocated rewritten string, or null on failure (caller
    /// should fall back to the original terse text).
    ///
    /// Why: subagents are forced to be terse + tool-first to actually do
    /// work. That output reads like a database dump. The voice pass keeps
    /// every fact intact but transforms tone — like Vera personally
    /// reporting back instead of a CI bot.
    fn rewriteInPersonaVoice(
        self: *Engine,
        parent_session_id: []const u8,
        terse_text: []const u8,
    ) ?[]const u8 {
        if (terse_text.len == 0) return null;

        // Look up the parent session to read its persona name.
        var sess = self.session_store.getSession(parent_session_id) catch return null;
        defer self.session_store.freeSessionInfo(&sess);

        // Load the persona text. DEFAULT_PERSONA is comptime-embedded —
        // tracking ownership separately so we only free the loaded variant.
        const persona_owned: ?[]const u8 = if (sess.system_prompt) |name|
            prompt_mod.loadPersona(self.allocator, name)
        else
            null;
        defer if (persona_owned) |p| self.allocator.free(p);
        const persona_text = persona_owned orelse prompt_mod.DEFAULT_PERSONA;

        const voice_directive =
            "\n\n--- VOICE PASS DIRECTIVE ---\n" ++
            "A subagent just completed a task on the user's behalf and produced " ++
            "the factual report in the user message below. Your job: rewrite " ++
            "that report in YOUR voice as if you personally did the work and " ++
            "are telling the user about it in Discord.\n" ++
            "\n" ++
            "HARD RULES:\n" ++
            "1. PRESERVE every fact verbatim — numbers, paths, file names, IDs, " ++
            "counts, statuses. Do not drop, alter, or add facts.\n" ++
            "2. Speak in your natural personality. Casual, warm, brief. " ++
            "Up to 2 appropriate emojis if they fit, never forced.\n" ++
            "3. Do NOT add greetings, 'Here's the summary', 'I successfully...', " ++
            "'Let me know if you need...', or any meta narration about the report.\n" ++
            "4. Keep it under ~400 words. Lists are fine if the original had them.\n" ++
            "5. Never mention 'the subagent' or 'the agent' — speak as if you did " ++
            "the work yourself.\n" ++
            "\n" ++
            "Your ENTIRE response is what the user sees. Just the rewritten report.";

        const system_prompt = std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{ persona_text, voice_directive },
        ) catch return null;
        defer self.allocator.free(system_prompt);

        // Build a single user message with the terse report. No tools, no
        // streaming — this is a one-shot transformation.
        const content = [_]api.messages.ContentBlock{
            .{ .text = .{ .text = terse_text } },
        };
        const msgs = [_]api.messages.Message{
            .{ .role = .user, .content = &content },
        };

        const req = api.MessageRequest{
            .model = "claude-haiku-4-5-20251001",
            .max_tokens = 2048,
            .messages = &msgs,
            .system = system_prompt,
            .tools = null,
            .stream = false,
        };

        var resp = self.provider.createMessage(&req) catch |err| {
            std.log.warn("Voice pass failed ({s}); falling back to terse text", .{@errorName(err)});
            return null;
        };
        defer resp.deinit(self.allocator);

        if (resp.text_content.len == 0) {
            std.log.warn("Voice pass returned empty text; falling back", .{});
            return null;
        }

        const dup = self.allocator.dupe(u8, resp.text_content) catch return null;
        std.log.info(
            "Voice pass: terse={d} chars → polished={d} chars ({d} in / {d} out tokens)",
            .{ terse_text.len, dup.len, resp.usage.input_tokens, resp.usage.output_tokens },
        );
        return dup;
    }

    /// Callback for the background chat worker thread. Matches the function
    /// signature expected by WorkerPool.setBackgroundChatContext.
    pub fn backgroundChatCallback(
        ctx: *anyopaque,
        job_id: *const [36]u8,
        message: []const u8,
        session_id: ?[]const u8,
        model_override: ?[]const u8,
        allowed_tools: ?[]const u8,
        attachments: ?[]const common.Request.Attachment,
        adapter_context_override: ?[]const u8,
        is_subagent: bool,
        is_explore: bool,
        compact_tool_schemas: bool,
        plans_required: bool,
        confirm_ctx: ?*anyopaque,
        confirm_fn: ?*const fn (ctx: *anyopaque, tool_name: []const u8, tool_id: []const u8, input_preview: []const u8) bool,
    ) workers.BackgroundChatOutput {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        const confirmer: ?ToolConfirmCallback = if (confirm_ctx != null and confirm_fn != null)
            .{ .ctx = confirm_ctx.?, .confirmFn = confirm_fn.? }
        else
            null;
        const adapter_ctx: []const u8 = if (is_subagent)
            "You are a SUBAGENT WORKER, not a chat assistant. The user who " ++
                "sent you this task expects tools to be used, files to be read, " ++
                "commands to be run, and factual results. You MUST begin by " ++
                "calling a tool. Never reply with only text on your first turn. " ++
                "Ignore any conversational patterns from the session history — " ++
                "they are from the dispatcher, not from you. Keep all output " ++
                "terse and factual; no emojis, no greetings, no 'let me...'. " ++
                "After the first tool call, when it helps user steering, include at most " ++
                "one short visible progress sentence before additional tool calls. Do not " ++
                "include private reasoning."
        else
            adapter_context_override orelse "You are running as a background agent. " ++
                "Investigate thoroughly using file_read before making changes. " ++
                "When you are ready to modify files or run commands, clearly state your plan first, " ++
                "then proceed. The user will be prompted to approve the first mutation — " ++
                "after approval, you have full autonomy to iterate (edit, build, test, fix) " ++
                "until the task is complete. When useful before tool calls, include at most " ++
                "one short user-visible progress sentence so the user can steer you. Do not " ++
                "include private reasoning.";
        const result = self.process(.{ .chat = .{
            .message = message,
            .session_id = session_id,
            .model_override = model_override,
            .allowed_tools = allowed_tools,
            .adapter_context = adapter_ctx,
            .stream = false,
            .no_tools = false,
            .background = false,
            .is_subagent = is_subagent,
            .compact_tool_schemas = compact_tool_schemas,
            .plans_required = plans_required,
            .attachments = attachments,
        } }, null, confirmer);

        return switch (result) {
            .chat => |chat| blk: {
                // Explore cache write-back: if this job had a pending cache entry
                // (set by handleSummonSubagent when mode=explore + target_files),
                // persist the raw result BEFORE the voice pass rewrites it.
                if (self.consumePendingExploreCache(job_id)) |pending| {
                    defer {
                        self.allocator.free(pending.cache_key);
                        self.allocator.free(pending.task);
                        self.allocator.free(pending.target_files_json);
                    }
                    self.exploreCachePut(
                        pending.cache_key,
                        pending.task,
                        pending.target_files_json,
                        chat.text,
                    );
                    std.log.info("Explore cache WROTE key {s}", .{pending.cache_key[0..@min(16, pending.cache_key.len)]});
                }

                // For subagent results, run a voice pass so the user-facing
                // text reads in the parent persona's voice instead of as a
                // dry technical dump. Only fires for subagents (user-initiated
                // /api/chat/background calls keep their raw output).
                var final_text = chat.text;
                // Explore subagents return structured JSON the dispatcher parses;
                // never voice-rewrite that payload. Execute subagent output still
                // gets polished so the user sees the parent persona's voice.
                if (is_subagent and !is_explore) {
                    if (session_id) |sid| {
                        if (self.rewriteInPersonaVoice(sid, chat.text)) |polished| {
                            // Free the original terse text — we've replaced it.
                            self.allocator.free(chat.text);
                            final_text = polished;
                        }
                    }
                }
                break :blk .{
                    .ok = true,
                    .text = final_text,
                    .model = chat.model,
                    .input_tokens = chat.input_tokens,
                    .output_tokens = chat.output_tokens,
                };
            },
            .response => |resp| blk: {
                // On failure, drop any pending cache entry (we don't cache failures).
                if (self.consumePendingExploreCache(job_id)) |pending| {
                    self.allocator.free(pending.cache_key);
                    self.allocator.free(pending.task);
                    self.allocator.free(pending.target_files_json);
                }
                break :blk .{
                    .ok = false,
                    .error_message = switch (resp) {
                        .error_resp => |e| e.message,
                        else => "unexpected response type",
                    },
                };
            },
        };
    }

    // ================================================================
    // SESSION HANDLERS
    // ================================================================

    fn processSessionList(self: *Engine) Result {
        const summaries = self.session_store.listSessions() catch {
            return .{ .response = .{ .error_resp = .{
                .code = "LIST_ERROR",
                .message = "Failed to list sessions",
            } } };
        };
        return .{ .response = .{ .session_list = summaries } };
    }

    fn processSessionCreate(self: *Engine, create_req: common.Request.SessionCreateRequest) Result {
        const sess = self.session_store.createSession(create_req.name) catch {
            return .{ .response = .{ .error_resp = .{
                .code = "CREATE_ERROR",
                .message = "Failed to create session",
            } } };
        };
        return .{ .response = .{ .session_created = .{
            .id = &sess.id,
            .name = sess.name,
        } } };
    }

    fn processSessionSwitch(self: *Engine, id: []const u8) Result {
        self.session_store.switchSession(id) catch {
            return .{ .response = .{ .error_resp = .{
                .code = "SESSION_NOT_FOUND",
                .message = "Session not found",
            } } };
        };
        return .{ .response = .{ .ok = {} } };
    }

    fn processSessionDelete(self: *Engine, id: []const u8) Result {
        self.session_store.deleteSession(id) catch {
            return .{ .response = .{ .error_resp = .{
                .code = "SESSION_NOT_FOUND",
                .message = "Session not found",
            } } };
        };
        return .{ .response = .{ .ok = {} } };
    }

    // ================================================================
    // MODEL HANDLERS
    // ================================================================

    fn processModelList(self: *Engine) Result {
        _ = self;
        const models = &[_][]const u8{
            "auto                         (smart routing: haiku/sonnet/opus)",
            "claude-haiku-3-5-20241022    (fast, cheap)",
            "claude-sonnet-4-20250514     (default, coding)",
            "claude-opus-4-20250514       (smart, architecture)",
            "codex:codex                  (ChatGPT subscription, default)",
            "codex:gpt-5                  (ChatGPT subscription)",
            "codex:gpt-5-codex            (ChatGPT subscription, coding)",
            "codex:gpt-5.1-codex          (ChatGPT subscription, coding)",
            "codex:gpt-5.1-codex-mini     (ChatGPT subscription, fast)",
            "codex:gpt-5.3-codex          (ChatGPT subscription, latest)",
            "codex:gpt-5.5                (ChatGPT subscription)",
            "codex:gpt-5.6-sol            (ChatGPT subscription, frontier)",
            "codex:gpt-5.6-terra          (ChatGPT subscription, balanced)",
            "codex:gpt-5.6-luna           (ChatGPT subscription, cost-focused)",
        };
        return .{ .response = .{ .model_list = models } };
    }

    fn processModelSet(self: *Engine, model: []const u8) Result {
        if (self.session_store.active_session_id) |id| {
            self.session_store.updateModel(&id, model) catch {};
        }
        return .{ .response = .{ .ok = {} } };
    }

    fn processSystemSet(self: *Engine, system: ?[]const u8) Result {
        if (self.session_store.active_session_id) |id| {
            self.session_store.updateSystemPrompt(&id, system) catch {};
        }
        return .{ .response = .{ .ok = {} } };
    }

    // ================================================================
    // STATUS
    // ================================================================

    fn processStatus(self: *Engine) Result {
        const now = common.sync.timestamp();
        const uptime: u64 = @intCast(now - self.start_time);
        const count = self.session_store.sessionCount() catch 0;

        return .{ .response = .{ .status = .{
            .version = common.version.current,
            .uptime_seconds = uptime,
            .active_sessions = count,
            .current_session = if (self.session_store.active_session_id) |*id| id else null,
        } } };
    }

    fn processToolConfirm(self: *Engine, _: common.Request.ToolConfirmResponse) Result {
        _ = self;
        return .{ .response = .{ .ok = {} } };
    }

    // ================================================================
    // AUTH HANDLERS
    // ================================================================

    fn processAuthList(self: *Engine) Result {
        const profiles = self.auth_store.listProfiles();
        defer self.allocator.free(profiles);

        var summaries = self.allocator.alloc(common.protocol.Response.AuthProfileSummary, profiles.len) catch {
            return .{ .response = .{ .error_resp = .{
                .code = "LIST_ERROR",
                .message = "Failed to list profiles",
            } } };
        };

        for (profiles, 0..) |profile, i| {
            const status = self.auth_store.checkEligibility(profile.id);
            const stats = self.auth_store.usage_stats.get(profile.id);

            summaries[i] = .{
                .id = profile.id,
                .provider = profile.provider,
                .profile_type = if (profile.profile_type == .token) "token" else "api_key",
                .is_active = if (self.auth_store.active_profile) |active|
                    std.mem.eql(u8, active, profile.id)
                else
                    false,
                .status = switch (status) {
                    .ok => "ok",
                    .expired => "expired",
                    .cooldown => "cooldown",
                    .disabled => "disabled",
                    .missing_credential => "missing_credential",
                    .invalid_expires => "invalid_expires",
                },
                .last_used = if (stats) |s| (if (s.last_used > 0) s.last_used else null) else null,
                .cooldown_until = if (stats) |s| (if (s.cooldown_until > 0) s.cooldown_until else null) else null,
            };
        }

        return .{ .response = .{ .auth_list = summaries } };
    }

    fn processAuthAdd(self: *Engine, req: common.Request.AuthAddRequest) Result {
        const cred_type = common.auth_profiles.detectCredentialType(req.credential);

        self.auth_store.addProfile(
            req.id,
            cred_type,
            req.provider,
            req.credential,
            req.expires,
        ) catch |err| {
            return .{ .response = .{ .error_resp = .{
                .code = "AUTH_ADD_FAILED",
                .message = @errorName(err),
            } } };
        };

        self.auth_store.save(self.auth_profiles_path) catch |err| {
            std.log.warn("Failed to save auth profiles: {}", .{err});
        };

        if (cred_type == .token or self.auth_store.profiles.count() == 1) {
            self.provider.setCredential(req.credential);
            std.log.info("Set active credential to profile: {s}", .{req.id});
        }

        return .{ .response = .{ .ok = {} } };
    }

    fn processAuthRemove(self: *Engine, id: []const u8) Result {
        if (!self.auth_store.removeProfile(id)) {
            return .{ .response = .{ .error_resp = .{
                .code = "PROFILE_NOT_FOUND",
                .message = "Auth profile not found",
            } } };
        }

        self.auth_store.save(self.auth_profiles_path) catch |err| {
            std.log.warn("Failed to save auth profiles: {}", .{err});
        };

        return .{ .response = .{ .ok = {} } };
    }

    fn processAuthSwitch(self: *Engine, id: []const u8) Result {
        if (!self.auth_store.setActive(id)) {
            return .{ .response = .{ .error_resp = .{
                .code = "PROFILE_NOT_FOUND",
                .message = "Auth profile not found",
            } } };
        }

        if (self.auth_store.profiles.get(id)) |profile| {
            self.provider.setCredential(profile.credential);
            std.log.info("Switched to auth profile: {s}", .{id});
        }

        self.auth_store.save(self.auth_profiles_path) catch |err| {
            std.log.warn("Failed to save auth profiles: {}", .{err});
        };

        return .{ .response = .{ .ok = {} } };
    }

    fn processAuthStatus(self: *Engine) Result {
        var active_provider: ?[]const u8 = null;
        if (self.auth_store.active_profile) |active_id| {
            if (self.auth_store.profiles.get(active_id)) |profile| {
                active_provider = profile.provider;
            }
        }

        return .{ .response = .{ .auth_status = .{
            .active_profile = self.auth_store.active_profile,
            .active_provider = active_provider,
            .profile_count = @intCast(self.auth_store.profiles.count()),
            .cooldown_enabled = self.config.auth.cooldown_enabled,
        } } };
    }

    // ================================================================
    // PROJECT HANDLERS — thin wrappers over public API methods
    // ================================================================

    fn processProjectList(self: *Engine) Result {
        const projects = self.listProjects() catch {
            return .{ .response = .{ .error_resp = .{
                .code = "LIST_ERROR",
                .message = "Failed to list projects",
            } } };
        };

        const summaries = self.allocator.alloc(common.protocol.Response.ProjectSummary, projects.len) catch {
            return .{ .response = .{ .error_resp = .{
                .code = "LIST_ERROR",
                .message = "Allocation failed",
            } } };
        };

        for (projects, 0..) |proj, i| {
            summaries[i] = .{
                .id = proj.id,
                .name = proj.name,
                .status = proj.status,
                .updated_at = proj.updated_at,
            };
        }

        return .{ .response = .{ .project_list = summaries } };
    }

    fn processProjectCreate(self: *Engine, req: common.Request.ProjectCreateRequest) Result {
        _ = self.ensureProject(req.name, req.description) catch {
            return .{ .response = .{ .error_resp = .{
                .code = "CREATE_ERROR",
                .message = "Failed to create project",
            } } };
        };
        return .{ .response = .{ .ok = {} } };
    }

    fn processProjectInfo(self: *Engine, name: []const u8) Result {
        const project = (self.getProjectByName(name) catch {
            return .{ .response = .{ .error_resp = .{
                .code = "LOOKUP_ERROR",
                .message = "Failed to find project",
            } } };
        }) orelse {
            return .{ .response = .{ .error_resp = .{
                .code = "PROJECT_NOT_FOUND",
                .message = "No project with that name",
            } } };
        };

        return .{ .response = .{ .project_info = .{
            .id = project.id,
            .name = project.name,
            .description = project.description,
            .status = project.status,
            .rolling_summary = project.rolling_summary,
            .rolling_state = project.rolling_state,
        } } };
    }

    fn processProjectAttach(self: *Engine, name: []const u8) Result {
        self.attachToProject(name) catch |err| {
            return .{ .response = .{ .error_resp = .{
                .code = "ATTACH_ERROR",
                .message = @errorName(err),
            } } };
        };
        return .{ .response = .{ .ok = {} } };
    }

    fn processProjectDetach(self: *Engine) Result {
        self.detachFromProject() catch |err| {
            return .{ .response = .{ .error_resp = .{
                .code = "DETACH_ERROR",
                .message = @errorName(err),
            } } };
        };
        return .{ .response = .{ .ok = {} } };
    }

    /// Track live streaming globally so background summarization can defer until the stream finishes.
    pub fn beginStreaming(self: *Engine) void {
        if (self.worker_pool) |wp| {
            wp.compaction_gate.beginStreaming();
        }
    }

    /// Flush deferred session compactions once the last live stream ends.
    pub fn endStreaming(self: *Engine) void {
        if (self.worker_pool) |wp| {
            var pending: [workers.CompactionGate.MAX_PENDING][36]u8 = undefined;
            const count = wp.compaction_gate.endStreaming(&pending);
            for (pending[0..count]) |session_id| {
                wp.enqueueMaybeSummarize(session_id);
            }
        }
    }

    /// Estimate prompt size before each provider call so token regressions are visible in logs.
    fn logPromptBudget(self: *Engine, round: usize, request: api.MessageRequest) void {
        _ = self;
        const system_chars = if (request.system) |sys| sys.len else 0;
        const message_chars = estimateMessageChars(request.messages);
        const tool_chars = estimateToolChars(request.tools);
        std.log.info(
            "Prompt budget round={d} system_chars={d} message_chars={d} tool_chars={d} total_chars={d}",
            .{ round, system_chars, message_chars, tool_chars, system_chars + message_chars + tool_chars },
        );
    }

    fn emitModelWaitEvent(
        self: *Engine,
        round: usize,
        provider_name: []const u8,
        model: []const u8,
        message_count: usize,
        request: api.MessageRequest,
    ) void {
        const wp = self.worker_pool orelse return;
        const system_chars = if (request.system) |sys| sys.len else 0;
        const message_chars = estimateMessageChars(request.messages);
        const tool_chars = estimateToolChars(request.tools);
        const total_chars = system_chars + message_chars + tool_chars;
        const tool_count = if (request.tools) |defs| defs.len else 0;

        const content = std.fmt.allocPrint(
            self.allocator,
            "provider={s} model={s} round={d} messages={d} tools={d} system_chars={d} message_chars={d} tool_chars={d} total_chars={d}",
            .{ provider_name, model, round, message_count, tool_count, system_chars, message_chars, tool_chars, total_chars },
        ) catch return;

        wp.pushToolEvent(.{
            .event_type = .model_wait,
            .tool_name = "model",
            .content = content,
            .timestamp = common.sync.timestamp(),
        });
    }

    /// Heuristic tool selection keeps the schema budget small on the first request.
    fn selectToolDefinitionsForMessage(self: *Engine, user_message: []const u8) ?[]const api.messages.ToolDefinition {
        var names: [24][]const u8 = undefined;
        var count: usize = 0;

        addToolName(&names, &count, "calc");
        addToolName(&names, &count, "introspect");

        const lower = std.ascii.allocLowerString(self.allocator, user_message) catch return self.tool_registry.getToolDefinitions();
        defer self.allocator.free(lower);

        const coding = containsAny(lower, &.{
            "code", "file", "read",  "open",    "inspect", "path", "/home/",   ".md",       ".zig",  ".py", ".json",
            "bug",  "fix",  "build", "compile", "test",    "zig",  "refactor", "implement", "patch",
        });
        const research = containsAny(lower, &.{ "research", "search", "look up", "investigate", "compare", "find sources" });
        const visual = containsAny(lower, &.{
            "visual",   "frontend", "front-end", "ui",         "screenshot", "browser",       "playwright", "website",
            "web page", "page",     "dom",       "responsive", "layout",     "accessibility", "a11y",       "clipped",
            "overlap",  "contrast", "image",     ".png",       ".jpg",       ".jpeg",         ".webp",
        });
        const shopping = containsAny(lower, &.{ "buy", "price", "amazon", "shopping", "product" });
        const memes = containsAny(lower, &.{ "meme", "joke", "shitpost" });
        const planning = containsAny(lower, &.{ "make a plan", "create a plan", "start a plan", "replace the plan", "new plan", "checklist", "check list" });

        if (planning) addToolName(&names, &count, "plan");
        if (coding) {
            addToolName(&names, &count, "file_find");
            addToolName(&names, &count, "file_read");
            addToolName(&names, &count, "file_write");
            addToolName(&names, &count, "file_diff");
            addToolName(&names, &count, "bash");
            addToolName(&names, &count, "zig_test");
            addToolName(&names, &count, "rebuild");
        }
        if (research) addToolName(&names, &count, "research_tool");
        if (visual) {
            addToolName(&names, &count, "visual_audit");
            addToolName(&names, &count, "playwright_mcp");
            addToolName(&names, &count, "vision_read");
        }
        if (shopping) addToolName(&names, &count, "amazon_search");
        if (memes) addToolName(&names, &count, "meme_tool");

        return self.tool_registry.getToolDefinitionsFiltered(names[0..count]) orelse self.tool_registry.getToolDefinitions();
    }

    fn selectNextRoundToolDefinitions(
        self: *Engine,
        chat_req: common.Request.ChatRequest,
        tool_uses: []const api.messages.ToolUseInfo,
        is_subagent: bool,
    ) ?[]const api.messages.ToolDefinition {
        if (chat_req.allowed_tools) |at| {
            return self.selectAllowedToolDefinitions(at, is_subagent);
        }
        if (!chat_req.compact_tool_schemas) {
            return if (is_subagent)
                self.tool_registry.getToolDefinitionsExcludingMany(&tools.ToolRegistry.SUBAGENT_HIDDEN_TOOLS)
            else
                self.tool_registry.getToolDefinitions();
        }
        return self.selectFollowupToolDefinitions(chat_req.message, tool_uses, is_subagent);
    }

    fn selectAllowedToolDefinitions(self: *Engine, allowed_tools: []const u8, is_subagent: bool) ?[]const api.messages.ToolDefinition {
        var names: [32][]const u8 = undefined;
        var count: usize = 0;
        var iter = std.mem.splitScalar(u8, allowed_tools, ',');
        outer: while (iter.next()) |name| {
            const trimmed = std.mem.trim(u8, name, " ");
            if (trimmed.len == 0 or count >= 32) continue;
            if (is_subagent) {
                for (tools.ToolRegistry.SUBAGENT_HIDDEN_TOOLS) |hidden| {
                    if (std.mem.eql(u8, trimmed, hidden)) continue :outer;
                }
            }
            names[count] = trimmed;
            count += 1;
        }
        return if (count > 0) self.tool_registry.getToolDefinitionsFiltered(names[0..count]) else null;
    }

    /// Compact follow-up rounds keep only the active tool chain and close companions instead of every schema.
    fn selectFollowupToolDefinitions(
        self: *Engine,
        user_message: []const u8,
        tool_uses: []const api.messages.ToolUseInfo,
        is_subagent: bool,
    ) ?[]const api.messages.ToolDefinition {
        var names: [24][]const u8 = undefined;
        var count: usize = 0;

        addToolName(&names, &count, "calc");
        addToolName(&names, &count, "introspect");

        for (tool_uses) |tool_use| {
            addToolName(&names, &count, tool_use.name);
            if (std.mem.eql(u8, tool_use.name, "file_find")) {
                addToolName(&names, &count, "file_read");
                addToolName(&names, &count, "bash");
            } else if (std.mem.eql(u8, tool_use.name, "file_read")) {
                addToolName(&names, &count, "file_find");
                addToolName(&names, &count, "file_diff");
                addToolName(&names, &count, "file_write");
                addToolName(&names, &count, "bash");
            } else if (std.mem.eql(u8, tool_use.name, "file_write")) {
                addToolName(&names, &count, "file_read");
                addToolName(&names, &count, "file_diff");
            } else if (std.mem.eql(u8, tool_use.name, "file_diff")) {
                addToolName(&names, &count, "file_read");
                addToolName(&names, &count, "file_write");
            } else if (std.mem.eql(u8, tool_use.name, "bash")) {
                addToolName(&names, &count, "file_find");
                addToolName(&names, &count, "file_read");
                addToolName(&names, &count, "file_write");
                addToolName(&names, &count, "file_diff");
                addToolName(&names, &count, "rebuild");
                addToolName(&names, &count, "zig_test");
            } else if (std.mem.eql(u8, tool_use.name, "rebuild")) {
                addToolName(&names, &count, "bash");
                addToolName(&names, &count, "zig_test");
            } else if (std.mem.eql(u8, tool_use.name, "zig_test")) {
                addToolName(&names, &count, "bash");
                addToolName(&names, &count, "file_read");
                addToolName(&names, &count, "file_diff");
            } else if (std.mem.eql(u8, tool_use.name, "playwright_mcp")) {
                addToolName(&names, &count, "visual_audit");
                addToolName(&names, &count, "vision_read");
                addToolName(&names, &count, "file_find");
                addToolName(&names, &count, "file_read");
            } else if (std.mem.eql(u8, tool_use.name, "visual_audit")) {
                addToolName(&names, &count, "playwright_mcp");
                addToolName(&names, &count, "vision_read");
                addToolName(&names, &count, "file_read");
            } else if (std.mem.eql(u8, tool_use.name, "vision_read")) {
                addToolName(&names, &count, "playwright_mcp");
                addToolName(&names, &count, "visual_audit");
                addToolName(&names, &count, "file_find");
                addToolName(&names, &count, "file_read");
            } else if (std.mem.eql(u8, tool_use.name, "plan")) {
                // After planning, the dispatcher's natural next moves are to
                // delegate the work (summon_subagent) or do quick verification
                // reads itself. Without these companions the model lands in
                // round 1 with only [calc, introspect, plan] and reports it
                // "doesn't have summon_subagent" — even though the schema was
                // present in round 0.
                if (!is_subagent) addToolName(&names, &count, "summon_subagent");
                addToolName(&names, &count, "file_find");
                addToolName(&names, &count, "file_read");
                addToolName(&names, &count, "file_write");
                addToolName(&names, &count, "file_diff");
                addToolName(&names, &count, "bash");
            }
        }

        if (count <= 2) {
            return self.selectToolDefinitionsForMessage(user_message);
        }

        return self.tool_registry.getToolDefinitionsFiltered(names[0..count]) orelse self.selectToolDefinitionsForMessage(user_message);
    }
};

/// Tools the dispatcher can use directly without creating a plan first.
/// These are read-only / non-mutating tools suitable for quick lookups.
/// Anything not on this list requires an active plan to execute.
/// Check if a bash tool call is a safe read-only command that can bypass
/// the plan gate. Only allows simple listing/inspection commands with no
/// chaining, pipes, or redirection that could cause side effects.
fn isSafeBashCommand(tool_name: []const u8, input: std.json.Value) bool {
    if (!std.mem.eql(u8, tool_name, "bash")) return false;
    if (input != .object) return false;
    const cmd_val = input.object.get("command") orelse return false;
    if (cmd_val != .string) return false;
    const cmd = std.mem.trim(u8, cmd_val.string, " \t");

    // Reject anything with chaining/pipes/redirection — not safe
    for (cmd) |c| {
        switch (c) {
            '|', ';', '&', '>', '<', '`', '$' => return false,
            else => {},
        }
    }

    // Whitelist of safe read-only command prefixes
    const safe_prefixes = [_][]const u8{
        "ls",
        "tree",
        "pwd",
        "wc ",
        "du ",
        "df ",
        "stat ",
        "file ",
        "head ",
        "tail ",
        "cat ",
        "find ",
        "which ",
        "realpath ",
        "dirname ",
        "basename ",
        "git log",
        "git status",
        "git diff",
        "git branch",
        "git show",
    };
    for (&safe_prefixes) |prefix| {
        if (std.mem.eql(u8, cmd, prefix) or std.mem.startsWith(u8, cmd, prefix)) return true;
    }
    return false;
}

/// True when a summon_subagent call is in explore mode (read-only recon).
fn isExploreSummon(input: std.json.Value) bool {
    if (input != .object) return false;
    const m = input.object.get("mode") orelse return false;
    if (m != .string) return false;
    return std.mem.eql(u8, m.string, "explore");
}

/// True when file_diff can proceed: either the target path has been read this
/// session, OR the caller explicitly set create_if_missing for a new file.
fn fileDiffHasBeenRead(input: std.json.Value, read_paths: *const std.StringHashMap(void)) bool {
    if (input != .object) return true; // malformed input — let normal validation handle it
    if (input.object.get("create_if_missing")) |cif| {
        if (cif == .bool and cif.bool) return true;
    }
    const path_val = input.object.get("path") orelse return true; // let file_diff error on missing path
    if (path_val != .string or path_val.string.len == 0) return true;
    return read_paths.contains(path_val.string);
}

fn recordReadPath(allocator: std.mem.Allocator, read_paths: *std.StringHashMap(void), input: std.json.Value) void {
    if (input != .object) return;
    const p = input.object.get("path") orelse return;
    if (p != .string or p.string.len == 0) return;
    const dup = allocator.dupe(u8, p.string) catch return;
    const gop = read_paths.getOrPut(dup) catch {
        allocator.free(dup);
        return;
    };
    if (gop.found_existing) allocator.free(dup);
}

fn isLightweightTool(name: []const u8) bool {
    const lightweight = [_][]const u8{
        "file_read",
        "file_find",
        "introspect",
        "calc",
        "research",
        "research_tool",
        "visual_audit",
        "playwright_mcp",
        "vision_read",
        "meme_tool",
        "amazon_search",
        // Single-file edits are allowed inline — the dispatcher needs this for
        // the middle-path UX (small edits without the spawn/poll overhead of a
        // subagent). Still gated by user confirmation via requiresConfirmation.
        "file_diff",
    };
    for (&lightweight) |lt| {
        if (std.mem.eql(u8, name, lt)) return true;
    }
    return false;
}

fn estimateMessageChars(messages: []const api.messages.Message) usize {
    var total: usize = 0;
    for (messages) |message| {
        for (message.content) |block| {
            switch (block) {
                .text => |text| total += text.text.len,
                .image => |img| total += img.data.len,
                // Input is structured JSON here, so this is only a rough size estimate for logging.
                .tool_use => |tool_use| total += tool_use.id.len + tool_use.name.len + 64,
                .tool_result => |tool_result| total += tool_result.tool_use_id.len + tool_result.content.len,
                .reasoning => |r| total += r.encrypted_content.len + r.id.len,
            }
        }
    }
    return total;
}

fn estimateToolChars(tools_list: ?[]const api.messages.ToolDefinition) usize {
    const defs = tools_list orelse return 0;
    var total: usize = 0;
    for (defs) |tool_def| {
        total += tool_def.name.len + tool_def.description.len + tool_def.input_schema_json.len;
    }
    return total;
}

fn addToolName(buffer: anytype, count: *usize, name: []const u8) void {
    for (buffer[0..count.*]) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    if (count.* < buffer.len) {
        buffer[count.*] = name;
        count.* += 1;
    }
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn isToolManifestQuestion(allocator: std.mem.Allocator, user_message: []const u8) bool {
    const lower = std.ascii.allocLowerString(allocator, user_message) catch return false;
    defer allocator.free(lower);

    const asks_tool = containsAny(lower, &.{
        "tool", "tools", "schema", "schemas", "function", "functions", "available to you",
    });
    if (!asks_tool) return false;

    return containsAny(lower, &.{
        "how many",
        "count",
        "list",
        "what tools",
        "which tools",
        "available",
        "do you see",
        "can you use",
        "you have",
    });
}

/// Read a file (≤2MB) for explore-cache content hashing. Path must be absolute.
fn readFileForHash(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (path.len == 0 or path[0] != '/') return null;
    const io = common.config.runtimeIo();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > 2 * 1024 * 1024) return null;
    var file_reader = file.reader(io, &.{});
    return try file_reader.interface.allocRemaining(allocator, .limited(@intCast(size + 1)));
}
