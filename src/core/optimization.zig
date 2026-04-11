const std = @import("std");
const storage = @import("storage");

pub const FileCache = @import("optimization/file_cache.zig").FileCache;
pub const ContextPruner = @import("optimization/context_pruner.zig").ContextPruner;
pub const BatchProcessor = @import("optimization/batch_processor.zig").BatchProcessor;
pub const ResultCache = @import("optimization/result_cache.zig").ResultCache;

/// Coordinates all optimization subsystems. Owned by the Engine.
pub const OptimizationManager = struct {
    allocator: std.mem.Allocator,
    file_cache: FileCache,
    context_pruner: ContextPruner,
    batch_processor: BatchProcessor,
    result_cache: ResultCache,

    pub fn init(
        allocator: std.mem.Allocator,
        message_store: *storage.MessageStore,
    ) OptimizationManager {
        return .{
            .allocator = allocator,
            .file_cache = FileCache.init(allocator, 50),
            .context_pruner = ContextPruner.init(allocator, message_store, 200000, 0.3),
            .batch_processor = BatchProcessor.init(allocator, 100),
            .result_cache = ResultCache.init(allocator, 300_000, 100), // 5min TTL, 100 entries
        };
    }

    pub fn deinit(self: *OptimizationManager) void {
        self.file_cache.deinit();
        self.batch_processor.deinit();
        self.result_cache.deinit();
    }

    // -- File cache pass-through --

    pub fn getCachedFile(self: *OptimizationManager, path: []const u8) ?[]const u8 {
        return self.file_cache.get(path);
    }

    pub fn cacheFile(self: *OptimizationManager, path: []const u8, content: []const u8) !void {
        try self.file_cache.put(path, content);
    }

    pub fn invalidateFile(self: *OptimizationManager, path: []const u8) void {
        self.file_cache.invalidate(path);
    }

    // -- Result cache pass-through --

    pub fn getCachedResult(self: *OptimizationManager, tool_name: []const u8, input: []const u8) ?[]const u8 {
        if (!self.result_cache.shouldCache(tool_name)) return null;
        return self.result_cache.get(tool_name, input);
    }

    pub fn cacheResult(self: *OptimizationManager, tool_name: []const u8, input: []const u8, result: []const u8) !void {
        if (!self.result_cache.shouldCache(tool_name)) return;
        try self.result_cache.put(tool_name, input, result);
    }

    // -- Context pruner pass-through --

    pub fn shouldPruneContext(self: *OptimizationManager, session_id: []const u8) bool {
        return self.context_pruner.shouldPrune(session_id);
    }

    // -- Stats --

    pub fn getStats(self: *OptimizationManager, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "=== Optimization Stats ===\n");

        const fc = try self.file_cache.getStats(allocator);
        defer allocator.free(fc);
        try buf.appendSlice(allocator, fc);
        try buf.appendSlice(allocator, "\n");

        const rc = try self.result_cache.getStats(allocator);
        defer allocator.free(rc);
        try buf.appendSlice(allocator, rc);
        try buf.appendSlice(allocator, "\n");

        const bp = try self.batch_processor.getStats(allocator);
        defer allocator.free(bp);
        try buf.appendSlice(allocator, bp);
        try buf.appendSlice(allocator, "\n");

        return buf.toOwnedSlice(allocator);
    }
};
