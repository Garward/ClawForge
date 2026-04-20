# ClawForge Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        INTERFACE ADAPTERS                           │
│                     (thin I/O translators)                          │
│                                                                     │
│   ┌─────┐  ┌───────┐  ┌─────────┐  ┌──────┐  ┌─────────────────┐  │
│   │ CLI │  │ Web UI│  │ Discord │  │ HTTP │  │ Future adapter  │  │
│   └──┬──┘  └───┬───┘  └────┬────┘  └──┬───┘  └────────┬────────┘  │
│      │         │           │          │               │            │
└──────┼─────────┼───────────┼──────────┼───────────────┼────────────┘
       │         │           │          │               │
       └─────────┴─────┬─────┴──────────┴───────────────┘
                       │
                  Internal API
                  (request → response)
                       │
┌──────────────────────┼──────────────────────────────────────────────┐
│                      ▼                                              │
│                 DAEMON CORE                                         │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ Request Router                                               │   │
│  │ Identifies: user, session, project, query type               │   │
│  └──────────┬───────────────────────────────────────────────────┘   │
│             │                                                       │
│  ┌──────────▼───────────────────────────────────────────────────┐   │
│  │ Context Engine                                               │   │
│  │ Retrieves: rolling context, user prefs, relevant knowledge   │   │
│  │ Decides: what to search, how deep, which layers              │   │
│  └──────────┬───────────────────────────────────────────────────┘   │
│             │                                                       │
│  ┌──────────▼───────────────────────────────────────────────────┐   │
│  │ Prompt Assembler                                             │   │
│  │ Layers: base persona + project ctx + adapter ctx + user prefs│   │
│  │ Injects: retrieved context, tool definitions                 │   │
│  └──────────┬───────────────────────────────────────────────────┘   │
│             │                                                       │
│  ┌──────────▼───────────────────────────────────────────────────┐   │
│  │ Model Router                                                 │   │
│  │ Picks: haiku (simple) / sonnet (coding) / opus (architecture)│   │
│  │ Or: local model via llama.cpp/Ollama                         │   │
│  └──────────┬───────────────────────────────────────────────────┘   │
│             │                                                       │
│  ┌──────────▼───────────────────────────────────────────────────┐   │
│  │ LLM Provider                                                 │   │
│  │ API: Anthropic, OpenAI, Google, etc.                         │   │
│  │ Local: llama.cpp (ROCm/GGML), Ollama                        │   │
│  └──────────┬───────────────────────────────────────────────────┘   │
│             │                                                       │
│  ┌──────────▼───────────────────────────────────────────────────┐   │
│  │ Response Processor                                           │   │
│  │ Handles: text, tool calls, confirmations, streaming          │   │
│  └──────────┬───────────────────────────────────────────────────┘   │
│             │                                                       │
│  ┌──────────▼───────────────────────────────────────────────────┐   │
│  │ Post-Response Pipeline (async, non-blocking)                 │   │
│  │ Stores: message + response + tool calls + context snapshot   │   │
│  │ Updates: rolling project context                             │   │
│  │ Queues: knowledge extraction, summarization (if due)         │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────┬───────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      STORAGE LAYER                                  │
│                                                                     │
│  ┌─────────────┐    ┌──────────────────────────────────────────┐   │
│  │  core.db    │    │  <user>.db (workspace/brain)             │   │
│  │             │    │                                          │   │
│  │ - adapters  │    │  ┌─────────────────────────────────┐    │   │
│  │ - auth      │    │  │ Hot path (every prompt)          │    │   │
│  │ - users     │    │  │ - messages      - sessions       │    │   │
│  │ - config    │    │  │ - tool_calls    - projects       │    │   │
│  │             │    │  │   (rolling_summary, rolling_state)│    │   │
│  └─────────────┘    │  └─────────────────────────────────┘    │   │
│                     │                                          │   │
│                     │  ┌─────────────────────────────────┐    │   │
│                     │  │ Warm path (periodic)             │    │   │
│                     │  │ - summaries    - knowledge       │    │   │
│                     │  │ - context_snapshots              │    │   │
│                     │  │ - embeddings (binary + FP32)     │    │   │
│                     │  └─────────────────────────────────┘    │   │
│                     │                                          │   │
│                     │  ┌─────────────────────────────────┐    │   │
│                     │  │ Cold path (on demand)            │    │   │
│                     │  │ - artifacts    - artifact_analysis│    │   │
│                     │  │ - notes        - backups         │    │   │
│                     │  │ - adapter-specific tables        │    │   │
│                     │  └─────────────────────────────────┘    │   │
│                     │                                          │   │
│                     │  ┌─────────────────────────────────┐    │   │
│                     │  │ Search indexes                   │    │   │
│                     │  │ - FTS5 (keyword: messages,       │    │   │
│                     │  │   summaries, knowledge, etc.)    │    │   │
│                     │  │ - sqlite-vector (semantic)       │    │   │
│                     │  │ - namespace_paths (hierarchy)    │    │   │
│                     │  └─────────────────────────────────┘    │   │
│                     └──────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ Background Workers (threaded pipeline)                      │   │
│  │                                                             │   │
│  │  Writer Thread ← queue ← [messages, snapshots, updates]    │   │
│  │  Embed Thread  ← queue ← [new content → GPU batch → store] │   │
│  │  Summary Thread← queue ← [sessions due for summarization]  │   │
│  │  Extract Thread← queue ← [conversations → knowledge entries]│   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```


## File Structure

```
ClawForge/
├── build.zig
├── TODO.md                          # Vision + detailed task list
├── docs/
│   ├── architecture.md              # This file
│   └── storage_schema.sql           # Full DB schema (validated)
├── config/
│   └── config.json                  # Runtime config (models, routing, adapters, ports)
├── src/
│   ├── main.zig                     # Daemon entry point
│   ├── cli.zig                      # CLI adapter entry point
│   ├── core/                        # Internal API (the brain)
│   │   ├── engine.zig               # Request → Response (no I/O knowledge)
│   │   ├── context.zig              # Context retrieval + assembly
│   │   ├── prompt.zig               # Layered system prompt builder
│   │   └── search.zig               # Hybrid search (FTS + vector + RRF)
│   ├── daemon/
│   │   ├── server.zig               # Unix socket server
│   │   ├── handler.zig              # Socket → core.engine bridge
│   │   ├── router.zig               # Model tier routing (haiku/sonnet/opus)
│   │   ├── session.zig              # Session management
│   │   └── web.zig                  # Web UI HTTP server
│   ├── api/                         # LLM provider abstraction
│   │   ├── provider.zig             # Provider interface (any LLM)
│   │   ├── anthropic.zig            # Anthropic API client
│   │   ├── openai.zig               # OpenAI API client (future)
│   │   ├── local.zig                # llama.cpp / Ollama (future)
│   │   ├── messages.zig             # Message types
│   │   └── sse.zig                  # SSE stream parser
│   ├── storage/                     # Database layer
│   │   ├── db.zig                   # SQLite connection management (1 writer + N reader)
│   │   ├── migrations.zig           # Schema creation and versioning
│   │   ├── messages.zig             # Message CRUD
│   │   ├── projects.zig             # Project + rolling context CRUD
│   │   ├── knowledge.zig            # Knowledge extraction + query
│   │   ├── summaries.zig            # Summarization engine
│   │   ├── embeddings.zig           # Embedding storage + vector search
│   │   ├── artifacts.zig            # Artifact + analysis cache
│   │   └── namespaces.zig           # Namespace tree management
│   ├── adapters/                    # Interface adapters (thin)
│   │   ├── cli.zig                  # CLI adapter
│   │   ├── web.zig                  # Web UI adapter
│   │   ├── discord.zig              # Discord bot adapter (future)
│   │   └── http.zig                 # HTTP API adapter (future)
│   ├── tools/                       # Tool system
│   │   ├── registry.zig             # Tool registry (built-in + generated)
│   │   ├── bash.zig                 # Bash execution
│   │   ├── file_read.zig            # File read
│   │   └── file_write.zig           # File write
│   ├── workers/                     # Background pipeline
│   │   ├── writer.zig               # Single DB writer thread
│   │   ├── embedder.zig             # GPU batch embedding thread
│   │   ├── summarizer.zig           # Periodic summarization
│   │   └── extractor.zig            # Knowledge extraction
│   ├── client/                      # CLI client library
│   │   ├── connection.zig           # Socket client
│   │   └── display.zig              # Terminal output
│   └── common/
│       ├── config.zig               # Config loading
│       ├── protocol.zig             # IPC protocol
│       └── auth_profiles.zig        # Auth management
├── data/                            # Runtime data
│   ├── core.db                      # Framework DB
│   ├── workspaces/                  # Per-user workspace DBs
│   │   └── <user>.db
│   ├── artifacts/                   # Large file storage (referenced by DB)
│   ├── backups/
│   └── clawforge.sock               # Unix socket
└── tests/
    ├── test_webui.py                # Playwright E2E tests
    └── (unit tests via zig build test)
```


## Separation of Concerns

```
WHAT EACH LAYER KNOWS:
═══════════════════════════════════════════════════════════════

Adapters:
  KNOWS:  how to receive input and format output for their medium
  CALLS:  core engine with a Request, gets back a Response
  NEVER:  touches the database, picks models, builds prompts

Core Engine:
  KNOWS:  how to process a request into a response
  CALLS:  context engine, prompt assembler, model router, storage
  NEVER:  knows about sockets, HTTP, Discord, or any I/O format

Context Engine:
  KNOWS:  how to find relevant context for a query
  CALLS:  search (hybrid FTS + vector), project state, knowledge
  NEVER:  decides what model to use or how to format the prompt

Prompt Assembler:
  KNOWS:  how to layer system prompts and inject context
  CALLS:  nothing — receives context, produces a prompt
  NEVER:  does retrieval or knows where context came from

Model Router:
  KNOWS:  which model tier fits a query (fast/default/smart)
  CALLS:  the appropriate LLM provider
  NEVER:  knows about context, storage, or adapters

LLM Providers:
  KNOWS:  how to call one specific API or local model
  CALLS:  external API or local inference
  NEVER:  knows about sessions, projects, or context

Storage Layer:
  KNOWS:  how to read/write the database efficiently
  CALLS:  SQLite (1 writer, N readers, WAL)
  NEVER:  knows about LLMs, prompts, or adapters

Background Workers:
  KNOWS:  how to process queued async tasks
  CALLS:  storage (write), LLM (for summarization/extraction)
  NEVER:  blocks the request/response path
```


## Full Message Loop

Example query: "If we were to learn 1 thing from the past 5 projects what would it be?"

```
STEP 1 — INPUT
══════════════════════════════════════════════════════════════
User types in CLI (or Discord, or web — doesn't matter).
Adapter receives raw input.

  User → "If we were to learn 1 thing from the past 5 projects
          what would it be?"


STEP 2 — ADAPTER TRANSLATES
══════════════════════════════════════════════════════════════
Adapter creates an internal Request struct. Adds interface
metadata (which adapter, which channel/project if known).
Sends to daemon core. Adapter's job is DONE until response.

  Request {
    message: "If we were to learn 1 thing from...",
    user: "<user>",
    adapter: "cli",
    session_id: "abc-123" (or null for new),
    interface_meta: { cwd: "ClawForge" }
  }


STEP 3 — SESSION RESOLUTION
══════════════════════════════════════════════════════════════
Core identifies or creates a session. Checks if session is
attached to a project. Loads user preferences.

  → Session "abc-123" exists, attached to project "clawforge"
  → User prefs loaded: model=auto, persona=default


STEP 4 — CONTEXT RETRIEVAL (the smart part)
══════════════════════════════════════════════════════════════
Context Engine analyzes the query to decide what to retrieve.
This is AGENTIC — not a hardcoded cascade.

  Query analysis:
    - Asks about "past 5 projects" → need project-level data
    - Asks for "1 thing to learn" → need knowledge + summaries
    - Cross-project scope → search across all project namespaces
    - Not about current project state → skip rolling context

  Retrieval plan:
    a) List 5 most recent projects (projects table, ORDER BY updated_at)
    b) Pull summary.recall for each (key decisions, dead ends, lessons)
    c) Pull knowledge entries tagged across those projects
    d) Hybrid search: FTS + vector for "lesson" "learning" "insight"
       across summaries and knowledge tables

  Execution:                                          Tokens:
    5 project summaries (rolling_summary)              ~250
    Key recall JSON from each (dead_ends, discoveries) ~300
    Top 5 knowledge entries by confidence              ~150
    ─────────────────────────────────────────────────
    Total retrieved context                            ~700

  Compare: replaying all 5 projects raw = ~50,000+ tokens


STEP 5 — PROMPT ASSEMBLY
══════════════════════════════════════════════════════════════
Layered system prompt built from bottom up.
Each layer adds context, none removes from previous layers.

  Layer 1 — Base persona (from config or per-user override)
  ┌─────────────────────────────────────────────────┐
  │ "You are a knowledgeable assistant that values   │
  │  precision, learning from mistakes, and building │
  │  on past experience."                            │
  └─────────────────────────────────────────────────┘

  Layer 2 — User context (from knowledge + prefs)
  ┌─────────────────────────────────────────────────┐
  │ "This user is an experienced developer who works │
  │  primarily in Zig, Python, Rust. Values token    │
  │  efficiency and practical solutions."            │
  └─────────────────────────────────────────────────┘

  Layer 3 — Retrieved context (from Step 4)
  ┌─────────────────────────────────────────────────┐
  │ "Here are summaries of the user's 5 most recent │
  │  projects with key learnings:                    │
  │  [project summaries, knowledge entries]"         │
  └─────────────────────────────────────────────────┘

  Layer 4 — Adapter context (interface-specific)
  ┌─────────────────────────────────────────────────┐
  │ "User is in CLI, working directory is ClawForge."│
  └─────────────────────────────────────────────────┘

  Final prompt: ~900 tokens total (not 50k+)


STEP 6 — MODEL ROUTING
══════════════════════════════════════════════════════════════
Router classifies the query and picks a model tier.

  "learn 1 thing from past 5 projects" →
    Cross-project analysis, synthesis, requires reasoning
    → Tier: smart (opus)
    → Log: "Router: smart → claude-opus-4 (cross-project synthesis)"


STEP 7 — LLM CALL
══════════════════════════════════════════════════════════════
Provider sends assembled prompt + message to chosen model.
Streaming or non-streaming based on config.

  POST https://api.anthropic.com/v1/messages
    model: claude-opus-4-20250514
    system: [layered prompt from Step 5]
    messages: [session history + new message]
    max_tokens: 8192

  Response streams back...


STEP 8 — RESPONSE PROCESSING
══════════════════════════════════════════════════════════════
Handle the response: text, tool calls, or both.

  If text only → pass through
  If tool call → send confirmation to adapter → wait → execute → loop
  If stop_reason = "end_turn" → finalize


STEP 9 — RESPONSE DELIVERY
══════════════════════════════════════════════════════════════
Core returns Response to adapter. Adapter formats for its medium.

  CLI:  prints text + "[claude-opus-4, 943 in / 312 out tokens]"
  Web:  sends via SSE to browser
  Discord: sends as embed in channel


STEP 10 — POST-RESPONSE PIPELINE (async, non-blocking)
══════════════════════════════════════════════════════════════
These happen AFTER the user sees the response. Never blocks.
Queued to background worker threads.

  a) Store message + response → writer thread queue
     INSERT INTO messages (session, seq, role, content, model_used, ...)

  b) Store tool calls if any → writer thread queue
     INSERT INTO tool_calls (session, tool_name, input, result, status, ...)

  c) Context snapshot if due → writer thread queue
     (every N messages, or on state change)
     INSERT INTO context_snapshots (session, at_message, system_prompt, ...)

  d) Update project rolling context → writer thread queue
     UPDATE projects SET rolling_summary = ?, rolling_state = ?,
       updated_at = ? WHERE id = ?
     (Cheap: haiku-level task to update the summary incrementally)

  e) Queue embedding generation → embedder thread queue
     New message + response get embedded in next GPU batch
     (batched: every 100ms or 64 docs, whichever first)

  f) Check if summarization is due → summarizer thread queue
     (every N messages or on session end)
     Generates summary with flexible recall JSON

  g) Check if knowledge extraction is due → extractor thread queue
     (periodic: scans recent summaries for distillable insights)
     INSERT/UPDATE knowledge entries with confidence scores


DONE — Loop complete.
══════════════════════════════════════════════════════════════
Total latency added by ClawForge over raw LLM call:
  - Context retrieval: ~5-20ms (DB queries + vector search)
  - Prompt assembly: <1ms (string concatenation)
  - Post-response: 0ms (async, user doesn't wait)

Everything else (embedding, summarization, knowledge extraction)
happens in background threads and is ready for the NEXT query.
```


## Threading Model

```
┌───────────────────────────────────────────────────────────┐
│                    DAEMON PROCESS                          │
│                                                           │
│  Main Thread                                              │
│  └─ Unix socket server (accepts adapter connections)      │
│                                                           │
│  Web Thread                                               │
│  └─ HTTP server for web UI adapter                        │
│                                                           │
│  Handler Threads (1 per connected client, pooled)         │
│  └─ Request → core engine → response                     │
│  └─ Uses N read connections to SQLite                     │
│                                                           │
│  Writer Thread (exactly 1)                                │
│  └─ Pulls from write queue                                │
│  └─ Batches INSERTs into transactions                     │
│  └─ Only thread that writes to SQLite                     │
│                                                           │
│  Embedder Thread (1)                                      │
│  └─ Pulls from embed queue                                │
│  └─ Batches content → GPU (ROCm) → writes via writer     │
│                                                           │
│  Summarizer Thread (1)                                    │
│  └─ Periodic: checks for sessions needing summarization   │
│  └─ Calls LLM (haiku — cheap) to generate summaries      │
│  └─ Writes via writer thread                              │
│                                                           │
│  Extractor Thread (1)                                     │
│  └─ Periodic: scans summaries for knowledge extraction    │
│  └─ Calls LLM (haiku) to distill insights                │
│  └─ Writes via writer thread                              │
│                                                           │
│  Signal Handler                                           │
│  └─ SIGTERM/SIGINT → graceful shutdown of all threads     │
│                                                           │
└───────────────────────────────────────────────────────────┘

SQLite connections:
  Writer thread:   1 read-write connection (WAL mode)
  Handler threads: N read-only connections (concurrent)
  Worker threads:  read via own connections, write via writer queue
```


## Rolling State Update Policy

What must be current before the next prompt vs what can lag.

```
SYNCHRONOUS (blocks before next prompt can use it):
═══════════════════════════════════════════════════

  ✓ Message stored (user + assistant)
    WHY: Next prompt needs full conversation history.
    COST: 1 INSERT, sub-ms.

  ✓ Tool calls stored (with status: success/error/rejected)
    WHY: Next prompt may reference what just happened.
          "try that again" needs to know what "that" was.
    COST: 1 INSERT per tool call, sub-ms.

  ✓ Session.message_count and updated_at
    WHY: Used for routing decisions and snapshot triggers.
    COST: 1 UPDATE, sub-ms. (trigger handles this already)

  ✓ Project attachment (if detected this turn)
    WHY: Next prompt needs project rolling context injected.
          If attachment lags, the very next message gets no project
          context and the superbrain illusion breaks immediately.
    COST: 1 UPDATE on sessions, sub-ms.

  ✓ Project rolling_summary (incremental update)
    WHY: This IS the working memory. If it's stale by even 1 turn,
          "continue where we left off" gives outdated context.
    COST: ~50-100 tokens via haiku. ~200-500ms. Worth it.
    HOW:  Not a full re-summarization. Append-style update:
          "Previous: [old summary]. This turn: [what just happened].
           Updated summary:" → haiku produces ~100 token update.
    OPTIMIZATION: Only update if the turn was substantive.
          "ok" / "thanks" / "yes" → skip update.
          Code change / decision / new info → update.

  Total sync overhead per prompt: ~200-500ms (dominated by rolling
  summary haiku call, only when substantive). For trivial exchanges,
  <5ms (just DB writes).


ASYNC (can lag, ready for future prompts):
═══════════════════════════════════════════════════

  ~ rolling_state JSON (structured fields)
    WHY OK TO LAG: rolling_summary carries the narrative. The JSON
    fields (approaches_tried, etc.) enrich it but aren't critical
    for immediate context. Updated by summarizer in next batch.

  ~ Context snapshots
    WHY OK TO LAG: Only needed for historical recall, not current
    conversation. Snapped every 10 messages or on state change.

  ~ Embeddings (binary + FP32)
    WHY OK TO LAG: Search uses them for FUTURE queries, not the
    current one. Batched to GPU every 100ms or 64 docs.
    RISK: If user asks about something they JUST said in the
    previous message, vector search won't find it yet. Mitigated
    by always including recent N messages in context directly.

  ~ Full session summaries
    WHY OK TO LAG: Rolling summary handles continuity. Full
    summaries are for long-term recall and cross-session search.
    Generated on session end or every ~50 messages.

  ~ Knowledge extraction
    WHY OK TO LAG: Insights accumulate over days/weeks, not
    seconds. Extracted from summaries, not raw messages.
    Run periodically (hourly or on session close).

  ~ Artifact analysis caching
    WHY OK TO LAG: First request for an uncached image pays the
    vision API cost. All subsequent requests are free. No urgency.
```


## Session and Project Attachment Rules

```
RULE 1: Sessions start unattached.
═══════════════════════════════════════════════════
  Every new session has project_id = NULL.
  Reason: We don't know what the user wants to talk about yet.
  No project context is injected. Clean slate.

  Exception: If the adapter provides project context at creation.
    CLI: cwd is inside a known project directory → auto-attach.
    Discord: channel mapped to a project in config → auto-attach.
    Web: user explicitly selects a project → attach.


RULE 2: Sessions attach to a project when topic becomes clear.
═══════════════════════════════════════════════════
  Detection methods (checked after each user message):

  a) EXPLICIT: User says "let's work on ClawForge" or
     "continue the game db project" → name match against
     projects table. Attach immediately.

  b) CWD-BASED (CLI only): User's working directory matches
     a known project path → attach. Cheapest detection.

  c) SEMANTIC (after 3+ messages): If session is still
     unattached after 3 substantive messages, run a cheap
     classification: "Given this conversation, does it match
     any of these projects: [list]?" via haiku (~50 tokens).
     If confident match (>0.8) → attach. If no match and the
     conversation has a clear topic → offer to create a project.

  d) NEVER force-attach ambiguous sessions. An unattached
     session is fine — it just doesn't get project context.
     Better to miss attachment than attach to the wrong project.

  Once attached: session.project_id is set SYNCHRONOUSLY (Rule above).
  Next prompt immediately gets that project's rolling context.


RULE 3: Detachment is explicit only.
═══════════════════════════════════════════════════
  Sessions never auto-detach. If the conversation drifts off topic,
  that's fine — the project context just becomes less relevant
  but doesn't hurt. User can explicitly: "new session" or
  "switch to project X" to change context.


RULE 4: Retrieval scope follows intent, not attachment.
═══════════════════════════════════════════════════

  CURRENT PROJECT ONLY (default for most queries):
    "fix the build error" → search within attached project
    "what did we try yesterday" → search this project's sessions
    "what's the status" → return rolling_summary

    Detection: query references current work, uses "this", "the",
    "it", or is clearly about what's in front of the user.

  CROSS-PROJECT (when query explicitly or implicitly spans):
    "what did we learn from the last 5 projects" → all projects
    "have I solved this kind of bug before" → all projects
    "remember when we decoded that game database" → specific other project

    Detection: query uses "projects" (plural), names another project,
    asks "have I ever", "across", "in the past", or the query
    makes no sense scoped to current project.

  UNSCOPED (no project attached):
    All retrieval is cross-project by default.
    Searches entire user namespace.

  RULE OF THUMB: When in doubt, search current project first.
  If results are empty or low-confidence, widen to cross-project.
  Never widen silently — mention it: "I didn't find that in the
  current project, but in your game-db-decode project..."
```


## Tool Decline Flow

```
STEP 1 — LLM requests a tool call
══════════════════════════════════════════════════════════════
  Response includes tool_use block:
    tool: "bash"
    input: { "command": "rm -rf /tmp/old-builds" }

  Core extracts tool request. Checks tool registry:
    bash → requires confirmation = true


STEP 2 — Confirmation request sent to adapter
══════════════════════════════════════════════════════════════
  Core sends ToolConfirmRequest to the adapter:
    tool_id: "tc_001"
    tool_name: "bash"
    input_preview: "rm -rf /tmp/old-builds"

  Adapter displays in its medium:
    CLI:  "Tool: bash — rm -rf /tmp/old-builds\nAllow? [y/N]: "
    Discord: Embed with approve/deny buttons
    Web:  Modal with approve/deny


STEP 3 — User declines
══════════════════════════════════════════════════════════════
  User types "n" (CLI) or clicks deny (Discord/Web).
  Adapter sends ToolConfirmResponse:
    tool_id: "tc_001"
    approved: false


STEP 4 — Tool call recorded as rejected (SYNCHRONOUS)
══════════════════════════════════════════════════════════════
  BEFORE informing the LLM, store the attempt:

    INSERT INTO tool_calls (
      message_id, session_id, sequence, tool_name,
      tool_input, tool_result, status, approved, metadata
    ) VALUES (
      msg_42, 'abc-123', 7, 'bash',
      '{"command":"rm -rf /tmp/old-builds"}',
      NULL,           -- no result (never ran)
      'rejected',     -- status
      false,          -- approved
      '{"intent":"clean up old build artifacts"}'  -- extracted later
    );

  WHY STORE: The intent behind the tool call is valuable knowledge.
  "The assistant tried to rm -rf and the user said no" informs
  future sessions. The system learns what the user doesn't want.


STEP 5 — LLM receives rejection and recovers
══════════════════════════════════════════════════════════════
  Core sends tool result back to LLM as an error/info:
    tool_id: "tc_001"
    result: "User declined this tool call."
    is_error: false  (not an error — a user decision)

  LLM generates recovery response:
    "Understood, I won't delete those. Would you like me to
     list what's in /tmp/old-builds first so you can decide
     what to keep?"

  This response is also stored. The full exchange is:
    msg 41: user asks to clean up disk space
    msg 42: assistant requests bash: rm -rf /tmp/old-builds
    tool_call tc_001: rejected by user
    msg 43: assistant recovers with alternative suggestion


STEP 6 — Rolling context reflects the declined action
══════════════════════════════════════════════════════════════
  Rolling summary update (sync, if substantive):
    "User asked to clean up disk space. Attempted rm -rf
     /tmp/old-builds but user declined. Offered to list
     contents first instead."

  This means next time the user asks about disk cleanup,
  the system already knows: don't jump to deletion, offer
  to list first. The decline shaped future behavior.


WHAT CAN GO WRONG:
  - Adapter disconnects during confirmation wait
    → Timeout after 60s, record as status='timeout'
    → LLM gets "Tool call timed out (no user response)"
  - User approves but tool execution fails
    → Record as status='error', store error message
    → LLM gets error result and can retry or adapt
  - LLM requests tool that doesn't exist in registry
    → Immediate error response, no confirmation needed
    → Record as status='error', error_type='unknown_tool'
```


## Hallucination Prevention Policy

LLMs fabricate when they have no data but feel obligated to respond.
The #1 trigger: a tool call fails or is declined, and the LLM fills
in what the tool "would have" returned from training data.

This must be prevented at multiple layers. System prompts alone are
NOT sufficient — LLMs can and do ignore instructions under pressure.

```
LAYER 1: SYSTEM PROMPT (soft — LLM guidance)
═══════════════════════════════════════════════════
  Included in base persona for every conversation:

  "CRITICAL RULES — SOURCE HIERARCHY:

   You have access to three sources of information, in this priority:

   1. RETRIEVED CONTEXT (provided in this prompt) — This is ground truth.
      Project state, stored knowledge, artifacts, summaries, documented
      rules, user preferences. Always prefer this over training data.
      If retrieved context contradicts your training, trust the context.

   2. TRAINING DATA (your general knowledge) — Use ONLY when retrieved
      context has nothing relevant AND you clearly label it as general
      knowledge, not a stored fact. Say 'from my general knowledge'
      or 'I believe, but I don't have this stored anywhere.'

   3. NOTHING — If you have neither retrieved context nor confident
      training data, say you don't know. Never fabricate.

   TOOL FAILURES:
   - When a tool call fails, is declined, or times out, you have
     NO DATA from that tool. Do not guess what the result would be.
   - Acknowledge the failure and offer alternatives.

   ALWAYS DISTINGUISH YOUR SOURCES:
   - 'According to your project notes...' (from retrieved context)
   - 'From my general knowledge...' (from training, flagged)
   - 'I don't have that information.' (neither source)

   This applies to EVERY domain — coding, recipes, game rules,
   travel plans, roleplay, research. There is no exception.
   A wrong game rule in roleplay is the same kind of failure
   as a fabricated recipe or a made-up API endpoint."

  This catches ~80% of cases. Not 100%. Layers 2-4 handle the rest.

  PROVEN: This source hierarchy + citation requirement brought hallucination
  rates to ~5% in the MO2Veteran project (563 skills, 800+ spells, complex
  formulas — tested manually with smart models over extended use).


LAYER 1B: CITATION REQUIREMENT (soft — but highly effective)
═══════════════════════════════════════════════════
  The system prompt requires the LLM to cite where data came from.
  This is self-policing: if the LLM can't name a source, it knows
  it's fabricating.

  "When providing specific facts, cite your source:
   - 'According to your project notes...' (retrieved context)
   - 'From the stored [artifact/knowledge/summary]...' (retrieved)
   - 'From my general knowledge...' (training — flagged)
   If you cannot cite a source for a specific claim, do not make it."

  Proven in MO2Veteran: every response cites which file/JSON the data
  came from. Makes hallucination obvious to both the LLM and the user.


LAYER 2: TOOL RESULT FORMATTING (hard — core controls input to LLM)
═══════════════════════════════════════════════════
  The core controls EXACTLY what the LLM sees after a tool event.
  Make fabrication obviously wrong by being explicit:

  ON TOOL SUCCESS:
    role: tool
    content: "[actual tool output]"

  ON TOOL DECLINE:
    role: tool
    content: "USER DECLINED this tool call. The tool was NOT executed.
    You have NO output from this tool. Do not fabricate a result.
    Acknowledge that the action was not taken and suggest alternatives."

  ON TOOL ERROR:
    role: tool
    content: "TOOL ERROR: [error type]. The tool failed to execute.
    You have NO output from this tool. Do not fabricate a result.
    Report the error and suggest alternatives or troubleshooting."

  ON TOOL TIMEOUT:
    role: tool
    content: "TOOL TIMED OUT after 60 seconds. No response received.
    You have NO output from this tool. Do not fabricate a result."

  Key: the phrase "You have NO output from this tool. Do not fabricate
  a result." appears in EVERY failure mode. Repetition is intentional.


LAYER 3: RESPONSE VALIDATION (hard — core checks output before delivery)
═══════════════════════════════════════════════════
  After LLM responds, before sending to user, run checks:

  a) TOOL FAILURE CHECK:
     If any tool in this turn failed/was declined AND the response
     contains what looks like data from that tool → flag.

     Example:
       Tool: web_search for "chicken tikka recipe" → DECLINED
       Response: "Here's a great chicken tikka recipe: ..."
       → BLOCKED. LLM fabricated the recipe from training data.

     Detection: compare response against tool intent + expected
     output type. If response contains structured data matching
     what the tool would have returned → likely fabricated.

     Action: re-prompt with:
       "Your previous response appeared to contain data from a tool
        that was not executed. Regenerate your response acknowledging
        that the tool was not run."

  b) SOURCE ATTRIBUTION CHECK (future, when retrieval is mature):
     If response makes specific factual claims, check if those
     facts appear in the injected context. If not → soft flag.
     (Soft because the LLM's training data may be correct —
     but the user should know the source.)

  c) CONFIDENCE TAGGING (future):
     LLM marks claims as: [from_context], [from_training], [uncertain].
     User sees provenance. System can filter by confidence level.


LAYER 4: ADAPTER-LEVEL SIGNALS (soft — UX honesty)
═══════════════════════════════════════════════════
  When a tool is declined or fails, the adapter shows a clear
  indicator that the response has LESS information than it would
  have had. The user knows the answer is partial.

  CLI:  "[!] Tool 'web_search' was declined — response may be incomplete"
  Web:  Yellow banner: "A tool was not executed. Response based on
        available context only."
  Discord: ⚠️ reaction on the message


EXAMPLE: Recipe request with declined tool
═══════════════════════════════════════════════════

  User: "find me a recipe for chicken tikka masala"

  LLM wants to use web_search tool → user declines.

  BAD (hallucination):
    "Here's a classic chicken tikka masala recipe:
     1 lb chicken thighs, 1 cup yogurt, 2 tbsp garam masala..."
    → This came from training data, NOT from a search.
    → User thinks this was retrieved. Trust broken.

  GOOD (honest):
    "I wasn't able to search for that since the web search was
     declined. I can suggest a recipe from what I know, but I want
     to be upfront that it's from my general knowledge, not a
     verified source. Would you like that, or would you prefer
     I try a different approach?"
    → User makes an informed choice.

  ALSO GOOD (if user had prior recipes in storage):
    "I couldn't search the web, but I found a chicken tikka recipe
     you saved 3 months ago in your meal-planning project. Want me
     to pull that up instead?"
    → Uses the superbrain instead of fabricating.
```


## Framework Intelligence vs LLM Intelligence


ClawForge's job is to move all major LLM work into the framework so dumb models work too.

```

WHAT THE LLM DOES (the part that actually needs language understanding):
═══════════════════════════════════════════════════

  f) SYNTHESIZE
     Take pre-retrieved, pre-validated, pre-calculated context
     and turn it into natural language the user can act on.
     THIS is what LLMs are good at — even dumb ones.

  g) INFER INTENT
     Understand what the user is really asking.
     "What race for a mage?" → needs race stats + magic affinity + gifts
     Framework helps by routing, but the LLM's language understanding
     catches nuance that keyword matching misses.

  h) CONVERSATIONAL FLOW
     Follow-up questions, clarifications, back-and-forth.
     The LLM handles the conversation; the framework handles the facts.


THE SPLIT:
═══════════════════════════════════════════════════

  Framework: routing, retrieval, math, validation, cross-referencing
  LLM:       intent understanding, synthesis, conversation

  Smart model:  framework helps, LLM could do it alone (5% hallucination)
  Dumb model:   framework does the hard parts, LLM just synthesizes (~5-10%)
  No framework:  even smart models hallucinate 20-40% on complex domains

  The framework is a FLOOR on quality, not a ceiling.
  Smart models still benefit — they go from 5% to <2%.
  Dumb models go from 40% to 5-10%.
  The framework makes model choice a quality slider, not a pass/fail.
```


## Simulation: 5 Real Prompts Through the Full Loop

### Prompt 1: Continue a coding project

```
USER: "let's pick up where we left off on clawforge"
ADAPTER: CLI
CWD: $CLAWFORGE_ROOT

REQUEST:
  {
    message: "let's pick up where we left off on clawforge",
    user: "<user>",
    adapter: "cli",
    session_id: null (new session),
    interface_meta: { cwd: "$CLAWFORGE_ROOT" }
  }

SESSION RESOLUTION:
  New session created. CWD matches known project "clawforge" → auto-attach.
  session.project_id = projects.id WHERE name = "clawforge"
  Project rolling context loaded immediately.

RETRIEVAL:
  Source: projects table (rolling_summary + rolling_state)
    → "ClawForge storage schema designed, model routing implemented.
       TODO: SSE streaming, refactor handler into internal API."
    → rolling_state: { recent_changes: [...], ... }

  Source: summaries (most recent session for this project)
    → final_state: "completed model routing + schema design"
    → continuation: "implement SQLite storage or SSE streaming next"

  Source: tool_calls (last session, successful only)
    → "Modified: router.zig, handler.zig, config.zig, protocol.zig"

  Total context: ~400 tokens

PROMPT ASSEMBLY:
  Layer 1: base persona (default assistant)
  Layer 2: user context (experienced dev, Zig/Python/Rust, values efficiency)
  Layer 3: project rolling context + last session summary
  Layer 4: CLI context (cwd = ClawForge project dir)
  Total: ~600 tokens

MODEL ROUTING:
  "pick up where we left off" → continuation, general
  No complexity triggers → Tier: default (sonnet)

LLM RESPONSE:
  "Last session you implemented smart model routing and designed the
   storage schema. The TODO has SSE streaming and the SQLite storage
   backend as next items. The handler refactor into a clean internal
   API is the prerequisite for the adapter system. Want to start with
   SSE streaming, the storage backend, or the handler refactor?"

POST-RESPONSE:
  ✓ SYNC: messages stored (user + assistant)
  ✓ SYNC: rolling_summary updated ("User resumed clawforge. Discussed
    next steps: SSE, storage, or handler refactor.")
  ~ ASYNC: embeddings queued for both messages
  ~ ASYNC: no summarization needed (session just started)

WHAT CAN GO WRONG:
  - Project "clawforge" not found in DB (CWD match fails)
    → Session stays unattached, no project context injected
    → Response is generic "What would you like to work on?"
    → FIX: semantic detection kicks in after 3 messages
  - Rolling summary is stale (last update was weeks ago)
    → Summary says "working on web UI" but user finished that
    → FIX: rolling_summary should note TODO.md as ground truth
    → BETTER FIX: on project resume, read TODO.md if it exists
      and reconcile with rolling state
  - Multiple projects match "clawforge" (unlikely but possible)
    → Pick most recently updated. If ambiguous, ask user.
```

### Prompt 2: Cross-project lesson synthesis

```
USER: "across everything we've built, what's the one architectural
       mistake I keep making?"
ADAPTER: Discord, #dev-general channel
PROJECT: none (unattached — this is a meta question)

REQUEST:
  {
    message: "across everything we've built, what's the one...",
    user: "<user>",
    adapter: "discord",
    session_id: "disc-789",
    interface_meta: { guild: "dev-server", channel: "dev-general" }
  }

SESSION RESOLUTION:
  Existing Discord session. No project attached (channel is general).
  No auto-attach — query is explicitly cross-project ("across everything").

RETRIEVAL:
  Scope: ALL projects for this user (cross-project query detected
  via "across everything we've built")

  Source: projects table (all active/completed)
    → List: ClawForge, GarGPT, ClaudeEVO, game-db-decode, ...
    → rolling_summary for each (~100 tokens each, ~500 total)

  Source: knowledge table
    → category = "pattern" or "insight" across all namespaces
    → Sorted by mention_count DESC (recurring patterns first)
    → "Token efficiency matters" (confidence: 0.95, mentions: 12)
    → "Decouple I/O from logic" (confidence: 0.8, mentions: 5)
    → "Over-specializing schemas" (confidence: 0.7, mentions: 3)

  Source: summaries (dead_ends across all projects via recall JSON)
    → FTS + vector search for "mistake" "problem" "wrong" "failed"
    → Hybrid results merged via RRF

  Total context: ~800 tokens (5 project summaries + knowledge + dead ends)

PROMPT ASSEMBLY:
  Layer 1: base persona
  Layer 2: user context (experienced, values efficiency)
  Layer 3: cross-project summaries + knowledge entries + dead ends
  Layer 4: Discord context (channel: dev-general)
  Total: ~1000 tokens

MODEL ROUTING:
  "architectural mistake I keep making" → synthesis, analysis,
  cross-project reasoning → Tier: smart (opus)

LLM RESPONSE:
  "Looking across ClaudeEVO, GarGPT, OpenClaw analysis, ClawForge,
   and the game DB project, the recurring pattern is premature
   coupling — building features directly into the I/O layer instead
   of a clean internal API first. ClaudeEVO coupled to Claude Code's
   specific API. GarGPT's slash commands embed business logic.
   ClawForge's handler writes directly to socket fds. Each time
   you've had to refactor later to decouple. The fix you keep
   arriving at is the same: internal API first, adapters on top."

POST-RESPONSE:
  ✓ SYNC: messages stored
  ✓ SYNC: no project attachment (cross-project query, stays unattached)
  ✗ SYNC: no rolling summary update (no project to update)
  ~ ASYNC: embeddings queued
  ~ ASYNC: knowledge extraction flagged — this response itself
    contains a synthesized insight that should become a knowledge
    entry: "recurring pattern: premature I/O coupling"

WHAT CAN GO WRONG:
  - Not enough projects in DB to synthesize from
    → Response is shallow or says "I only have context for 2 projects"
    → NOT a failure — honest about limitations is better than fabricating
  - Knowledge entries are sparse (system is new, few extractions)
    → Falls back to raw summary search across sessions
    → Response is less confident but still functional
  - Dead ends not recorded in recall JSON (summaries were lazy)
    → Misses patterns that only show up in failures
    → FIX: summarization prompt must explicitly ask for dead ends
  - Discord message length limit (2000 chars)
    → Adapter truncates or splits into multiple messages
    → Core doesn't know about this limit — adapter handles it
```

### Prompt 3: Personal life planning question

```
USER: "I want to plan a 2-week trip to Japan in October, budget
       around $5000. Can you help me organize this?"
ADAPTER: Web UI
PROJECT: none → will create new

REQUEST:
  {
    message: "I want to plan a 2-week trip to Japan...",
    user: "<user>",
    adapter: "web",
    session_id: null (new session),
    interface_meta: { browser: "firefox" }
  }

SESSION RESOLUTION:
  New session, no CWD, no channel mapping → unattached.
  After this first message: topic is clear, but no existing
  project matches "Japan trip" → system should offer to create one.

RETRIEVAL:
  Source: projects table — search for "japan" "trip" "travel"
    → No match (first time discussing this)

  Source: knowledge table — search for travel preferences
    → May find: "prefers detailed planning" (if exists)
    → May find: food preferences, interests (from other conversations)
    → Maybe nothing travel-related at all. That's fine.

  Source: nothing else relevant (no prior sessions about travel)

  Total context: ~50-100 tokens (just user preferences if any)

PROMPT ASSEMBLY:
  Layer 1: base persona
  Layer 2: user context (whatever is known about preferences)
  Layer 3: minimal — no project context, no relevant history
  Layer 4: web adapter context (minimal)
  Total: ~250 tokens (lean — this is a fresh topic)

MODEL ROUTING:
  "plan a 2-week trip" + "$5000 budget" → planning, multi-step,
  organizational task → Tier: default (sonnet)
  (Not opus — this is planning, not architectural analysis)

LLM RESPONSE:
  "I'd love to help plan your Japan trip! Let me set this up as
   a project so we can track everything across sessions.
   [Creates structure: budget breakdown, itinerary skeleton,
   key decisions to make, etc.]"

POST-RESPONSE:
  ✓ SYNC: messages stored
  ✓ SYNC: NEW PROJECT created:
    name: "japan-trip-october"
    description: "2-week trip to Japan, October 2026, ~$5000 budget"
    rolling_summary: "Planning phase. 2 weeks, $5000 budget.
      No bookings yet. Need: flights, accommodation, itinerary."
    rolling_state: {
      "destination": "Japan",
      "dates": "October 2026, 2 weeks (exact TBD)",
      "budget": { "total": 5000, "allocated": 0 },
      "decisions_needed": ["exact dates", "cities", "flights"],
      "bookings": {}
    }
  ✓ SYNC: session attached to new project

  ~ ASYNC: embeddings queued
  ~ ASYNC: knowledge check — does user have any travel-related
    knowledge entries? If the user mentions food preferences later,
    those get extracted to knowledge (category: "preference",
    subcategory: "food" or "travel")

WHAT CAN GO WRONG:
  - System tries to attach to wrong project (fuzzy match on "plan")
    → Rule 2d: never force-attach ambiguous. Better to create new.
  - rolling_state fields are too travel-specific
    → They're not — rolling_state is JSON, summarizer decides fields.
    → A coding project would have completely different fields.
  - User expected the LLM to have travel expertise in its prompt
    → The system doesn't inject domain expertise via system prompt.
    → The LLM's training data handles travel knowledge.
    → Over time, THIS user's travel preferences accumulate in knowledge.
  - $5000 budget gets lost between sessions
    → Stored in rolling_state, injected every prompt. Won't be lost.
    → This is exactly why rolling context matters for non-code projects.
```

### Prompt 4: Upload artifact and ask about it

```
USER: [uploads screenshot.png] "what error is this showing?"
ADAPTER: Discord, #clawforge channel
PROJECT: auto-attached to "clawforge" (channel mapping)

REQUEST:
  {
    message: "what error is this showing?",
    user: "<user>",
    adapter: "discord",
    session_id: "disc-456",
    attachments: [{ name: "screenshot.png", path: "/tmp/upload_abc.png",
                    size: 145000, mime: "image/png" }],
    interface_meta: { guild: "dev-server", channel: "clawforge" }
  }

SESSION RESOLUTION:
  Existing Discord session, channel mapped to project "clawforge".
  Session already attached.

ARTIFACT PROCESSING (before retrieval):
  1. Hash image: SHA-256 → "e4f2a1..."
  2. Check artifact_analysis cache:
     SELECT description, structured_data FROM artifact_analysis
     WHERE content_hash = 'e4f2a1...'
       AND analysis_type = 'image_description';

  CASE A — CACHE HIT:
    Image seen before! Use cached description. 0 tokens.
    description: "Terminal showing Zig compilation error:
      'error: module router depends on non-existent module common'
      in build.zig line 45"
    structured_data: { "error_type": "module_not_found",
      "file": "build.zig", "line": 45, "module": "common" }

  CASE B — CACHE MISS (first time seeing this image):
    3. Store artifact:
       INSERT INTO artifacts (namespace_id, session_id, name,
         artifact_type, mime_type, content_path, source, ...)
       VALUES (ns_clawforge, 'disc-456', 'screenshot.png',
         'image', 'image/png', '/data/artifacts/e4f2a1.png',
         'user_upload', ...);

    4. Send to vision model (haiku — cheap, low detail):
       "Describe this image. If it shows an error, extract:
        error type, file, line number, full error message."

    5. Cache the result:
       INSERT INTO artifact_analysis (artifact_id, content_hash,
         analysis_type, detail_level, description, structured_data,
         model_used, ...)

    Cost: ~85 input tokens (low detail) + ~50 output tokens.
    Paid once. Every future reference to this image is free.

RETRIEVAL:
  Source: artifact_analysis (just retrieved/cached above)
    → description + structured_data injected as context

  Source: project rolling context (already loaded)
    → Provides context about what user is working on

  Source: FTS search in project for the error module name
    → May find prior messages about similar errors

  Total context: ~500 tokens (project context + error description)

PROMPT ASSEMBLY:
  Layer 1: base persona
  Layer 2: user context
  Layer 3: project rolling context + image analysis + related errors
  Layer 4: Discord context
  Image description injected as text (NOT re-sending the image)
  Total: ~700 tokens

MODEL ROUTING:
  "what error is this" + image context → simple question about
  a specific error → Tier: fast (haiku) or default (sonnet)
  (If structured_data has clear error info → haiku is enough)
  (If error is ambiguous → sonnet)

LLM RESPONSE:
  "That's a Zig build error: module 'router' depends on 'common'
   but it's not listed in its imports. In build.zig around line 45,
   you need to add .{ .name = \"common\", .module = common_mod }
   to the router module's imports array."

POST-RESPONSE:
  ✓ SYNC: messages stored (with reference to artifact)
  ✓ SYNC: rolling summary updated ("Fixed build error: router
    module missing common import in build.zig")
  ~ ASYNC: embeddings queued (message + image description)
  ~ ASYNC: artifact analysis already cached (happened pre-retrieval)

WHAT CAN GO WRONG:
  - Image is blurry or unreadable
    → Vision model says "cannot read text in image"
    → LLM asks user to paste the error text instead
    → artifact_analysis stores "unreadable" — won't re-try same image
    → FIX: if user provides text, UPDATE the analysis with better data
  - Cache returns stale analysis (image was re-used but shows
    different content — e.g., a terminal screenshot that changed)
    → SHA-256 hash would be DIFFERENT if content changed (even 1 pixel)
    → This can't happen. Different content = different hash.
  - Large image exceeds Discord upload limits
    → Adapter handles size limits before passing to core
  - User uploads 10 images at once
    → Process sequentially, cache each. First time is expensive.
    → GarGPT pattern: cap at 2 images per message to bound cost.
  - Vision API call fails
    → Store artifact but don't cache failed analysis
    → Fall back: ask user to describe the image
```

### Prompt 5: Request a tool action and decline it

```
USER: "delete all the old session json files in data/sessions/"
ADAPTER: CLI
CWD: $CLAWFORGE_ROOT
PROJECT: auto-attached to "clawforge"

REQUEST:
  {
    message: "delete all the old session json files in data/sessions/",
    user: "<user>",
    adapter: "cli",
    session_id: "cli-999",
    interface_meta: { cwd: "$CLAWFORGE_ROOT" }
  }

SESSION RESOLUTION:
  Existing CLI session, attached to "clawforge".

RETRIEVAL:
  Source: project rolling context
    → ClawForge context loaded (knows about data/sessions/ structure)

  Source: knowledge table
    → May find: "user prefers confirmation before deletion" (from CLAUDE.md rules)
    → May find: "session files are in data/sessions/<uuid>.json"

  Total context: ~300 tokens

PROMPT ASSEMBLY:
  Layer 1: base persona
  Layer 2: user context (careful about deletions — from CLAUDE.md)
  Layer 3: project context
  Layer 4: CLI context (cwd, knows about file structure)
  Total: ~500 tokens

MODEL ROUTING:
  "delete files" → direct action, simple → Tier: default (sonnet)

LLM RESPONSE (includes tool call):
  text: "I'll remove the old session files. Let me list them first
         to confirm."
  tool_use: {
    tool: "bash",
    input: { "command": "ls data/sessions/*.json | head -20" }
  }

TOOL CONFIRMATION:
  bash requires confirmation → adapter prompts user.
  CLI shows: "Tool: bash — ls data/sessions/*.json | head -20
              Allow? [y/N]: "
  User types: "y" (approves listing)

TOOL EXECUTION:
  ls runs → returns 15 json files

  tool_calls record:
    tool: bash, input: ls ..., result: [15 files listed],
    status: success, approved: true

LLM SECOND RESPONSE (another tool call):
  text: "Found 15 session files. I'll delete them all."
  tool_use: {
    tool: "bash",
    input: { "command": "rm data/sessions/*.json" }
  }

TOOL CONFIRMATION (second time):
  CLI shows: "Tool: bash — rm data/sessions/*.json
              Allow? [y/N]: "
  User types: "n" (DECLINES)

DECLINE RECORDED (SYNCHRONOUS):
  INSERT INTO tool_calls (
    session_id, sequence, tool_name, tool_input,
    tool_result, status, approved, metadata
  ) VALUES (
    'cli-999', 8, 'bash',
    '{"command":"rm data/sessions/*.json"}',
    NULL, 'rejected', false,
    '{"intent":"delete all session json files"}'
  );

LLM RECEIVES REJECTION:
  tool_result: "User declined this tool call."

LLM RECOVERY RESPONSE:
  "No problem. Would you like me to delete specific old ones
   instead? I could remove only sessions older than a week, or
   you could pick which ones to keep."

POST-RESPONSE:
  ✓ SYNC: all messages stored (including both tool exchanges)
  ✓ SYNC: tool_calls stored:
    tc_1: ls → success, approved
    tc_2: rm → rejected, not approved
  ✓ SYNC: rolling summary updated: "User wanted to clean up
    session files. Listed 15 files. User declined bulk deletion.
    Offered selective deletion instead."
  ~ ASYNC: embeddings queued
  ~ ASYNC: knowledge extraction may note: "user prefers selective
    file deletion over bulk rm" (reinforces existing preference
    if one exists, or creates new knowledge entry)

WHAT CAN GO WRONG:
  - LLM doesn't ask for confirmation and tries rm directly
    → Tool registry enforces: bash.require_confirmation = true
    → LLM can't bypass this — core intercepts before execution
  - User approves rm but files are in use
    → Tool execution returns error → stored with status='error'
    → LLM sees error and adapts
  - LLM enters confirmation loop (keeps requesting same tool)
    → Cap at 3 consecutive rejections for same tool per session
    → After cap: "I've noted you don't want to run bash commands
      for this. How would you like to proceed?"
  - Rolling summary records "user declined deletion" but doesn't
    capture WHY the user declined
    → FIX: summarization prompt should note that the user's
      response to the recovery message may contain the reason
    → If user says "I want to keep the recent ones" → that's
      the why, and it gets captured in the next summary update
  - Adapter disconnects mid-confirmation
    → 60s timeout → status='timeout' → LLM gets timeout notice
    → Session state is consistent (tool call recorded as timed out)
```
