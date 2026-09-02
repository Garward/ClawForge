//! Zig 0.16 synchronization and timing adapters backed by the process Io.

const std = @import("std");
const config = @import("config.zig");

/// Mutex with the pre-0.16 lock()/unlock() call shape used throughout ClawForge.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(config.runtimeIo());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(config.runtimeIo());
    }
};

/// Condition with uncancelable waits. All ClawForge condition wait sites have
/// explicit predicates and are signaled during shutdown/cancellation.
pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(config.runtimeIo(), &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(config.runtimeIo());
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(config.runtimeIo());
    }
};

pub fn sleepNanoseconds(nanoseconds: u64) void {
    const duration = std.Io.Duration.fromNanoseconds(@intCast(nanoseconds));
    std.Io.sleep(config.runtimeIo(), duration, .awake) catch {};
}

pub fn milliTimestamp() i64 {
    const now = std.Io.Clock.real.now(config.runtimeIo());
    return @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
}

pub fn timestamp() i64 {
    const now = std.Io.Clock.real.now(config.runtimeIo());
    return @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s));
}
