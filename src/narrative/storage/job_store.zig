//! Durable authoring jobs and append-only runtime events.

const std = @import("std");
const common = @import("common");
const storage = @import("storage");
const domain = @import("../domain/root.zig");

pub const JobStore = struct {
    allocator: std.mem.Allocator,
    conn: *storage.Connection,

    pub fn init(allocator: std.mem.Allocator, conn: *storage.Connection) JobStore {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn createWriterJob(
        self: *JobStore,
        story_id: []const u8,
        node_id: []const u8,
        model: []const u8,
        mode: []const u8,
        revision_instruction: []const u8,
    ) !domain.Job {
        const story_state = try self.storyState(story_id) orelse return error.StoryNotFound;
        defer self.allocator.free(story_state.branch_id);
        if (!try self.writableNodeExists(story_id, node_id)) return error.NodeNotFound;
        var id: [36]u8 = undefined;
        generateUuid(&id);
        const state_json = try std.json.Stringify.valueAlloc(self.allocator, .{
            .node_id = node_id,
            .pass = @as(u32, 0),
            .continue_context = "",
            .mode = mode,
            .revision_instruction = revision_instruction,
            .revision_cursor = @as(usize, 0),
            .remaining_original_blocks = @as(?usize, null),
            .postprocess_pending = false,
        }, .{});
        defer self.allocator.free(state_json);
        const model_json = try std.json.Stringify.valueAlloc(self.allocator, .{
            .passage_writer = model,
        }, .{});
        defer self.allocator.free(model_json);
        const now = common.sync.timestamp();
        var statement = try self.conn.prepare(
            \\INSERT INTO narrative_jobs
            \\ (id, story_id, branch_id, job_type, status, state_json,
            \\  model_snapshot_json, base_story_version, created_at, updated_at)
            \\VALUES (?, ?, ?, 'write_section', 'queued', ?, ?, ?, ?, ?)
        );
        defer statement.deinit();
        try statement.bindText(1, &id);
        try statement.bindText(2, story_id);
        try statement.bindText(3, story_state.branch_id);
        try statement.bindText(4, state_json);
        try statement.bindText(5, model_json);
        try statement.bindInt64(6, story_state.version);
        try statement.bindInt64(7, now);
        try statement.bindInt64(8, now);
        try statement.exec();
        try self.addEvent(&id, "job_created", "{}");
        return try self.get(&id) orelse error.JobCreateFailed;
    }

    pub fn get(self: *JobStore, job_id: []const u8) !?domain.Job {
        var statement = try self.conn.prepare(
            \\SELECT id, story_id, branch_id, job_type, status, state_json,
            \\       model_snapshot_json, base_story_version, created_at, updated_at
            \\FROM narrative_jobs WHERE id = ?
        );
        defer statement.deinit();
        try statement.bindText(1, job_id);
        if (!try statement.step()) return null;
        return try readJob(self.allocator, &statement);
    }

    pub fn list(self: *JobStore, story_id: []const u8) ![]domain.Job {
        var result: std.ArrayList(domain.Job) = .empty;
        errdefer {
            for (result.items) |*job| job.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        var statement = try self.conn.prepare(
            \\SELECT id, story_id, branch_id, job_type, status, state_json,
            \\       model_snapshot_json, base_story_version, created_at, updated_at
            \\FROM narrative_jobs WHERE story_id = ? ORDER BY updated_at DESC LIMIT 100
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        while (try statement.step()) {
            try result.append(self.allocator, try readJob(self.allocator, &statement));
        }
        return try result.toOwnedSlice(self.allocator);
    }

    pub fn setStatus(self: *JobStore, job_id: []const u8, status: []const u8) !void {
        var statement = try self.conn.prepare(
            "UPDATE narrative_jobs SET status = ?, updated_at = ? WHERE id = ?",
        );
        defer statement.deinit();
        try statement.bindText(1, status);
        try statement.bindInt64(2, common.sync.timestamp());
        try statement.bindText(3, job_id);
        try statement.exec();
        if (self.conn.changes() == 0) return error.JobNotFound;
    }

    pub fn finishPass(
        self: *JobStore,
        job_id: []const u8,
        state_json: []const u8,
        status: []const u8,
    ) !domain.Job {
        if (!std.mem.eql(u8, status, "queued") and
            !std.mem.eql(u8, status, "complete") and
            !std.mem.eql(u8, status, "paused")) return error.InvalidJobStatus;
        var statement = try self.conn.prepare(
            "UPDATE narrative_jobs SET state_json = ?, status = ?, updated_at = ? WHERE id = ?",
        );
        defer statement.deinit();
        try statement.bindText(1, state_json);
        try statement.bindText(2, status);
        try statement.bindInt64(3, common.sync.timestamp());
        try statement.bindText(4, job_id);
        try statement.exec();
        if (self.conn.changes() == 0) return error.JobNotFound;
        const event_type = if (std.mem.eql(u8, status, "complete"))
            "job_completed"
        else if (std.mem.eql(u8, status, "paused"))
            "job_paused"
        else
            "pass_completed";
        try self.addEvent(job_id, event_type, "{}");
        return try self.get(job_id) orelse error.JobNotFound;
    }

    pub fn addEvent(self: *JobStore, job_id: []const u8, event_type: []const u8, payload_json: []const u8) !void {
        var statement = try self.conn.prepare(
            \\INSERT INTO narrative_job_events (job_id, sequence, event_type, payload_json, created_at)
            \\VALUES (?, (SELECT COALESCE(MAX(sequence), 0) + 1 FROM narrative_job_events WHERE job_id = ?), ?, ?, ?)
        );
        defer statement.deinit();
        try statement.bindText(1, job_id);
        try statement.bindText(2, job_id);
        try statement.bindText(3, event_type);
        try statement.bindText(4, payload_json);
        try statement.bindInt64(5, common.sync.timestamp());
        try statement.exec();
    }

    fn writableNodeExists(self: *JobStore, story_id: []const u8, node_id: []const u8) !bool {
        var statement = try self.conn.prepare(
            "SELECT 1 FROM narrative_nodes WHERE story_id = ? AND id = ? AND node_type IN ('chapter', 'scene')",
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        try statement.bindText(2, node_id);
        return try statement.step();
    }

    fn storyState(self: *JobStore, story_id: []const u8) !?struct { branch_id: []u8, version: i64 } {
        var statement = try self.conn.prepare(
            "SELECT active_branch_id, active_version FROM narrative_stories WHERE id = ?",
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        if (!try statement.step()) return null;
        return .{
            .branch_id = try self.allocator.dupe(u8, statement.columnText(0) orelse ""),
            .version = statement.columnInt64(1),
        };
    }
};

fn readJob(allocator: std.mem.Allocator, statement: *storage.Statement) !domain.Job {
    return .{
        .id = try allocator.dupe(u8, statement.columnText(0) orelse ""),
        .story_id = try allocator.dupe(u8, statement.columnText(1) orelse ""),
        .branch_id = if (statement.columnOptionalText(2)) |value| try allocator.dupe(u8, value) else null,
        .job_type = try allocator.dupe(u8, statement.columnText(3) orelse ""),
        .status = try allocator.dupe(u8, statement.columnText(4) orelse ""),
        .state_json = try allocator.dupe(u8, statement.columnText(5) orelse "{}"),
        .model_snapshot_json = try allocator.dupe(u8, statement.columnText(6) orelse "{}"),
        .base_story_version = statement.columnInt64(7),
        .created_at = statement.columnInt64(8),
        .updated_at = statement.columnInt64(9),
    };
}

fn generateUuid(buffer: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    std.Io.random(common.config.runtimeIo(), &bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var source: usize = 0;
    var destination: usize = 0;
    while (source < bytes.len) : (source += 1) {
        if (source == 4 or source == 6 or source == 8 or source == 10) {
            buffer[destination] = '-';
            destination += 1;
        }
        buffer[destination] = hex[bytes[source] >> 4];
        buffer[destination + 1] = hex[bytes[source] & 0x0f];
        destination += 2;
    }
}
