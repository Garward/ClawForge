const std = @import("std");
const common = @import("common");
const core = @import("core");
const adapter_mod = @import("adapter.zig");

/// Daemon-owned Discord adapter.  The Python child is deliberately only a
/// discord.py Gateway/REST transport; all ClawForge state and work remains here.
pub const DiscordAdapter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: *const common.Config,
    engine: *core.Engine,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    child: ?std.process.Child = null,
    channel_sessions: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator, config: *const common.Config, engine: *core.Engine) !Self {
        return .{
            .allocator = allocator,
            .config = config,
            .engine = engine,
            .channel_sessions = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        var it = self.channel_sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.channel_sessions.deinit();
    }

    pub fn adapter(self: *Self) adapter_mod.Adapter {
        return .{
            .name = "discord",
            .display_name = "Discord",
            .version = "2.0.0",
            .ptr = self,
            .vtable = &.{ .start = adapterStart, .run = adapterRun, .stop = adapterStop },
        };
    }

    pub fn run(self: *Self) void {
        self.running.store(true, .release);
        while (self.running.load(.acquire)) {
            self.runChild() catch |err| std.log.err("Discord bridge failed: {}", .{err});
            if (!self.running.load(.acquire)) break;
            common.sync.sleepNanoseconds(5 * std.time.ns_per_s);
        }
    }

    fn runChild(self: *Self) !void {
        const token_file = self.config.discord.token_file;
        const max_bytes = try std.fmt.allocPrint(self.allocator, "{d}", .{self.config.discord.max_attachment_bytes});
        defer self.allocator.free(max_bytes);
        const max_count = try std.fmt.allocPrint(self.allocator, "{d}", .{self.config.discord.max_attachment_count});
        defer self.allocator.free(max_count);
        const args = [_][]const u8{
            ".venv/bin/python",       "bridges/discord_bridge.py",  "--token-file",           token_file,
            "--guild-id",             self.config.discord.guild_id, "--attachment-spool",     self.config.discord.attachment_spool,
            "--max-attachment-bytes", max_bytes,                    "--max-attachment-count", max_count,
        };
        const io = common.config.runtimeIo();
        const child = try std.process.spawn(io, .{
            .argv = &args,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        self.child = child;
        std.log.info("Discord transport started (pid={any})", .{self.child.?.id});

        var line_buf: [1024 * 1024]u8 = undefined;
        var reader = self.child.?.stdout.?.reader(io, &line_buf);
        while (self.running.load(.acquire)) {
            const line = (try reader.interface.takeDelimiter('\n')) orelse break;
            if (line.len == 0) continue;
            self.handleFrame(line) catch |err| {
                std.log.err("Discord RPC frame failed: {}", .{err});
                self.writeFrameError(line, @errorName(err));
            };
        }
        // This worker thread is the sole owner of reaping the child. stop()
        // only sends SIGTERM, avoiding Child.kill()/wait cleanup races.
        if (self.child.?.id != null) _ = self.child.?.wait(io) catch {};
        self.child = null;
    }

    fn handleFrame(self: *Self, line: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        const id = root.get("id").?.string;
        const method = root.get("method").?.string;
        const params = if (root.get("params")) |p| p.object else std.json.ObjectMap.empty;

        if (std.mem.eql(u8, method, "chat") or std.mem.eql(u8, method, "dispatch")) {
            const message = try stringParam(params, "message");
            const requested_model = if (params.get("model")) |v| if (v == .string) v.string else null else null;
            const channel = try stringParam(params, "channel");
            const requested_session = if (params.get("session_id")) |v| if (v == .string) v.string else null else null;
            const session: ?[]const u8 = requested_session orelse self.channel_sessions.get(channel);
            const plans_required = if (params.get("plans_required")) |v| if (v == .bool) v.bool else true else true;
            const allowed_tools = if (params.get("allowed_tools")) |v| if (v == .string) v.string else null else null;
            const requested_context = if (params.get("adapter_context")) |v| if (v == .string) v.string else null else null;
            const is_dispatch = std.mem.eql(u8, method, "dispatch");

            var attachments: std.ArrayList(common.Request.Attachment) = .empty;
            defer attachments.deinit(self.allocator);
            var trusted_context: std.ArrayList(u8) = .empty;
            defer trusted_context.deinit(self.allocator);
            if (requested_context) |context|
                try trusted_context.appendSlice(self.allocator, context)
            else
                try trusted_context.appendSlice(self.allocator, "Discord transport. Reply for Discord markdown; do not mention RPC or transport internals.");
            const spool = try common.config.resolveProjectPath(self.allocator, self.config.discord.attachment_spool);
            defer self.allocator.free(spool);
            if (params.get("attachments")) |value| {
                if (value != .array or value.array.items.len > self.config.discord.max_attachment_count) return error.InvalidRpcParameter;
                for (value.array.items) |item| {
                    if (item != .object) return error.InvalidRpcParameter;
                    const path = try stringParam(item.object, "path");
                    const mime = try stringParam(item.object, "mime");
                    const name = try stringParam(item.object, "name");
                    if (!std.fs.path.isAbsolute(path) or !pathWithin(spool, path)) return error.InvalidRpcParameter;
                    try attachments.append(self.allocator, .{ .path = path, .mime = mime, .name = name });
                    try trusted_context.appendSlice(self.allocator, "\nTrusted Discord attachment path: ");
                    try trusted_context.appendSlice(self.allocator, path);
                    try trusted_context.appendSlice(self.allocator, " (name: ");
                    try trusted_context.appendSlice(self.allocator, name);
                    try trusted_context.appendSlice(self.allocator, ")");
                }
            }
            const adapter_context: ?[]const u8 = if (trusted_context.items.len > 0) trusted_context.items else null;
            var tier_model_buf: [512]u8 = undefined;
            var delegated_model_buf: [512]u8 = undefined;
            const model: ?[]const u8 = if (is_dispatch and self.config.routing.enabled)
                std.fmt.bufPrint(
                    &tier_model_buf,
                    "{s}:{s}",
                    .{ self.config.routing.fast_provider, self.config.routing.fast_model },
                ) catch self.config.routing.fast_model
            else
                requested_model;
            const delegated_model: ?[]const u8 = if (!is_dispatch)
                null
            else if (requested_model) |requested|
                requested
            else if (self.config.routing.enabled)
                std.fmt.bufPrint(
                    &delegated_model_buf,
                    "{s}:{s}",
                    .{ self.config.routing.default_provider, self.config.routing.default_model },
                ) catch self.config.routing.default_model
            else
                null;
            const result = self.engine.process(.{ .chat = .{
                .message = message,
                .session_id = session,
                .model_override = model,
                .delegated_model_override = delegated_model,
                .attachments = if (attachments.items.len > 0) attachments.items else null,
                .stream = false,
                .plans_required = plans_required,
                .background = !is_dispatch,
                .callback_channel = channel,
                .allowed_tools = allowed_tools,
                .adapter_context = adapter_context orelse "Discord transport. Reply for Discord markdown; do not mention RPC or transport internals.",
            } }, null, null);
            switch (result) {
                .response => |response| switch (response) {
                    .background_queued => |bg| {
                        try self.rememberSession(channel, &bg.session_id);
                        try self.writeResult(id, .{ .queued = .{ .job_id = bg.job_id[0..], .session_id = bg.session_id } });
                    },
                    .error_resp => |err| try self.writeError(id, err.message),
                    else => try self.writeError(id, "unexpected engine response"),
                },
                .chat => |chat| {
                    if (!is_dispatch) {
                        try self.writeError(id, "unexpected synchronous response");
                    } else {
                        try self.writeResult(id, .{ .dispatched = .{
                            .text = chat.text,
                            .model = chat.model,
                            .spawned_jobs = chat.spawned_jobs,
                        } });
                    }
                },
            }
        } else if (std.mem.eql(u8, method, "poll")) {
            const job_id = try parseJobId(try stringParam(params, "job_id"));
            if (self.engine.worker_pool) |wp| {
                if (wp.getPendingConfirmation(&job_id)) |c| {
                    try self.writeResult(id, .{ .confirmation = .{ .job_id = c.job_id[0..], .tool_id = c.tool_id, .tool_name = c.tool_name, .input_preview = c.input_preview } });
                } else if (wp.getBackgroundResult(&job_id)) |r| {
                    const status: []const u8 = @tagName(r.status);
                    try self.writeResult(id, .{ .finished = .{ .job_id = r.job_id[0..], .status = status, .text = r.text, .model = r.model } });
                } else {
                    const cursor = if (params.get("cursor")) |v|
                        if (v == .integer and v.integer >= 0) @as(usize, @intCast(v.integer)) else 0
                    else
                        0;
                    const snapshot = try wp.getToolEvents(&job_id, cursor);
                    defer snapshot.deinit();
                    var latest_index: ?usize = null;
                    for (snapshot.events, 0..) |maybe_event, index| {
                        if (maybe_event != null) latest_index = index;
                    }
                    if (latest_index) |index| {
                        const event = snapshot.events[index].?;
                        try self.writeResult(id, .{ .pending = .{
                            .job_id = job_id[0..],
                            .cursor = snapshot.new_cursor,
                            .event = .{
                                .type = @tagName(event.event_type),
                                .tool = event.tool_name,
                                .content = event.content,
                                .is_error = event.is_error,
                            },
                        } });
                    } else {
                        try self.writeResult(id, .{ .pending = .{
                            .job_id = job_id[0..],
                            .cursor = snapshot.new_cursor,
                        } });
                    }
                }
            } else try self.writeError(id, "background workers unavailable");
        } else if (std.mem.eql(u8, method, "cancel")) {
            const job_id = try parseJobId(try stringParam(params, "job_id"));
            const cancelled = if (self.engine.worker_pool) |wp| wp.cancelBackgroundJob(&job_id) else false;
            try self.writeResult(id, .{ .cancelled = cancelled });
        } else if (std.mem.eql(u8, method, "confirm")) {
            const job_id = try parseJobId(try stringParam(params, "job_id"));
            const tool_id = try stringParam(params, "tool_id");
            const approved_value = params.get("approved") orelse return error.MissingRpcParameter;
            if (approved_value != .bool) return error.InvalidRpcParameter;
            const approved = approved_value.bool;
            const resolved = if (self.engine.worker_pool) |wp| wp.resolveConfirmation(&job_id, tool_id, approved) else false;
            try self.writeResult(id, .{ .resolved = resolved });
        } else if (std.mem.eql(u8, method, "status")) {
            try self.writeResult(id, .{ .status = "ok", .web_required = false });
        } else {
            try self.writeError(id, "unsupported RPC method");
        }
    }

    fn parseJobId(value: []const u8) ![36]u8 {
        if (value.len != 36) return error.InvalidJobId;
        var out: [36]u8 = undefined;
        @memcpy(&out, value);
        return out;
    }

    fn stringParam(params: std.json.ObjectMap, name: []const u8) ![]const u8 {
        const value = params.get(name) orelse return error.MissingRpcParameter;
        if (value != .string) return error.InvalidRpcParameter;
        return value.string;
    }

    fn pathWithin(root: []const u8, path: []const u8) bool {
        if (!std.mem.startsWith(u8, path, root)) return false;
        if (path.len == root.len) return false;
        return root.len == 1 or path[root.len] == std.fs.path.sep;
    }

    fn rememberSession(self: *Self, channel: []const u8, session_id: []const u8) !void {
        if (self.channel_sessions.getPtr(channel)) |existing| {
            if (std.mem.eql(u8, existing.*, session_id)) return;
            self.allocator.free(existing.*);
            existing.* = try self.allocator.dupe(u8, session_id);
            return;
        }
        try self.channel_sessions.put(try self.allocator.dupe(u8, channel), try self.allocator.dupe(u8, session_id));
    }

    fn writeResult(self: *Self, id: []const u8, result: anytype) !void {
        try self.writeJson(.{ .id = id, .ok = true, .result = result });
    }

    fn writeError(self: *Self, id: []const u8, message: []const u8) !void {
        try self.writeJson(.{ .id = id, .ok = false, .error_message = message });
    }

    fn writeFrameError(self: *Self, line: []const u8, message: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const id_value = parsed.value.object.get("id") orelse return;
        if (id_value != .string) return;
        self.writeError(id_value.string, message) catch {};
    }

    fn writeJson(self: *Self, value: anytype) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(encoded);
        if (self.child) |*child| {
            var writer = child.stdin.?.writer(common.config.runtimeIo(), &.{});
            try writer.interface.writeAll(encoded);
            try writer.interface.writeAll("\n");
        }
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        if (self.child) |*child| {
            if (child.id) |pid| {
                // The active reader retains its own stdout handle. Detach the
                // pipe fields before wait() cleanup during whole-daemon
                // shutdown; the OS closes them when this process exits.
                child.stdin = null;
                child.stdout = null;
                child.stderr = null;
                std.posix.kill(pid, .TERM) catch {};
            }
        }
    }

    fn adapterStart(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.running.store(true, .release);
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
