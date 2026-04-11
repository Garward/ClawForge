# ClawForge Implementation Plan

Each phase is a self-contained slice that can be done in one context window.
Phases are ordered by dependency — each builds on the one before it.
Within each phase, steps are ordered so you can build-test-verify incrementally.

Reference docs:
- Architecture: `docs/architecture.md` (system overview, message loop, threading, simulations)
- Schema: `docs/storage_schema.sql` (full DB schema, validated)
- TODO: `TODO.md` (vision + detailed task descriptions)


## Dependency Graph

```
Phase 1: Internal API ──────────┐
                                │
Phase 2: SQLite core ───────────┤
                                │
Phase 3: Streaming (SSE) ──┐    ├── Phase 6: Prompt assembler
                            │   │
Phase 4: Projects +         │   ├── Phase 7: Adapter system
  rolling context ──────────┤   │
                            │   ├── Phase 8: Summarization
Phase 5: Tool confirm ──┐  │   │
  flow                  │  │   ├── Phase 9: Knowledge extraction
                        │  │   │
                        └──┴───┤── Phase 10: Embeddings + hybrid search
                               │
                               ├── Phase 11: Background workers
                               │
                               ├── Phase 12: Provider abstraction
                               │
                               └── Phase 13: Self-extension
```


## Phase 1: Internal API Refactor
**Goal:** Decouple handler from fd/socket so any adapter can call the same function.
**Why first:** Everything else builds on this. Can't add adapters, can't change storage,
can't do streaming properly if the core is coupled to Unix socket fd writes.

**Files to modify:**
- `src/daemon/handler.zig` → `src/core/engine.zig`
- `src/daemon/server.zig` (becomes an adapter over engine)
- `src/daemon/web.zig` (becomes an adapter over engine)
- `src/common/protocol.zig` (Request/Response types stay, but engine returns Response directly)

**Steps:**
1. Create `src/core/engine.zig` with `fn process(request: Request) Response`
   - Move all handle* logic from handler.zig into engine
   - No fd parameter. No sendResponse. Just return the Response.
2. Update handler.zig to be a thin wrapper: receive from socket → call engine → serialize response → write to fd
3. Update web.zig to call engine.process() instead of duplicating logic
4. Update build.zig to add core module
5. Verify: all existing functionality works identically (CLI, web UI, tests)

**Test:** `zig build test` passes. CLI commands work. Web UI works. Playwright tests pass.
**Size:** ~200-300 lines changed. Small, surgical.


## Phase 2: SQLite Core Storage
**Goal:** Replace JSON file sessions with SQLite. Set up the DB foundation
that everything else builds on.

**Files to create:**
- `src/storage/db.zig` — connection management (1 writer + N readers, WAL)
- `src/storage/migrations.zig` — schema creation from docs/storage_schema.sql
- `src/storage/messages.zig` — message CRUD
- `src/storage/sessions.zig` — session CRUD (replaces session.zig JSON logic)
- `src/storage/namespaces.zig` — namespace tree + materialized paths

**Steps:**
1. Create `src/storage/db.zig`:
   - SQLite bindings via Zig's C interop (`@cImport sqlite3.h`)
   - Connection pool: 1 write connection, N read connections
   - Writer thread with message queue (channel-based)
   - WAL mode, busy_timeout=5000, synchronous=NORMAL
2. Create `src/storage/migrations.zig`:
   - Create core tables: namespaces, namespace_paths, sessions, messages, context_snapshots
   - FTS5 indexes for messages
   - Version tracking for future migrations
3. Create `src/storage/namespaces.zig`:
   - Create/resolve namespace tree nodes
   - Maintain materialized paths on insert
4. Create `src/storage/sessions.zig`:
   - Drop-in replacement for current session.zig
   - Same public API (createSession, getActiveSession, etc.)
   - Backed by SQLite instead of JSON files
5. Create `src/storage/messages.zig`:
   - Store/retrieve messages with sequence numbers
   - buildApiMessages() from DB instead of in-memory array
6. Update engine.zig to use storage instead of session manager
7. Update main.zig to init DB, run migrations, pass to engine
8. Update build.zig: link sqlite3, add storage module

**Test:** Existing functionality works with SQLite backend. Sessions persist across daemon restarts.
Old JSON sessions can be migrated (one-time script or on first load).
**Size:** ~800-1000 lines new code. Largest phase but mostly mechanical CRUD.
**Dependency:** sqlite3 C library (`pacman -S sqlite`)


## Phase 3: Streaming (SSE)
**Goal:** Stream responses to CLI and web UI instead of waiting for completion.

**Why here:** Improves UX dramatically. Independent of storage changes.
Can be done in parallel with Phase 2 if desired.

**Files to modify:**
- `src/api/anthropic.zig` — use `open()` instead of `fetch()` for streaming
- `src/api/sse.zig` — SSE line parser (event: / data: lines)
- `src/core/engine.zig` — streaming callback interface
- `src/daemon/server.zig` — forward stream chunks over socket
- `src/daemon/web.zig` — SSE endpoint (GET /api/chat/stream)
- `src/daemon/web/index.html` — EventSource JS client

**Steps:**
1. Implement SSE parser in `src/api/sse.zig`:
   - Parse `event:` and `data:` lines from HTTP response body
   - Handle: message_start, content_block_delta, message_stop
   - Yield text deltas as they arrive
2. Update anthropic.zig `createMessage()` to support streaming:
   - Use `std.http.Client.open()` for incremental reads
   - Call a callback function for each text delta
3. Add streaming callback to engine.process():
   - `fn process(request, onChunk: fn(Response) void) Response`
   - Chunks sent as stream_text responses
   - Final response is stream_end with token usage
4. Update socket server to forward chunks
5. Add SSE endpoint to web server
6. Update web UI JS to use EventSource

**Test:** CLI shows text appearing incrementally. Web UI streams text.
**Size:** ~400-500 lines. Medium complexity (SSE parsing is fiddly).


## Phase 4: Projects and Rolling Context
**Goal:** Projects as first-class entities with rolling context updated per prompt.

**Files to create:**
- `src/storage/projects.zig` — project CRUD + rolling state management
- `src/core/context.zig` — context retrieval (project state, recent messages)
- `src/core/attachment.zig` — session-to-project attachment logic

**Steps:**
1. Create projects table in migrations (already in schema)
2. Create `src/storage/projects.zig`:
   - CRUD for projects
   - `updateRollingContext(project_id, summary, state)` — called synchronously
   - `getRollingContext(project_id) -> {summary, state}`
3. Create `src/core/attachment.zig`:
   - Rule 1: CWD match → auto-attach (CLI adapter provides cwd in interface_meta)
   - Rule 2: Explicit name match ("let's work on X")
   - Rule 3: Semantic match after 3+ messages (cheap haiku call)
   - Rule 4: Never force-attach ambiguous
   - `fn checkAttachment(session, message, interface_meta) ?project_id`
4. Create `src/core/context.zig`:
   - Load project rolling context if attached
   - Load recent N messages from session
   - Combine into context struct for prompt assembly
5. Integrate into engine.zig:
   - After session resolution, check attachment
   - Load context
   - After response, update rolling summary (sync, haiku call, skip for trivial messages)
6. Add CLI command: `clawforge project list`, `project create <name>`, `project attach <name>`

**Test:** Create a project. Start session. Session auto-attaches via CWD. Rolling summary
updates after each substantive message. Resume session next day → context is current.
**Size:** ~600-700 lines.


## Phase 5: Tool Confirmation Flow
**Goal:** Full tool execution with adapter-specific confirmation UI and graceful decline handling.

**Files to modify:**
- `src/core/engine.zig` — tool execution loop with confirmation callback
- `src/tools/registry.zig` — which tools need confirmation
- `src/common/protocol.zig` — ToolConfirmRequest/Response (already exists)
- `src/daemon/server.zig` — relay confirmation to CLI
- `src/daemon/web.zig` — relay confirmation to web UI
- `src/client/display.zig` — CLI confirmation prompt

**Steps:**
1. In engine.zig, when LLM returns tool_use:
   - Check registry: does this tool need confirmation?
   - If yes: return ToolConfirmRequest through callback
   - Wait for ToolConfirmResponse (approved/declined)
   - If declined: record in tool_calls with status='rejected', send rejection to LLM
   - If approved: execute tool, record result, send to LLM
   - LLM may respond with more tool calls → loop
2. Implement 3-rejection cap per tool per session
3. Tool call results stored synchronously (before LLM sees next turn)
4. CLI display: show tool request, prompt y/N, send response
5. Web UI: modal with approve/deny buttons
6. Store all tool calls (success, error, rejected, timeout) in DB

6. Implement anti-hallucination tool result formatting:
   - Declined: "USER DECLINED. You have NO output. Do not fabricate a result."
   - Error: "TOOL ERROR: [type]. You have NO output. Do not fabricate a result."
   - Timeout: "TOOL TIMED OUT. You have NO output. Do not fabricate a result."
   - Every failure mode includes explicit "do not fabricate" instruction
7. Implement Layer 3 response validation:
   - After LLM responds to a tool failure, check if response contains data
     that could only come from the failed tool
   - If detected: re-prompt with "Your response contained fabricated data.
     Regenerate acknowledging the tool was not run."
   - Simple heuristic: if tool was web_search and response contains
     structured data (lists, recipes, prices) → flag

**Test:** LLM requests bash → user approves → executes → result shown.
LLM requests bash → user declines → LLM recovers gracefully.
LLM requests web_search → declined → LLM does NOT fabricate search results.
Declined tool call visible in DB with status='rejected'.
**Size:** ~500-600 lines. Medium — the confirmation callback + validation is the tricky part.


## Phase 6: Prompt Assembler (Layered System Prompts)
**Goal:** Build system prompts from composable layers with sane defaults.

**Files to create:**
- `src/core/prompt.zig` — layered prompt builder
- `config/personas/default.txt` — default base persona
- `config/personas/` — directory for custom personas

**Steps:**
1. Define prompt layers:
   - Layer 1: Base persona + source hierarchy rules (from config file or per-user override)
     The source hierarchy is NON-NEGOTIABLE in every prompt:
       Priority 1: Retrieved context (ground truth — project state, stored knowledge, artifacts)
       Priority 2: Training data (only when flagged as "from my general knowledge")
       Priority 3: Nothing (say you don't know)
     This is what prevents hallucination across ALL domains — coding, recipes, game rules,
     roleplay, anything. A wrong game rule from training is the same failure as a fake recipe.
   - Layer 2: User context (from knowledge table — preferences, expertise, style)
   - Layer 3: Project context (rolling_summary + rolling_state from context.zig)
   - Layer 4: Retrieved context (from search — summaries, knowledge entries)
     TAGGED: each piece of retrieved context labeled with source for provenance
   - Layer 5: Adapter context (cwd, channel info, interface-specific)
   - Layer 6: Tool definitions (from registry)
2. Create `src/core/prompt.zig`:
   - `fn buildSystemPrompt(layers: PromptLayers) []const u8`
   - Each layer is optional (null = skip)
   - Token budget: cap total system prompt at configurable limit
   - If over budget: trim retrieved context first, then project context
3. Ship default persona that works for any topic:
   - Not opinionated about domain
   - Values: precision, learning from mistakes, building on past experience
   - Includes anti-hallucination rules (see architecture.md: Hallucination Prevention Policy)
     - Never fabricate tool results
     - Never fill from training data when retrieval returns empty
     - Distinguish: context facts vs training facts vs uncertain
   - Short, <200 tokens (anti-hallucination rules are non-negotiable, worth the tokens)
4. Config option: per-user persona override, per-project persona override
5. Integrate into engine.zig: build prompt before LLM call
6. Retrieved context tagging: every piece of injected context labeled with provenance
   so the LLM can cite sources: "[from project rolling_state]", "[from knowledge entry]",
   "[from session summary 2026-04-08]", "[from artifact analysis]"
7. Per-project constraints injection: if rolling_state has a "constraints" field,
   include those as explicit rules: "CONSTRAINT: budget must not exceed $5000"
   or "CONSTRAINT: do not suggest pets exceeding available pet points"
   These get checked by response validator (Phase 5 layer 3) after LLM responds.
8. Per-project response templates: if rolling_state has a "response_template" field,
   include it as a formatting guide. E.g., build requests always return 12 sections.
   Learned from MO2Veteran's build_request_template.md — consistency matters.

**Test:** Default persona works for coding, travel, gaming questions.
Custom persona overrides base. Project context injected when attached.
Citations appear in responses. Constraints enforced on output.
**Size:** ~400-500 lines. The constraint injection and tagging add complexity.


## Phase 7: Adapter System
**Goal:** Refactor CLI and Web UI as formal adapters. Define the adapter interface.

**Files to create/modify:**
- `src/adapters/adapter.zig` — adapter interface definition
- `src/adapters/cli.zig` — CLI adapter (refactored from server.zig)
- `src/adapters/web.zig` — Web adapter (refactored from web.zig)
- `src/storage/adapter_registry.zig` — adapter registration in DB

**Steps:**
1. Define adapter interface:
   ```
   const Adapter = struct {
     name: []const u8,
     fn start(engine: *Engine, config: *Config) void,
     fn stop() void,
   };
   ```
   Adapters receive input in their own way, call engine.process(), format output.
2. Refactor CLI socket server as an adapter
3. Refactor web HTTP server as an adapter
4. Adapter registration: on startup, each enabled adapter registers in adapter_registry table
5. Config: `adapters: { cli: { enabled: true }, web: { enabled: true, port: 8081 } }`
6. main.zig: iterate enabled adapters, start each in its own thread

**Test:** CLI and web still work identically. `clawforge status` shows registered adapters.
**Size:** ~400-500 lines (mostly moving existing code, not writing new).


## Phase 8: Summarization Engine
**Goal:** Automatic multi-level summaries with flexible recall JSON.

**Files to create:**
- `src/workers/summarizer.zig` — background summarization worker
- `src/storage/summaries.zig` — summary CRUD

**Steps:**
1. Create `src/storage/summaries.zig`:
   - CRUD for summaries table
   - FTS5 index maintenance (triggers handle this)
2. Create `src/workers/summarizer.zig`:
   - Runs as background thread
   - Triggers: session end, every 50 messages, daily roll-up
   - Calls haiku with session messages → produces summary + recall JSON
   - Prompt: "Summarize this conversation. Extract: topics, final_state,
     continuation, and any structured fields relevant to the conversation type."
   - Prompt does NOT prescribe fields — model decides what's relevant
3. Summary levels:
   - Session summary: on session close or 50+ messages
   - Daily summary: roll up all sessions for a project in a day
   - Weekly summary: roll up dailies (coarser, loses less-important detail)
4. Context snapshots: create snapshot every 10 messages or on state change
5. Wire into engine.zig post-response pipeline (async queue)

**Test:** Chat for 20 messages. End session. Summary generated with topics,
final_state, recall JSON. Summary searchable via FTS.
**Size:** ~500-600 lines. The summarization prompt design is the hard part.


## Phase 9: Knowledge Extraction
**Goal:** Distill insights from conversations into reusable knowledge entries.

**Files to create:**
- `src/workers/extractor.zig` — knowledge extraction worker
- `src/storage/knowledge.zig` — knowledge CRUD + confidence management

**Steps:**
1. Create `src/storage/knowledge.zig`:
   - CRUD for knowledge table
   - FTS5 index maintenance
   - `reinforce(id)` — bump mention_count and confidence
   - `contradict(id, reason)` — lower confidence, record contradiction
   - `findSimilar(title, content)` — dedup check before inserting
2. Create `src/workers/extractor.zig`:
   - Runs periodically (hourly, or on session close)
   - Reads recent summaries (not raw messages — cheaper)
   - Calls haiku: "From these summaries, extract reusable insights.
     For each: title, content, category, subcategory, confidence, tags.
     Only extract things that would be useful to recall in future sessions."
   - Dedup: check for existing similar knowledge before inserting
   - Reinforce: if insight matches existing entry, bump confidence
3. Knowledge decay: entries not reinforced in 90 days get confidence * 0.9
4. Integrate into search cascade: knowledge is layer 2 after projects

**Test:** Have several sessions about coding preferences. Extractor
produces knowledge entries like "Prefers composition over inheritance"
with confidence score. Mention it again → confidence increases.
**Size:** ~400-500 lines.


## Phase 10: Embeddings + Hybrid Search
**Goal:** Semantic search via local embeddings + FTS5 keyword search + RRF fusion.

**Files to create:**
- `src/storage/embeddings.zig` — embedding CRUD + vector search
- `src/workers/embedder.zig` — GPU batch embedding worker
- `src/core/search.zig` — hybrid search with RRF
- `src/core/simd.zig` — SIMD vector math (dot product, hamming)

**Steps:**
1. Set up local embedding model:
   - Option A: Link GGML as C dep, load model in-process
   - Option B: Shell out to llama-embedding server (simpler to start)
   - Start with Option B, migrate to A for performance later
2. Create `src/core/simd.zig`:
   - `dotProduct(a: []f32, b: []f32) f32` using @Vector(8, f32)
   - `hammingDistance(a: []u64, b: []u64) u32` using @popCount
   - Build with `-Dcpu=native` for AVX2
3. Create `src/storage/embeddings.zig`:
   - Store embeddings (binary + FP32) via sqlite-vector or raw BLOBs
   - `fn search(query_vec, namespace_scope, limit) []Result`
   - Two-pass: binary hamming broad → FP32 rescore top-k
4. Create `src/workers/embedder.zig`:
   - Background thread
   - Pulls from embed queue (new messages, summaries, knowledge entries)
   - Batches content (every 100ms or 64 docs)
   - Generates contextual chunk headers before embedding
   - Sends batch to GPU, writes results via writer thread
5. Create `src/core/search.zig`:
   - `fn hybridSearch(query, scope, limit) []Result`
   - Runs FTS5 and vector search in parallel
   - Merges via RRF: score = 1/(60+fts_rank) + 1/(60+vec_rank)
   - Returns merged, ranked results
6. Integrate into context.zig: search.hybridSearch() for context retrieval

**Test:** Store 100 messages. Search "what keeps me engaged" when actual
text says "progression systems" → semantic match found. Search "router.zig" →
keyword match found. Both appear in merged results.
**Size:** ~800-1000 lines. Complex but well-defined pieces.
**Dependencies:** sqlite-vector extension, local embedding model binary.


## Phase 11: Background Workers Unification
**Goal:** Clean worker thread management with proper queues and shutdown.

**Files to create:**
- `src/workers/pool.zig` — worker thread pool + queue management

**Steps:**
1. Create unified worker pool:
   - Writer thread (1): DB writes only
   - Embedder thread (1): GPU batch embedding
   - Summarizer thread (1): periodic summarization
   - Extractor thread (1): periodic knowledge extraction
2. Each worker has a typed queue (ring buffer or channel)
3. Graceful shutdown: SIGTERM → drain queues → join threads
4. Health monitoring: log if any queue backs up
5. Wire all workers through pool.zig instead of ad-hoc thread spawning

**Test:** All background operations complete. Graceful shutdown doesn't lose data.
**Size:** ~300-400 lines. Mostly threading infrastructure.


## Phase 12: Provider Abstraction
**Goal:** Plug in any LLM — Anthropic, OpenAI, local models.

**Files to create:**
- `src/api/provider.zig` — provider interface
- `src/api/openai.zig` — OpenAI-compatible API client
- `src/api/local.zig` — llama.cpp / Ollama integration

**Steps:**
1. Define provider interface:
   ```
   const Provider = struct {
     fn createMessage(request, onChunk) Response,
     fn createEmbedding(text) []f32,
   };
   ```
2. Wrap existing anthropic.zig as a provider
3. Implement OpenAI provider (API is similar, different auth/endpoints)
4. Implement local provider (llama.cpp server or Ollama API)
5. Config: `providers: { anthropic: {...}, openai: {...}, local: {...} }`
6. Model router can route to different providers:
   - haiku tier → local model (free)
   - sonnet tier → Anthropic API
   - opus tier → Anthropic API
   - Or any custom mapping

**Test:** Same conversation uses haiku (local) for simple and sonnet (API) for complex.
Switch providers mid-session without losing context.
**Size:** ~500-600 lines.


## Phase 13: Self-Extension (Tool Generation)
**Goal:** System can create, test, and register new tools.

**Files to create:**
- `src/tools/generator.zig` — tool generation from natural language
- `src/tools/sandbox.zig` — safe execution environment for generated tools

**Steps:**
1. When user asks for a capability that doesn't exist:
   - LLM recognizes no tool matches → generates a tool spec
   - Spec: name, description, input schema, implementation (bash script or code)
2. Sandbox: generated tools run in restricted environment
   - No network by default
   - Filesystem limited to project scope
   - Timeout enforced
3. Test: generated tool is executed in sandbox first
   - If passes → registered in tool registry
   - If fails → LLM sees error, iterates
4. Persistence: generated tools stored in DB (adapter_tables or tools table)
5. User can approve/revoke generated tools

**Test:** User asks "create a tool that counts lines of code by language".
System generates a bash script, tests it, registers it. Next time user
asks to count LOC, the tool is available.
**Size:** ~500-600 lines. Last phase — requires everything else working.


## Phase Sizing Summary

| Phase | Description | Lines | Depends on |
|-------|-------------|-------|------------|
| 1 | Internal API refactor | ~250 | nothing |
| 2 | SQLite core storage | ~900 | Phase 1 |
| 3 | Streaming (SSE) | ~450 | Phase 1 (can parallel with 2) |
| 4 | Projects + rolling context | ~650 | Phase 2 |
| 5 | Tool confirmation flow | ~450 | Phase 1 |
| 6 | Prompt assembler | ~350 | Phase 4 |
| 7 | Adapter system | ~450 | Phase 1 |
| 8 | Summarization engine | ~550 | Phase 2, 4 |
| 9 | Knowledge extraction | ~450 | Phase 8 |
| 10 | Embeddings + hybrid search | ~900 | Phase 2, 8 |
| 11 | Worker thread unification | ~350 | Phase 8, 9, 10 |
| 12 | Provider abstraction | ~550 | Phase 1, 3 |
| 13 | Self-extension | ~550 | Phase 5, 12 |
| **Total** | | **~6,850** | |

~6,850 lines of new code for the entire framework. Not a massive codebase.
Each phase is 250-900 lines — one focused session each.


## Parallel Tracks

Some phases can be worked on in parallel if desired:

```
Track A (storage):     Phase 2 → 4 → 8 → 9 → 10 → 11
Track B (UX):          Phase 3 → 5 → 7
Track C (intelligence): Phase 6 → 12 → 13

All tracks require Phase 1 first.
Track A is the critical path (most things depend on storage).
Track B is the most user-visible (streaming, tools, adapters).
Track C is the "superbrain" layer (prompts, providers, self-extension).
```


## Starting Each Phase

When starting any phase in a new context window, read:
1. `docs/architecture.md` — system overview, message loop, policies, simulations
2. `docs/storage_schema.sql` — DB schema (if phase touches storage)
3. `TODO.md` — vision + task descriptions
4. The source files listed in that phase's "Files to modify/create"

That's enough context to work without needing this conversation.
