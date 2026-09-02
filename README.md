# ClawForge

A multi-interface LLM agent daemon written in Zig with a Python Discord bridge.
One daemon, multiple front-ends (CLI, web UI, Discord), a shared SQLite
workspace, and a pluggable tool registry — all orchestrated by a dispatcher
that can spawn explore/execute subagents on worker threads.

## What it's for

ClawForge is the scaffolding you put between a language model and the
places you actually use it. Instead of each interface (terminal, browser,
chat app) reinventing history, prompts, tools, and context, they all
talk to one daemon that handles:

- **Persistent sessions** across interfaces — start a thread in Discord,
  continue it in the web UI, query it from the CLI.
- **Multi-provider routing** — Anthropic, OpenAI, OpenRouter, Ollama, and
  any local llama.cpp server are first-class; the routing config picks
  a model tier (fast/default/smart) per request.
- **A shared tool registry** — file I/O, bash, SQLite introspection,
  web research, calculators, Amazon search, meme generation, and
  user-defined tools registered at runtime.
- **Explore/execute subagent pattern** — a dispatcher model decides when
  to delegate. Explore subagents run on worker threads, cache their
  results (content-hashed) in SQLite, and auto-chain their output back
  into the main conversation via a synthetic continuation message.
- **A durable knowledge base** — messages, summaries, tool calls, and
  distilled facts all land in a single `workspace.db` that any adapter
  can query.

## Features at a glance

- **Zig daemon** (`clawforged`) hosting the core engine, tool registry,
  storage layer, worker pool, and HTTP/web UI.
- **Web UI** at `http://127.0.0.1:8081` — streaming responses, per-session
  token tracking, lazy-loaded message history (cursor-paginated),
  configurable personas, image uploads with optional vision calls.
- **Discord bridge** (`bridges/discord_bridge.py`) — mentions the bot,
  autofills context, forwards to the daemon over a unix socket.
- **CLI adapter** — quick one-shot queries without starting the web UI.
- **SQLite workspace DB** with FTS5 + optional Ollama embeddings for
  hybrid keyword/semantic search over everything the agent has ever seen.
- **Explore cache** — repeat explore calls on the same files skip the
  model entirely (keyed by content hash, auto-invalidated on edit).

## Requirements

- **Zig 0.15+** (tracks current `master`; build breakages across Zig
  versions are expected).
- **Python 3.11+** with a venv containing:
  `playwright` (for browser-based tools),
  `discord.py` (for the Discord bridge),
  `requests`, `urllib3`.
- **SQLite 3.38+** (for `JSONB` and FTS5).
- **Optional:** Ollama (for local models + embeddings), a llama.cpp
  server (for local Anthropic-style APIs), ROCm/CUDA for GPU inference.

## Install

```bash
git clone https://github.com/Garward/ClawForge.git
cd ClawForge
zig build
```

The binary lands at `zig-out/bin/clawforged`.

## Configure

Copy the env template and fill in the paths/secrets you use:

```bash
cp .env.example .env
$EDITOR .env
```

Minimum you need for a useful setup:

```bash
# tools/*.py live here, shebangs use /usr/bin/env python3, so supply
# a venv with playwright, requests, etc.
CLAWFORGE_PYTHON=/path/to/venv/bin/python3

# One or more API keys (at least one provider):
OPENROUTER_API_KEY=sk-or-...
# or put your Anthropic key in config.api.token_file (default: data/anthropic-token.txt)

# Optional: Discord bot
DISCORD_TOKEN=...
```

Everything path-related (`CLAWFORGE_ROOT`, `CLAWFORGE_DB`,
`CLAWFORGE_PYTHON`, etc.) has a sensible default — see `.env.example`
for the full list. The daemon derives its root from the binary's
location, so running `./zig-out/bin/clawforged` from the repo root
works without any path env vars.

Tune `config/config.json` for model preferences, routing tiers, and
per-provider options (Ollama base URL, OpenRouter model, vision model,
context window size, etc.).

## Run

```bash
./restart.sh           # kill any running daemon + socket, start fresh
./restart.sh build     # zig build, then start
./restart.sh clean     # wipe sessions/messages from the DB, then start
```

Then:

- Web UI:  `http://127.0.0.1:8081`
- Discord: runs automatically if `discord.enabled=true` in the config
  and `DISCORD_TOKEN` is set in `.env`.
- CLI:     `./zig-out/bin/clawforge "your prompt"` (if built)

## Keep development separate from active use

The Git checkout is the development tree. Deploy a tested build to a separate
active directory so source updates and build experiments cannot disturb the
running instance:

```bash
./scripts/deploy.sh --build
../runtime/restart.sh
```

The recommended source workspace has two clearly named directories:

```text
ClawForge/
├── repo/       # Git checkout, builds, and release work
└── runtime/    # Active config, secrets, database, tools, and binaries
```

The default active directory is `../runtime`. Set
`CLAWFORGE_RUNTIME_ROOT` to put it elsewhere. Deployments update application
files while preserving `.env`, `data/`, custom personas, and runtime config.
The deployed rebuild helper builds in the source checkout and only replaces
the active application after a successful build.

## Release archives

Build a versioned Linux x86_64 archive and checksum with:

```bash
./scripts/build-release.sh
```

Archives land in `dist/`. A release can be installed without root access on
most x86_64 Linux systems, including WSL:

```bash
unzip clawforge-0.2.1-linux-x86_64.zip
cd clawforge-0.2.1-linux-x86_64
./install.sh
```

The installer uses `${XDG_DATA_HOME:-$HOME/.local/share}/clawforge`, preserves
existing configuration and data during upgrades, creates a Python virtual
environment, and adds launchers under `~/.local/bin`. Pushing a `v*` tag runs
the same packaging script and attaches the zip and SHA-256 checksum to a
GitHub release.

Future upgrades are one command:

```bash
clawforge-update
```

The updater verifies the release checksum, preserves all runtime state, and
restarts ClawForge only when it was already running.

On startup, ClawForge also seeds a native `ClawForge operations` skill into the
workspace database. It answers questions about runtime architecture, safe
updates, configuration, data locations, backups, and troubleshooting. Existing
user-created skills are preserved.

## Repository layout

```
src/
├── adapters/          # CLI, web (HTTP/WS), Discord interface layers
├── api/               # Provider clients (Anthropic, OpenAI, Ollama, etc.)
├── common/            # Config loading, shared types, path helpers
├── core/              # Engine, prompt assembly, dispatcher/subagent logic
├── daemon/            # Process lifecycle, signal handling
├── storage/           # SQLite schema, migrations, session store
├── tools/             # Built-in tool definitions (bash, file_*, introspect…)
└── workers/           # Background thread pool for subagent chat jobs

bridges/
└── discord_bridge.py  # Standalone Discord client, talks to daemon via socket

tools/                 # Python tool scripts invoked by Zig tool wrappers
config/                # config.json + personas/
docs/                  # architecture.md, schema docs, design notes
scripts/               # deployment, release packaging, and installation
```

## Documentation

- **Architecture:** `docs/architecture.md` — full system diagram, adapter
  contract, subagent flow, context engine.
- **Storage schema:** `docs/storage_schema.sql` — every table with
  commentary on the workspace DB layout.
- **TurboQuant notes:** `docs/turboquant_paper.md` — local
  quantization/inference experiments.

## License

MIT — see [`LICENSE`](LICENSE). Use it, fork it, embed it, sell it;
just keep the copyright notice.
