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

## Planned

### Skills System
- [ ] "How to create a tool" skill — guides the model through ToolGenerator workflow
- [ ] Model auto-selects applicable skills based on user request (prompt-injection side)

### Tool Ecosystem
- [ ] Tool generator UI: describe capability → LLM generates → sandbox test → approve
      (backend generator exists in `src/tools/generator.zig` — missing the guided web flow)
- [ ] Tool marketplace concept: shareable tool definitions between ClawForge instances
- [ ] Tool analytics dashboard (usage counts + success rates already tracked via
      `introspect` + `auth_profiles.usage_stats`, but no surfaced UI)

### Adapters
- [ ] Discord adapter sub-features: reaction-based tool confirmation, StreamEmitter →
      edit messages with deltas, react emojis for tool status. Base bot gateway +
      guild/channel isolation already live via `bridges/discord_bridge.py`.
- [ ] HTTP API adapter: stateless request/response for external integrations
      (web adapter doubles as REST but there's no purpose-built stateless adapter)
- [ ] Per-adapter enable flags in config (only `discord.enabled` exists today)

### Storage & Search
- [ ] GPU batch embedding via ROCm (7900XT): queue + batch for 10-50x throughput
- [ ] Agentic retrieval: LLM decides what to search based on query decomposition
- [ ] Re-ranking: top-50 candidates → cross-encoder re-rank to top-10
- [ ] Matryoshka dimension truncation for speed vs precision tradeoff
- [ ] Periodic backups with configurable retention

### OpenRouter / Multi-Provider
- [x] **OpenAI-compatible streaming**: `createMessageStreaming` on `OpenAIClient`
      parses OpenAI SSE format (text deltas + tool call chunks by index).
      OpenRouter and OpenAI stream in real time. Ollama still falls back
      to non-streaming (needs its own impl for `num_ctx` injection).
- [x] **OpenRouter prompt caching**: `X-Title: ClawForge` + `HTTP-Referer` headers
      sent on all requests. Cache stats (`cache_read_input_tokens`,
      `cache_creation_input_tokens`, `prompt_tokens_details.cached_tokens`)
      parsed from both streaming and non-streaming responses. Surfaced in
      web UI token footer (green "cached", amber "cache write") and SSE done events.
- [x] **OpenRouter model costs in web UI**: live fetch from `/api/v1/models` with
      pricing (`pricing.prompt`, `pricing.completion`). Models returned as objects
      with `input_cost`/`output_cost` strings. Dropdown shows `($in/$out)` per M
      tokens next to each model name. Replaces static model list — new models
      appear automatically.

### Core
- [ ] Auto-project detection from conversation content (manual `createProject` exists,
      the semantic-detection hook in `engine.zig` is still a stub)
- [ ] Rate limiting and token budget enforcement per session/project
      (token budgets are computed in `prompt.zig` for compaction but not enforced as a
      hard cap per session/project)
- [ ] **UTF-8 scrubbing across all providers.** The Anthropic path now routes every
      outgoing string through `messages.appendJsonEscaped` (UTF-8 validate → replace
      invalid bytes, truncated sequences, overlong forms, and lone surrogates with
      U+FFFD) so a single poisoned byte in session history can't 400 every turn
      forever. `openai_provider.zig` and `ollama_provider.zig` still use their own
      `writeEscaped` helpers that only handle basic character escapes and will hit
      the same bug the moment a poisoned session is replayed through them. Fix by
      making them call the shared helper — ideally move `appendJsonEscaped` to a
      common utility module (e.g. `src/common/json_escape.zig`) so `api/messages.zig`,
      `api/anthropic.zig`, `api/openai_provider.zig`, and `api/ollama_provider.zig`
      all share one chokepoint. Also worth auditing any other hand-built JSON
      emitters (web adapter SSE, tool result serialization) for the same class of
      bug. Root cause is usually emoji from Discord or vision-model output that
      landed in the DB with a lone-surrogate byte pattern.

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

### Web UI Polish
- [x] Tool management: search + add/remove + runtime enable/disable via `/api/tools`
- [x] Config panel: model selector, persona editor, system prompt textarea
- [x] Session naming: rename via `renameSession()` (`src/storage/sessions.zig`)
- [x] Message search within session: FTS5-backed `message_search` mode in `introspect` tool

### Skills System (core)
- [x] Skill struct + `skills` table with FTS triggers (`src/storage/migrations.zig`, `skills.zig`)
- [x] SkillStore CRUD + skill management panel in web UI (add / toggle / delete)
- [x] Reusable instruction templates the system can follow for complex multi-step tasks

### Tool Ecosystem (partial)
- [x] Runtime tool enable/disable API (`POST /api/tools/:name/enable|disable`)
- [x] Tool generator backend (`src/tools/generator.zig`) — LLM generates → sandbox test → approve lifecycle

### Adapters (base)
- [x] Discord adapter: bot gateway, guild/channel isolation, slash commands,
      session-per-channel, `bridges/discord_bridge.py` + adapter registration
- [x] Image attachments: main-model image blocks + vision-pipeline text supplement
- [x] Vision pipeline: Haiku description cache keyed on image SHA-256

### Multi-Provider Swap (Phase 1)
- [x] `resolveProviderForModel()` on Engine — parses `provider:model` prefix,
      looks up in `ProviderRegistry`, strips prefix, falls back to default
      provider for bare names
- [x] Tool loop call sites use the resolved provider per turn (logs provider
      switch when it deviates from the default)
- [x] OpenAI provider full rewrite: per-request arena, dynamic ArrayList body
      buffer, OpenAI content-blocks format (system + history with text/image/
      tool_use/tool_result), tools array, response parser fills
      `MessageResponse.tool_use`, UTF-8 safe via shared escaper. Streaming
      still TODO (falls back to non-streaming).
- [x] Ollama provider: thin wrapper targeting `{base_url}/v1/chat/completions`
      that reuses the OpenAI-compat builder/parser — gives Qwen 3, Llama 3.x,
      and other tool-capable local models the full tool loop for free
- [x] `OllamaConfig.num_ctx` (default 16384) threaded through as
      `options.num_ctx` on every request so Ollama doesn't silently truncate
      to its tiny default window
- [x] `GET /api/models` endpoint — Anthropic + OpenAI static lists, Ollama
      queried live via `/api/tags`. Every model string is pre-prefixed with
      `provider:` so clients can echo it back as a `model_override`
- [x] Discord `/model` slash command: free-form string with live autocomplete
      from `/api/models`, `reset` to clear, 128-char cap
- [x] Fetched `qwen3:4b` (2.3 GB) and `qwen3:30b` (17.3 GB) for local testing
      via Ollama HTTP `/api/pull`

### Storage & Search
- [x] Artifact storage: `artifacts` table + `ArtifactStore` with content-hash-based
      LLM analysis caching (used by the vision pipeline)

### Core
- [x] Multi-round tool loop with proper message history threading (20-round loop stable)
- [x] CLI adapter tool confirmation flow (`cli_adapter.zig` confirmTool)
- [x] UTF-8-safe JSON escaper for the Anthropic path (shared
      `messages.appendJsonEscaped` used by both `toJson` and `describeImage`)
