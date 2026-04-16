const std = @import("std");
const db_mod = @import("db.zig");

/// Run all pending migrations. Idempotent — safe to call on every startup.
pub fn runMigrations(conn: *db_mod.Connection) !void {
    // Create version tracking table
    try conn.execSimple(
        \\CREATE TABLE IF NOT EXISTS schema_version (
        \\    version INTEGER PRIMARY KEY,
        \\    applied_at INTEGER NOT NULL,
        \\    description TEXT
        \\)
    );

    const current = try getCurrentVersion(conn);

    // Run each migration that hasn't been applied
    inline for (migrations, 0..) |migration, i| {
        const version = i + 1;
        if (current < version) {
            std.log.info("Running migration {d}: {s}", .{ version, migration.description });
            try conn.execMulti(migration.sql);
            try recordVersion(conn, version, migration.description);
        }
    }

    std.log.info("Database at version {d}", .{@max(current, migrations.len)});
}

fn getCurrentVersion(conn: *db_mod.Connection) !usize {
    var stmt = try conn.prepare("SELECT MAX(version) FROM schema_version");
    defer stmt.deinit();

    if (try stmt.step()) {
        const ver = stmt.columnOptionalInt64(0);
        return if (ver) |v| @intCast(v) else 0;
    }
    return 0;
}

fn recordVersion(conn: *db_mod.Connection, version: usize, description: []const u8) !void {
    var stmt = try conn.prepare("INSERT INTO schema_version (version, applied_at, description) VALUES (?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindInt64(1, @intCast(version));
    try stmt.bindInt64(2, std.time.timestamp());
    try stmt.bindText(3, description);
    try stmt.exec();
}

const Migration = struct {
    description: []const u8,
    sql: [*:0]const u8,
};

/// Ordered list of migrations. Each is applied exactly once.
const migrations = [_]Migration{
    .{
        .description = "Core tables: namespaces, sessions, messages",
        .sql =
        // Namespace tree
        \\CREATE TABLE IF NOT EXISTS namespaces (
        \\    id          INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    parent_id   INTEGER REFERENCES namespaces(id) ON DELETE CASCADE,
        \\    name        TEXT NOT NULL,
        \\    node_type   TEXT NOT NULL,
        \\    metadata    TEXT DEFAULT '{}',
        \\    created_at  INTEGER NOT NULL,
        \\    updated_at  INTEGER NOT NULL,
        \\    UNIQUE(parent_id, name)
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS namespace_paths (
        \\    namespace_id INTEGER PRIMARY KEY REFERENCES namespaces(id) ON DELETE CASCADE,
        \\    full_path    TEXT NOT NULL UNIQUE,
        \\    depth        INTEGER NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_namespaces_parent ON namespaces(parent_id);
        \\CREATE INDEX IF NOT EXISTS idx_namespace_paths_prefix ON namespace_paths(full_path);
        \\
        // Projects
        \\CREATE TABLE IF NOT EXISTS projects (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
        \\    name            TEXT NOT NULL,
        \\    description     TEXT,
        \\    status          TEXT DEFAULT 'active',
        \\    rolling_summary TEXT,
        \\    rolling_state   TEXT DEFAULT '{}',
        \\    metadata        TEXT DEFAULT '{}',
        \\    created_at      INTEGER NOT NULL,
        \\    updated_at      INTEGER NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_projects_namespace ON projects(namespace_id);
        \\CREATE INDEX IF NOT EXISTS idx_projects_status ON projects(status);
        \\CREATE INDEX IF NOT EXISTS idx_projects_updated ON projects(updated_at);
        \\
        // Sessions
        \\CREATE TABLE IF NOT EXISTS sessions (
        \\    id              TEXT PRIMARY KEY,
        \\    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
        \\    project_id      INTEGER REFERENCES projects(id) ON DELETE SET NULL,
        \\    name            TEXT,
        \\    model           TEXT NOT NULL,
        \\    system_prompt   TEXT,
        \\    status          TEXT DEFAULT 'active',
        \\    message_count   INTEGER DEFAULT 0,
        \\    metadata        TEXT DEFAULT '{}',
        \\    created_at      INTEGER NOT NULL,
        \\    updated_at      INTEGER NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_sessions_namespace ON sessions(namespace_id);
        \\CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_id);
        \\CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
        \\CREATE INDEX IF NOT EXISTS idx_sessions_updated ON sessions(updated_at);
        \\
        // Messages
        \\CREATE TABLE IF NOT EXISTS messages (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    session_id      TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        \\    sequence        INTEGER NOT NULL,
        \\    role            TEXT NOT NULL,
        \\    content         TEXT NOT NULL,
        \\    model_used      TEXT,
        \\    route_tier      TEXT,
        \\    route_reason    TEXT,
        \\    input_tokens    INTEGER,
        \\    output_tokens   INTEGER,
        \\    created_at      INTEGER NOT NULL,
        \\    UNIQUE(session_id, sequence)
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, sequence);
        \\CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at);
        \\CREATE INDEX IF NOT EXISTS idx_messages_role ON messages(session_id, role);
        \\
        // Context snapshots
        \\CREATE TABLE IF NOT EXISTS context_snapshots (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    session_id      TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        \\    at_message      INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        \\    reason          TEXT NOT NULL,
        \\    system_prompt   TEXT,
        \\    model_active    TEXT,
        \\    tools_active    TEXT,
        \\    message_count   INTEGER,
        \\    interface_state TEXT DEFAULT '{}',
        \\    user_context    TEXT DEFAULT '{}',
        \\    conversation_context TEXT DEFAULT '{}',
        \\    created_at      INTEGER NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_context_snapshots_session ON context_snapshots(session_id, at_message);
        \\
        // Tool calls
        \\CREATE TABLE IF NOT EXISTS tool_calls (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    message_id      INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        \\    session_id      TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        \\    sequence        INTEGER NOT NULL,
        \\    tool_name       TEXT NOT NULL,
        \\    tool_input      TEXT NOT NULL,
        \\    tool_result     TEXT,
        \\    status          TEXT DEFAULT 'success',
        \\    approved        BOOLEAN,
        \\    duration_ms     INTEGER,
        \\    metadata        TEXT DEFAULT '{}',
        \\    created_at      INTEGER NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_tool_calls_session ON tool_calls(session_id, sequence);
        \\CREATE INDEX IF NOT EXISTS idx_tool_calls_message ON tool_calls(message_id);
        \\
        // FTS for messages
        \\CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
        \\    content,
        \\    role,
        \\    content='messages',
        \\    content_rowid='id',
        \\    tokenize='porter unicode61'
        \\);
        \\
        // Auto-sync message FTS
        \\CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages BEGIN
        \\    INSERT INTO messages_fts(rowid, content, role)
        \\    VALUES (new.id, new.content, new.role);
        \\END;
        \\
        \\CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages BEGIN
        \\    INSERT INTO messages_fts(messages_fts, rowid, content, role)
        \\    VALUES ('delete', old.id, old.content, old.role);
        \\END;
        \\
        // Auto-update session message count
        \\CREATE TRIGGER IF NOT EXISTS messages_count_insert AFTER INSERT ON messages BEGIN
        \\    UPDATE sessions SET
        \\        message_count = message_count + 1,
        \\        updated_at = new.created_at
        \\    WHERE id = new.session_id;
        \\END;
        ,
    },
    .{
        .description = "Summaries table with FTS",
        .sql =
        \\CREATE TABLE IF NOT EXISTS summaries (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
        \\    session_id      TEXT REFERENCES sessions(id) ON DELETE SET NULL,
        \\    project_id      INTEGER REFERENCES projects(id) ON DELETE SET NULL,
        \\    scope           TEXT NOT NULL,
        \\    granularity     TEXT NOT NULL,
        \\    start_message   INTEGER REFERENCES messages(id),
        \\    end_message     INTEGER REFERENCES messages(id),
        \\    start_time      INTEGER NOT NULL,
        \\    end_time        INTEGER NOT NULL,
        \\    message_count   INTEGER NOT NULL,
        \\    summary         TEXT NOT NULL,
        \\    topics          TEXT,
        \\    participants    TEXT,
        \\    final_state     TEXT,
        \\    continuation    TEXT,
        \\    recall          TEXT DEFAULT '{}',
        \\    model_used      TEXT,
        \\    token_cost      INTEGER,
        \\    created_at      INTEGER NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_summaries_namespace ON summaries(namespace_id);
        \\CREATE INDEX IF NOT EXISTS idx_summaries_session ON summaries(session_id);
        \\CREATE INDEX IF NOT EXISTS idx_summaries_project ON summaries(project_id);
        \\CREATE INDEX IF NOT EXISTS idx_summaries_scope ON summaries(scope, granularity);
        \\CREATE INDEX IF NOT EXISTS idx_summaries_time ON summaries(start_time, end_time);
        \\
        \\CREATE VIRTUAL TABLE IF NOT EXISTS summaries_fts USING fts5(
        \\    summary,
        \\    topics,
        \\    recall,
        \\    content='summaries',
        \\    content_rowid='id',
        \\    tokenize='porter unicode61'
        \\);
        \\
        \\CREATE TRIGGER IF NOT EXISTS summaries_fts_insert AFTER INSERT ON summaries BEGIN
        \\    INSERT INTO summaries_fts(rowid, summary, topics, recall)
        \\    VALUES (new.id, new.summary, new.topics, new.recall);
        \\END;
        \\
        \\CREATE TRIGGER IF NOT EXISTS summaries_fts_delete AFTER DELETE ON summaries BEGIN
        \\    INSERT INTO summaries_fts(summaries_fts, rowid, summary, topics, recall)
        \\    VALUES ('delete', old.id, old.summary, old.topics, old.recall);
        \\END;
        ,
    },
    .{
        .description = "Knowledge table with FTS and confidence",
        .sql =
        \\CREATE TABLE IF NOT EXISTS knowledge (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
        \\    category        TEXT NOT NULL,
        \\    subcategory     TEXT,
        \\    title           TEXT NOT NULL,
        \\    content         TEXT NOT NULL,
        \\    confidence      REAL DEFAULT 1.0,
        \\    mention_count   INTEGER DEFAULT 1,
        \\    source_sessions TEXT,
        \\    first_seen      INTEGER NOT NULL,
        \\    last_reinforced INTEGER NOT NULL,
        \\    contradicted_by TEXT,
        \\    tags            TEXT DEFAULT '[]',
        \\    related_ids     TEXT DEFAULT '[]',
        \\    metadata        TEXT DEFAULT '{}',
        \\    created_at      INTEGER NOT NULL,
        \\    updated_at      INTEGER NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_knowledge_namespace ON knowledge(namespace_id);
        \\CREATE INDEX IF NOT EXISTS idx_knowledge_category ON knowledge(category, subcategory);
        \\CREATE INDEX IF NOT EXISTS idx_knowledge_confidence ON knowledge(confidence);
        \\CREATE INDEX IF NOT EXISTS idx_knowledge_reinforced ON knowledge(last_reinforced);
        \\
        \\CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
        \\    title,
        \\    content,
        \\    category,
        \\    subcategory,
        \\    tags,
        \\    content='knowledge',
        \\    content_rowid='id',
        \\    tokenize='porter unicode61'
        \\);
        \\
        \\CREATE TRIGGER IF NOT EXISTS knowledge_fts_insert AFTER INSERT ON knowledge BEGIN
        \\    INSERT INTO knowledge_fts(rowid, title, content, category, subcategory, tags)
        \\    VALUES (new.id, new.title, new.content, new.category, new.subcategory, new.tags);
        \\END;
        \\
        \\CREATE TRIGGER IF NOT EXISTS knowledge_fts_delete AFTER DELETE ON knowledge BEGIN
        \\    INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content, category, subcategory, tags)
        \\    VALUES ('delete', old.id, old.title, old.content, old.category, old.subcategory, old.tags);
        \\END;
        ,
    },
    .{
        .description = "Embeddings table for vector search",
        .sql =
        \\CREATE TABLE IF NOT EXISTS embeddings (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    source_type     TEXT NOT NULL,
        \\    source_id       INTEGER NOT NULL,
        \\    namespace_id    INTEGER REFERENCES namespaces(id) ON DELETE CASCADE,
        \\    chunk_text      TEXT NOT NULL,
        \\    context_header  TEXT,
        \\    model           TEXT NOT NULL,
        \\    dimensions      INTEGER NOT NULL,
        \\    vector_fp32     BLOB,
        \\    vector_binary   BLOB,
        \\    created_at      INTEGER NOT NULL,
        \\    UNIQUE(source_type, source_id)
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_embeddings_source ON embeddings(source_type, source_id);
        \\CREATE INDEX IF NOT EXISTS idx_embeddings_namespace ON embeddings(namespace_id);
        ,
    },
    .{
        .description = "Generated tools table",
        .sql =
        \\CREATE TABLE IF NOT EXISTS generated_tools (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
        \\    name            TEXT NOT NULL UNIQUE,
        \\    description     TEXT NOT NULL,
        \\    input_schema    TEXT NOT NULL DEFAULT '{}',
        \\    implementation  TEXT NOT NULL,
        \\    language        TEXT NOT NULL DEFAULT 'bash',
        \\    status          TEXT NOT NULL DEFAULT 'pending',
        \\    requires_confirmation BOOLEAN DEFAULT 1,
        \\    test_output     TEXT,
        \\    approved_by     TEXT,
        \\    created_at      INTEGER NOT NULL,
        \\    updated_at      INTEGER NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_generated_tools_ns ON generated_tools(namespace_id);
        \\CREATE INDEX IF NOT EXISTS idx_generated_tools_status ON generated_tools(status);
        ,
    },
    .{
        .description = "Make tool_calls.message_id nullable (tool calls are recorded before message is stored)",
        .sql =
        \\CREATE TABLE IF NOT EXISTS tool_calls_new (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    message_id      INTEGER,
        \\    session_id      TEXT NOT NULL,
        \\    sequence        INTEGER NOT NULL,
        \\    tool_name       TEXT NOT NULL,
        \\    tool_input      TEXT NOT NULL,
        \\    tool_result     TEXT,
        \\    status          TEXT DEFAULT 'success',
        \\    approved        BOOLEAN,
        \\    duration_ms     INTEGER,
        \\    metadata        TEXT DEFAULT '{}',
        \\    created_at      INTEGER NOT NULL
        \\);
        \\INSERT OR IGNORE INTO tool_calls_new SELECT * FROM tool_calls;
        \\DROP TABLE IF EXISTS tool_calls;
        \\ALTER TABLE tool_calls_new RENAME TO tool_calls;
        \\CREATE INDEX IF NOT EXISTS idx_tool_calls_session ON tool_calls(session_id, sequence);
        \\CREATE INDEX IF NOT EXISTS idx_tool_calls_name ON tool_calls(tool_name, created_at);
        ,
    },
    .{
        .description = "Skills table — reusable instruction templates with trigger matching",
        .sql =
        \\CREATE TABLE IF NOT EXISTS skills (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
        \\    name            TEXT NOT NULL,
        \\    category        TEXT NOT NULL DEFAULT 'general',
        \\    trigger_type    TEXT NOT NULL DEFAULT 'always',
        \\    trigger_value   TEXT,
        \\    instruction     TEXT NOT NULL,
        \\    priority        INTEGER DEFAULT 0,
        \\    enabled         BOOLEAN DEFAULT 1,
        \\    created_at      INTEGER NOT NULL,
        \\    updated_at      INTEGER NOT NULL,
        \\    UNIQUE(namespace_id, name)
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_skills_namespace ON skills(namespace_id);
        \\CREATE INDEX IF NOT EXISTS idx_skills_trigger ON skills(trigger_type, enabled);
        \\CREATE INDEX IF NOT EXISTS idx_skills_category ON skills(category);
        \\
        \\CREATE VIRTUAL TABLE IF NOT EXISTS skills_fts USING fts5(
        \\    name, instruction, category,
        \\    content='skills', content_rowid='id',
        \\    tokenize='porter unicode61'
        \\);
        \\
        \\CREATE TRIGGER IF NOT EXISTS skills_fts_insert AFTER INSERT ON skills BEGIN
        \\    INSERT INTO skills_fts(rowid, name, instruction, category)
        \\    VALUES (new.id, new.name, new.instruction, new.category);
        \\END;
        \\CREATE TRIGGER IF NOT EXISTS skills_fts_delete AFTER DELETE ON skills BEGIN
        \\    INSERT INTO skills_fts(skills_fts, rowid, name, instruction, category)
        \\    VALUES ('delete', old.id, old.name, old.instruction, old.category);
        \\END;
        \\CREATE TRIGGER IF NOT EXISTS skills_fts_update AFTER UPDATE ON skills BEGIN
        \\    INSERT INTO skills_fts(skills_fts, rowid, name, instruction, category)
        \\    VALUES ('delete', old.id, old.name, old.instruction, old.category);
        \\    INSERT INTO skills_fts(rowid, name, instruction, category)
        \\    VALUES (new.id, new.name, new.instruction, new.category);
        \\END;
        ,
    },
    .{
        .description = "Artifacts + artifact_analysis (vision/OCR cache)",
        .sql =
        \\CREATE TABLE IF NOT EXISTS artifacts (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
        \\    session_id      TEXT REFERENCES sessions(id) ON DELETE SET NULL,
        \\    name            TEXT NOT NULL,
        \\    artifact_type   TEXT NOT NULL,
        \\    mime_type       TEXT,
        \\    content_path    TEXT,
        \\    content_size    INTEGER,
        \\    content_hash    TEXT,
        \\    description     TEXT,
        \\    source          TEXT,
        \\    created_at      INTEGER NOT NULL,
        \\    updated_at      INTEGER NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_artifacts_namespace ON artifacts(namespace_id);
        \\CREATE INDEX IF NOT EXISTS idx_artifacts_session ON artifacts(session_id);
        \\CREATE INDEX IF NOT EXISTS idx_artifacts_hash ON artifacts(content_hash);
        \\
        \\CREATE TABLE IF NOT EXISTS artifact_analysis (
        \\    id              INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    artifact_id     INTEGER NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
        \\    content_hash    TEXT NOT NULL,
        \\    analysis_type   TEXT NOT NULL,
        \\    detail_level    TEXT NOT NULL DEFAULT 'low',
        \\    description     TEXT NOT NULL,
        \\    structured_data TEXT,
        \\    model_used      TEXT NOT NULL,
        \\    input_tokens    INTEGER,
        \\    output_tokens   INTEGER,
        \\    prompt_used     TEXT,
        \\    created_at      INTEGER NOT NULL,
        \\    UNIQUE(content_hash, analysis_type, detail_level)
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_artifact_analysis_hash ON artifact_analysis(content_hash);
        \\CREATE INDEX IF NOT EXISTS idx_artifact_analysis_artifact ON artifact_analysis(artifact_id);
        ,
    },
    .{
        .description = "Add active_plan column to sessions for agent task tracking",
        .sql =
        \\ALTER TABLE sessions ADD COLUMN active_plan TEXT;
        ,
    },
};
