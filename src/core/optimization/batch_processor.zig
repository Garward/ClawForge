const std = @import("std");

/// Coalesces multiple file operations within a time window to reduce syscalls.
/// Deduplicates reads (same path → one read) and writes (latest write wins).
pub const BatchProcessor = struct {
    const OpType = enum { read, write, stat };

    const FileOp = struct {
        op_type: OpType,
        path: []const u8,
        content: ?[]const u8,
        timestamp: i64,
    };

    allocator: std.mem.Allocator,
    pending_ops: std.ArrayList(FileOp),
    batch_window_ms: i64,
    last_flush: i64,
    total_flushed: u64,

    pub fn init(allocator: std.mem.Allocator, batch_window_ms: i64) BatchProcessor {
        return .{
            .allocator = allocator,
            .pending_ops = .{},
            .batch_window_ms = batch_window_ms,
            .last_flush = std.time.milliTimestamp(),
            .total_flushed = 0,
        };
    }

    pub fn deinit(self: *BatchProcessor) void {
        for (self.pending_ops.items) |op| {
            self.allocator.free(op.path);
            if (op.content) |c| self.allocator.free(c);
        }
        self.pending_ops.deinit(self.allocator);
    }

    pub fn queueRead(self: *BatchProcessor, path: []const u8) !void {
        try self.queueOp(.read, path, null);
    }

    pub fn queueWrite(self: *BatchProcessor, path: []const u8, content: []const u8) !void {
        try self.queueOp(.write, path, content);
    }

    pub fn queueStat(self: *BatchProcessor, path: []const u8) !void {
        try self.queueOp(.stat, path, null);
    }

    fn queueOp(self: *BatchProcessor, op_type: OpType, path: []const u8, content: ?[]const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_content = if (content) |c| try self.allocator.dupe(u8, c) else null;

        try self.pending_ops.append(self.allocator, .{
            .op_type = op_type,
            .path = owned_path,
            .content = owned_content,
            .timestamp = std.time.milliTimestamp(),
        });

        if (self.shouldFlush()) {
            var results = try self.flush();
            // Caller didn't ask for results — free them
            for (results.items) |r| self.allocator.free(r);
            results.deinit(self.allocator);
        }
    }

    pub fn shouldFlush(self: *const BatchProcessor) bool {
        const now = std.time.milliTimestamp();
        return (now - self.last_flush) > self.batch_window_ms or self.pending_ops.items.len > 10;
    }

    pub fn flush(self: *BatchProcessor) !std.ArrayList([]u8) {
        var results: std.ArrayList([]u8) = .{};

        if (self.pending_ops.items.len == 0) return results;

        // Deduplicate reads
        var seen_reads: std.StringHashMap(void) = std.StringHashMap(void).init(self.allocator);
        defer seen_reads.deinit();

        // For writes, keep only the latest per path
        var latest_writes: std.StringHashMap(FileOp) = std.StringHashMap(FileOp).init(self.allocator);
        defer latest_writes.deinit();

        for (self.pending_ops.items) |op| {
            switch (op.op_type) {
                .read => {
                    if (seen_reads.get(op.path) == null) {
                        try seen_reads.put(op.path, {});
                        const result = self.executeRead(op.path);
                        try results.append(self.allocator, result);
                    }
                },
                .write => {
                    if (latest_writes.getPtr(op.path)) |existing| {
                        // Keep the newer write
                        if (op.timestamp > existing.timestamp) {
                            existing.* = op;
                        }
                    } else {
                        try latest_writes.put(op.path, op);
                    }
                },
                .stat => {
                    const result = self.executeStat(op.path);
                    try results.append(self.allocator, result);
                },
            }
        }

        // Execute deduplicated writes
        var write_it = latest_writes.iterator();
        while (write_it.next()) |entry| {
            if (entry.value_ptr.content) |content| {
                const result = self.executeWrite(entry.value_ptr.path, content);
                try results.append(self.allocator, result);
            }
        }

        // Clean up pending ops
        for (self.pending_ops.items) |op| {
            self.allocator.free(op.path);
            if (op.content) |c| self.allocator.free(c);
        }
        self.pending_ops.clearRetainingCapacity();
        self.total_flushed += results.items.len;
        self.last_flush = std.time.milliTimestamp();

        return results;
    }

    fn executeRead(self: *BatchProcessor, path: []const u8) []u8 {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            return std.fmt.allocPrint(self.allocator, "Error reading {s}: {}", .{ path, err }) catch @constCast("read error");
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            return std.fmt.allocPrint(self.allocator, "Error reading {s}: {}", .{ path, err }) catch @constCast("read error");
        };
        defer self.allocator.free(content);
        return std.fmt.allocPrint(self.allocator, "Read {s}: {d} bytes", .{ path, content.len }) catch @constCast("read ok");
    }

    fn executeWrite(self: *BatchProcessor, path: []const u8, content: []const u8) []u8 {
        const file = std.fs.cwd().createFile(path, .{}) catch |err| {
            return std.fmt.allocPrint(self.allocator, "Error writing {s}: {}", .{ path, err }) catch @constCast("write error");
        };
        defer file.close();
        file.writeAll(content) catch |err| {
            return std.fmt.allocPrint(self.allocator, "Error writing {s}: {}", .{ path, err }) catch @constCast("write error");
        };
        return std.fmt.allocPrint(self.allocator, "Wrote {s}: {d} bytes", .{ path, content.len }) catch @constCast("write ok");
    }

    fn executeStat(self: *BatchProcessor, path: []const u8) []u8 {
        const stat = std.fs.cwd().statFile(path) catch |err| {
            return std.fmt.allocPrint(self.allocator, "Error stat {s}: {}", .{ path, err }) catch @constCast("stat error");
        };
        return std.fmt.allocPrint(self.allocator, "Stat {s}: size={d}", .{ path, stat.size }) catch @constCast("stat ok");
    }

    pub fn getPendingCount(self: *const BatchProcessor) usize {
        return self.pending_ops.items.len;
    }

    pub fn getStats(self: *const BatchProcessor, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "BatchProcessor: {d} pending, {d} total flushed, last flush {d}ms ago", .{
            self.pending_ops.items.len, self.total_flushed, std.time.milliTimestamp() - self.last_flush,
        });
    }
};
