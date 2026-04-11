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

    // Threads
    summarize_thread: ?std.Thread = null,
    extract_thread: ?std.Thread = null,
    embed_thread: ?std.Thread = null,

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

        std.log.info("Worker pool started", .{});
    }

    /// Stop all workers gracefully: signal stop → drain queues → join threads.
    pub fn stop(self: *WorkerPool) void {
        self.running = false;

        // Wake all threads so they check the running flag
        self.summarize_queue.signal();
        self.extract_queue.signal();
        self.embed_queue.signal();

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
        };
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
