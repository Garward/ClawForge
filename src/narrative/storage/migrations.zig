//! Narrative-owned schema. It is versioned independently from chat storage.

const std = @import("std");
const common = @import("common");
const storage = @import("storage");

pub fn run(conn: *storage.Connection) !void {
    try conn.execSimple(
        \\CREATE TABLE IF NOT EXISTS narrative_schema_version (
        \\    version INTEGER PRIMARY KEY,
        \\    applied_at INTEGER NOT NULL,
        \\    description TEXT NOT NULL
        \\)
    );

    const current = try currentVersion(conn);
    for (migrations, 0..) |migration, index| {
        const version: usize = index + 1;
        if (current >= version) continue;

        std.log.info("Running Narrative migration {d}: {s}", .{ version, migration.description });
        try conn.execSimple("BEGIN IMMEDIATE");
        errdefer conn.execSimple("ROLLBACK") catch {};
        try conn.execMulti(migration.sql);

        var statement = try conn.prepare(
            "INSERT INTO narrative_schema_version (version, applied_at, description) VALUES (?, ?, ?)",
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intCast(version));
        try statement.bindInt64(2, common.sync.timestamp());
        try statement.bindText(3, migration.description);
        try statement.exec();
        try conn.execSimple("COMMIT");
    }
}

fn currentVersion(conn: *storage.Connection) !usize {
    var statement = try conn.prepare("SELECT MAX(version) FROM narrative_schema_version");
    defer statement.deinit();
    if (!try statement.step()) return 0;
    return if (statement.columnOptionalInt64(0)) |version| @intCast(version) else 0;
}

const Migration = struct {
    description: []const u8,
    sql: [*:0]const u8,
};

const migrations = [_]Migration{
    .{ .description = "Narrative workspace foundation", .sql =
    \\CREATE TABLE IF NOT EXISTS narrative_stories (
    \\    id TEXT PRIMARY KEY,
    \\    title TEXT NOT NULL,
    \\    premise TEXT,
    \\    genre TEXT,
    \\    status TEXT NOT NULL DEFAULT 'active',
    \\    active_branch_id TEXT,
    \\    active_version INTEGER NOT NULL DEFAULT 1,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_narrative_stories_updated
    \\    ON narrative_stories(updated_at DESC);
    \\
    \\CREATE TABLE IF NOT EXISTS narrative_branches (
    \\    id TEXT PRIMARY KEY,
    \\    story_id TEXT NOT NULL REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    parent_branch_id TEXT REFERENCES narrative_branches(id) ON DELETE SET NULL,
    \\    name TEXT NOT NULL,
    \\    status TEXT NOT NULL DEFAULT 'accepted',
    \\    head_node_id TEXT,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL,
    \\    UNIQUE(story_id, name)
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_narrative_branches_story
    \\    ON narrative_branches(story_id);
    \\
    \\CREATE TABLE IF NOT EXISTS narrative_story_versions (
    \\    id TEXT PRIMARY KEY,
    \\    story_id TEXT NOT NULL REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    branch_id TEXT NOT NULL REFERENCES narrative_branches(id) ON DELETE CASCADE,
    \\    version_number INTEGER NOT NULL,
    \\    parent_version_id TEXT REFERENCES narrative_story_versions(id),
    \\    reason TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL,
    \\    UNIQUE(story_id, branch_id, version_number)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS narrative_nodes (
    \\    id TEXT PRIMARY KEY,
    \\    story_id TEXT NOT NULL REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    branch_id TEXT REFERENCES narrative_branches(id) ON DELETE CASCADE,
    \\    parent_id TEXT REFERENCES narrative_nodes(id) ON DELETE CASCADE,
    \\    node_type TEXT NOT NULL,
    \\    title TEXT NOT NULL,
    \\    ordinal INTEGER NOT NULL DEFAULT 0,
    \\    lifecycle TEXT NOT NULL DEFAULT 'candidate',
    \\    purpose TEXT,
    \\    synopsis TEXT,
    \\    metadata_json TEXT NOT NULL DEFAULT '{}',
    \\    revision INTEGER NOT NULL DEFAULT 1,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_narrative_nodes_parent
    \\    ON narrative_nodes(story_id, branch_id, parent_id, ordinal);
    \\
    \\CREATE TABLE IF NOT EXISTS narrative_records (
    \\    id TEXT PRIMARY KEY,
    \\    story_id TEXT NOT NULL REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    branch_id TEXT REFERENCES narrative_branches(id) ON DELETE CASCADE,
    \\    parent_id TEXT,
    \\    record_type TEXT NOT NULL,
    \\    lifecycle TEXT NOT NULL,
    \\    truth_class TEXT NOT NULL,
    \\    valid_from_node_id TEXT,
    \\    valid_to_node_id TEXT,
    \\    confidence REAL NOT NULL DEFAULT 1.0,
    \\    value_json TEXT NOT NULL,
    \\    provenance_json TEXT NOT NULL DEFAULT '[]',
    \\    revision INTEGER NOT NULL DEFAULT 1,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_narrative_records_scope
    \\    ON narrative_records(story_id, branch_id, record_type, lifecycle);
    \\
    \\CREATE TABLE IF NOT EXISTS narrative_model_profiles (
    \\    story_id TEXT PRIMARY KEY REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    default_model TEXT,
    \\    role_overrides_json TEXT NOT NULL DEFAULT '{}',
    \\    revision INTEGER NOT NULL DEFAULT 1,
    \\    updated_at INTEGER NOT NULL
    \\);
    },
    .{ .description = "Narrative authoring and import workflow foundation", .sql =
    \\CREATE TABLE IF NOT EXISTS narrative_jobs (
    \\    id TEXT PRIMARY KEY,
    \\    story_id TEXT NOT NULL REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    branch_id TEXT REFERENCES narrative_branches(id) ON DELETE CASCADE,
    \\    job_type TEXT NOT NULL,
    \\    status TEXT NOT NULL,
    \\    state_json TEXT NOT NULL DEFAULT '{}',
    \\    model_snapshot_json TEXT NOT NULL DEFAULT '{}',
    \\    base_story_version INTEGER NOT NULL,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_narrative_jobs_story_status
    \\    ON narrative_jobs(story_id, status, updated_at DESC);
    \\
    \\CREATE TABLE IF NOT EXISTS narrative_job_events (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    job_id TEXT NOT NULL REFERENCES narrative_jobs(id) ON DELETE CASCADE,
    \\    sequence INTEGER NOT NULL,
    \\    event_type TEXT NOT NULL,
    \\    payload_json TEXT NOT NULL DEFAULT '{}',
    \\    created_at INTEGER NOT NULL,
    \\    UNIQUE(job_id, sequence)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS narrative_prose_revisions (
    \\    id TEXT PRIMARY KEY,
    \\    story_id TEXT NOT NULL REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    branch_id TEXT REFERENCES narrative_branches(id) ON DELETE CASCADE,
    \\    node_id TEXT REFERENCES narrative_nodes(id) ON DELETE CASCADE,
    \\    parent_revision_id TEXT REFERENCES narrative_prose_revisions(id),
    \\    lifecycle TEXT NOT NULL,
    \\    author_source TEXT NOT NULL,
    \\    content_hash TEXT NOT NULL,
    \\    word_count INTEGER NOT NULL DEFAULT 0,
    \\    created_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS narrative_prose_blocks (
    \\    id TEXT PRIMARY KEY,
    \\    revision_id TEXT NOT NULL REFERENCES narrative_prose_revisions(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    block_type TEXT NOT NULL,
    \\    text TEXT NOT NULL,
    \\    content_hash TEXT NOT NULL,
    \\    UNIQUE(revision_id, ordinal)
    \\);
    \\CREATE TABLE IF NOT EXISTS narrative_prose_patches (
    \\    id TEXT PRIMARY KEY,
    \\    job_id TEXT REFERENCES narrative_jobs(id) ON DELETE SET NULL,
    \\    parent_revision_id TEXT REFERENCES narrative_prose_revisions(id),
    \\    resulting_revision_id TEXT NOT NULL REFERENCES narrative_prose_revisions(id),
    \\    operation TEXT NOT NULL,
    \\    anchors_json TEXT NOT NULL,
    \\    patch_json TEXT NOT NULL,
    \\    context_manifest_id TEXT,
    \\    created_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS narrative_author_threads (
    \\    id TEXT PRIMARY KEY,
    \\    story_id TEXT NOT NULL REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    branch_id TEXT REFERENCES narrative_branches(id) ON DELETE CASCADE,
    \\    selected_node_id TEXT REFERENCES narrative_nodes(id) ON DELETE SET NULL,
    \\    title TEXT,
    \\    summary TEXT,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS narrative_author_messages (
    \\    id TEXT PRIMARY KEY,
    \\    thread_id TEXT NOT NULL REFERENCES narrative_author_threads(id) ON DELETE CASCADE,
    \\    sequence INTEGER NOT NULL,
    \\    role TEXT NOT NULL,
    \\    content TEXT NOT NULL,
    \\    model_used TEXT,
    \\    created_at INTEGER NOT NULL,
    \\    UNIQUE(thread_id, sequence)
    \\);
    \\CREATE TABLE IF NOT EXISTS narrative_decision_proposals (
    \\    id TEXT PRIMARY KEY,
    \\    story_id TEXT NOT NULL REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    thread_id TEXT REFERENCES narrative_author_threads(id) ON DELETE SET NULL,
    \\    status TEXT NOT NULL DEFAULT 'pending',
    \\    title TEXT NOT NULL,
    \\    decision TEXT NOT NULL,
    \\    proposal_json TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS narrative_import_jobs (
    \\    id TEXT PRIMARY KEY,
    \\    story_id TEXT REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    import_type TEXT NOT NULL,
    \\    status TEXT NOT NULL,
    \\    coverage_json TEXT NOT NULL DEFAULT '{}',
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS narrative_import_sources (
    \\    id TEXT PRIMARY KEY,
    \\    import_job_id TEXT NOT NULL REFERENCES narrative_import_jobs(id) ON DELETE CASCADE,
    \\    display_name TEXT NOT NULL,
    \\    source_type TEXT NOT NULL,
    \\    content_hash TEXT NOT NULL,
    \\    metadata_json TEXT NOT NULL DEFAULT '{}',
    \\    created_at INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS narrative_import_candidates (
    \\    id TEXT PRIMARY KEY,
    \\    import_job_id TEXT NOT NULL REFERENCES narrative_import_jobs(id) ON DELETE CASCADE,
    \\    record_type TEXT NOT NULL,
    \\    status TEXT NOT NULL DEFAULT 'pending',
    \\    candidate_json TEXT NOT NULL,
    \\    evidence_json TEXT NOT NULL,
    \\    confidence REAL NOT NULL,
    \\    conflict_json TEXT NOT NULL DEFAULT '[]',
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    },
    .{ .description = "Guided discovery thread classification", .sql =
    \\ALTER TABLE narrative_author_threads
    \\    ADD COLUMN thread_type TEXT NOT NULL DEFAULT 'author_room';
    \\CREATE INDEX IF NOT EXISTS idx_narrative_author_threads_type
    \\    ON narrative_author_threads(story_id, thread_type, updated_at DESC);
    },
    .{ .description = "Durable narrative import source text for retrieval", .sql =
    \\ALTER TABLE narrative_import_sources
    \\    ADD COLUMN content_text TEXT NOT NULL DEFAULT '';
    \\CREATE INDEX IF NOT EXISTS idx_narrative_import_jobs_story_created
    \\    ON narrative_import_jobs(story_id, created_at DESC);
    },
    .{ .description = "Addressable narrative source chunks for shared embeddings", .sql =
    \\CREATE TABLE IF NOT EXISTS narrative_import_source_chunks (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    source_id TEXT NOT NULL REFERENCES narrative_import_sources(id) ON DELETE CASCADE,
    \\    story_id TEXT NOT NULL REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    chunk_text TEXT NOT NULL,
    \\    context_header TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL,
    \\    UNIQUE(source_id, ordinal)
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_narrative_source_chunks_story
    \\    ON narrative_import_source_chunks(story_id, id);
    },
    .{ .description = "Document-level proposal revisions", .sql =
    \\CREATE TABLE IF NOT EXISTS narrative_document_changes (
    \\    id TEXT PRIMARY KEY,
    \\    story_id TEXT NOT NULL REFERENCES narrative_stories(id) ON DELETE CASCADE,
    \\    thread_id TEXT REFERENCES narrative_author_threads(id) ON DELETE SET NULL,
    \\    source_proposal_id TEXT NOT NULL REFERENCES narrative_decision_proposals(id) ON DELETE CASCADE,
    \\    record_type TEXT NOT NULL,
    \\    status TEXT NOT NULL DEFAULT 'pending',
    \\    revision INTEGER NOT NULL,
    \\    value_json TEXT NOT NULL,
    \\    rationale TEXT NOT NULL DEFAULT '',
    \\    supersedes_id TEXT REFERENCES narrative_document_changes(id) ON DELETE SET NULL,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL
    \\);
    \\INSERT INTO narrative_document_changes
    \\    (id, story_id, thread_id, source_proposal_id, record_type, status,
    \\     revision, value_json, rationale, created_at, updated_at)
    \\SELECT p.id || '-' || printf('%02d', CAST(j.key AS INTEGER)),
    \\       p.story_id, p.thread_id, p.id,
    \\       json_extract(j.value, '$.record_type'),
    \\       CASE WHEN p.status = 'pending' AND EXISTS (
    \\           SELECT 1
    \\           FROM narrative_decision_proposals newer,
    \\                json_each(newer.proposal_json, '$.record_patches') newer_patch
    \\           WHERE newer.story_id = p.story_id
    \\             AND newer.status = 'pending'
    \\             AND json_extract(newer_patch.value, '$.record_type') =
    \\                 json_extract(j.value, '$.record_type')
    \\             AND (newer.created_at > p.created_at OR
    \\                  (newer.created_at = p.created_at AND newer.id > p.id))
    \\       ) THEN 'superseded' ELSE p.status END,
    \\       1 + (
    \\           SELECT COUNT(*)
    \\           FROM narrative_decision_proposals older,
    \\                json_each(older.proposal_json, '$.record_patches') older_patch
    \\           WHERE older.story_id = p.story_id
    \\             AND json_extract(older_patch.value, '$.record_type') =
    \\                 json_extract(j.value, '$.record_type')
    \\             AND (older.created_at < p.created_at OR
    \\                  (older.created_at = p.created_at AND older.id < p.id))
    \\       ),
    \\       json_extract(j.value, '$.value_json'),
    \\       COALESCE(json_extract(j.value, '$.rationale'), ''),
    \\       p.created_at, p.updated_at
    \\FROM narrative_decision_proposals p,
    \\     json_each(p.proposal_json, '$.record_patches') j;
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_narrative_document_changes_pending
    \\    ON narrative_document_changes(story_id, record_type)
    \\    WHERE status = 'pending';
    \\CREATE INDEX IF NOT EXISTS idx_narrative_document_changes_history
    \\    ON narrative_document_changes(story_id, record_type, revision DESC);
    },
};
