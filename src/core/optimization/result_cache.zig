const std = @import("std");

/// TTL cache for deterministic tool results. Avoids re-executing identical
/// tool calls within a session (e.g. reading the same file twice, running
/// the same calc expression). Non-deterministic tools (bash) are excluded.
pub const ResultCache = struct {
    const CacheEntry = struct {
        result: []u8,
        timestamp: i64,
        hit_count: u32,
    };

    allocator: std.mem.Allocator,
    /// Key = hash of (tool_name ++ "\x00" ++ input)
    cache: std.AutoHashMap(u64, CacheEntry),
    max_age_ms: i64,
    max_entries: usize,
    hits: u64,
    misses: u64,

    pub fn init(allocator: std.mem.Allocator, max_age_ms: i64, max_entries: usize) ResultCache {
        return .{
            .allocator = allocator,
            .cache = std.AutoHashMap(u64, CacheEntry).init(allocator),
            .max_age_ms = max_age_ms,
            .max_entries = max_entries,
            .hits = 0,
            .misses = 0,
        };
    }

    pub fn deinit(self: *ResultCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.result);
        }
        self.cache.deinit();
    }

    pub fn get(self: *ResultCache, tool_name: []const u8, input: []const u8) ?[]const u8 {
        const key = makeKey(tool_name, input);
        const entry_ptr = self.cache.getPtr(key) orelse {
            self.misses += 1;
            return null;
        };

        const now = std.time.milliTimestamp();
        if (now - entry_ptr.timestamp > self.max_age_ms) {
            // Expired — remove and miss
            self.allocator.free(entry_ptr.result);
            _ = self.cache.remove(key);
            self.misses += 1;
            return null;
        }

        entry_ptr.hit_count += 1;
        self.hits += 1;
        return entry_ptr.result;
    }

    pub fn put(self: *ResultCache, tool_name: []const u8, input: []const u8, result: []const u8) !void {
        self.cleanExpired();

        // Evict LRU if at capacity
        while (self.cache.count() >= self.max_entries) {
            self.evictLRU();
        }

        const key = makeKey(tool_name, input);

        // If key exists, update in-place
        if (self.cache.getPtr(key)) |existing| {
            self.allocator.free(existing.result);
            existing.* = .{
                .result = try self.allocator.dupe(u8, result),
                .timestamp = std.time.milliTimestamp(),
                .hit_count = 0,
            };
            return;
        }

        try self.cache.put(key, .{
            .result = try self.allocator.dupe(u8, result),
            .timestamp = std.time.milliTimestamp(),
            .hit_count = 0,
        });
    }

    /// Only cache results for deterministic, read-heavy tools.
    pub fn shouldCache(_: *const ResultCache, tool_name: []const u8) bool {
        return std.mem.eql(u8, tool_name, "file_read") or
            std.mem.eql(u8, tool_name, "calc") or
            std.mem.eql(u8, tool_name, "introspect");
    }

    fn makeKey(tool_name: []const u8, input: []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(tool_name);
        h.update("\x00");
        h.update(input);
        return h.final();
    }

    fn cleanExpired(self: *ResultCache) void {
        const now = std.time.milliTimestamp();
        // Collect keys to remove (can't mutate during iteration)
        var remove_buf: [64]u64 = undefined;
        var remove_count: usize = 0;

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.timestamp > self.max_age_ms) {
                if (remove_count < remove_buf.len) {
                    remove_buf[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }

        for (remove_buf[0..remove_count]) |key| {
            if (self.cache.fetchRemove(key)) |kv| {
                self.allocator.free(kv.value.result);
            }
        }
    }

    fn evictLRU(self: *ResultCache) void {
        var victim_key: ?u64 = null;
        var lowest_hits: u32 = std.math.maxInt(u32);
        var oldest_time: i64 = std.math.maxInt(i64);

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            const better_victim = entry.value_ptr.hit_count < lowest_hits or
                (entry.value_ptr.hit_count == lowest_hits and entry.value_ptr.timestamp < oldest_time);
            if (better_victim) {
                victim_key = entry.key_ptr.*;
                lowest_hits = entry.value_ptr.hit_count;
                oldest_time = entry.value_ptr.timestamp;
            }
        }

        if (victim_key) |key| {
            if (self.cache.fetchRemove(key)) |kv| {
                self.allocator.free(kv.value.result);
            }
        }
    }

    pub fn clear(self: *ResultCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.result);
        }
        self.cache.clearAndFree();
        self.hits = 0;
        self.misses = 0;
    }

    pub fn getStats(self: *ResultCache, allocator: std.mem.Allocator) ![]u8 {
        const total = self.hits + self.misses;
        const hit_rate = if (total > 0) (@as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) * 100.0) else 0.0;
        return std.fmt.allocPrint(allocator, "ResultCache: {d}/{d} entries, {d} hits, {d} misses, {d:.1}% hit rate, TTL {d}ms", .{
            self.cache.count(), self.max_entries, self.hits, self.misses, hit_rate, self.max_age_ms,
        });
    }
};
