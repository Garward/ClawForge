const std = @import("std");
const common = @import("common");
const core = @import("core");
const adapter_mod = @import("adapter.zig");

/// Discord adapter: spawns the Python bridge as a child process.
///
/// The bridge (bridges/discord_bridge.py) handles the Gateway WebSocket via
/// discord.py and forwards messages to ClawForge's HTTP API. This adapter is a
/// thin lifecycle wrapper that starts/stops the child process alongside the daemon.
///
/// Requires the web adapter to be enabled — the bridge connects to it via HTTP.
pub const DiscordAdapter = struct {
    allocator: std.mem.Allocator,
    config: *const common.Config,
    engine: *core.Engine,
    child: ?std.process.Child = null,
    running: std.atomic.Value(bool),
    url_buf: [64]u8 = undefined,
    python_abs: ?[]u8 = null,
    bridge_abs: ?[]u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: *const common.Config, engine: *core.Engine) !Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .engine = engine,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    pub fn adapter(self: *Self) adapter_mod.Adapter {
        return .{
            .name = "discord",
            .display_name = "Discord Bot (bridge)",
            .version = "0.2.0",
            .ptr = @ptrCast(self),
            .vtable = &.{
                .start = adapterStart,
                .run = adapterRun,
                .stop = adapterStop,
            },
        };
    }

    pub fn start(self: *Self) !void {
        if (self.running.load(.acquire)) return;

        if (!self.config.web.enabled) {
            std.log.err("Discord bridge requires web adapter to be enabled", .{});
            return error.WebAdapterRequired;
        }

        const url = try std.fmt.bufPrint(
            &self.url_buf,
            "http://{s}:{d}",
            .{ self.config.web.host, self.config.web.port },
        );

        // Resolve bridge paths to absolute (daemon cwd must be ClawForge root).
        const cwd = try std.process.getCwdAlloc(self.allocator);
        defer self.allocator.free(cwd);
        self.python_abs = try std.fs.path.join(self.allocator, &.{ cwd, ".venv/bin/python" });
        self.bridge_abs = try std.fs.path.join(self.allocator, &.{ cwd, "bridges/discord_bridge.py" });

        // Verify the venv python exists before spawning — fail fast with a clear message.
        std.fs.accessAbsolute(self.python_abs.?, .{}) catch {
            std.log.err("Discord bridge: venv python not found at {s}", .{self.python_abs.?});
            std.log.err("Create it with: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt", .{});
            self.freePaths();
            return error.VenvMissing;
        };

        const argv = [_][]const u8{ self.python_abs.?, self.bridge_abs.?, "--clawforge-url", url };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        child.spawn() catch |err| {
            std.log.err("Failed to spawn Discord bridge: {}", .{err});
            return err;
        };

        self.child = child;
        self.running.store(true, .release);
        std.log.info("Discord bridge spawned (pid={d}, url={s})", .{ child.id, url });
    }

    pub fn run(self: *Self) void {
        // Block until the child process exits or stop() is called.
        if (self.child) |*c| {
            const term = c.wait() catch |err| {
                std.log.err("Discord bridge wait error: {}", .{err});
                self.running.store(false, .release);
                self.freePaths();
                return;
            };
            switch (term) {
                .Exited => |code| std.log.info("Discord bridge exited (code={d})", .{code}),
                .Signal => |sig| std.log.info("Discord bridge terminated (signal={d})", .{sig}),
                else => std.log.info("Discord bridge stopped", .{}),
            }
            self.child = null;
            self.running.store(false, .release);
            self.freePaths();
        }
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);

        if (self.child) |*c| {
            _ = c.kill() catch |err| {
                std.log.warn("Failed to kill Discord bridge: {}", .{err});
            };
            std.log.info("Discord bridge stop requested", .{});
        }
    }

    fn freePaths(self: *Self) void {
        if (self.python_abs) |p| {
            self.allocator.free(p);
            self.python_abs = null;
        }
        if (self.bridge_abs) |p| {
            self.allocator.free(p);
            self.bridge_abs = null;
        }
    }

    // VTable wrappers
    fn adapterStart(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.start();
    }

    fn adapterRun(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.run();
    }

    fn adapterStop(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.stop();
    }
};
