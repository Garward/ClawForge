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
    start_time: i64,

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
            .start_time = std.time.timestamp(),
        };
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

        // Enforce read-before-write: file_diff and file_write (force=true on existing) require prior file_read
        if (std.mem.eql(u8, name, "file_diff") or std.mem.eql(u8, name, "file_write")) {
            if (input == .object) {
                if (input.object.get("path")) |p| {
                    if (p == .string) {
                        const file_path = self.normalizeToolPath(p.string);
                        defer if (file_path.ptr != p.string.ptr) self.allocator.free(@constCast(file_path));

                        const needs_read = if (std.mem.eql(u8, name, "file_diff")) blk: {
                            const create = if (input.object.get("create_if_missing")) |c| (c == .bool and c.bool) else false;
                            if (create) {
                                std.fs.accessAbsolute(file_path, .{}) catch break :blk false;
                                break :blk true;
                            }
                            break :blk true;
                        } else blk: {
                            const force = if (input.object.get("force")) |f| (f == .bool and f.bool) else false;
                            if (!force) break :blk false;
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
            const home = std.posix.getenv("HOME") orelse return raw;
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
    ) void {
        var stmt = self.project_store.conn.prepare(
            "INSERT INTO tool_calls (message_id, session_id, sequence, tool_name, tool_input, tool_result, status, approved, created_at) " ++
                "VALUES (?, ?, (SELECT COALESCE(MAX(sequence), -1) + 1 FROM tool_calls WHERE session_id = ?), ?, ?, ?, ?, ?, ?)",
        ) catch return;
        defer stmt.deinit();
        if (message_id == 0) {
            stmt.bindNull(1) catch return;
        } else {
            stmt.bindInt64(1, message_id) catch return;
        }
        stmt.bindText(2, session_id) catch return;
        stmt.bindText(3, session_id) catch return;
        stmt.bindText(4, record.tool_name) catch return;
        stmt.bindText(5, record.tool_input) catch return;
        stmt.bindOptionalText(6, record.tool_result) catch return;
        stmt.bindText(7, record.status) catch return;
        if (record.approved) |a| {
            stmt.bindInt(8, if (a) 1 else 0) catch return;
        } else {
            stmt.bindNull(8) catch return;
        }
        stmt.bindInt64(9, std.time.timestamp()) catch return;
        stmt.exec() catch return;
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
    ) ![]const u8 {
        var layers = try prompt_mod.buildFromState(
            self.allocator,
            self.project_store,
            session_id,
            session_system_prompt,
            adapter_context,
        );

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
        var out: std.ArrayList(u8) = .{};
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

        // Add user message to DB. Skipped for subagents — their wrapped
        // task is a machine-generated instruction from the dispatcher, not
        // a real user turn, and persisting it pollutes the dispatcher's
        // session history with directive boilerplate.
        if (!chat_req.is_subagent) {
            _ = self.message_store.addUserMessage(&sess.id, chat_req.message) catch {
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

        var user_turn_images: std.ArrayList(api.messages.ContentBlock) = .{};

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
            const attach_to_main_turn = !chat_req.is_subagent;

            var overlay: std.ArrayList(u8) = .{};
            if (chat_req.adapter_context) |ctx| {
                overlay.appendSlice(vision_arena, ctx) catch {};
                overlay.appendSlice(vision_arena, "\n\n") catch {};
            }
            overlay.appendSlice(vision_arena, "--- Attached images (auto-described via vision model) ---\n") catch {};

            var i: usize = 0;
            while (i < limit) : (i += 1) {
                const att = attachments[i];

                // Read the image bytes and base64-encode them for the main
                // model's user turn. Bounded by max_image_bytes. On any
                // failure we fall through to the vision-description path so
                // the model still sees *something*.
                img_read: {
                    if (!attach_to_main_turn) break :img_read;
                    const file = std.fs.openFileAbsolute(att.path, .{}) catch |err| {
                        std.log.warn("Main-turn image read failed for {s}: {s}", .{ att.name, @errorName(err) });
                        break :img_read;
                    };
                    defer file.close();
                    const bytes = file.readToEndAlloc(vision_arena, vision_cfg.max_image_bytes + 1) catch |err| {
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
            }

            if (attachments.len > limit) {
                var trim_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&trim_buf, "\n[{d} additional attachments omitted: over per-turn limit of {d}]\n", .{
                    attachments.len - limit,
                    limit,
                }) catch "\n[additional attachments omitted]\n";
                overlay.appendSlice(vision_arena, msg) catch {};
            }
            overlay.appendSlice(vision_arena, "--- End images ---") catch {};

            break :blk overlay.items;
        };

        // Inject the collected image blocks into the current user turn so
        // the main model sees the pixels. The vision description stays in
        // adapter_context as a supplement.
        if (user_turn_images.items.len > 0 and msgs.len > 0) {
            const last_idx = msgs.len - 1;
            if (msgs[last_idx].role == .user) {
                const orig_content = msgs[last_idx].content;
                const new_len = user_turn_images.items.len + orig_content.len;
                if (vision_arena.alloc(api.messages.ContentBlock, new_len)) |new_content| {
                    @memcpy(new_content[0..user_turn_images.items.len], user_turn_images.items);
                    @memcpy(new_content[user_turn_images.items.len..], orig_content);
                    const msgs_mut = @constCast(msgs);
                    msgs_mut[last_idx] = .{ .role = .user, .content = new_content };
                    std.log.info("Attached {d} image block(s) to user turn", .{user_turn_images.items.len});
                } else |_| {}
            }
        }

        // Build layered system prompt: persona + user context + project + retrieved + adapter + session
        // For subagents, skip retrieval — their user_message is a wrapped
        // directive ("[SUBAGENT EXECUTION MODE]...") that would pollute the
        // FTS query. The dispatcher (the actual user-facing turn) is where
        // memory injection matters.
        const retrieval_query: ?[]const u8 = if (chat_req.is_subagent) null else chat_req.message;
        const system_prompt: ?[]const u8 = self.buildSystemPrompt(
            &sess.id,
            sess.system_prompt,
            effective_adapter_context,
            chat_req.message,
            retrieval_query,
        ) catch sess.system_prompt;

        var owned_tool_defs: std.ArrayList([]const api.messages.ToolDefinition) = .{};
        defer {
            for (owned_tool_defs.items) |defs| self.allocator.free(defs);
            owned_tool_defs.deinit(self.allocator);
        }

        // Subagents (confirmer != null) must not recursively summon more
        // subagents — nested job IDs aren't tracked by adapters, so results
        // get orphaned. Strip summon_subagent from their tool set.
        const is_subagent = confirmer != null;

        // Tool selection: allowed_tools filter > all enabled tools
        const initial_tools = if (chat_req.allowed_tools) |at| blk: {
            var names: [32][]const u8 = undefined;
            var count: usize = 0;
            var iter = std.mem.splitScalar(u8, at, ',');
            while (iter.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " ");
                if (trimmed.len == 0 or count >= 32) continue;
                if (is_subagent and std.mem.eql(u8, trimmed, "summon_subagent")) continue;
                names[count] = trimmed;
                count += 1;
            }
            break :blk if (count > 0) self.tool_registry.getToolDefinitionsFiltered(names[0..count]) else null;
        } else if (is_subagent)
            self.tool_registry.getToolDefinitionsExcluding("summon_subagent")
        else
            self.tool_registry.getToolDefinitions();

        if (initial_tools) |defs| {
            owned_tool_defs.append(self.allocator, defs) catch {};
        }

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

        // Append the voice-calibration style guide to the system prompt
        // when targeting a non-Anthropic provider. The goal is to pin
        // small local models (qwen3, llama3.x, mistral) to the persona
        // voice instead of defaulting to generic-assistant cadence.
        const effective_system: ?[]const u8 = blk_sys: {
            const base = system_prompt orelse break :blk_sys null;
            if (std.mem.eql(u8, active_provider.getName(), "anthropic")) {
                break :blk_sys base;
            }
            // Concatenate onto the vision_arena so lifetime matches the
            // rest of the request (the arena deinits at function exit).
            const combined_len = base.len + SMALL_MODEL_STYLE_GUIDE.len;
            const combined = vision_arena.alloc(u8, combined_len) catch break :blk_sys base;
            @memcpy(combined[0..base.len], base);
            @memcpy(combined[base.len..], SMALL_MODEL_STYLE_GUIDE);
            std.log.info(
                "Appended {d}b style guide for non-Anthropic provider ({s})",
                .{ SMALL_MODEL_STYLE_GUIDE.len, active_provider.getName() },
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
        var text_parts: std.ArrayList(u8) = .{};
        defer text_parts.deinit(self.allocator);

        // Track tool calls for persistence in message history
        var tool_log: std.ArrayList(u8) = .{};
        defer tool_log.deinit(self.allocator);

        // Background job IDs spawned via summon_subagent during this chat turn.
        // Each entry is exactly 36 chars (a UUID).
        var spawned_subagent_ids: std.ArrayList([36]u8) = .{};
        defer spawned_subagent_ids.deinit(self.allocator);

        // Collect response arenas — freed after the tool loop is done.
        // Each API call returns a response with an arena; we can't free it
        // until the next round has consumed the tool_use data from it.
        var response_arenas: std.ArrayList(*std.heap.ArenaAllocator) = .{};
        defer {
            for (response_arenas.items) |arena| {
                arena.deinit();
                self.allocator.destroy(arena);
            }
            response_arenas.deinit(self.allocator);
        }

        var cancelled = false;
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

            std.log.info("Tool round {d}, emitter={}, msgs={d}", .{ tool_round, emitter != null, current_request.messages.len });
            self.logPromptBudget(tool_round, current_request);

            // Make API call — stream ALL rounds if emitter present
            const is_stream_round = emitter != null and current_request.stream;
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

            // Build messages for next API round: assistant(tool_use) → user(tool_results)
            // Execute each tool, emit events, record in DB, and build result messages.
            {
                // Assistant message: text preamble + tool_use blocks
                var assistant_blocks: std.ArrayList(api.messages.ContentBlock) = .{};
                if (api_response.text_content.len > 0) {
                    assistant_blocks.append(self.allocator, .{ .text = .{ .text = api_response.text_content } }) catch {};
                }
                for (api_response.tool_use) |tu| {
                    assistant_blocks.append(self.allocator, .{ .tool_use = .{
                        .id = tu.id,
                        .name = tu.name,
                        .input = tu.input,
                    } }) catch {};
                }

                // User message: tool_result for each tool call
                var result_blocks: std.ArrayList(api.messages.ContentBlock) = .{};
                for (api_response.tool_use) |tool_call| {
                    // Check cancellation before each tool execution
                    if (emitter) |em| {
                        if (em.isCancelled()) {
                            std.log.info("Stream cancelled before executing tool {s}", .{tool_call.name});
                            cancelled = true;
                            break;
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

                    // Push tool_use event for subagent live transparency
                    if (is_subagent) {
                        if (self.worker_pool) |wp| {
                            wp.pushToolEvent(.{
                                .event_type = .tool_use,
                                .tool_name = tool_call.name,
                                .content = tool_call.input_json,
                                .timestamp = std.time.timestamp(),
                            });
                        }
                    }

                    // Confirmation check
                    var declined = false;
                    if (self.tool_registry.requiresConfirmation(tool_call.name)) {
                        if (confirmer) |c| {
                            if (!c.confirm(tool_call.name, tool_call.id, tool_call.input_json)) {
                                declined = true;
                            }
                        }
                        // No confirmer → auto-approve
                    }

                    // Plan enforcement gate: block heavyweight tool calls when
                    // no active plan exists. Lightweight (read-only) tools are
                    // allowed so the dispatcher can answer quick questions
                    // directly without creating a full plan.
                    const is_plan_tool = std.mem.eql(u8, tool_call.name, "plan");
                    const is_lightweight = isLightweightTool(tool_call.name) or
                        isSafeBashCommand(tool_call.name, tool_call.input);
                    const plan_gate_active = !has_active_plan and !is_plan_tool and !is_subagent and !is_lightweight;
                    const tool_res = if (declined) blk: {
                        std.log.info("Tool {s} declined by user", .{tool_call.name});
                        break :blk tools.ToolResult{ .content = TOOL_DECLINED_MSG, .is_error = true };
                    } else if (plan_gate_active) blk: {
                        std.log.info("Plan gate: blocked {s} — no active plan", .{tool_call.name});
                        break :blk tools.ToolResult{
                            .content = "BLOCKED: This tool requires an active execution plan. Call the `plan` " ++
                                "tool with operation \"create\" first. Note: lightweight tools (file_read, " ++
                                "introspect, calc, research, meme_tool, amazon_search) and safe bash " ++
                                "commands (ls, tree, git log/status/diff, head, tail, cat, find, pwd) " ++
                                "work without a plan. For multi-step work, create a plan and delegate " ++
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
                        break :blk self.handleSummonSubagent(tool_call.input, &sess.id, &spawned_subagent_ids, model);
                    } else blk: {
                        std.log.info("Executing tool: {s}", .{tool_call.name});
                        break :blk self.executeToolParsedCached(tool_call.name, tool_call.input, tool_call.input_json);
                    };

                    // Emit result
                    if (emitter) |em| {
                        em.emit(.{ .stream_tool_result = .{
                            .tool_id = tool_call.id,
                            .result = tool_res.content,
                            .is_error = tool_res.is_error,
                        } });
                    }

                    // Push tool_result event for subagent live transparency
                    if (is_subagent) {
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
                                .timestamp = std.time.timestamp(),
                            });
                        }
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

                    // Record in DB
                    self.recordToolCall(&sess.id, 0, .{
                        .tool_id = tool_call.id,
                        .tool_name = tool_call.name,
                        .tool_input = tool_call.input_json,
                        .tool_result = tool_res.content,
                        .status = if (declined) "rejected" else if (tool_res.is_error) "error" else "success",
                        .approved = if (declined) false else !tool_res.is_error,
                    });

                    // For failed tool calls, augment the error with recovery guidance
                    const model_content = tool_res.modelContent();
                    const result_content = if (tool_res.is_error and !declined) blk: {
                        var err_msg: std.ArrayList(u8) = .{};
                        err_msg.appendSlice(self.allocator, model_content) catch break :blk model_content;
                        err_msg.appendSlice(
                            self.allocator,
                            "\n\n[RECOVERY HINT: This tool call failed. Fix the issue in your PREVIOUS call " ++
                                "(correct the path, argument, or parameter) rather than regenerating all content from scratch. " ++
                                "Your original input is preserved above — adjust only what caused the error.]",
                        ) catch {};
                        break :blk err_msg.items;
                    } else model_content;

                    result_blocks.append(self.allocator, .{ .tool_result = .{
                        .tool_use_id = tool_call.id,
                        .content = result_content,
                        .is_error = tool_res.is_error,
                    } }) catch {};
                }

                if (cancelled) break;

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
                                    if (tr.content.len > 600) {
                                        const head_len = @min(tr.content.len, 320);
                                        const tail_len = @min(tr.content.len - head_len, 220);
                                        const omitted = tr.content.len - head_len - tail_len;
                                        const summary = std.fmt.allocPrint(
                                            self.allocator,
                                            "{s}\n\n[...truncated {d} chars...]\n\n{s}",
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

                current_request.messages = extended;
                current_request.tools = self.selectFollowupToolDefinitions(chat_req.message, api_response.tool_use);
                if (current_request.tools) |defs| {
                    owned_tool_defs.append(self.allocator, defs) catch {};
                }
                // Keep persona/system flavor on the initial user-facing round only.
                // Intermediate tool-work rounds should focus on the task state, not chat style.
                current_request.system = null;
                // Keep streaming enabled so tool use progress is visible to the user.
                // current_request.stream stays as-is (true if emitter present).
            }
        }

        if (cancelled) {
            final_stop_reason = "cancelled";
            // Append cancellation note so the stored message is self-documenting
            if (text_parts.items.len > 0) {
                text_parts.appendSlice(self.allocator, "\n\n[Response stopped by user]") catch {};
            } else if (tool_log.items.len > 0) {
                text_parts.appendSlice(self.allocator, "[Response stopped by user during tool execution]") catch {};
            }
        }

        // If we exhausted tool rounds without a final text response, make one more
        // API call with tools disabled to force a text summary of everything so far.
        // Route through `active_provider` — `self.provider` is always the
        // default (Anthropic), so calling it with a bare Ollama model name
        // like `qwen3:30b` returns 404 and the whole chat dies with no
        // response. `final_req.model` already holds the bare name from the
        // earlier resolve, so `active_provider` is the right target.
        if (!cancelled and text_parts.items.len == 0 and tool_log.items.len > 0) {
            std.log.info(
                "Tool loop exhausted without text — forcing final summary call via {s}",
                .{active_provider.getName()},
            );
            var final_req = current_request;
            final_req.tools = null; // No tools → model must respond with text
            final_req.system = system_prompt; // Reapply persona/system prompt for the final user-facing response.
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
            var stored: std.ArrayList(u8) = .{};
            stored.appendSlice(self.allocator, "<tool_calls>") catch {};
            stored.appendSlice(self.allocator, tool_log.items) catch {};
            stored.appendSlice(self.allocator, "\n</tool_calls>\n\n") catch {};
            stored.appendSlice(self.allocator, final_text) catch {};
            break :blk stored.toOwnedSlice(self.allocator) catch final_text;
        } else final_text;

        // Store assistant response in DB
        _ = self.message_store.addAssistantMessage(
            &sess.id,
            stored_text,
            model,
            null,
            null,
            @as(?i64, @intCast(total_input_tokens)),
            @as(?i64, @intCast(total_output_tokens)),
        ) catch |err| {
            std.log.warn("Failed to save assistant message: {}", .{err});
        };

        // POST-RESPONSE HOOKS
        self.postResponseHooks(&sess.id, chat_req.message, final_text);

        // Dupe model string before freeing session info (model may alias sess.model)
        const result_model = self.allocator.dupe(u8, model) catch "unknown";
        self.session_store.freeSessionInfo(&sess);

        // Serialize spawned subagent IDs as a comma-joined string for the response payload.
        const spawned_jobs_str: ?[]const u8 = if (spawned_subagent_ids.items.len > 0) blk: {
            const total_len = spawned_subagent_ids.items.len * 37; // 36 + comma
            var out: std.ArrayList(u8) = .{};
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

            // Parse existing plan
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, existing.?, .{}) catch return .{
                .content = "Failed to parse existing plan. Consider re-creating it.",
                .is_error = true,
            };
            var plan_obj = parsed.value;

            if (plan_obj != .object) return .{
                .content = "Existing plan is corrupt. Use 'create' to make a new one.",
                .is_error = true,
            };

            // Update goal if provided
            if (input.object.get("goal")) |new_goal| {
                if (new_goal == .string) {
                    _ = plan_obj.object.fetchPut("goal", new_goal) catch {};
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
                                            _ = es.*.object.fetchPut("status", s) catch {};
                                        }
                                        if (new_step.object.get("description")) |d| {
                                            _ = es.*.object.fetchPut("description", d) catch {};
                                        }
                                        // notes: subagents attach findings, discoveries,
                                        // warnings here so the next subagent inherits context.
                                        if (new_step.object.get("notes")) |n| {
                                            _ = es.*.object.fetchPut("notes", n) catch {};
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
                    } else {
                        // No existing steps — set them
                        _ = plan_obj.object.fetchPut("steps", new_steps_val) catch {};
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
    ) tools.ToolResult {
        const wp = self.worker_pool orelse return .{
            .content = "summon_subagent unavailable: no worker pool configured",
            .is_error = true,
        };

        if (input != .object) return .{
            .content = "summon_subagent: input must be an object with a 'task' field",
            .is_error = true,
        };

        const task_val = input.object.get("task") orelse return .{
            .content = "summon_subagent: missing required 'task' field",
            .is_error = true,
        };
        if (task_val != .string or task_val.string.len == 0) return .{
            .content = "summon_subagent: 'task' must be a non-empty string",
            .is_error = true,
        };

        // Explicit override from the parent LLM's tool call args wins; otherwise
        // inherit the parent's active model so the subagent runs on whatever the
        // user selected. Without this, any subagent spawned during an Ollama turn
        // silently falls back to Claude.
        const explicit_model: ?[]const u8 = if (input.object.get("model")) |m|
            (if (m == .string and m.string.len > 0) m.string else null)
        else
            null;
        const model_val: ?[]const u8 = explicit_model orelse
            (if (parent_model.len > 0) parent_model else null);

        // Load the current plan so the subagent sees what step it's working on.
        const current_plan = self.session_store.getPlan(parent_session_id) catch null;

        // Wrap the task with a hard execution directive. The subagent
        // otherwise pattern-matches the dispatcher's chatty Discord style
        // (seen via shared session history) and replies with "Let me...",
        // "Dispatching...", "Firing off..." instead of calling tools. This
        // prefix is terminal: the model sees it as the latest instruction,
        // after persona and adapter_context.
        const wrapped_task = std.fmt.allocPrint(
            self.allocator,
            \\[SUBAGENT EXECUTION MODE — READ BEFORE RESPONDING]
            \\
            \\You are running as an autonomous file/code/shell agent. You are NOT
            \\the Discord dispatcher. Ignore any chat-style patterns from prior
            \\conversation — they do not apply to you.
            \\
            \\HARD RULES:
            \\1. Your FIRST response MUST contain a tool_use block. Do NOT reply
            \\   with text only. Start by calling file_read, bash, file_write,
            \\   or another concrete tool.
            \\2. NEVER write phrases like "Let me...", "I'll...", "Dispatching...",
            \\   "Firing off...", "Working on it...", or any dispatcher ack. You
            \\   are the worker, not a dispatcher.
            \\3. You do NOT have summon_subagent. Do not try to delegate — you
            \\   ARE the worker. Finish the task yourself.
            \\4. When complete, give a concise factual report (≤300 words). No
            \\   emojis, no greetings, no "let me know if you need more".
            \\5. You have the `plan` tool (view/update only). When you finish your
            \\   task, call `plan` with operation "update" to mark your step as
            \\   "done" and include a "notes" field with key findings, file paths,
            \\   gotchas, or anything the next step needs to know. This is critical
            \\   — other subagents see your notes and avoid repeating mistakes.
            \\   Example: {{"operation":"update","steps":[{{"id":2,"status":"done",
            \\   "description":"...", "notes":"config was at /etc/x not /opt/x"}}]}}
            \\
            \\{s}
            \\TASK:
            \\{s}
            ,
            .{
                if (current_plan) |p|
                    std.fmt.allocPrint(self.allocator,
                        \\CURRENT PLAN STATE:
                        \\{s}
                        \\
                        \\Find which step matches your task below and update it when done.
                        \\
                    , .{p}) catch ""
                else
                    "",
                task_val.string,
            },
        ) catch return .{
            .content = "summon_subagent: out of memory",
            .is_error = true,
        };

        const model_dup: ?[]const u8 = if (model_val) |m|
            (self.allocator.dupe(u8, m) catch null)
        else
            null;

        var job_id: [36]u8 = undefined;
        generateUUID(&job_id);

        wp.enqueueBackgroundChat(.{
            .job_id = job_id,
            .message = wrapped_task,
            .session_id = parent_session_id.*,
            .model_override = model_dup,
            .callback_channel = null,
            .allowed_tools = null,
            .is_subagent = true,
            .cancelled = std.atomic.Value(bool).init(false),
        });

        spawned_ids.append(self.allocator, job_id) catch {};

        std.log.info("Spawned subagent job {s}", .{job_id});

        const result_text = std.fmt.allocPrint(
            self.allocator,
            "Subagent dispatched. Job ID: {s}. The user will receive the result automatically when it completes — you do not need to wait.",
            .{job_id},
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

            // Hook 4: Embed the assistant response for future semantic search
            // (user message gets embedded too, but by the message store hook)
            if (assistant_response.len > 50) {
                wp.enqueueEmbed("message", 0, assistant_response, null);
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

        wp.enqueueBackgroundChat(.{
            .job_id = job_id,
            .message = self.allocator.dupe(u8, req.message) catch {
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
            .is_subagent = req.is_subagent,
            .cancelled = std.atomic.Value(bool).init(false),
        });

        return .{ .response = .{ .background_queued = .{
            .job_id = &job_id,
            .session_id = &session_id,
        } } };
    }

    fn generateUUID(buf: *[36]u8) void {
        var random_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
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
        message: []const u8,
        session_id: ?[]const u8,
        model_override: ?[]const u8,
        allowed_tools: ?[]const u8,
        is_subagent: bool,
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
            "terse and factual; no emojis, no greetings, no 'let me...'."
        else
            "You are running as a background agent. " ++
            "Investigate thoroughly using file_read before making changes. " ++
            "When you are ready to modify files or run commands, clearly state your plan first, " ++
            "then proceed. The user will be prompted to approve the first mutation — " ++
            "after approval, you have full autonomy to iterate (edit, build, test, fix) " ++
            "until the task is complete.";
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
        } }, null, confirmer);

        return switch (result) {
            .chat => |chat| blk: {
                // For subagent results, run a voice pass so the user-facing
                // text reads in the parent persona's voice instead of as a
                // dry technical dump. Only fires for subagents (user-initiated
                // /api/chat/background calls keep their raw output).
                var final_text = chat.text;
                if (is_subagent) {
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
            .response => |resp| .{
                .ok = false,
                .error_message = switch (resp) {
                    .error_resp => |e| e.message,
                    else => "unexpected response type",
                },
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
        const now = std.time.timestamp();
        const uptime: u64 = @intCast(now - self.start_time);
        const count = self.session_store.sessionCount() catch 0;

        return .{ .response = .{ .status = .{
            .version = "0.2.0",
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

    /// Heuristic tool selection keeps the schema budget small on the first request.
    fn selectToolDefinitionsForMessage(self: *Engine, user_message: []const u8) ?[]const api.messages.ToolDefinition {
        var names: [12][]const u8 = undefined;
        var count: usize = 0;

        addToolName(&names, &count, "calc");
        addToolName(&names, &count, "introspect");

        const lower = std.ascii.allocLowerString(self.allocator, user_message) catch return self.tool_registry.getToolDefinitions();
        defer self.allocator.free(lower);

        const coding = containsAny(lower, &.{
            "code", "file", "bug", "fix", "build", "compile", "test", "zig", "refactor", "implement", "patch",
        });
        const research = containsAny(lower, &.{ "research", "search", "look up", "investigate", "compare", "find sources" });
        const shopping = containsAny(lower, &.{ "buy", "price", "amazon", "shopping", "product" });
        const memes = containsAny(lower, &.{ "meme", "joke", "shitpost" });

        if (coding) {
            addToolName(&names, &count, "file_read");
            addToolName(&names, &count, "file_write");
            addToolName(&names, &count, "file_diff");
            addToolName(&names, &count, "bash");
            addToolName(&names, &count, "zig_test");
            addToolName(&names, &count, "rebuild");
        }
        if (research) addToolName(&names, &count, "research_tool");
        if (shopping) addToolName(&names, &count, "amazon_search");
        if (memes) addToolName(&names, &count, "meme_tool");

        return self.tool_registry.getToolDefinitionsFiltered(names[0..count]) orelse self.tool_registry.getToolDefinitions();
    }

    /// Follow-up rounds keep only the active tool chain and close companions instead of every schema.
    fn selectFollowupToolDefinitions(
        self: *Engine,
        user_message: []const u8,
        tool_uses: []const api.messages.ToolUseInfo,
    ) ?[]const api.messages.ToolDefinition {
        var names: [12][]const u8 = undefined;
        var count: usize = 0;

        addToolName(&names, &count, "calc");
        addToolName(&names, &count, "introspect");

        for (tool_uses) |tool_use| {
            addToolName(&names, &count, tool_use.name);
            if (std.mem.eql(u8, tool_use.name, "file_read")) {
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
                addToolName(&names, &count, "file_read");
                addToolName(&names, &count, "rebuild");
                addToolName(&names, &count, "zig_test");
            } else if (std.mem.eql(u8, tool_use.name, "rebuild")) {
                addToolName(&names, &count, "bash");
                addToolName(&names, &count, "zig_test");
            } else if (std.mem.eql(u8, tool_use.name, "zig_test")) {
                addToolName(&names, &count, "bash");
                addToolName(&names, &count, "file_read");
                addToolName(&names, &count, "file_diff");
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

fn isLightweightTool(name: []const u8) bool {
    const lightweight = [_][]const u8{
        "file_read",
        "introspect",
        "calc",
        "research",
        "meme_tool",
        "amazon_search",
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

fn addToolName(buffer: *[12][]const u8, count: *usize, name: []const u8) void {
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
