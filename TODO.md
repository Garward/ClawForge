# ClawForge

## Vision

ClawForge is a **semantic agentic framework** — a local-first AI superbrain that works as a
co-developer, co-conversationalist, and personal assistant across any topic or project.

**Core philosophy:** The intelligence lives in the *storage and retrieval layer*, not the prompt.
The system gets smarter over time through accumulated knowledge, context, and user understanding —
not through increasingly complex system prompts. Any LLM (API or local) can be plugged in and
immediately benefit from the user's entire history, preferences, and project state.

**What it is:**
- **Provider-agnostic**: plug in any LLM — Anthropic, OpenAI, local models via Ollama.
  Smart routing picks the right model tier (cheap/default/powerful) per message automatically.
- **Interface-agnostic**: same brain accessible from CLI, web UI, Discord, HTTP API, or any
  future adapter. One daemon, one database, multiple thin I/O adapters.
- **Self-aware**: the model can query its own database — conversation history, knowledge base,
  tool usage, project state, embeddings — via the introspect tool. Full transparency.
- **Self-extending**: creates new tools as needed via LLM-generated code + sandbox testing.
- **Token-efficient**: surgical context injection via hybrid search (FTS5 + vector + RRF),
  session compaction, rolling project context. ~500 tokens of context, not 200k stuffing.

## Current State (v0.2.0)

### Working Systems
- [x] Engine: 20-round tool loop, per-request arena allocator, forced final text summary
- [x] Real SSE streaming: text deltas + tool_use/tool_result events end-to-end
- [x] Worker pool: 3 background threads (summarizer/extractor/embedder) with per-thread SQLite connections
- [x] Session compaction: auto-summarize long sessions, keep recent N raw messages
- [x] Tool call persistence: DB records + XML log in stored messages for cross-turn recall
- [x] Provider system: Anthropic (OAuth + API key), OpenAI, Ollama — configurable tier mapping
- [x] Web UI: forge theme, marked.js markdown, session persistence, config panel, SSE streaming
- [x] Hybrid search: FTS5 + Ollama nomic-embed-text vectors + RRF merge
- [x] All 6 database stores queryable via introspect tool (messages, knowledge, summaries, projects, tool_calls, embeddings)

### Tools (6 registered)
- [x] `bash` — shell execution, requires confirmation
- [x] `file_read` — file reading with line numbers, path traversal blocked
- [x] `file_write` — file writing with backup, requires confirmation
- [x] `amazon_search` — Playwright parallel multi-query, pre-computed price_per_oz/unit_size/pack_count/value_rank
- [x] `calc` — safe AST math evaluator, batch expressions, unit conversions, sorting
- [x] `introspect` — 13 query modes: message_search, message_history, knowledge_search, knowledge_browse, summary_search, summary_history, projects, project_context, semantic_search, sessions, tool_stats, tool_history, session_stats

## In Progress

### Web UI Polish
- [ ] Tool management: search bar, add/remove tools, runtime enable/disable via API endpoint
- [ ] Config panel: model selector, system prompt editor
- [ ] Session naming: auto-name from first message or user rename
- [ ] Message search within session (Ctrl+F style)

## Planned

### Skills System
- [ ] Reusable instruction templates the system can follow for complex multi-step tasks
- [ ] "How to create a tool" skill — guides the model through ToolGenerator workflow
- [ ] Skills stored in DB with category, trigger conditions, instruction text
- [ ] Model auto-selects applicable skills based on user request
- [ ] Skills editable via web UI

### Tool Ecosystem
- [ ] Runtime tool enable/disable API (POST /api/tools/:name/enable|disable)
- [ ] Tool generator UI: describe capability → LLM generates → sandbox test → approve
- [ ] Tool marketplace concept: shareable tool definitions between ClawForge instances
- [ ] Tool analytics: which tools are most used, success rates, avg execution time

### Adapters
- [ ] Discord adapter: bot gateway, guild/channel isolation, reaction-based tool confirmation,
      StreamEmitter → edit messages with deltas, react emojis for tool status
- [ ] HTTP API adapter: stateless request/response for external integrations
- [ ] Each adapter toggleable in config

### Storage & Search
- [ ] Artifact storage: files, images, code with content-hash-based LLM analysis caching
- [ ] GPU batch embedding via ROCm (7900XT): queue + batch for 10-50x throughput
- [ ] Agentic retrieval: LLM decides what to search based on query decomposition
- [ ] Re-ranking: top-50 candidates → cross-encoder re-rank to top-10
- [ ] Matryoshka dimension truncation for speed vs precision tradeoff
- [ ] Periodic backups with configurable retention

### Core
- [ ] Auto-project detection from conversation content
- [ ] Multi-round tool loop with proper message history threading (currently breaks after tool round on some edge cases)
- [ ] Proper CLI adapter tool confirmation flow (currently web-only auto-approve)
- [ ] Rate limiting and token budget enforcement per session/project

## Completed

### Original 13 Phases
- [x] Internal API refactor — engine decoupled from transport
- [x] SQLite core storage — 6 migrations, WAL mode, FTS5, per-thread connections
- [x] Streaming (SSE) — real-time text deltas, tool_use/tool_result events
- [x] Projects + rolling context — auto-updated per prompt, context injection
- [x] Tool confirmation flow — adapter-agnostic confirm callback, anti-hallucination
- [x] Prompt assembler — 6 composable layers, constraint/template injection
- [x] Adapter system — formal interface, CLI + Web adapters, DB registry
- [x] Summarization engine — haiku-powered session summaries + rolling context
- [x] Knowledge extraction — confidence lifecycle (reinforce/contradict/decay)
- [x] Embeddings + hybrid search — SIMD vector math, binary+FP32 dual storage, RRF
- [x] Background workers — 3-thread pool with typed queues, per-thread DB connections
- [x] Provider abstraction — Anthropic/OpenAI/Ollama, configurable tier mapping
- [x] Self-extension — LLM generates tools, sandbox testing, approve/revoke lifecycle

### Session Fixes
- [x] Per-request arena allocator (no more memory leaks)
- [x] Dynamic toJson buffer (no more overflow crashes)
- [x] Session resume across web requests (resumeLatestSession)
- [x] Tool call text accumulation across rounds (text preamble no longer lost)
- [x] Web adapter auto-approve for tools (all adapters have tool access)
- [x] Messages API endpoint for session history persistence
- [x] Tools API endpoint for live tool list

### Infrastructure
- [x] OAuth + API key authentication
- [x] Auth profile management
- [x] Smart model routing (haiku/sonnet/opus with auto mode)
- [x] Config-driven everything (providers, tiers, compaction, tools)
- [x] restart.sh convenience script
