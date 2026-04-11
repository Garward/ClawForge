const std = @import("std");

/// LRU file cache for frequent reads. Validates entries against mtime
/// so stale content is never served. Used by file_read tool to avoid
/// redundant disk I/O on files the model reads repeatedly in a session.
pub const FileCache = struct {
    const CacheEntry = struct {
        content: []u8,
        mtime: i128,
        access_count: u32,
        last_access: i64,
    };

    allocator: std.mem.Allocator,
    cache: std.StringHashMap(CacheEntry),
    max_size: usize,
    hits: u64,
    misses: u64,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) FileCache {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .max_size = max_size,
            .hits = 0,
            .misses = 0,
        };
    }

    pub fn deinit(self: *FileCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.content);
        }
        self.cache.deinit();
    }

    pub fn get(self: *FileCache, path: []const u8) ?[]const u8 {
        const entry_ptr = self.cache.getPtr(path) orelse {
            self.misses += 1;
            return null;
        };

        // Validate mtime — stale entries are evicted on access
        const stat = std.fs.cwd().statFile(path) catch {
            self.remove(path);
            self.misses += 1;
            return null;
        };

        if (stat.mtime != entry_ptr.mtime) {
            self.remove(path);
            self.misses += 1;
            return null;
        }

        entry_ptr.access_count += 1;
        entry_ptr.last_access = std.time.timestamp();
        self.hits += 1;
        return entry_ptr.content;
    }

    pub fn put(self: *FileCache, path: []const u8, content: []const u8) !void {
        const stat = std.fs.cwd().statFile(path) catch return;

        // Evict LRU entries until under budget
        while (self.cache.count() >= self.max_size) {
            self.evictLRU();
        }

        // If key already exists, free old content
        if (self.cache.getPtr(path)) |existing| {
            self.allocator.free(existing.content);
            existing.* = .{
                .content = try self.allocator.dupe(u8, content),
                .mtime = stat.mtime,
                .access_count = 1,
                .last_access = std.time.timestamp(),
            };
            return;
        }

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);

        try self.cache.put(owned_path, .{
            .content = owned_content,
            .mtime = stat.mtime,
            .access_count = 1,
            .last_access = std.time.timestamp(),
        });
    }

    pub fn invalidate(self: *FileCache, path: []const u8) void {
        self.remove(path);
    }

    fn remove(self: *FileCache, path: []const u8) void {
        if (self.cache.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.content);
        }
    }

    fn evictLRU(self: *FileCache) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_access < oldest_time) {
                oldest_time = entry.value_ptr.last_access;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            self.remove(key);
        }
    }

    pub fn clear(self: *FileCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.content);
        }
        self.cache.clearAndFree();
        self.hits = 0;
        self.misses = 0;
    }

    pub fn getStats(self: *FileCache, allocator: std.mem.Allocator) ![]u8 {
        const total = self.hits + self.misses;
        const hit_rate = if (total > 0) (@as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) * 100.0) else 0.0;
        return std.fmt.allocPrint(allocator, "FileCache: {d}/{d} entries, {d} hits, {d} misses, {d:.1}% hit rate", .{
            self.cache.count(), self.max_size, self.hits, self.misses, hit_rate,
        });
    }
};
