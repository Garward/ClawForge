//! Persistence for approval-gated discovery and Author Room proposals.

const std = @import("std");
const common = @import("common");
const storage = @import("storage");
const domain = @import("../domain/root.zig");

pub const ProposalStore = struct {
    allocator: std.mem.Allocator,
    conn: *storage.Connection,

    pub fn init(allocator: std.mem.Allocator, conn: *storage.Connection) ProposalStore {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn create(
        self: *ProposalStore,
        story_id: []const u8,
        thread_id: []const u8,
        title: []const u8,
        decision: []const u8,
        proposal_json: []const u8,
    ) !domain.DecisionProposal {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, proposal_json, .{}) catch
            return error.InvalidProposal;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidProposal;
        const patches = parsed.value.object.get("record_patches") orelse return error.InvalidProposal;
        if (patches != .array) return error.InvalidProposal;
        var id: [36]u8 = undefined;
        generateUuid(&id);
        const now = common.sync.timestamp();
        try self.conn.execSimple("BEGIN IMMEDIATE");
        errdefer self.conn.execSimple("ROLLBACK") catch {};
        var statement = try self.conn.prepare(
            \\INSERT INTO narrative_decision_proposals
            \\ (id, story_id, thread_id, status, title, decision, proposal_json, created_at, updated_at)
            \\VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?)
        );
        defer statement.deinit();
        try statement.bindText(1, &id);
        try statement.bindText(2, story_id);
        try statement.bindText(3, thread_id);
        try statement.bindText(4, title);
        try statement.bindText(5, decision);
        try statement.bindText(6, proposal_json);
        try statement.bindInt64(7, now);
        try statement.bindInt64(8, now);
        try statement.exec();
        for (patches.array.items) |patch| {
            if (patch != .object) return error.InvalidProposal;
            const record_type_value = patch.object.get("record_type") orelse return error.InvalidProposal;
            const value_json_value = patch.object.get("value_json") orelse return error.InvalidProposal;
            const rationale_value = patch.object.get("rationale") orelse return error.InvalidProposal;
            if (record_type_value != .string or value_json_value != .string or rationale_value != .string)
                return error.InvalidProposal;
            try self.createDocumentRevision(
                story_id,
                thread_id,
                &id,
                record_type_value.string,
                value_json_value.string,
                rationale_value.string,
                now,
            );
        }
        try self.conn.execSimple("COMMIT");
        return try self.get(story_id, &id) orelse error.ProposalCreateFailed;
    }

    fn createDocumentRevision(
        self: *ProposalStore,
        story_id: []const u8,
        thread_id: []const u8,
        source_proposal_id: []const u8,
        record_type: []const u8,
        value_json: []const u8,
        rationale: []const u8,
        now: i64,
    ) !void {
        var previous_id: ?[]u8 = null;
        defer if (previous_id) |value| self.allocator.free(value);
        var revision: i64 = 1;
        var previous = try self.conn.prepare(
            \\SELECT id, revision FROM narrative_document_changes
            \\WHERE story_id = ? AND record_type = ? AND status = 'pending'
        );
        defer previous.deinit();
        try previous.bindText(1, story_id);
        try previous.bindText(2, record_type);
        if (try previous.step()) {
            previous_id = try self.allocator.dupe(u8, previous.columnText(0) orelse "");
            revision = previous.columnInt64(1) + 1;
        } else {
            var max_revision = try self.conn.prepare(
                "SELECT COALESCE(MAX(revision), 0) + 1 FROM narrative_document_changes WHERE story_id = ? AND record_type = ?",
            );
            defer max_revision.deinit();
            try max_revision.bindText(1, story_id);
            try max_revision.bindText(2, record_type);
            if (try max_revision.step()) revision = max_revision.columnInt64(0);
        }
        if (previous_id) |value| {
            var supersede = try self.conn.prepare(
                "UPDATE narrative_document_changes SET status = 'superseded', updated_at = ? WHERE id = ? AND status = 'pending'",
            );
            defer supersede.deinit();
            try supersede.bindInt64(1, now);
            try supersede.bindText(2, value);
            try supersede.exec();
        }
        var change_id: [36]u8 = undefined;
        generateUuid(&change_id);
        var insert = try self.conn.prepare(
            \\INSERT INTO narrative_document_changes
            \\ (id, story_id, thread_id, source_proposal_id, record_type, status,
            \\  revision, value_json, rationale, supersedes_id, created_at, updated_at)
            \\VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?)
        );
        defer insert.deinit();
        try insert.bindText(1, &change_id);
        try insert.bindText(2, story_id);
        try insert.bindText(3, thread_id);
        try insert.bindText(4, source_proposal_id);
        try insert.bindText(5, record_type);
        try insert.bindInt64(6, revision);
        try insert.bindText(7, value_json);
        try insert.bindText(8, rationale);
        if (previous_id) |value| try insert.bindText(9, value) else try insert.bindNull(9);
        try insert.bindInt64(10, now);
        try insert.bindInt64(11, now);
        try insert.exec();
    }

    pub fn listDocumentChanges(self: *ProposalStore, story_id: []const u8) ![]domain.DocumentChange {
        var result: std.ArrayList(domain.DocumentChange) = .empty;
        errdefer {
            for (result.items) |*change| change.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        var statement = try self.conn.prepare(
            \\SELECT c.id, c.story_id, c.thread_id, c.source_proposal_id,
            \\       c.record_type, c.status, c.revision, c.value_json, c.rationale,
            \\       c.supersedes_id, COALESCE(r.value_json, '{}'), c.created_at, c.updated_at
            \\FROM narrative_document_changes c
            \\LEFT JOIN narrative_records r
            \\  ON r.story_id = c.story_id AND r.record_type = c.record_type
            \\WHERE c.story_id = ?
            \\ORDER BY CASE c.status WHEN 'pending' THEN 0 ELSE 1 END,
            \\         c.record_type, c.revision DESC
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        while (try statement.step())
            try result.append(self.allocator, try readDocumentChange(self.allocator, &statement));
        return try result.toOwnedSlice(self.allocator);
    }

    pub fn getDocumentChange(
        self: *ProposalStore,
        story_id: []const u8,
        change_id: []const u8,
    ) !?domain.DocumentChange {
        var statement = try self.conn.prepare(
            \\SELECT c.id, c.story_id, c.thread_id, c.source_proposal_id,
            \\       c.record_type, c.status, c.revision, c.value_json, c.rationale,
            \\       c.supersedes_id, COALESCE(r.value_json, '{}'), c.created_at, c.updated_at
            \\FROM narrative_document_changes c
            \\LEFT JOIN narrative_records r
            \\  ON r.story_id = c.story_id AND r.record_type = c.record_type
            \\WHERE c.story_id = ? AND c.id = ?
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        try statement.bindText(2, change_id);
        if (!try statement.step()) return null;
        return try readDocumentChange(self.allocator, &statement);
    }

    pub fn setDocumentChangeStatus(
        self: *ProposalStore,
        story_id: []const u8,
        change_id: []const u8,
        status: []const u8,
    ) !domain.DocumentChange {
        if (!std.mem.eql(u8, status, "accepted") and !std.mem.eql(u8, status, "rejected"))
            return error.InvalidProposalStatus;
        var statement = try self.conn.prepare(
            "UPDATE narrative_document_changes SET status = ?, updated_at = ? WHERE story_id = ? AND id = ? AND status = 'pending'",
        );
        defer statement.deinit();
        try statement.bindText(1, status);
        try statement.bindInt64(2, common.sync.timestamp());
        try statement.bindText(3, story_id);
        try statement.bindText(4, change_id);
        try statement.exec();
        if (self.conn.changes() == 0) return error.ProposalNotPending;
        return try self.getDocumentChange(story_id, change_id) orelse error.ProposalNotFound;
    }

    pub fn listDiscovery(self: *ProposalStore, story_id: []const u8) ![]domain.DecisionProposal {
        var result: std.ArrayList(domain.DecisionProposal) = .empty;
        errdefer {
            for (result.items) |*proposal| proposal.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        var statement = try self.conn.prepare(
            \\SELECT p.id, p.story_id, p.thread_id, p.status, p.title, p.decision,
            \\       p.proposal_json, p.created_at, p.updated_at
            \\FROM narrative_decision_proposals p
            \\JOIN narrative_author_threads t ON t.id = p.thread_id
            \\WHERE p.story_id = ? AND t.thread_type = 'discovery'
            \\ORDER BY p.created_at DESC
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        while (try statement.step()) {
            try result.append(self.allocator, try readProposal(self.allocator, &statement));
        }
        return try result.toOwnedSlice(self.allocator);
    }

    pub fn get(
        self: *ProposalStore,
        story_id: []const u8,
        proposal_id: []const u8,
    ) !?domain.DecisionProposal {
        var statement = try self.conn.prepare(
            \\SELECT id, story_id, thread_id, status, title, decision,
            \\       proposal_json, created_at, updated_at
            \\FROM narrative_decision_proposals WHERE story_id = ? AND id = ?
        );
        defer statement.deinit();
        try statement.bindText(1, story_id);
        try statement.bindText(2, proposal_id);
        if (!try statement.step()) return null;
        return try readProposal(self.allocator, &statement);
    }

    pub fn setStatus(
        self: *ProposalStore,
        story_id: []const u8,
        proposal_id: []const u8,
        status: []const u8,
    ) !domain.DecisionProposal {
        if (!std.mem.eql(u8, status, "accepted") and !std.mem.eql(u8, status, "rejected"))
            return error.InvalidProposalStatus;
        var statement = try self.conn.prepare(
            "UPDATE narrative_decision_proposals SET status = ?, updated_at = ? WHERE story_id = ? AND id = ? AND status = 'pending'",
        );
        defer statement.deinit();
        try statement.bindText(1, status);
        try statement.bindInt64(2, common.sync.timestamp());
        try statement.bindText(3, story_id);
        try statement.bindText(4, proposal_id);
        try statement.exec();
        if (self.conn.changes() == 0) return error.ProposalNotPending;
        return try self.get(story_id, proposal_id) orelse error.ProposalNotFound;
    }
};

fn readProposal(
    allocator: std.mem.Allocator,
    statement: *storage.Statement,
) !domain.DecisionProposal {
    return .{
        .id = try allocator.dupe(u8, statement.columnText(0) orelse ""),
        .story_id = try allocator.dupe(u8, statement.columnText(1) orelse ""),
        .thread_id = if (statement.columnOptionalText(2)) |value| try allocator.dupe(u8, value) else null,
        .status = try allocator.dupe(u8, statement.columnText(3) orelse ""),
        .title = try allocator.dupe(u8, statement.columnText(4) orelse ""),
        .decision = try allocator.dupe(u8, statement.columnText(5) orelse ""),
        .proposal_json = try allocator.dupe(u8, statement.columnText(6) orelse "{}"),
        .created_at = statement.columnInt64(7),
        .updated_at = statement.columnInt64(8),
    };
}

fn readDocumentChange(
    allocator: std.mem.Allocator,
    statement: *storage.Statement,
) !domain.DocumentChange {
    return .{
        .id = try allocator.dupe(u8, statement.columnText(0) orelse ""),
        .story_id = try allocator.dupe(u8, statement.columnText(1) orelse ""),
        .thread_id = if (statement.columnOptionalText(2)) |value| try allocator.dupe(u8, value) else null,
        .source_proposal_id = try allocator.dupe(u8, statement.columnText(3) orelse ""),
        .record_type = try allocator.dupe(u8, statement.columnText(4) orelse ""),
        .status = try allocator.dupe(u8, statement.columnText(5) orelse ""),
        .revision = statement.columnInt64(6),
        .value_json = try allocator.dupe(u8, statement.columnText(7) orelse "{}"),
        .rationale = try allocator.dupe(u8, statement.columnText(8) orelse ""),
        .supersedes_id = if (statement.columnOptionalText(9)) |value| try allocator.dupe(u8, value) else null,
        .accepted_value_json = try allocator.dupe(u8, statement.columnText(10) orelse "{}"),
        .created_at = statement.columnInt64(11),
        .updated_at = statement.columnInt64(12),
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
