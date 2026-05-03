const std = @import("std");
const storage = @import("storage");
const summarizer_mod = @import("summarizer.zig");
const extractor_mod = @import("extractor.zig");
const embedder_mod = @import("embedder.zig");

/// Unified worker pool. Manages background threads for async processing.
///
/// Each worker type has a dedicated thread + queue. Post-response hooks
/// enqueue work items instead of calling workers directly, so the chat
/// response isn't blocked by LLM calls or embedding generation.
///
/// Public API: enqueue methods are thread-safe (mutex-protected queues).
pub const WorkerPool = struct {
    allocator: std.mem.Allocator,
    summarizer: ?*summarizer_mod.Summarizer,
    extractor: ?*extractor_mod.Extractor,
    embedder: ?*embedder_mod.Embedder,
    compaction_gate: CompactionGate = .{},

    // Queues (mutex-protected ring buffers)
    summarize_queue: Queue(SummarizeJob),
    extract_queue: Queue(ExtractJob),
    embed_queue: Queue(EmbedJob),
    background_chat_queue: Queue(BackgroundChatJob),

    // Threads
    summarize_thread: ?std.Thread = null,
    extract_thread: ?std.Thread = null,
    embed_thread: ?std.Thread = null,
    background_chat_thread: ?std.Thread = null,

    // Background chat worker context (set via setBackgroundChatContext)
    bg_process_fn: ?*const fn (
        ctx: *anyopaque,
        job_id: *const [36]u8,
        message: []const u8,
        session_id: ?[]const u8,
        model_override: ?[]const u8,
        allowed_tools: ?[]const u8,
        is_subagent: bool,
        is_explore: bool,
        confirm_ctx: ?*anyopaque,
        confirm_fn: ?*const fn (ctx: *anyopaque, tool_name: []const u8, tool_id: []const u8, input_preview: []const u8) bool,
    ) BackgroundChatOutput = null,
    bg_process_ctx: ?*anyopaque = null,

    // Background job result store
    result_store: ResultStore = .{},

    // Per-job tool event log for live transparency
    tool_event_log: ToolEventLog = .{},
    // The job_id currently being processed by the background chat thread.
    // Safe because there is exactly one background chat worker thread.
    active_job_id: ?[36]u8 = null,

    // Per-session index of subagent jobs (active + recently completed).
    subagent_registry: SubagentRegistry = .{},

    // Tool confirmation gate (one at a time — single background thread)
    confirmation_mutex: std.Thread.Mutex = .{},
    confirmation_cond: std.Thread.Condition = .{},
    current_confirmation: ?PendingConfirmation = null,

    running: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        summarizer: ?*summarizer_mod.Summarizer,
        extractor: ?*extractor_mod.Extractor,
        embedder: ?*embedder_mod.Embedder,
    ) WorkerPool {
        return .{
            .allocator = allocator,
            .summarizer = summarizer,
            .extractor = extractor,
            .embedder = embedder,
            .summarize_queue = Queue(SummarizeJob).init(),
            .extract_queue = Queue(ExtractJob).init(),
            .embed_queue = Queue(EmbedJob).init(),
            .background_chat_queue = Queue(BackgroundChatJob).init(),
        };
    }

    // ================================================================
    // LIFECYCLE
    // ================================================================

    /// Start all worker threads.
    pub fn start(self: *WorkerPool) void {
        self.running = true;

        if (self.summarizer != null) {
            if (std.Thread.spawn(.{}, runSummarizeWorker, .{self})) |t| {
                self.summarize_thread = t;
            } else |err| {
                std.log.err("Failed to spawn summarize worker: {}", .{err});
            }
        }

        if (self.extractor != null) {
            if (std.Thread.spawn(.{}, runExtractWorker, .{self})) |t| {
                self.extract_thread = t;
            } else |err| {
                std.log.err("Failed to spawn extract worker: {}", .{err});
            }
        }

        if (self.embedder != null) {
            if (std.Thread.spawn(.{}, runEmbedWorker, .{self})) |t| {
                self.embed_thread = t;
            } else |err| {
                std.log.err("Failed to spawn embed worker: {}", .{err});
            }
        }

        if (self.bg_process_fn != null) {
            if (std.Thread.spawn(.{}, runBackgroundChatWorker, .{self})) |t| {
                self.background_chat_thread = t;
            } else |err| {
                std.log.err("Failed to spawn background chat worker: {}", .{err});
            }
        }

        std.log.info("Worker pool started", .{});
    }

    /// Stop all workers gracefully: signal stop → drain queues → join threads.
    pub fn stop(self: *WorkerPool) void {
        self.running = false;

        // Wake all threads so they check the running flag
        self.summarize_queue.signal();
        self.extract_queue.signal();
        self.embed_queue.signal();
        self.background_chat_queue.signal();

        if (self.summarize_thread) |t| {
            t.join();
            self.summarize_thread = null;
        }
        if (self.extract_thread) |t| {
            t.join();
            self.extract_thread = null;
        }
        if (self.embed_thread) |t| {
            t.join();
            self.embed_thread = null;
        }
        if (self.background_chat_thread) |t| {
            t.join();
            self.background_chat_thread = null;
        }

        std.log.info("Worker pool stopped", .{});
    }

    // ================================================================
    // PUBLIC ENQUEUE API — thread-safe, non-blocking
    // ================================================================

    /// Queue a rolling context update (runs on summarizer thread).
    pub fn enqueueRollingUpdate(self: *WorkerPool, project_id: i64, session_id: [36]u8, user_msg: []const u8, assistant_resp: []const u8) void {
        self.summarize_queue.push(.{
            .job_type = .rolling_update,
            .project_id = project_id,
            .session_id = session_id,
            .text_a = self.allocator.dupe(u8, user_msg) catch return,
            .text_b = self.allocator.dupe(u8, assistant_resp) catch return,
        });
    }

    /// Queue a session summarization check (runs on summarizer thread).
    pub fn enqueueMaybeSummarize(self: *WorkerPool, session_id: [36]u8) void {
        self.summarize_queue.push(.{
            .job_type = .maybe_summarize,
            .project_id = null,
            .session_id = session_id,
            .text_a = null,
            .text_b = null,
        });
    }

    /// Queue knowledge extraction (runs on extractor thread).
    pub fn enqueueExtract(self: *WorkerPool, session_id: [36]u8, user_msg: []const u8, assistant_resp: []const u8) void {
        self.extract_queue.push(.{
            .session_id = session_id,
            .text_a = self.allocator.dupe(u8, user_msg) catch return,
            .text_b = self.allocator.dupe(u8, assistant_resp) catch return,
        });
    }

    /// Queue content embedding (runs on embedder thread).
    pub fn enqueueEmbed(self: *WorkerPool, source_type: []const u8, source_id: i64, text: []const u8, context_header: ?[]const u8) void {
        self.embed_queue.push(.{
            .source_type = self.allocator.dupe(u8, source_type) catch return,
            .source_id = source_id,
            .text = self.allocator.dupe(u8, text) catch return,
            .context_header = if (context_header) |h| (self.allocator.dupe(u8, h) catch null) else null,
        });
    }

    /// Get queue depths for health monitoring.
    pub fn getQueueDepths(self: *WorkerPool) QueueDepths {
        return .{
            .summarize = self.summarize_queue.len(),
            .extract = self.extract_queue.len(),
            .embed = self.embed_queue.len(),
            .background_chat = self.background_chat_queue.len(),
        };
    }

    /// Queue a background chat job (runs full tool loop on dedicated thread).
    pub fn enqueueBackgroundChat(self: *WorkerPool, job: BackgroundChatJob) void {
        self.background_chat_queue.push(job);
    }

    /// Get result for a background job by ID.
    pub fn getBackgroundResult(self: *WorkerPool, job_id: *const [36]u8) ?BackgroundChatResult {
        return self.result_store.get(job_id);
    }

    /// Cancel a background job by setting its cancelled flag.
    pub fn cancelBackgroundJob(self: *WorkerPool, job_id: *const [36]u8) bool {
        // Check the queue for pending jobs
        self.background_chat_queue.mutex.lock();
        defer self.background_chat_queue.mutex.unlock();
        var idx = self.background_chat_queue.head;
        var checked: usize = 0;
        while (checked < self.background_chat_queue.count) : (checked += 1) {
            if (std.mem.eql(u8, &self.background_chat_queue.items[idx].job_id, job_id)) {
                self.background_chat_queue.items[idx].cancelled.store(true, .release);
                return true;
            }
            idx = (idx + 1) % Queue(BackgroundChatJob).CAPACITY;
        }
        return false;
    }

    /// Wire background chat context. Called from main.zig after engine init.
    pub fn setBackgroundChatContext(
        self: *WorkerPool,
        ctx: *anyopaque,
        process_fn: *const fn (
            ctx: *anyopaque,
            job_id: *const [36]u8,
            message: []const u8,
            session_id: ?[]const u8,
            model_override: ?[]const u8,
            allowed_tools: ?[]const u8,
            is_subagent: bool,
            is_explore: bool,
            confirm_ctx: ?*anyopaque,
            confirm_fn: ?*const fn (ctx: *anyopaque, tool_name: []const u8, tool_id: []const u8, input_preview: []const u8) bool,
        ) BackgroundChatOutput,
    ) void {
        self.bg_process_ctx = ctx;
        self.bg_process_fn = process_fn;
    }

    /// Block until user approves/denies a tool, or 60s timeout (auto-deny).
    pub fn waitForConfirmation(self: *WorkerPool, job_id: *const [36]u8, tool_name: []const u8, tool_id: []const u8, input_preview: []const u8) bool {
        self.confirmation_mutex.lock();
        defer self.confirmation_mutex.unlock();

        self.current_confirmation = .{
            .job_id = job_id.*,
            .tool_name = tool_name,
            .tool_id = tool_id,
            .input_preview = input_preview,
            .approved = null,
        };

        var waited: u64 = 0;
        const max_wait: u64 = 60;
        while (waited < max_wait) : (waited += 1) {
            if (self.current_confirmation) |c| {
                if (c.approved != null) break;
            } else break;
            self.confirmation_cond.timedWait(&self.confirmation_mutex, std.time.ns_per_s) catch {};
        }

        const approved = if (self.current_confirmation) |c| c.approved orelse false else false;
        self.current_confirmation = null;
        return approved;
    }

    /// Resolve a pending confirmation from an API call.
    pub fn resolveConfirmation(self: *WorkerPool, job_id: *const [36]u8, tool_id: []const u8, approved: bool) bool {
        self.confirmation_mutex.lock();
        defer self.confirmation_mutex.unlock();

        if (self.current_confirmation) |*c| {
            if (std.mem.eql(u8, &c.job_id, job_id) and std.mem.eql(u8, c.tool_id, tool_id)) {
                c.approved = approved;
                self.confirmation_cond.signal();
                return true;
            }
        }
        return false;
    }

    /// Push a tool event for the currently-active background job.
    /// No-op if no job is active (i.e. not running on the bg chat thread).
    pub fn pushToolEvent(self: *WorkerPool, event: ToolEvent) void {
        if (self.active_job_id) |*jid| {
            self.tool_event_log.push(jid, event);
        }
    }

    /// Get tool events for a job starting from cursor (for polling).
    pub fn getToolEvents(self: *WorkerPool, job_id: *const [36]u8, cursor: usize) ToolEventLog.EventSlice {
        return self.tool_event_log.getEvents(job_id, cursor);
    }

    /// Register a subagent job in the per-session index. Called by the engine
    /// when summon_subagent enqueues a BackgroundChatJob.
    pub fn registerSubagent(
        self: *WorkerPool,
        job_id: *const [36]u8,
        parent_session_id: *const [36]u8,
        is_explore: bool,
        brief: []const u8,
    ) void {
        self.subagent_registry.register(job_id, parent_session_id, is_explore, brief);
    }

    /// Update a subagent's lifecycle status. Called from the bg chat worker.
    pub fn markSubagentStatus(self: *WorkerPool, job_id: *const [36]u8, status: SubagentStatus) void {
        self.subagent_registry.markStatus(job_id, status);
    }

    /// Request a subagent to stop at its next round boundary. Returns true if
    /// the job was found in the registry. The engine's round loop polls
    /// isSubagentStopRequested between rounds and emits accumulated state.
    pub fn requestSubagentStop(self: *WorkerPool, job_id: *const [36]u8, reason: []const u8) bool {
        return self.subagent_registry.requestStop(job_id, reason);
    }

    /// Update the most-recent tool name for a subagent. Owned in fixed buffer.
    pub fn markSubagentLastTool(self: *WorkerPool, job_id: *const [36]u8, tool_name: []const u8) void {
        self.subagent_registry.markLastTool(job_id, tool_name);
    }

    /// Whether a stop has been requested for the given subagent job.
    pub fn isSubagentStopRequested(self: *WorkerPool, job_id: *const [36]u8) bool {
        return self.subagent_registry.isStopRequested(job_id);
    }

    /// Queue a redirect message for the given subagent. Returns true on success.
    pub fn queueSubagentRedirect(self: *WorkerPool, job_id: *const [36]u8, instruction: []const u8) bool {
        return self.subagent_registry.queueRedirect(job_id, instruction);
    }

    /// Consume any pending redirect for the given subagent. Returns the
    /// number of bytes copied into `out` (0 if none pending).
    pub fn consumeSubagentRedirect(self: *WorkerPool, job_id: *const [36]u8, out: []u8) usize {
        return self.subagent_registry.consumeRedirect(job_id, out);
    }

    /// Snapshot all subagent records for a parent session into out (capacity = SubagentRegistry.MAX_PER_SESSION).
    /// Returns the number of records written.
    pub fn snapshotSubagentsForSession(
        self: *WorkerPool,
        parent_session_id: *const [36]u8,
        out: *[SubagentRegistry.MAX_PER_SESSION]SubagentRecord,
    ) usize {
        return self.subagent_registry.forSession(parent_session_id, out);
    }

    /// Look up a single subagent record by job_id.
    pub fn getSubagent(self: *WorkerPool, job_id: *const [36]u8) ?SubagentRecord {
        return self.subagent_registry.getById(job_id);
    }

    /// Format the Active Subagents context layer for a given parent session.
    /// Returns null when there are no active or recently-completed subagents.
    /// Caller owns the returned allocation. Caps total length at ~LAYER_CAP bytes.
    pub fn formatActiveSubagentsLayer(
        self: *WorkerPool,
        allocator: std.mem.Allocator,
        parent_session_id: *const [36]u8,
    ) ?[]u8 {
        const LAYER_CAP: usize = 1024;
        const KEEP_COMPLETED_SECS: i64 = 30 * 60;
        const MAX_COMPLETED_SHOWN: usize = 5;

        var records: [SubagentRegistry.MAX_PER_SESSION]SubagentRecord = undefined;
        const n = self.subagent_registry.forSession(parent_session_id, &records);
        if (n == 0) return null;

        const now = std.time.timestamp();

        // Partition into active vs eligible-completed; sort completed newest-first.
        var active_idx: [SubagentRegistry.MAX_PER_SESSION]usize = undefined;
        var active_n: usize = 0;
        var done_idx: [SubagentRegistry.MAX_PER_SESSION]usize = undefined;
        var done_n: usize = 0;
        for (records[0..n], 0..) |rec, i| {
            switch (rec.status) {
                .pending, .running => {
                    active_idx[active_n] = i;
                    active_n += 1;
                },
                .completed, .failed, .stopped => {
                    if (rec.completed_at) |ct| {
                        if ((now - ct) <= KEEP_COMPLETED_SECS) {
                            done_idx[done_n] = i;
                            done_n += 1;
                        }
                    }
                },
            }
        }
        if (active_n == 0 and done_n == 0) return null;

        // Sort completed by completed_at desc.
        std.sort.insertion(usize, done_idx[0..done_n], records[0..n], struct {
            fn lt(ctx: []const SubagentRecord, a: usize, b: usize) bool {
                const ca = ctx[a].completed_at orelse 0;
                const cb = ctx[b].completed_at orelse 0;
                return ca > cb;
            }
        }.lt);
        const done_show = @min(done_n, MAX_COMPLETED_SHOWN);

        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        w.writeAll("Active Subagents (auto-injected; use subagent_inspect/stop to manage):\n") catch {};

        for (active_idx[0..active_n]) |i| {
            self.appendSubagentLine(allocator, &records[i], now, w) catch {};
            if (buf.items.len > LAYER_CAP) break;
        }
        if (done_show > 0 and buf.items.len < LAYER_CAP) {
            w.writeAll("Recently completed:\n") catch {};
            for (done_idx[0..done_show]) |i| {
                self.appendSubagentLine(allocator, &records[i], now, w) catch {};
                if (buf.items.len > LAYER_CAP) break;
            }
        }

        // Truncate if we ran over.
        if (buf.items.len > LAYER_CAP) {
            buf.shrinkRetainingCapacity(LAYER_CAP);
            buf.appendSlice(allocator, "…\n") catch {};
        }

        return buf.toOwnedSlice(allocator) catch null;
    }

    /// Format a single subagent's status as a one-line summary.
    /// Caller owns the returned allocation.
    pub fn formatSubagentSummary(
        self: *WorkerPool,
        allocator: std.mem.Allocator,
        job_id: *const [36]u8,
    ) ?[]u8 {
        const rec = self.subagent_registry.getById(job_id) orelse return null;
        const now = std.time.timestamp();
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        self.appendSubagentLine(allocator, &rec, now, buf.writer(allocator)) catch return null;
        return buf.toOwnedSlice(allocator) catch null;
    }

    fn appendSubagentLine(
        self: *WorkerPool,
        allocator: std.mem.Allocator,
        rec: *const SubagentRecord,
        now: i64,
        w: anytype,
    ) !void {
        _ = self;
        _ = allocator;
        const status_str = switch (rec.status) {
            .pending => "queued",
            .running => "running",
            .completed => "done",
            .failed => "failed",
            .stopped => "stopped",
        };
        const mode_str = if (rec.is_explore) "explore" else "execute";
        const age_secs: i64 = switch (rec.status) {
            .pending, .running => now - rec.spawned_at,
            else => now - (rec.completed_at orelse rec.spawned_at),
        };
        const age_buf = formatAge(age_secs);

        try w.print("- [{s} {s}] job {s} {s}: {s}", .{
            status_str,
            age_buf.slice(),
            rec.job_id[0..8],
            mode_str,
            rec.briefSlice(),
        });

        // Append last tool for active jobs (read from owned fixed buffer).
        if (rec.status == .running or rec.status == .pending) {
            if (rec.last_tool_len > 0) {
                try w.print(" | last_tool={s}", .{rec.lastToolSlice()});
            }
        } else if (rec.status == .stopped and rec.stop_reason_len > 0) {
            try w.print(" | reason={s}", .{rec.stopReasonSlice()});
        }

        try w.writeAll("\n");
    }

    const AgeBuf = struct {
        buf: [16]u8 = undefined,
        len: usize = 0,
        pub fn slice(self: *const AgeBuf) []const u8 {
            return self.buf[0..self.len];
        }
    };

    fn formatAge(secs: i64) AgeBuf {
        var a = AgeBuf{};
        const abs_s: i64 = if (secs < 0) 0 else secs;
        if (abs_s < 60) {
            a.len = (std.fmt.bufPrint(&a.buf, "{d}s", .{abs_s}) catch return a).len;
        } else if (abs_s < 3600) {
            a.len = (std.fmt.bufPrint(&a.buf, "{d}m", .{@divTrunc(abs_s, 60)}) catch return a).len;
        } else {
            a.len = (std.fmt.bufPrint(&a.buf, "{d}h", .{@divTrunc(abs_s, 3600)}) catch return a).len;
        }
        return a;
    }

    /// Check if there's a pending confirmation for a given job.
    pub fn getPendingConfirmation(self: *WorkerPool, job_id: *const [36]u8) ?PendingConfirmation {
        self.confirmation_mutex.lock();
        defer self.confirmation_mutex.unlock();
        if (self.current_confirmation) |c| {
            if (std.mem.eql(u8, &c.job_id, job_id) and c.approved == null) return c;
        }
        return null;
    }

    // ================================================================
    // WORKER THREADS
    // ================================================================

    fn runSummarizeWorker(self: *WorkerPool) void {
        std.log.info("Summarize worker started", .{});
        while (self.running) {
            if (self.summarize_queue.pop()) |job| {
                if (self.summarizer) |s| {
                    switch (job.job_type) {
                        .rolling_update => {
                            if (job.project_id) |pid| {
                                s.updateRollingContext(pid, &job.session_id, job.text_a orelse "", job.text_b orelse "") catch {};
                            }
                        },
                        .maybe_summarize => {
                            if (!self.compaction_gate.deferIfStreaming(job.session_id)) {
                                s.maybeSummarizeSession(&job.session_id);
                            }
                        },
                    }
                }
                // Free allocated strings
                if (job.text_a) |t| self.allocator.free(t);
                if (job.text_b) |t| self.allocator.free(t);
            } else {
                // No work — wait for signal or timeout
                self.summarize_queue.waitOrTimeout(100_000_000); // 100ms
            }
        }
        // Drain remaining items
        while (self.summarize_queue.pop()) |job| {
            if (self.summarizer) |s| {
                switch (job.job_type) {
                    .rolling_update => {
                        if (job.project_id) |pid| {
                            s.updateRollingContext(pid, &job.session_id, job.text_a orelse "", job.text_b orelse "") catch {};
                        }
                    },
                    .maybe_summarize => {
                        if (!self.compaction_gate.deferIfStreaming(job.session_id)) {
                            s.maybeSummarizeSession(&job.session_id);
                        }
                    },
                }
            }
            if (job.text_a) |t| self.allocator.free(t);
            if (job.text_b) |t| self.allocator.free(t);
        }
        std.log.info("Summarize worker stopped", .{});
    }

    fn runExtractWorker(self: *WorkerPool) void {
        std.log.info("Extract worker started", .{});
        while (self.running) {
            if (self.extract_queue.pop()) |job| {
                if (self.extractor) |e| {
                    _ = e.extractFromExchange(&job.session_id, job.text_a orelse "", job.text_b orelse "") catch {};
                }
                if (job.text_a) |t| self.allocator.free(t);
                if (job.text_b) |t| self.allocator.free(t);
            } else {
                self.extract_queue.waitOrTimeout(100_000_000);
            }
        }
        while (self.extract_queue.pop()) |job| {
            if (self.extractor) |e| {
                _ = e.extractFromExchange(&job.session_id, job.text_a orelse "", job.text_b orelse "") catch {};
            }
            if (job.text_a) |t| self.allocator.free(t);
            if (job.text_b) |t| self.allocator.free(t);
        }
        std.log.info("Extract worker stopped", .{});
    }

    fn runEmbedWorker(self: *WorkerPool) void {
        std.log.info("Embed worker started", .{});
        while (self.running) {
            if (self.embed_queue.pop()) |job| {
                if (self.embedder) |e| {
                    _ = e.embedAndStore(job.source_type, job.source_id, job.text, job.context_header) catch {};
                }
                self.allocator.free(job.source_type);
                self.allocator.free(job.text);
                if (job.context_header) |h| self.allocator.free(h);
            } else {
                self.embed_queue.waitOrTimeout(100_000_000);
            }
        }
        while (self.embed_queue.pop()) |job| {
            if (self.embedder) |e| {
                _ = e.embedAndStore(job.source_type, job.source_id, job.text, job.context_header) catch {};
            }
            self.allocator.free(job.source_type);
            self.allocator.free(job.text);
            if (job.context_header) |h| self.allocator.free(h);
        }
        std.log.info("Embed worker stopped", .{});
    }

    const BgConfirmCtx = struct {
        pool: *WorkerPool,
        job_id: *const [36]u8,
        job_approved: bool = false,
    };

    fn bgConfirmCallback(ctx_ptr: *anyopaque, tool_name: []const u8, tool_id: []const u8, input_preview: []const u8) bool {
        const confirm_ctx: *BgConfirmCtx = @ptrCast(@alignCast(ctx_ptr));
        if (confirm_ctx.job_approved) return true;
        const approved = confirm_ctx.pool.waitForConfirmation(confirm_ctx.job_id, tool_name, tool_id, input_preview);
        if (approved) confirm_ctx.job_approved = true;
        return approved;
    }

    fn runBackgroundChatWorker(self: *WorkerPool) void {
        std.log.info("Background chat worker started", .{});

        const process_fn = self.bg_process_fn orelse {
            std.log.err("Background chat: no process function configured", .{});
            return;
        };
        const process_ctx = self.bg_process_ctx orelse return;

        while (self.running) {
            if (self.background_chat_queue.pop()) |job| {
                if (job.cancelled.load(.acquire)) {
                    self.freeJobStrings(job);
                    continue;
                }

                std.log.info("Background chat: processing job {s}", .{job.job_id[0..8]});

                // Track active job for tool event logging
                self.tool_event_log.startJob(&job.job_id);
                self.active_job_id = job.job_id;

                // Transition subagent registry status to running (no-op for non-subagent jobs).
                if (job.is_subagent) {
                    self.subagent_registry.markStatus(&job.job_id, .running);
                }

                var confirm_ctx = BgConfirmCtx{ .pool = self, .job_id = &job.job_id };
                const output = process_fn(
                    process_ctx,
                    &job.job_id,
                    job.message,
                    &job.session_id,
                    job.model_override,
                    job.allowed_tools,
                    job.is_subagent,
                    job.is_explore,
                    @ptrCast(&confirm_ctx),
                    &bgConfirmCallback,
                );

                // Auto-chain: if this was a successful explore subagent and the
                // dispatcher asked for chaining, run a dispatcher continuation
                // turn. The continuation ingests the brief as a synthetic user
                // message and its model-generated response replaces the raw
                // brief as the stored result — so the polling adapter sees a
                // dispatcher reply instead of a JSON dump.
                var final_output = output;
                var continuation_msg_opt: ?[]u8 = null;
                if (output.ok and job.auto_chain and job.is_explore) {
                    const brief = output.text orelse "";
                    const cont_msg = std.fmt.allocPrint(
                        self.allocator,
                        \\[EXPLORE SUBAGENT RESULT — synthetic continuation]
                        \\
                        \\A prior explore subagent you dispatched has returned its 3-layer brief. It is
                        \\included below verbatim. The user is still waiting for your reply to their
                        \\original request (visible earlier in this session). Using this brief:
                        \\
                        \\- If the user's intent was clear and actionable, summon_subagent(mode='execute')
                        \\  now with the findings: drop layer2_facts + layer3_evidence into known_facts,
                        \\  layer1_map paths into target_files, and add a crisp task + acceptance.
                        \\- If the user asked you to 'explore first', 'show me the plan', or similar, DO
                        \\  NOT summon execute. Instead, write a concise plain-text summary of what you
                        \\  found (key files, what needs to change, any risks) and ask for their
                        \\  green-light to proceed.
                        \\
                        \\Your reply will be sent directly to the user — keep it brief and natural in
                        \\your normal voice. Do not quote the raw JSON back at them.
                        \\
                        \\--- BRIEF ---
                        \\{s}
                        \\--- END BRIEF ---
                    ,
                        .{brief},
                    ) catch null;

                    if (cont_msg) |cm| {
                        continuation_msg_opt = cm;
                        // Run dispatcher continuation. is_subagent=false so the
                        // engine pulls session history and applies the normal
                        // background-agent adapter context; is_explore=false so
                        // the voice-pass (if applicable) runs.
                        var cont_confirm_ctx = BgConfirmCtx{ .pool = self, .job_id = &job.job_id };
                        const cont_output = process_fn(
                            process_ctx,
                            &job.job_id,
                            cm,
                            &job.session_id,
                            job.model_override,
                            job.chain_allowed_tools orelse job.allowed_tools,
                            false,
                            false,
                            @ptrCast(&cont_confirm_ctx),
                            &bgConfirmCallback,
                        );
                        if (cont_output.ok) {
                            // Free the brief — we're replacing it with the continuation response.
                            if (output.text) |t| self.allocator.free(t);
                            final_output = cont_output;
                            std.log.info("Background chat: job {s} auto-chained dispatcher continuation", .{job.job_id[0..8]});
                        } else {
                            // Continuation failed — keep the raw brief as the result so the user
                            // at least sees something. Log the chain failure.
                            std.log.err("Background chat: auto-chain continuation failed for job {s}: {s}", .{
                                job.job_id[0..8], cont_output.error_message orelse "unknown",
                            });
                        }
                    }
                }

                // Clear active job tracking
                self.active_job_id = null;
                self.tool_event_log.endJob(&job.job_id);

                if (job.is_subagent) {
                    const final_status: SubagentStatus = if (final_output.ok)
                        (if (self.subagent_registry.isStopRequested(&job.job_id)) .stopped else .completed)
                    else
                        .failed;
                    self.subagent_registry.markStatus(&job.job_id, final_status);
                }

                if (final_output.ok) {
                    self.result_store.put(.{
                        .job_id = job.job_id,
                        .status = .completed,
                        .text = final_output.text,
                        .model = final_output.model,
                        .input_tokens = final_output.input_tokens,
                        .output_tokens = final_output.output_tokens,
                        .callback_channel = job.callback_channel,
                        .timestamp = std.time.timestamp(),
                    });
                    std.log.info("Background chat: job {s} completed ({d} in / {d} out tokens)", .{
                        job.job_id[0..8], final_output.input_tokens, final_output.output_tokens,
                    });
                } else {
                    self.result_store.put(.{
                        .job_id = job.job_id,
                        .status = .failed,
                        .text = final_output.error_message,
                        .model = null,
                        .input_tokens = 0,
                        .output_tokens = 0,
                        .callback_channel = job.callback_channel,
                        .timestamp = std.time.timestamp(),
                    });
                    std.log.err("Background chat: job {s} failed: {s}", .{
                        job.job_id[0..8], final_output.error_message orelse "unknown error",
                    });
                }

                // Free owned job strings (message, model_override, continuation msg, chain tools)
                // callback_channel ownership transfers to the result
                self.allocator.free(job.message);
                if (job.model_override) |mo| self.allocator.free(mo);
                if (job.chain_allowed_tools) |cat| self.allocator.free(cat);
                if (continuation_msg_opt) |cm| self.allocator.free(cm);
            } else {
                self.background_chat_queue.waitOrTimeout(100_000_000);
            }
        }

        // Drain remaining jobs
        while (self.background_chat_queue.pop()) |job| {
            self.freeJobStrings(job);
        }
        std.log.info("Background chat worker stopped", .{});
    }

    fn freeJobStrings(self: *WorkerPool, job: BackgroundChatJob) void {
        self.allocator.free(job.message);
        if (job.model_override) |mo| self.allocator.free(mo);
        if (job.callback_channel) |cc| self.allocator.free(cc);
        if (job.allowed_tools) |at| self.allocator.free(at);
        if (job.chain_allowed_tools) |at| self.allocator.free(at);
    }
};

// ================================================================
// JOB TYPES
// ================================================================

const SummarizeJob = struct {
    job_type: enum { rolling_update, maybe_summarize },
    project_id: ?i64,
    session_id: [36]u8,
    text_a: ?[]const u8, // user message (for rolling_update)
    text_b: ?[]const u8, // assistant response (for rolling_update)
};

const ExtractJob = struct {
    session_id: [36]u8,
    text_a: ?[]const u8, // user message
    text_b: ?[]const u8, // assistant response
};

const EmbedJob = struct {
    source_type: []const u8,
    source_id: i64,
    text: []const u8,
    context_header: ?[]const u8,
};

pub const QueueDepths = struct {
    summarize: usize,
    extract: usize,
    embed: usize,
    background_chat: usize,
};

pub const BackgroundChatOutput = struct {
    ok: bool,
    text: ?[]const u8 = null,
    model: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
};

pub const BackgroundChatJob = struct {
    job_id: [36]u8,
    message: []const u8,
    session_id: [36]u8,
    model_override: ?[]const u8,
    callback_channel: ?[]const u8,
    allowed_tools: ?[]const u8,
    /// True when this job was spawned by the summon_subagent tool. The
    /// engine uses this to skip session history and apply a hard
    /// subagent-execution adapter context.
    is_subagent: bool = false,
    /// True when this is an explore-mode subagent. The engine skips the
    /// persona voice-pass on completion so the raw 3-layer JSON brief is
    /// preserved for the dispatcher to consume.
    is_explore: bool = false,
    /// If true and is_explore is true and the subagent completes successfully,
    /// the worker will run a dispatcher continuation turn (feeding the brief
    /// back as a synthetic user message) before storing the final result.
    /// The stored result is the dispatcher's response, so the polling adapter
    /// (Discord/web) sees a model-generated summary / next-action message
    /// instead of the raw JSON brief.
    auto_chain: bool = false,
    /// Allowed tools for the dispatcher continuation (used when auto_chain is
    /// true). Typically the parent dispatcher's tool set. Owned by engine.
    chain_allowed_tools: ?[]const u8 = null,
    cancelled: std.atomic.Value(bool),
};

pub const BackgroundChatResult = struct {
    job_id: [36]u8,
    status: enum { completed, failed, cancelled },
    text: ?[]const u8,
    model: ?[]const u8,
    input_tokens: u32,
    output_tokens: u32,
    callback_channel: ?[]const u8,
    timestamp: i64,
};

pub const PendingConfirmation = struct {
    job_id: [36]u8,
    tool_name: []const u8,
    tool_id: []const u8,
    input_preview: []const u8,
    approved: ?bool,
};

/// A single tool event captured during subagent execution.
pub const ToolEvent = struct {
    event_type: enum { tool_use, tool_result },
    tool_name: []const u8,
    /// For tool_use: the input JSON. For tool_result: the output text.
    content: []const u8,
    is_error: bool = false,
    timestamp: i64,
};

/// Per-job ring buffer of tool events for live transparency.
/// Pollers provide a cursor (number of events already seen) and get back only new ones.
pub const ToolEventLog = struct {
    const MAX_EVENTS = 128;
    const MAX_JOBS = 16;

    pub const EventSlice = struct {
        events: []const ?ToolEvent,
        new_cursor: usize,
    };

    /// Each slot is a job's event buffer.
    entries: [MAX_JOBS]JobEvents = [_]JobEvents{.{}} ** MAX_JOBS,
    mutex: std.Thread.Mutex = .{},

    const JobEvents = struct {
        job_id: [36]u8 = undefined,
        active: bool = false,
        events: [MAX_EVENTS]?ToolEvent = [_]?ToolEvent{null} ** MAX_EVENTS,
        count: usize = 0,
    };

    pub fn startJob(self: *ToolEventLog, job_id: *const [36]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Find empty or evict oldest
        for (&self.entries) |*slot| {
            if (!slot.active) {
                slot.* = .{ .job_id = job_id.*, .active = true };
                return;
            }
        }
        // All full — evict first inactive, or first slot
        self.entries[0] = .{ .job_id = job_id.*, .active = true };
    }

    pub fn endJob(self: *ToolEventLog, job_id: *const [36]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*slot| {
            if (slot.active and std.mem.eql(u8, &slot.job_id, job_id)) {
                slot.active = false;
                return;
            }
        }
    }

    pub fn push(self: *ToolEventLog, job_id: *const [36]u8, event: ToolEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*slot| {
            if (slot.active and std.mem.eql(u8, &slot.job_id, job_id)) {
                if (slot.count < MAX_EVENTS) {
                    slot.events[slot.count] = event;
                    slot.count += 1;
                }
                return;
            }
        }
    }

    /// Get events for a job starting from cursor. Returns slice of events and new cursor.
    pub fn getEvents(self: *ToolEventLog, job_id: *const [36]u8, cursor: usize) EventSlice {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*slot| {
            if (std.mem.eql(u8, &slot.job_id, job_id)) {
                const start = @min(cursor, slot.count);
                return .{
                    .events = slot.events[start..slot.count],
                    .new_cursor = slot.count,
                };
            }
        }
        return .{ .events = &.{}, .new_cursor = cursor };
    }
};

pub const SubagentStatus = enum { pending, running, completed, failed, stopped };

/// One subagent job's record in the per-session registry.
/// Fixed-size strings keep this trivially copyable for snapshot reads.
pub const SubagentRecord = struct {
    job_id: [36]u8,
    parent_session_id: [36]u8,
    is_explore: bool,
    spawned_at: i64,
    completed_at: ?i64 = null,
    status: SubagentStatus = .pending,
    brief: [96]u8 = [_]u8{0} ** 96,
    brief_len: u8 = 0,
    stop_requested: bool = false,
    stop_reason: [80]u8 = [_]u8{0} ** 80,
    stop_reason_len: u8 = 0,

    /// Pending redirect injected by subagent_redirect. Consumed at the next
    /// round boundary by the engine and appended as a user-role message.
    redirect_pending: bool = false,
    redirect_text: [512]u8 = [_]u8{0} ** 512,
    redirect_text_len: u16 = 0,

    /// Most recent tool name observed for this subagent. Owned (fixed buffer)
    /// so reads from the dispatcher are safe across arena boundaries.
    last_tool: [32]u8 = [_]u8{0} ** 32,
    last_tool_len: u8 = 0,

    pub fn briefSlice(self: *const SubagentRecord) []const u8 {
        return self.brief[0..self.brief_len];
    }

    pub fn stopReasonSlice(self: *const SubagentRecord) []const u8 {
        return self.stop_reason[0..self.stop_reason_len];
    }

    pub fn redirectSlice(self: *const SubagentRecord) []const u8 {
        return self.redirect_text[0..self.redirect_text_len];
    }

    pub fn lastToolSlice(self: *const SubagentRecord) []const u8 {
        return self.last_tool[0..self.last_tool_len];
    }
};

/// Tracks subagent jobs by parent session_id. Active + recently completed.
/// Bounded by capacity; oldest completed records are evicted when full.
pub const SubagentRegistry = struct {
    pub const MAX_RECORDS = 64;
    pub const MAX_PER_SESSION = 16;

    entries: [MAX_RECORDS]?SubagentRecord = [_]?SubagentRecord{null} ** MAX_RECORDS,
    mutex: std.Thread.Mutex = .{},

    pub fn register(
        self: *SubagentRegistry,
        job_id: *const [36]u8,
        parent_session_id: *const [36]u8,
        is_explore: bool,
        brief: []const u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var rec = SubagentRecord{
            .job_id = job_id.*,
            .parent_session_id = parent_session_id.*,
            .is_explore = is_explore,
            .spawned_at = std.time.timestamp(),
            .status = .pending,
        };
        const n = @min(brief.len, rec.brief.len);
        @memcpy(rec.brief[0..n], brief[0..n]);
        rec.brief_len = @intCast(n);

        // Find empty slot, or evict oldest completed record.
        var oldest_completed_idx: ?usize = null;
        var oldest_completed_ts: i64 = std.math.maxInt(i64);
        for (self.entries, 0..) |entry, i| {
            if (entry == null) {
                self.entries[i] = rec;
                return;
            }
            const e = entry.?;
            if (e.completed_at) |ct| {
                if (ct < oldest_completed_ts) {
                    oldest_completed_ts = ct;
                    oldest_completed_idx = i;
                }
            }
        }
        if (oldest_completed_idx) |idx| {
            self.entries[idx] = rec;
        } else {
            // All slots active — overwrite slot 0 to bound memory.
            std.log.warn("SubagentRegistry full of active jobs, evicting slot 0", .{});
            self.entries[0] = rec;
        }
    }

    pub fn markStatus(self: *SubagentRegistry, job_id: *const [36]u8, status: SubagentStatus) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.*) |*rec| {
                if (std.mem.eql(u8, &rec.job_id, job_id)) {
                    rec.status = status;
                    if (status == .completed or status == .failed or status == .stopped) {
                        rec.completed_at = std.time.timestamp();
                    }
                    return;
                }
            }
        }
    }

    pub fn requestStop(self: *SubagentRegistry, job_id: *const [36]u8, reason: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.*) |*rec| {
                if (std.mem.eql(u8, &rec.job_id, job_id)) {
                    rec.stop_requested = true;
                    const n = @min(reason.len, rec.stop_reason.len);
                    @memcpy(rec.stop_reason[0..n], reason[0..n]);
                    rec.stop_reason_len = @intCast(n);
                    return true;
                }
            }
        }
        return false;
    }

    /// Queue a redirect for a subagent. Returns true if the job was found.
    /// Overwrites any previous pending redirect (latest wins).
    pub fn queueRedirect(self: *SubagentRegistry, job_id: *const [36]u8, instruction: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.*) |*rec| {
                if (std.mem.eql(u8, &rec.job_id, job_id)) {
                    const n = @min(instruction.len, rec.redirect_text.len);
                    @memcpy(rec.redirect_text[0..n], instruction[0..n]);
                    rec.redirect_text_len = @intCast(n);
                    rec.redirect_pending = true;
                    return true;
                }
            }
        }
        return false;
    }

    /// Consume the pending redirect for a subagent (clears the flag).
    /// Copies the text into out and returns its length, or 0 if none pending.
    pub fn consumeRedirect(self: *SubagentRegistry, job_id: *const [36]u8, out: []u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.*) |*rec| {
                if (std.mem.eql(u8, &rec.job_id, job_id)) {
                    if (!rec.redirect_pending) return 0;
                    const n = @min(rec.redirect_text_len, out.len);
                    @memcpy(out[0..n], rec.redirect_text[0..n]);
                    rec.redirect_pending = false;
                    rec.redirect_text_len = 0;
                    return n;
                }
            }
        }
        return 0;
    }

    pub fn markLastTool(self: *SubagentRegistry, job_id: *const [36]u8, tool_name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.*) |*rec| {
                if (std.mem.eql(u8, &rec.job_id, job_id)) {
                    const n = @min(tool_name.len, rec.last_tool.len);
                    @memcpy(rec.last_tool[0..n], tool_name[0..n]);
                    rec.last_tool_len = @intCast(n);
                    return;
                }
            }
        }
    }

    pub fn isStopRequested(self: *SubagentRegistry, job_id: *const [36]u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.*) |*rec| {
                if (std.mem.eql(u8, &rec.job_id, job_id)) return rec.stop_requested;
            }
        }
        return false;
    }

    pub fn forSession(
        self: *SubagentRegistry,
        parent_session_id: *const [36]u8,
        out: *[MAX_PER_SESSION]SubagentRecord,
    ) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.entries) |entry| {
            if (n >= MAX_PER_SESSION) break;
            if (entry) |rec| {
                if (std.mem.eql(u8, &rec.parent_session_id, parent_session_id)) {
                    out[n] = rec;
                    n += 1;
                }
            }
        }
        return n;
    }

    pub fn getById(self: *SubagentRegistry, job_id: *const [36]u8) ?SubagentRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries) |entry| {
            if (entry) |rec| {
                if (std.mem.eql(u8, &rec.job_id, job_id)) return rec;
            }
        }
        return null;
    }
};

pub const ResultStore = struct {
    const MAX_RESULTS = 64;

    results: [MAX_RESULTS]?BackgroundChatResult = [_]?BackgroundChatResult{null} ** MAX_RESULTS,
    mutex: std.Thread.Mutex = .{},

    pub fn put(self: *ResultStore, result: BackgroundChatResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find empty slot or evict oldest
        var oldest_idx: usize = 0;
        var oldest_ts: i64 = std.math.maxInt(i64);
        for (self.results, 0..) |entry, i| {
            if (entry == null) {
                self.results[i] = result;
                return;
            }
            if (entry.?.timestamp < oldest_ts) {
                oldest_ts = entry.?.timestamp;
                oldest_idx = i;
            }
        }
        // Evict oldest
        if (self.results[oldest_idx]) |old| {
            self.freeResult(old);
        }
        self.results[oldest_idx] = result;
    }

    pub fn get(self: *ResultStore, job_id: *const [36]u8) ?BackgroundChatResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.results) |entry| {
            if (entry) |r| {
                if (std.mem.eql(u8, &r.job_id, job_id)) return r;
            }
        }
        return null;
    }

    fn freeResult(_: ResultStore, _: BackgroundChatResult) void {
        // Results own their text/model strings via the allocator that created them.
        // For simplicity, we let the allocator (GPA) track these — they're small and bounded.
    }
};

pub const CompactionGate = struct {
    pub const MAX_PENDING = 32;

    mutex: std.Thread.Mutex = .{},
    active_streams: usize = 0,
    pending_sessions: [MAX_PENDING][36]u8 = undefined,
    pending_count: usize = 0,

    pub fn beginStreaming(self: *CompactionGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active_streams += 1;
    }

    pub fn endStreaming(self: *CompactionGate, out: *[MAX_PENDING][36]u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.active_streams > 0) {
            self.active_streams -= 1;
        }

        if (self.active_streams != 0 or self.pending_count == 0) {
            return 0;
        }

        const count = self.pending_count;
        for (0..count) |i| {
            out[i] = self.pending_sessions[i];
        }
        self.pending_count = 0;
        return count;
    }

    pub fn deferIfStreaming(self: *CompactionGate, session_id: [36]u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.active_streams == 0) return false;

        for (0..self.pending_count) |i| {
            if (std.mem.eql(u8, &self.pending_sessions[i], &session_id)) {
                return true;
            }
        }

        if (self.pending_count < MAX_PENDING) {
            self.pending_sessions[self.pending_count] = session_id;
            self.pending_count += 1;
        } else {
            std.log.warn("Compaction gate full, dropping deferred session {s}", .{session_id[0..8]});
        }
        return true;
    }
};

// ================================================================
// THREAD-SAFE QUEUE — mutex-protected ring buffer
// ================================================================

fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        const CAPACITY = 256;

        items: [CAPACITY]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        mutex: std.Thread.Mutex = .{},
        condition: std.Thread.Condition = .{},

        pub fn init() Self {
            return .{};
        }

        pub fn push(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count >= CAPACITY) {
                // Queue full — drop oldest item
                std.log.warn("Worker queue full, dropping oldest item", .{});
                self.head = (self.head + 1) % CAPACITY;
                self.count -= 1;
            }

            self.items[self.tail] = item;
            self.tail = (self.tail + 1) % CAPACITY;
            self.count += 1;

            self.condition.signal();
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count == 0) return null;

            const item = self.items[self.head];
            self.head = (self.head + 1) % CAPACITY;
            self.count -= 1;
            return item;
        }

        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }

        pub fn signal(self: *Self) void {
            self.condition.signal();
        }

        pub fn waitOrTimeout(self: *Self, timeout_ns: u64) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count == 0) {
                self.condition.timedWait(&self.mutex, timeout_ns) catch {};
            }
        }
    };
}
