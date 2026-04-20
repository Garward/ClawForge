-- ClawForge Unified Storage Schema
-- SQLite (portable, no server process, good enough for single-machine)
--
-- TWO-DATABASE ARCHITECTURE:
--
--   1. core.db (one per installation)
--      - Adapter registry, auth, daemon config
--      - User registry (points to workspace DBs)
--      - Global shared knowledge
--
--   2. <user>.db (one per user — their workspace/brain)
--      - All their sessions, messages, artifacts, knowledge
--      - Projects (the primary organizational unit)
--      - Rolling context per project (updated every prompt)
--      - Interface-specific data under adapter namespaces
--
-- Why split: each user's workspace is self-contained, portable,
-- and backupable independently. A user's DB IS their brain.
--
-- WORKSPACE LAYOUT (logical, within user.db namespace tree):
--
--   <user>/
--   ├── shared/                      # Cross-project knowledge and tools
--   │   ├── knowledge/               # Distilled insights (the knowledge table)
--   │   └── tools/                   # Shared configs, scripts, templates
--   ├── projects/                    # The primary organizational unit
--   │   ├── clawforge/               # Sessions migrate here as they focus
--   │   │   ├── rolling_context      # Live project state, updated per prompt
--   │   │   ├── sessions/            # From any interface
--   │   │   ├── artifacts/
--   │   │   └── summaries/
--   │   ├── game-db-decode/
--   │   └── gargpt/
--   ├── cli/                         # Interface-specific, non-project chat
--   ├── discord/
--   │   └── guild-123/
--   │       └── channel-general/     # Social chat, not project-tied
--   └── web/
--
-- KEY CONCEPT: Conversations are claimed by projects as they develop.
-- A session might start in discord/guild-123/general and get reclassified
-- to projects/clawforge once the topic becomes clear. The rolling context
-- for that project updates with every prompt across any interface.

-- ============================================================
-- CORE TABLES (framework-provided, all adapters use these)
-- ============================================================

-- Namespace tree — hierarchical path nodes
-- Each node has a parent, forming a tree. Adapters create their own subtrees.
CREATE TABLE IF NOT EXISTS namespaces (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_id   INTEGER REFERENCES namespaces(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,           -- segment name: "cli", "guild-123", "project-foo"
    node_type   TEXT NOT NULL,           -- "user", "adapter", "context" (adapter-defined subtypes)
    metadata    TEXT DEFAULT '{}',       -- JSON blob, unlimited adapter-specific metadata
    created_at  INTEGER NOT NULL,        -- unix timestamp
    updated_at  INTEGER NOT NULL,

    UNIQUE(parent_id, name)
);

-- Full materialized path for fast lookups without recursive queries
-- Updated via triggers when namespace tree changes
CREATE TABLE IF NOT EXISTS namespace_paths (
    namespace_id INTEGER PRIMARY KEY REFERENCES namespaces(id) ON DELETE CASCADE,
    full_path    TEXT NOT NULL UNIQUE,   -- "<user>/cli/project-clawforge"
    depth        INTEGER NOT NULL        -- 0 = root user, 1 = adapter, 2+ = context
);

-- Projects — the primary organizational unit.
-- Conversations get claimed by projects as they develop.
-- A project's rolling context is the "working memory" for that project.
CREATE TABLE IF NOT EXISTS projects (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    description     TEXT,
    status          TEXT DEFAULT 'active', -- "active", "paused", "completed", "archived"

    -- Rolling context — the live "working memory" for this project.
    -- Updated with every prompt that touches this project.
    -- This is what gets injected into context instead of replaying full history.
    -- One narrative field + one flexible JSON blob. That's it.
    rolling_summary TEXT,                 -- narrative: what this is and where it stands right now
    rolling_state   TEXT DEFAULT '{}',    -- JSON: structured state, fields vary by project type
    --
    -- The summarizer decides what fields go here based on what the project IS.
    -- Software project: {focus, recent_changes, blockers, open_questions, ...}
    -- Game DB decode: {mapped_fields, unknown_fields, assumptions, next_experiment, ...}
    -- Recipe collection: {categories, recent_additions, favorites, ...}
    -- D&D campaign: {current_arc, party_status, npc_relations, next_session_prep, ...}
    -- Music project: {tracks, mix_status, reference_notes, ...}

    metadata        TEXT DEFAULT '{}',
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL      -- bumped on every rolling context update
);

CREATE INDEX IF NOT EXISTS idx_projects_namespace ON projects(namespace_id);
CREATE INDEX IF NOT EXISTS idx_projects_status ON projects(status);
CREATE INDEX IF NOT EXISTS idx_projects_updated ON projects(updated_at);

CREATE VIRTUAL TABLE IF NOT EXISTS projects_fts USING fts5(
    name,
    description,
    rolling_summary,
    rolling_state,
    content='projects',
    content_rowid='id',
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS projects_fts_insert AFTER INSERT ON projects BEGIN
    INSERT INTO projects_fts(rowid, name, description, rolling_summary, rolling_state)
    VALUES (new.id, new.name, new.description, new.rolling_summary, new.rolling_state);
END;

CREATE TRIGGER IF NOT EXISTS projects_fts_delete AFTER DELETE ON projects BEGIN
    INSERT INTO projects_fts(projects_fts, rowid, name, description, rolling_summary, rolling_state)
    VALUES ('delete', old.id, old.name, old.description, old.rolling_summary, old.rolling_state);
END;

CREATE TRIGGER IF NOT EXISTS projects_fts_update AFTER UPDATE ON projects BEGIN
    INSERT INTO projects_fts(projects_fts, rowid, name, description, rolling_summary, rolling_state)
    VALUES ('delete', old.id, old.name, old.description, old.rolling_summary, old.rolling_state);
    INSERT INTO projects_fts(rowid, name, description, rolling_summary, rolling_state)
    VALUES (new.id, new.name, new.description, new.rolling_summary, new.rolling_state);
END;

-- Sessions — a conversation, scoped to a namespace
CREATE TABLE IF NOT EXISTS sessions (
    id              TEXT PRIMARY KEY,    -- UUID
    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
    project_id      INTEGER REFERENCES projects(id) ON DELETE SET NULL, -- null = unattached
    name            TEXT,                -- human-readable label
    model           TEXT NOT NULL,       -- model or "auto" for routing
    system_prompt   TEXT,                -- active system prompt
    status          TEXT DEFAULT 'active',  -- "active", "archived", "summarized"
    message_count   INTEGER DEFAULT 0,
    metadata        TEXT DEFAULT '{}',   -- JSON: adapter-specific session data
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);

-- Messages — individual messages with full context envelope
CREATE TABLE IF NOT EXISTS messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    sequence        INTEGER NOT NULL,    -- order within session (0-indexed)
    role            TEXT NOT NULL,        -- "user", "assistant", "system", "tool"
    content         TEXT NOT NULL,
    model_used      TEXT,                -- which model actually responded (null for user messages)
    route_tier      TEXT,                -- "fast", "default", "smart" (null if not auto-routed)
    route_reason    TEXT,                -- why this tier was chosen

    -- Token accounting
    input_tokens    INTEGER,
    output_tokens   INTEGER,

    -- Timestamps
    created_at      INTEGER NOT NULL,

    UNIQUE(session_id, sequence)
);

-- Context snapshots — the world state at the time a message was sent
-- Stored per-message so recall can reconstruct what was happening
-- Not stored per-message — that's too expensive. Stored at checkpoints:
-- every N messages, on system prompt change, on model change, on session pause.
-- When recalling a specific message, find the nearest prior snapshot.
CREATE TABLE IF NOT EXISTS context_snapshots (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    at_message      INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    reason          TEXT NOT NULL,        -- "periodic", "prompt_change", "model_change", "pause", "resume"

    -- Conversation state at this point
    system_prompt   TEXT,
    model_active    TEXT,
    tools_active    TEXT,                -- JSON array
    message_count   INTEGER,

    -- Context blobs — adapter and user fill what's relevant
    interface_state TEXT DEFAULT '{}',   -- JSON: cwd, files, guild, channel, whatever
    user_context    TEXT DEFAULT '{}',   -- JSON: interests, expertise, comm style
    conversation_context TEXT DEFAULT '{}', -- JSON: topic, mood, what's being worked on

    created_at      INTEGER NOT NULL
);

-- Tool calls — linked to the assistant message that triggered them
-- Tracks not just what happened but how useful it was, so recall can rank
-- "which approach worked best" without replaying the whole conversation
CREATE TABLE IF NOT EXISTS tool_calls (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id      INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    session_id      TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    sequence        INTEGER NOT NULL,    -- order within session (across all messages)
    tool_name       TEXT NOT NULL,
    tool_input      TEXT NOT NULL,        -- JSON
    tool_result     TEXT,                 -- result content

    -- Outcome
    status          TEXT DEFAULT 'success', -- "success", "error", "rejected", "timeout"
    approved        BOOLEAN,             -- null = no confirmation needed
    duration_ms     INTEGER,

    -- AI-extracted context (populated by summarizer, not at insert time)
    -- Keeps the hot path cheap — raw data in, enrichment later
    metadata        TEXT DEFAULT '{}',   -- JSON: intent, result_summary, error_type, retry_of, etc.

    created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tool_calls_session ON tool_calls(session_id, sequence);
CREATE INDEX IF NOT EXISTS idx_tool_calls_status ON tool_calls(session_id, status);
CREATE INDEX IF NOT EXISTS idx_tool_calls_name ON tool_calls(tool_name);

-- ============================================================
-- ARTIFACTS — files, images, scripts, code, any binary or text blob
-- The "files in folders" equivalent — anything can be attached anywhere
-- ============================================================

-- Artifacts stored in the DB or referenced on disk (large files)
CREATE TABLE IF NOT EXISTS artifacts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
    session_id      TEXT REFERENCES sessions(id) ON DELETE SET NULL,
    message_id      INTEGER REFERENCES messages(id) ON DELETE SET NULL,

    -- What is this
    name            TEXT NOT NULL,        -- filename or label: "schema.sql", "screenshot.png"
    artifact_type   TEXT NOT NULL,        -- "text", "code", "image", "binary", "link", "snippet"
    mime_type       TEXT,                 -- "text/plain", "image/png", "application/json"
    language        TEXT,                 -- for code: "zig", "python", "sql"

    -- Content — either inline or on disk
    content_text    TEXT,                 -- inline text/code content (null for binary)
    content_path    TEXT,                 -- path to file on disk for large/binary artifacts
    content_size    INTEGER,             -- size in bytes

    -- Context — why does this exist
    description     TEXT,                 -- what this is and why it was created/attached
    source          TEXT,                 -- "user_upload", "generated", "tool_output", "reference"
    tags            TEXT DEFAULT '[]',    -- JSON array of searchable tags

    -- Metadata
    metadata        TEXT DEFAULT '{}',    -- JSON: adapter-specific, unlimited
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);

-- Cached analysis of artifacts (images, documents, code files, etc.)
-- Read once by an LLM, never pay for the same analysis twice.
-- Keyed by content hash so identical files share cached descriptions.
CREATE TABLE IF NOT EXISTS artifact_analysis (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    artifact_id     INTEGER NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
    content_hash    TEXT NOT NULL,        -- SHA-256 of the original content (dedup key)
    analysis_type   TEXT NOT NULL,        -- "image_description", "code_review", "document_summary"
    detail_level    TEXT NOT NULL,        -- "low", "high" (maps to vision detail param)

    -- The cached analysis
    description     TEXT NOT NULL,        -- the LLM's description/analysis
    structured_data TEXT,                 -- JSON: extracted data (OCR text, objects detected, etc.)

    -- What produced this
    model_used      TEXT NOT NULL,        -- which model did the analysis
    input_tokens    INTEGER,
    output_tokens   INTEGER,
    prompt_used     TEXT,                 -- the prompt that produced this (for reproducibility)

    created_at      INTEGER NOT NULL,

    UNIQUE(content_hash, analysis_type, detail_level)
);

CREATE INDEX IF NOT EXISTS idx_artifact_analysis_hash ON artifact_analysis(content_hash);
CREATE INDEX IF NOT EXISTS idx_artifact_analysis_artifact ON artifact_analysis(artifact_id);
CREATE INDEX IF NOT EXISTS idx_artifact_analysis_type ON artifact_analysis(analysis_type);

-- FTS over cached analyses so they're searchable too
CREATE VIRTUAL TABLE IF NOT EXISTS artifact_analysis_fts USING fts5(
    description,
    structured_data,
    content='artifact_analysis',
    content_rowid='id',
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS artifact_analysis_fts_insert AFTER INSERT ON artifact_analysis BEGIN
    INSERT INTO artifact_analysis_fts(rowid, description, structured_data)
    VALUES (new.id, new.description, new.structured_data);
END;

CREATE TRIGGER IF NOT EXISTS artifact_analysis_fts_delete AFTER DELETE ON artifact_analysis BEGIN
    INSERT INTO artifact_analysis_fts(artifact_analysis_fts, rowid, description, structured_data)
    VALUES ('delete', old.id, old.description, old.structured_data);
END;

-- Links between artifacts (dependencies, versions, related files)
CREATE TABLE IF NOT EXISTS artifact_links (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id       INTEGER NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
    target_id       INTEGER NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
    link_type       TEXT NOT NULL,        -- "version_of", "depends_on", "derived_from", "related_to"
    metadata        TEXT DEFAULT '{}',
    created_at      INTEGER NOT NULL,

    UNIQUE(source_id, target_id, link_type)
);

-- FTS over artifacts
CREATE VIRTUAL TABLE IF NOT EXISTS artifacts_fts USING fts5(
    name,
    content_text,
    description,
    tags,
    content='artifacts',
    content_rowid='id',
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS artifacts_fts_insert AFTER INSERT ON artifacts BEGIN
    INSERT INTO artifacts_fts(rowid, name, content_text, description, tags)
    VALUES (new.id, new.name, new.content_text, new.description, new.tags);
END;

CREATE TRIGGER IF NOT EXISTS artifacts_fts_delete AFTER DELETE ON artifacts BEGIN
    INSERT INTO artifacts_fts(artifacts_fts, rowid, name, content_text, description, tags)
    VALUES ('delete', old.id, old.name, old.content_text, old.description, old.tags);
END;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_artifacts_namespace ON artifacts(namespace_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_session ON artifacts(session_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_message ON artifacts(message_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_type ON artifacts(artifact_type);
CREATE INDEX IF NOT EXISTS idx_artifact_links_source ON artifact_links(source_id);
CREATE INDEX IF NOT EXISTS idx_artifact_links_target ON artifact_links(target_id);

-- ============================================================
-- SUMMARIZATION TABLES
-- ============================================================

-- Multi-level summaries — compress old context at various granularities
CREATE TABLE IF NOT EXISTS summaries (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
    session_id      TEXT REFERENCES sessions(id) ON DELETE SET NULL,
    scope           TEXT NOT NULL,        -- "conversation", "session", "period", "project"
    granularity     TEXT NOT NULL,        -- "hourly", "daily", "weekly", "monthly", "session"

    -- What this summary covers
    start_message   INTEGER REFERENCES messages(id),
    end_message     INTEGER REFERENCES messages(id),
    start_time      INTEGER NOT NULL,
    end_time        INTEGER NOT NULL,
    message_count   INTEGER NOT NULL,     -- how many messages this summarizes

    -- The summary itself
    summary         TEXT NOT NULL,        -- AI-generated narrative summary
    topics          TEXT,                 -- JSON array of topics discussed
    participants    TEXT,                 -- JSON array of participants
    final_state     TEXT,                -- where things ended: "completed", "WIP", "blocked on X"
    continuation    TEXT,                -- what needs to happen next if resumed

    -- Structured recall — JSON blob, fields vary by conversation type.
    -- The summarization prompt decides what's relevant to extract.
    -- Not every session has every field — that's the point.
    --
    -- Technical/investigation sessions might include:
    --   goal, how_we_got_here, assumptions, constraints, key_discoveries,
    --   dead_ends, open_questions, approaches_tried, research, tools_used
    --
    -- Casual/social sessions might include:
    --   mood, topics_enjoyed, shared_interests, memorable_moments
    --
    -- Planning sessions might include:
    --   decisions_made, action_items, owners, timeline, risks
    --
    recall           TEXT DEFAULT '{}',   -- JSON: structured fields extracted by summarizer

    -- Metadata
    model_used      TEXT,                 -- which model generated the summary
    token_cost      INTEGER,             -- tokens used to generate
    created_at      INTEGER NOT NULL
);

-- ============================================================
-- KNOWLEDGE — extracted insights, patterns, and learnings
-- This is the "what did we learn" layer. Not raw messages, not summaries,
-- but distilled knowledge that persists across sessions.
--
-- Populated by periodic extraction: the system reviews recent conversations
-- and pulls out reusable knowledge. Think of it as the difference between
-- "we talked about gaming for 2 hours" (summary) and "user stays engaged
-- with games that have progression systems and avoids PvP" (knowledge).
-- ============================================================

CREATE TABLE IF NOT EXISTS knowledge (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,

    -- What kind of knowledge
    category        TEXT NOT NULL,        -- "preference", "insight", "fact", "pattern",
                                          -- "decision", "technique", "opinion", "relationship"
    subcategory     TEXT,                 -- freeform: "gaming", "coding_style", "food", "architecture"

    -- The knowledge itself
    title           TEXT NOT NULL,        -- short: "Prefers progression-based games"
    content         TEXT NOT NULL,        -- full detail with context
    confidence      REAL DEFAULT 1.0,     -- 0.0-1.0, decays if contradicted, grows if reinforced
    mention_count   INTEGER DEFAULT 1,    -- how many times this has come up

    -- Provenance — where did this come from
    source_sessions TEXT,                 -- JSON array of session IDs that contributed
    first_seen      INTEGER NOT NULL,     -- when first observed
    last_reinforced INTEGER NOT NULL,     -- when last confirmed/mentioned
    contradicted_by TEXT,                 -- JSON: if something challenged this, what and when

    -- Searchability
    tags            TEXT DEFAULT '[]',    -- JSON array
    related_ids     TEXT DEFAULT '[]',    -- JSON array of other knowledge IDs that connect

    metadata        TEXT DEFAULT '{}',
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
    title,
    content,
    category,
    subcategory,
    tags,
    content='knowledge',
    content_rowid='id',
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS knowledge_fts_insert AFTER INSERT ON knowledge BEGIN
    INSERT INTO knowledge_fts(rowid, title, content, category, subcategory, tags)
    VALUES (new.id, new.title, new.content, new.category, new.subcategory, new.tags);
END;

CREATE TRIGGER IF NOT EXISTS knowledge_fts_delete AFTER DELETE ON knowledge BEGIN
    INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content, category, subcategory, tags)
    VALUES ('delete', old.id, old.title, old.content, old.category, old.subcategory, old.tags);
END;

CREATE INDEX IF NOT EXISTS idx_knowledge_namespace ON knowledge(namespace_id);
CREATE INDEX IF NOT EXISTS idx_knowledge_category ON knowledge(category, subcategory);
CREATE INDEX IF NOT EXISTS idx_knowledge_confidence ON knowledge(confidence);
CREATE INDEX IF NOT EXISTS idx_knowledge_reinforced ON knowledge(last_reinforced);

-- ============================================================
-- NOTES — freeform key-value store, the "sticky note in a folder"
-- For anything that doesn't fit messages, artifacts, or summaries
-- ============================================================

CREATE TABLE IF NOT EXISTS notes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    namespace_id    INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
    session_id      TEXT REFERENCES sessions(id) ON DELETE SET NULL,
    key             TEXT NOT NULL,        -- lookup key: "decision", "todo", "pin", "reminder"
    value           TEXT NOT NULL,        -- the content
    note_type       TEXT DEFAULT 'note',  -- "note", "decision", "todo", "pin", "bookmark"
    tags            TEXT DEFAULT '[]',    -- JSON array
    metadata        TEXT DEFAULT '{}',
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL,
    expires_at      INTEGER              -- null = permanent
);

CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
    key,
    value,
    tags,
    content='notes',
    content_rowid='id',
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS notes_fts_insert AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts(rowid, key, value, tags)
    VALUES (new.id, new.key, new.value, new.tags);
END;

CREATE TRIGGER IF NOT EXISTS notes_fts_delete AFTER DELETE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, key, value, tags)
    VALUES ('delete', old.id, old.key, old.value, old.tags);
END;

CREATE INDEX IF NOT EXISTS idx_notes_namespace ON notes(namespace_id);
CREATE INDEX IF NOT EXISTS idx_notes_session ON notes(session_id);
CREATE INDEX IF NOT EXISTS idx_notes_type ON notes(note_type);
CREATE INDEX IF NOT EXISTS idx_notes_key ON notes(namespace_id, key);
CREATE INDEX IF NOT EXISTS idx_notes_expires ON notes(expires_at);

-- ============================================================
-- ADAPTER REGISTRY
-- ============================================================

-- Adapters register themselves and their custom tables here
CREATE TABLE IF NOT EXISTS adapter_registry (
    adapter_name    TEXT PRIMARY KEY,     -- "cli", "discord", "web", "http"
    display_name    TEXT NOT NULL,
    version         TEXT NOT NULL,
    schema_version  INTEGER DEFAULT 1,   -- for adapter migrations
    metadata        TEXT DEFAULT '{}',   -- adapter config/capabilities
    registered_at   INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);

-- Adapter-defined tables registry — tracks what custom tables each adapter created
CREATE TABLE IF NOT EXISTS adapter_tables (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    adapter_name    TEXT NOT NULL REFERENCES adapter_registry(adapter_name) ON DELETE CASCADE,
    table_name      TEXT NOT NULL UNIQUE, -- prefixed: "discord_guilds", "cli_projects"
    description     TEXT,
    schema_sql      TEXT NOT NULL,        -- CREATE TABLE statement for recreation/migration
    created_at      INTEGER NOT NULL
);

-- ============================================================
-- BACKUPS
-- ============================================================

CREATE TABLE IF NOT EXISTS backups (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    backup_type     TEXT NOT NULL,        -- "full", "incremental", "summary_only"
    file_path       TEXT NOT NULL,
    file_size       INTEGER,
    namespace_scope TEXT,                 -- null = full backup, otherwise path prefix
    message_range   TEXT,                 -- "1-5000" or null for full
    created_at      INTEGER NOT NULL,
    expires_at      INTEGER              -- null = keep forever
);

-- ============================================================
-- FULL-TEXT SEARCH (SQLite FTS5)
-- ============================================================

-- FTS index over messages for RAG-like recall
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    content,
    role,
    content='messages',
    content_rowid='id',
    tokenize='porter unicode61'          -- stemming + unicode support
);

-- FTS index over summaries
CREATE VIRTUAL TABLE IF NOT EXISTS summaries_fts USING fts5(
    summary,
    topics,
    recall,
    content='summaries',
    content_rowid='id',
    tokenize='porter unicode61'
);

-- ============================================================
-- TRIGGERS
-- ============================================================

-- Keep FTS in sync with messages
CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, content, role)
    VALUES (new.id, new.content, new.role);
END;

CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content, role)
    VALUES ('delete', old.id, old.content, old.role);
END;

-- Keep FTS in sync with summaries
CREATE TRIGGER IF NOT EXISTS summaries_fts_insert AFTER INSERT ON summaries BEGIN
    INSERT INTO summaries_fts(rowid, summary, topics, recall)
    VALUES (new.id, new.summary, new.topics, new.recall);
END;

CREATE TRIGGER IF NOT EXISTS summaries_fts_delete AFTER DELETE ON summaries BEGIN
    INSERT INTO summaries_fts(summaries_fts, rowid, summary, topics, recall)
    VALUES ('delete', old.id, old.summary, old.topics, old.recall);
END;

-- Auto-update session message count
CREATE TRIGGER IF NOT EXISTS messages_count_insert AFTER INSERT ON messages BEGIN
    UPDATE sessions SET
        message_count = message_count + 1,
        updated_at = new.created_at
    WHERE id = new.session_id;
END;

-- ============================================================
-- INDEXES
-- ============================================================

-- Namespace lookups
CREATE INDEX IF NOT EXISTS idx_namespaces_parent ON namespaces(parent_id);
CREATE INDEX IF NOT EXISTS idx_namespace_paths_prefix ON namespace_paths(full_path);

-- Session lookups
CREATE INDEX IF NOT EXISTS idx_sessions_namespace ON sessions(namespace_id);
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_id);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
CREATE INDEX IF NOT EXISTS idx_sessions_updated ON sessions(updated_at);

-- Message lookups
CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, sequence);
CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at);
CREATE INDEX IF NOT EXISTS idx_messages_role ON messages(session_id, role);

-- Context snapshot lookups
CREATE INDEX IF NOT EXISTS idx_context_snapshots_session ON context_snapshots(session_id, at_message);
CREATE INDEX IF NOT EXISTS idx_context_snapshots_reason ON context_snapshots(reason);

-- Tool call lookups
CREATE INDEX IF NOT EXISTS idx_tool_calls_message ON tool_calls(message_id);

-- Summary lookups
CREATE INDEX IF NOT EXISTS idx_summaries_namespace ON summaries(namespace_id);
CREATE INDEX IF NOT EXISTS idx_summaries_session ON summaries(session_id);
CREATE INDEX IF NOT EXISTS idx_summaries_scope ON summaries(scope, granularity);
CREATE INDEX IF NOT EXISTS idx_summaries_time ON summaries(start_time, end_time);

-- Backup lookups
CREATE INDEX IF NOT EXISTS idx_backups_created ON backups(created_at);
CREATE INDEX IF NOT EXISTS idx_backups_expires ON backups(expires_at);

-- ============================================================
-- EMBEDDINGS (sqlite-vec — local vector search, no server)
-- ============================================================
--
-- Hybrid search: FTS5 (keyword) + sqlite-vec (semantic) merged via
-- Reciprocal Rank Fusion (RRF). Neither alone is sufficient:
--   FTS catches exact terms (error codes, names, identifiers)
--   Vectors catch meaning ("what keeps me engaged" ≈ "progression systems")
--
-- Vector engine: sqlite-vector (SQLite Cloud, Sep 2025)
--   17x faster than sqlite-vec, SIMD-accelerated, regular tables (no virtual tables),
--   supports FLOAT32/16, BFLOAT16, INT8/UINT8 quantization, 3.97ms @ 100K vectors.
--   Free for open source. Falls back to sqlite-vec if unavailable.
--
-- Embedding models (local, no API dependency):
--   - Qwen3-VL-Embedding (2B) — open source, multimodal (text+image), fits consumer GPU
--   - Jina Embeddings v4 — LoRA adapters for retrieval/matching modes, text+image+PDF
--   - nomic-embed-text / MiniLM — lightweight fallback (budget tier but functional)
--   - Matryoshka (MRL) support: truncate dimensions dynamically per query
--     (e.g., 256d for broad search, full 2048d for precision re-ranking)
--
-- Generated at insert time, stored permanently. Model field tracks which
-- model produced the embedding so vectors can be re-generated on model upgrade.

-- Unified embedding store — any searchable entity gets an embedding.
-- Rather than per-table vector columns, one table links embeddings
-- to their source by type + id. Generic, not opinionated.
CREATE TABLE IF NOT EXISTS embeddings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source_type     TEXT NOT NULL,        -- "message", "summary", "knowledge", "artifact", "note", "project"
    source_id       INTEGER NOT NULL,     -- FK to the source table's id
    namespace_id    INTEGER REFERENCES namespaces(id) ON DELETE CASCADE,

    -- The embedding itself (stored via sqlite-vec virtual table below)
    -- This row links metadata; the actual vector lives in embeddings_vec.
    chunk_text      TEXT NOT NULL,        -- the text that was embedded (may include context header)
    context_header  TEXT,                 -- prepended context (Anthropic's contextual retrieval)
                                          -- e.g. "From a CLI session about ClawForge storage design:"

    model           TEXT NOT NULL,        -- which embedding model produced this
    dimensions      INTEGER NOT NULL,     -- full vector dimensions (768, 2048, etc.)
    created_at      INTEGER NOT NULL,

    UNIQUE(source_type, source_id)        -- one embedding per source entity

    -- Full FP32 vectors stored via sqlite-vector column (see below).
    -- Binary (1-bit) vectors stored as packed BLOBs for fast hamming distance.
    -- Search pipeline: binary popcount broad search → FP32 rescore top-k.
    -- Matryoshka: full dims stored, truncated dynamically at query time.
);

CREATE INDEX IF NOT EXISTS idx_embeddings_source ON embeddings(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_embeddings_namespace ON embeddings(namespace_id);

-- PERFORMANCE ARCHITECTURE:
--
--   SQLite concurrency: 1 writer thread (queue-fed) + N reader threads, WAL mode.
--     PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;
--
--   Embedding pipeline (threaded):
--     Thread 1: batch incoming content (every 100ms or 64 docs)
--     Thread 2: GPU embedding via ROCm (7900XT, batch_size=512)
--     Thread 3: SQLite write (single writer, transaction batched)
--     Ring buffers between stages. Embedding overlaps with I/O.
--
--   Search pipeline (two-pass):
--     Pass 1: binary embeddings + popcount hamming distance (broad, fast)
--       Zig @popCount on packed u64 — fits in a few CPU instructions
--     Pass 2: FP32 rescore top-100 candidates (precise)
--     Pass 3: FTS5 keyword results merged via RRF
--     Optional: LLM re-rank top-10 for final precision
--
--   Zig SIMD: @Vector(8, f32) + @reduce(.Add, a*b) for dot product (AVX2)
--     Build with -Dcpu=native to target host ISA. Zero GC on hot path.
--
-- Vector storage — uses sqlite-vector (regular table, not virtual).
-- Dimension is configurable per embedding model.
-- Supports Matryoshka: store full dims, query with truncated for speed.
--
-- With sqlite-vector:
--   ALTER TABLE embeddings ADD COLUMN vector VECTOR(2048);
--   CREATE INDEX idx_embeddings_vector ON embeddings(vector) USING ivfflat;
--
-- With sqlite-vec (fallback):
--   CREATE VIRTUAL TABLE embeddings_vec USING vec0(
--       embedding_id INTEGER PRIMARY KEY,
--       vector float[2048]
--   );
--
-- Hybrid search (FTS5 + vector + RRF):
--
--   WITH kw AS (
--     SELECT rowid as id, rank as score FROM messages_fts WHERE messages_fts MATCH ?
--   ),
--   vec AS (
--     SELECT e.source_id as id, vector_distance(e.vector, ?) as score
--     FROM embeddings e WHERE e.source_type = 'message'
--     ORDER BY score LIMIT 50
--   ),
--   fused AS (
--     SELECT id, COALESCE(1.0/(60+kw.score),0) + COALESCE(1.0/(60+vec.score),0) as rrf
--     FROM kw FULL OUTER JOIN vec USING(id)
--   )
--   SELECT * FROM fused ORDER BY rrf DESC LIMIT 10;
--
-- Optional: re-rank top-10 with cross-encoder or LLM for final precision.

-- ============================================================
-- SEARCH CASCADE
-- ============================================================
--
-- Two modes of retrieval:
--
-- A) AGENTIC (preferred) — the LLM decides what to search.
--    Given the user's query, the model picks which retrieval tools
--    to call: project lookup, knowledge search, summary search, etc.
--    It can decompose complex queries, do iterative retrieval, and
--    self-evaluate whether results are sufficient. This avoids the
--    rigidity of a fixed cascade.
--
-- B) FIXED CASCADE (fallback / simple queries) — cheapest first.
--    For straightforward queries, follow this order:
--
--   Query
--    │
--    ├─ 1. projects ──── rolling_summary + rolling_state
--    │     Cheapest. "What's the current state of X?"
--    │
--    ├─ 2. knowledge ─── distilled insights with confidence scores
--    │     "What do we know about X?"
--    │
--    ├─ 3. summaries ─── per-session/period recall
--    │     "What happened when we worked on X?"
--    │
--    ├─ 4. notes ──────── pinned items, decisions, bookmarks
--    │
--    ├─ 5. artifacts ──── files, cached analyses, images
--    │
--    └─ 6. messages ───── raw search, last resort
--
-- Within each layer, search is HYBRID:
--   FTS5 (keyword) + sqlite-vec (semantic) → Reciprocal Rank Fusion
--   Then optionally re-rank top candidates with a cross-encoder or LLM.
--
-- The cascade is generic — works the same whether the topic is:
--   a software project, a recipe, a game mechanic, a personal goal,
--   a research topic, a D&D character, a travel plan, anything.
--
-- ============================================================
-- EXAMPLE QUERIES (varied topics)
-- ============================================================
--
-- --- "continue where we left off on the game db decode" ---
--
--   SELECT p.name, p.rolling_summary, p.rolling_state, p.status
--   FROM projects p
--   WHERE projects_fts MATCH 'game database decode'
--   LIMIT 1;
--
--   -- Returns rolling_state with whatever fields the summarizer
--   -- decided were relevant: mapped_columns, unknown_fields, etc.
--   -- ~200 tokens of context, instantly.
--
-- --- "remember that idea I had about what keeps me playing games?" ---
--
--   SELECT k.title, k.content, k.confidence, k.source_sessions
--   FROM knowledge k
--   WHERE k.category = 'preference'
--     AND knowledge_fts MATCH 'game OR play OR motivation OR engagement'
--   ORDER BY k.confidence * k.mention_count DESC;
--
--   -- Returns distilled knowledge entries, not raw chat.
--   -- Each has source_sessions for drill-down if needed.
--
-- --- "what did we decide last week?" (across all projects) ---
--
--   SELECT sum.summary, sum.final_state, sum.topics, p.name as project_name
--   FROM summaries sum
--   LEFT JOIN sessions s ON s.id = sum.session_id
--   LEFT JOIN projects p ON p.id = s.project_id
--   WHERE sum.start_time >= strftime('%s', 'now', '-7 days')
--   ORDER BY sum.end_time DESC;
--
-- --- "do we have that screenshot from the error?" ---
--
--   SELECT a.name, aa.description, aa.structured_data
--   FROM artifact_analysis aa
--   JOIN artifacts a ON a.id = aa.artifact_id
--   WHERE artifact_analysis_fts MATCH 'error'
--   ORDER BY aa.created_at DESC;
--
--   -- Returns cached description — no need to re-read the image.
--
-- --- "find that conversation where I was ranting about X" ---
--   (last resort — raw message search)
--
--   SELECT m.content, m.role, s.name, np.full_path,
--          cs.conversation_context
--   FROM messages_fts fts
--   JOIN messages m ON m.id = fts.rowid
--   JOIN sessions s ON s.id = m.session_id
--   JOIN namespace_paths np ON np.namespace_id = s.namespace_id
--   LEFT JOIN context_snapshots cs ON cs.session_id = s.id
--     AND cs.at_message <= m.id
--   WHERE messages_fts MATCH 'ranting about X'
--   ORDER BY m.created_at DESC
--   LIMIT 10;
--
-- ============================================================
-- EXAMPLE: Adapter registration
-- ============================================================
--
-- Each adapter registers itself and creates whatever tables it needs.
-- The framework doesn't dictate adapter schema — adapters own their tables.
--
--   INSERT INTO adapter_registry VALUES ('discord', 'Discord', '1.0', 1, '{}', ...);
--   INSERT INTO adapter_tables VALUES (NULL, 'discord', 'discord_guilds', 'Guild info',
--     'CREATE TABLE discord_guilds (...)', ...);
--
-- ============================================================
-- EXAMPLE: Image/artifact analysis caching
-- ============================================================
--
-- Any artifact analyzed by an LLM gets cached by content hash.
-- Same content referenced anywhere = free recall forever.
--
--   1. Hash content: SHA-256 -> "a1b2c3..."
--   2. SELECT description FROM artifact_analysis WHERE content_hash = 'a1b2c3...';
--   3a. HIT -> use cached description (0 tokens)
--   3b. MISS -> analyze, store result, never pay again
