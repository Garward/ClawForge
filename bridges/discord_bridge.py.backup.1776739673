"""
ClawForge Discord Bridge

Thin transport layer: discord.py handles the Gateway WebSocket,
this script forwards messages to ClawForge's HTTP API and relays responses.

Two-tier pattern:
  1. Quick ack via Haiku (no tools, ~2s) — posted immediately on @mention
  2. Background worker (full model + tools) — posted when done

Slash commands provide management surfaces (personas, tools, sessions, etc.).

Token resolution (first match wins):
  1. --token CLI argument
  2. DISCORD_TOKEN environment variable
  3. ClawForge/.env DISCORD_TOKEN

Requires: discord.py>=2.3, aiohttp>=3.9
"""

import json
import os
import re
import sys
import asyncio
import logging
import argparse
from pathlib import Path
from typing import Optional

import discord
from discord import app_commands
import aiohttp

try:
    from PIL import Image
    _PIL_AVAILABLE = True
except ImportError:
    _PIL_AVAILABLE = False

log = logging.getLogger("clawforge-discord")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)

# Strip hallucinated tool-call XML the model may emit in dispatcher mode.
# Handles closed blocks plus dangling open blocks (model truncated mid-call).
_FUNCTION_CALLS_CLOSED = re.compile(r"<function_calls>.*?</function_calls>", re.DOTALL)
_FUNCTION_CALLS_OPEN = re.compile(r"<function_calls>.*\Z", re.DOTALL)
_INVOKE_BLOCK = re.compile(r"<invoke[^>]*>.*?</invoke>", re.DOTALL)
_PARAMETER_BLOCK = re.compile(r"<parameter[^>]*>.*?</parameter>", re.DOTALL)


_TOOL_OUTPUT_URLS = re.compile(
    r'<tool_call\s+name="(\w+)"[^>]*>.*?<output[^>]*>(.*?)</output>',
    re.DOTALL,
)
_IMAGE_URL = re.compile(r'(https?://[^\s<>"]+\.(?:png|jpg|jpeg|gif|webp)[^\s<>"]*)', re.IGNORECASE)


def extract_media_urls(text: str) -> list[str]:
    """Pull image URLs out of tool_call output blocks before they get stripped."""
    urls = []
    for match in _TOOL_OUTPUT_URLS.finditer(text):
        output = match.group(2)
        for url_match in _IMAGE_URL.finditer(output):
            urls.append(url_match.group(1))
    return urls


def strip_tool_calls(text: str) -> str:
    """Remove any tool-call XML the model emitted as text. Returns cleaned text."""
    if not text:
        return text
    text = _FUNCTION_CALLS_CLOSED.sub("", text)
    text = _FUNCTION_CALLS_OPEN.sub("", text)
    text = _INVOKE_BLOCK.sub("", text)
    text = _PARAMETER_BLOCK.sub("", text)
    # Collapse runs of >2 blank lines that the stripping may leave behind
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()

FAST_MODEL = "claude-haiku-4-5-20251001"

# Dispatcher toolset — middle path between "answer inline" and "delegate everything".
# Read-only + single-file edits run inline for snappy UX. summon_subagent is reserved
# for heavy work (multi-file changes, builds, long investigations).
DISPATCHER_TOOLS = [
    "plan",
    "summon_subagent",
    "bash",
    "file_read",
    "file_diff",
    "introspect",
    "calc",
    "research",
    "meme_tool",
    "amazon_search",
]

DISPATCHER_CONTEXT = (
    "You are the Discord dispatcher for ClawForge. Never emit <function_calls>, "
    "<invoke>, or any XML tool-call markup as text.\n"
    "\n"
    "You have THREE modes. Default to the lowest one that fits.\n"
    "\n"
    "QUICK MODE — no tools, just answer:\n"
    "- Casual chat, conceptual explanations, answering from conversation history.\n"
    "\n"
    "INLINE TOOL MODE — call tools yourself, answer in one turn:\n"
    "Use when the work is small enough to finish in ≤3 tool rounds:\n"
    "- Read/show/list/search: file_read, bash (ls, grep, find, cat, git log/status/diff), introspect.\n"
    "- Single-file edits: file_diff. ONE file, a focused change, no build step needed.\n"
    "- Math: calc. Web lookup: research. Meme: meme_tool. Shopping: amazon_search.\n"
    "No plan required for inline mode. Just call the tool and reply.\n"
    "\n"
    "DELEGATE MODE — summon_subagent:\n"
    "Use ONLY when ALL of these are likely true:\n"
    "  (a) work touches 2+ files OR runs a build/test OR does destructive shell work,\n"
    "  (b) you'd need more than ~3 tool rounds to finish it inline,\n"
    "  (c) it's safe to run in the background (user doesn't need an interactive reply).\n"
    "\n"
    "summon_subagent has TWO modes — use them together:\n"
    "\n"
    "  STEP A — mode='explore' (read-only research, ASYNC with auto-chain):\n"
    "  When you need to understand code you haven't read, spawn an explore subagent.\n"
    "  It returns a structured 3-layer JSON brief (executive map + structured facts +\n"
    "  pinned evidence). It only needs a 'task' field (the question) and optional\n"
    "  'target_files' as hint paths. Explore bypasses the plan gate.\n"
    "\n"
    "  HOW THE EXPLORE FLOW WORKS NOW (default: chain=true, wait=false):\n"
    "    1. You call summon_subagent(mode='explore', ...). The tool returns a brief\n"
    "       'dispatched' ack. You reply with ONE short sentence acknowledging the work\n"
    "       (e.g. 'Sending a probe out — be right back.'). Your reply goes to the user.\n"
    "    2. The subagent runs on a worker thread. When it finishes, a dispatcher\n"
    "       CONTINUATION TURN is automatically started on the worker — THAT turn is\n"
    "       YOU again, running with the brief injected as a synthetic user message.\n"
    "    3. In the continuation turn you'll see '[EXPLORE SUBAGENT RESULT]' at the\n"
    "       top of the user message, followed by the 3-layer brief. Use it to either\n"
    "       auto-summon execute, or summarize findings for the user and ask.\n"
    "    4. Your continuation reply is what the user actually sees as the final\n"
    "       message. So keep step 1's ack SHORT and let the real content land in the\n"
    "       continuation.\n"
    "\n"
    "  OVERRIDES:\n"
    "    - wait=true: block the tool call, see the brief in-turn, chain inline.\n"
    "      Useful if you prefer one synchronous turn over two async ones.\n"
    "    - chain=false: disable auto-continuation. The raw JSON brief becomes the\n"
    "      user-facing message. Rarely what you want.\n"
    "\n"
    "  STEP B — mode='execute' (default, the worker that changes things):\n"
    "  Take the explore brief's layer2_facts + layer3_evidence and drop them into\n"
    "  known_facts. Take the paths from layer1_map and use them as target_files.\n"
    "  Add task + acceptance + constraints. The execute subagent does the real work.\n"
    "  execute defaults to wait=false — the user receives the result asynchronously.\n"
    "\n"
    "  PAUSE FOR APPROVAL:\n"
    "  When the user said things like 'just explore first', 'show me the plan before\n"
    "  you touch anything', or 'explore only', in the CONTINUATION TURN you should\n"
    "  summarize the brief plainly and ask for their green-light — do NOT auto-summon\n"
    "  execute. When they approve next turn, summon execute with the same brief\n"
    "  facts (you have them in the prior continuation's history).\n"
    "\n"
    "The explore→execute pattern is the preferred flow for anything non-trivial.\n"
    "Skipping the explore step is fine ONLY when you've already done the recon\n"
    "yourself inline (file_read, bash grep) and have the facts at hand.\n"
    "\n"
    "A subagent sees NONE of this Discord conversation — only the brief you send.\n"
    "Empty or vague briefs are the #1 cause of failure. Execute-mode requires\n"
    "task + target_files + acceptance; the schema will reject a bare task string.\n"
    "\n"
    "Other brief fields:\n"
    "  - context: the user's actual words — the subagent needs to know why\n"
    "  - constraints / out_of_scope: things not to touch, to prevent drift\n"
    "\n"
    "After summon_subagent: reply with ONE short sentence acknowledging the work.\n"
    "Do NOT narrate fake progress. The user sees subagent results automatically.\n"
    "\n"
    "CRITICAL: default to the lowest mode that works. A single-file edit goes through\n"
    "file_diff inline, NOT through a subagent. Only escalate when inline would be\n"
    "painful or unsafe."
)

ALL_TOOLS = [
    "file_read", "file_diff", "file_write", "bash", "rebuild",
    "zig_test", "calc", "introspect", "research_tool", "amazon_search", "meme_tool",
]

DEFAULT_ENABLED_TOOLS = {
    "file_read", "file_diff", "file_write", "bash",
    "calc", "introspect", "zig_test", "rebuild",
    "meme_tool", "amazon_search", "summon_subagent",
}

class ToolConfirmView(discord.ui.View):
    """Discord button view for approving/denying tool execution."""

    def __init__(self, http_session: aiohttp.ClientSession, clawforge_url: str,
                 job_id: str, tool_id: str, tool_name: str):
        super().__init__(timeout=60)
        self.http_session = http_session
        self.clawforge_url = clawforge_url
        self.job_id = job_id
        self.tool_id = tool_id
        self.tool_name = tool_name
        self.resolved = False

    async def _resolve(self, interaction: discord.Interaction, approved: bool):
        if self.resolved:
            await interaction.response.send_message("Already resolved.", ephemeral=True)
            return
        self.resolved = True
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/background/confirm",
                json={"job_id": self.job_id, "tool_id": self.tool_id, "approved": approved},
            ) as resp:
                if resp.status != 200:
                    log.warning("Confirm POST failed: %s", await resp.text())
        except Exception as e:
            log.error("Confirm error: %s", e)

        label = "Approved" if approved else "Denied"
        for child in self.children:
            child.disabled = True
        await interaction.response.edit_message(
            content=f"**{self.tool_name}** — {label}", view=self
        )
        self.stop()

    @discord.ui.button(label="Approve", style=discord.ButtonStyle.green)
    async def approve(self, interaction: discord.Interaction, button: discord.ui.Button):
        await self._resolve(interaction, True)

    @discord.ui.button(label="Deny", style=discord.ButtonStyle.red)
    async def deny(self, interaction: discord.Interaction, button: discord.ui.Button):
        await self._resolve(interaction, False)

    async def on_timeout(self):
        if not self.resolved:
            self.resolved = True
            try:
                async with self.http_session.post(
                    f"{self.clawforge_url}/api/background/confirm",
                    json={"job_id": self.job_id, "tool_id": self.tool_id, "approved": False},
                ) as resp:
                    pass
            except Exception:
                pass


STATE_FILE = Path(__file__).resolve().parent.parent / "data" / "discord_bridge_state.json"


class ClawForgeBridge(discord.Client):
    def __init__(self, clawforge_url: str, guild_id: Optional[str] = None, **kwargs):
        super().__init__(**kwargs)
        self.clawforge_url = clawforge_url.rstrip("/")
        self.guild_id = guild_id
        self.http_session: Optional[aiohttp.ClientSession] = None
        self.channel_sessions: dict[str, str] = {}
        self.channel_models: dict[str, str] = {}
        self.channel_jobs: dict[str, str] = {}  # channel_id -> active background job_id (NOT persisted)
        self.channel_respond_all: dict[str, bool] = {}  # channel_id -> respond to every message
        self.enabled_tools: set[str] = set(DEFAULT_ENABLED_TOOLS)
        self.known_guild_ids: set[str] = set()  # auto-detected guild IDs
        self.tree = app_commands.CommandTree(self)
        self.load_state()

    def load_state(self) -> None:
        if not STATE_FILE.is_file():
            return
        try:
            data = json.loads(STATE_FILE.read_text())
        except Exception as e:
            log.warning("Failed to load bridge state: %s", e)
            return

        self.channel_sessions = dict(data.get("channel_sessions", {}))
        self.channel_models = dict(data.get("channel_models", {}))
        self.channel_respond_all = {k: bool(v) for k, v in data.get("channel_respond_all", {}).items()}
        tools = data.get("enabled_tools")
        if isinstance(tools, list):
            self.enabled_tools = set(tools)
        guilds = data.get("known_guild_ids")
        if isinstance(guilds, list):
            self.known_guild_ids = set(guilds)
            # Use first known guild as fallback if no explicit guild_id configured
            if not self.guild_id and self.known_guild_ids:
                self.guild_id = next(iter(self.known_guild_ids))
                log.info("Auto-detected guild_id from state: %s", self.guild_id)
        log.info(
            "Loaded bridge state: %d channels, %d models, %d tools enabled, %d guilds",
            len(self.channel_sessions),
            len(self.channel_models),
            len(self.enabled_tools),
            len(self.known_guild_ids),
        )

    def save_state(self) -> None:
        try:
            STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "channel_sessions": self.channel_sessions,
                "channel_models": self.channel_models,
                "channel_respond_all": self.channel_respond_all,
                "enabled_tools": sorted(self.enabled_tools),
                "known_guild_ids": sorted(self.known_guild_ids),
            }
            tmp = STATE_FILE.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(payload, indent=2))
            tmp.replace(STATE_FILE)
        except Exception as e:
            log.warning("Failed to save bridge state: %s", e)

    async def validate_persisted_sessions(self) -> None:
        """Drop cached channel→session mappings whose session no longer exists."""
        if not self.channel_sessions:
            return
        sessions = await self.fetch_sessions()
        valid_ids = {s.get("id") for s in sessions}
        dropped = [
            cid for cid, sid in self.channel_sessions.items() if sid not in valid_ids
        ]
        for cid in dropped:
            log.info("Dropping stale session for channel %s", cid)
            self.channel_sessions.pop(cid, None)
        if dropped:
            self.save_state()

    async def setup_hook(self):
        # Dispatcher now runs inline tools (file_read, file_diff, bash, introspect)
        # before deciding whether to delegate, so the /api/chat round-trip can take
        # longer than the old 120s budget. 300s covers a dispatcher that does a few
        # rounds of recon + a small edit before handing off (or completing inline).
        self.http_session = aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=300)
        )
        await self.validate_persisted_sessions()
        register_commands(self)

        # Sync slash commands to known guilds (instant).
        # We avoid global sync entirely — it causes duplicate commands in
        # guilds that also have guild-specific commands. New guilds get
        # commands synced on first interaction via _maybe_learn_guild().
        synced_guilds = set()
        for gid in self.known_guild_ids:
            try:
                guild = discord.Object(id=int(gid))
                self.tree.copy_global_to(guild=guild)
                synced = await self.tree.sync(guild=guild)
                synced_guilds.add(gid)
                log.info("Synced %d slash commands to guild %s (instant)", len(synced), gid)
            except Exception as e:
                log.error("Guild sync failed for %s: %s", gid, e)

        if self.guild_id and self.guild_id not in synced_guilds:
            try:
                guild = discord.Object(id=int(self.guild_id))
                self.tree.copy_global_to(guild=guild)
                synced = await self.tree.sync(guild=guild)
                log.info("Synced %d slash commands to guild %s (instant)", len(synced), self.guild_id)
            except Exception as e:
                log.error("Guild sync failed for %s: %s", self.guild_id, e)

        # Clear stale global commands that cause duplicates
        if self.known_guild_ids or self.guild_id:
            try:
                self.tree.clear_commands(guild=None)
                await self.tree.sync()
                log.info("Cleared global slash commands (guild-only mode)")
            except Exception as e:
                log.error("Failed to clear global commands: %s", e)

    async def close(self):
        if self.http_session:
            await self.http_session.close()
        await super().close()

    # -- ClawForge API helpers --

    async def ensure_session(self, channel_id: str, channel_name: str) -> Optional[str]:
        if channel_id in self.channel_sessions:
            return self.channel_sessions[channel_id]

        session_id = await self._create_session(f"discord-{channel_name}")
        if session_id:
            self.channel_sessions[channel_id] = session_id
            self.save_state()
        return session_id

    async def _create_session(self, name: str) -> Optional[str]:
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/sessions/new",
                json={"name": name},
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return data.get("id")
                log.warning("Session create failed: %s", await resp.text())
        except Exception as e:
            log.error("Session create error: %s", e)
        return None

    async def fetch_sessions(self) -> list[dict]:
        try:
            async with self.http_session.get(f"{self.clawforge_url}/api/sessions") as resp:
                if resp.status == 200:
                    return await resp.json()
        except Exception as e:
            log.error("Fetch sessions error: %s", e)
        return []

    async def fetch_personas(self, session_id: Optional[str] = None) -> dict:
        url = f"{self.clawforge_url}/api/persona"
        if session_id:
            url += f"?session_id={session_id}"
        try:
            async with self.http_session.get(url) as resp:
                if resp.status == 200:
                    return await resp.json()
        except Exception as e:
            log.error("Fetch personas error: %s", e)
        return {"active": "default", "personas": []}

    async def set_persona(self, session_id: str, name: str) -> bool:
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/persona",
                json={"action": "select", "name": name, "session_id": session_id},
            ) as resp:
                return resp.status == 200
        except Exception as e:
            log.error("Set persona error: %s", e)
            return False

    async def create_persona(self, name: str, content: str) -> bool:
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/persona",
                json={"action": "create", "name": name, "content": content},
            ) as resp:
                return resp.status == 200
        except Exception as e:
            log.error("Create persona error: %s", e)
            return False

    async def delete_persona(self, name: str) -> bool:
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/persona",
                json={"action": "delete", "name": name},
            ) as resp:
                return resp.status == 200
        except Exception as e:
            log.error("Delete persona error: %s", e)
            return False

    async def fetch_auto_approve(self) -> Optional[bool]:
        try:
            async with self.http_session.get(
                f"{self.clawforge_url}/api/tools/autoapprove"
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return bool(data.get("enabled", False))
        except Exception as e:
            log.error("Fetch auto-approve error: %s", e)
        return None

    async def set_auto_approve(self, enabled: bool) -> bool:
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/tools/autoapprove",
                json={"enabled": enabled},
            ) as resp:
                return resp.status == 200
        except Exception as e:
            log.error("Set auto-approve error: %s", e)
            return False

    async def fetch_status(self) -> Optional[dict]:
        try:
            async with self.http_session.get(f"{self.clawforge_url}/api/status") as resp:
                if resp.status == 200:
                    return await resp.json()
        except Exception as e:
            log.error("Status error: %s", e)
        return None

    async def fetch_vision(self) -> Optional[dict]:
        try:
            async with self.http_session.get(f"{self.clawforge_url}/api/vision") as resp:
                if resp.status == 200:
                    return await resp.json()
                log.warning("Vision GET failed: %d %s", resp.status, await resp.text())
        except Exception as e:
            log.error("Vision GET error: %s", e)
        return None

    async def fetch_models(self) -> list[str]:
        """Query /api/models and return a flat list of `provider:model` strings
        across all enabled providers. Used for /model autocomplete."""
        try:
            async with self.http_session.get(f"{self.clawforge_url}/api/models") as resp:
                if resp.status != 200:
                    log.warning("Models GET failed: %d %s", resp.status, await resp.text())
                    return []
                data = await resp.json()
        except Exception as e:
            log.error("Models GET error: %s", e)
            return []

        # Curated model list per provider.
        # Models come as "provider:model" strings or objects with "id".
        # Only surface models we actually want in Discord autocomplete.
        allowed_ollama = {"ollama:qwen3:4b"}
        allowed_openrouter = {"openrouter:x-ai/grok-4.1-fast"}

        out: list[str] = []
        for prov in data.get("providers", []):
            provider_name = prov.get("name", "").lower()
            for m in prov.get("models", []):
                if not m:
                    continue
                # OpenRouter returns objects with "id" key
                model_id = m["id"] if isinstance(m, dict) and "id" in m else m
                if not isinstance(model_id, str):
                    continue

                if provider_name == "anthropic":
                    # All Anthropic models
                    out.append(model_id)
                elif provider_name == "ollama" and model_id in allowed_ollama:
                    out.append(model_id)
                elif provider_name == "openrouter" and model_id in allowed_openrouter:
                    out.append(model_id)
        return out

    async def set_vision_model(self, model: Optional[str]) -> bool:
        """Set (or clear) the runtime vision model override."""
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/vision",
                json={"model": model},
            ) as resp:
                if resp.status == 200:
                    return True
                log.warning("Vision POST failed: %d %s", resp.status, await resp.text())
        except Exception as e:
            log.error("Vision POST error: %s", e)
        return False

    async def cancel_job(self, job_id: str) -> bool:
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/background/cancel",
                json={"job_id": job_id},
            ) as resp:
                return resp.status == 200
        except Exception as e:
            log.error("Cancel error: %s", e)
            return False

    IMAGE_MIMES = {"image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"}
    IMAGE_EXT_TO_MIME = {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".gif": "image/gif",
        ".webp": "image/webp",
    }
    ATTACHMENT_DIR = Path("/tmp/clawforge_attachments")

    # Anthropic internally downscales images so the longest edge is ~1568px
    # before the model sees them. Anything larger is thrown away server-side,
    # so pre-resizing to this target gives identical OCR quality at a fraction
    # of the payload size and token cost. It also guarantees we stay under
    # their 8000px hard limit on either dimension.
    VISION_LONGEST_EDGE = 1568
    VISION_JPEG_QUALITY = 85

    async def download_image_attachments(
        self, attachments: list[discord.Attachment]
    ) -> list[dict]:
        """Download image attachments to /tmp and return [{path, mime, name}].

        Pipeline: Discord download → Pillow open (format sniff from magic
        bytes, not extension/content_type) → resize if longest edge > target
        → re-encode as JPEG. This normalizes everything to a known-good
        format and shrinks phone photos from ~4MB to ~200KB.
        """
        if not attachments:
            return []
        self.ATTACHMENT_DIR.mkdir(parents=True, exist_ok=True)
        out: list[dict] = []
        for att in attachments[:4]:  # hard cap at 4 per Discord message
            mime = (att.content_type or "").lower().split(";")[0].strip()
            if not mime:
                mime = self.IMAGE_EXT_TO_MIME.get(Path(att.filename).suffix.lower(), "")
            if mime not in self.IMAGE_MIMES:
                log.info("Skipping non-image attachment: %s (%s)", att.filename, mime or "?")
                continue
            safe_name = re.sub(r"[^a-zA-Z0-9._-]", "_", att.filename) or "image"
            raw_path = self.ATTACHMENT_DIR / f"{att.id}_{safe_name}"
            try:
                await att.save(raw_path)
            except Exception as e:
                log.warning("Failed to save %s: %s", att.filename, e)
                continue

            final_path, final_mime = await asyncio.to_thread(
                self._preprocess_image, raw_path
            )
            if final_path is None:
                log.warning("Skipping %s: preprocess failed", att.filename)
                continue

            out.append({
                "path": str(final_path),
                "mime": final_mime,
                "name": att.filename,
            })
        if out:
            log.info("Downloaded %d image attachment(s) for vision", len(out))
        return out

    def _preprocess_image(self, raw_path: Path) -> tuple[Optional[Path], str]:
        """Open with Pillow, resize if oversized, re-encode as JPEG.

        Returns (path, mime) on success, (None, "") on failure. Runs in a
        worker thread because Pillow is blocking.
        """
        if not _PIL_AVAILABLE:
            # Without Pillow we can't sniff or resize — fall back to raw bytes
            # with the extension-derived MIME. Accuracy not guaranteed.
            ext = raw_path.suffix.lower()
            return raw_path, self.IMAGE_EXT_TO_MIME.get(ext, "image/png")
        try:
            with Image.open(raw_path) as im:
                im.load()
                # Convert anything with alpha or palette to RGB for JPEG.
                if im.mode not in ("RGB", "L"):
                    im = im.convert("RGB")
                w, h = im.size
                longest = max(w, h)
                if longest > self.VISION_LONGEST_EDGE:
                    scale = self.VISION_LONGEST_EDGE / longest
                    new_size = (max(1, int(w * scale)), max(1, int(h * scale)))
                    im = im.resize(new_size, Image.LANCZOS)
                    log.info(
                        "Resized %s: %dx%d → %dx%d",
                        raw_path.name, w, h, new_size[0], new_size[1],
                    )
                out_path = raw_path.with_suffix(".vision.jpg")
                im.save(out_path, "JPEG", quality=self.VISION_JPEG_QUALITY, optimize=True)
            # Remove the raw download once we have the normalized copy.
            try:
                raw_path.unlink()
            except OSError:
                pass
            return out_path, "image/jpeg"
        except Exception as e:
            log.warning("Pillow preprocess failed for %s: %s", raw_path.name, e)
            return None, ""

    async def dispatcher_chat(
        self,
        message_text: str,
        session_id: Optional[str] = None,
        model_override: Optional[str] = None,
        attachments: Optional[list[dict]] = None,
    ) -> dict:
        """Dispatcher chat: fast model with summon_subagent as the only tool.

        Returns a dict with keys: text (str), spawned_jobs (list[str]), error (Optional[str]).
        The model decides whether to answer directly or call summon_subagent for real work.
        """
        payload = {
            "message": message_text,
            "model_override": model_override or FAST_MODEL,
            "allowed_tools": ",".join(DISPATCHER_TOOLS),
            "adapter_context": DISPATCHER_CONTEXT,
        }
        if session_id:
            payload["session_id"] = session_id
        if attachments:
            payload["attachments"] = attachments
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/chat",
                json=payload,
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    if data.get("ok"):
                        return {
                            "text": data.get("text", "") or "",
                            "spawned_jobs": data.get("spawned_jobs", []) or [],
                            "error": None,
                        }
                    return {"text": "", "spawned_jobs": [], "error": data.get("error", "ClawForge error")}
                return {"text": "", "spawned_jobs": [], "error": f"ClawForge HTTP {resp.status}"}
        except asyncio.TimeoutError:
            return {"text": "", "spawned_jobs": [], "error": "Request timed out."}
        except Exception as e:
            log.error("Dispatcher chat error: %s", e)
            return {"text": "", "spawned_jobs": [], "error": f"Bridge error: {e}"}

    async def spawn_background(
        self,
        message_text: str,
        session_id: Optional[str] = None,
        callback_channel: Optional[str] = None,
        model_override: Optional[str] = None,
    ) -> Optional[str]:
        """Enqueue a background job. Returns job_id."""
        payload = {"message": message_text}
        if session_id:
            payload["session_id"] = session_id
        if callback_channel:
            payload["callback_channel"] = callback_channel
        if model_override:
            payload["model_override"] = model_override
        if self.enabled_tools:
            payload["allowed_tools"] = ",".join(sorted(self.enabled_tools))
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/chat/background",
                json=payload,
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return data.get("job_id")
                log.warning("Background spawn failed: %s", await resp.text())
        except Exception as e:
            log.error("Background spawn error: %s", e)
        return None

    async def poll_background(self, job_id: str, cursor: int = 0) -> Optional[dict]:
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/background/status",
                json={"job_id": job_id, "cursor": cursor},
            ) as resp:
                if resp.status == 200:
                    return await resp.json()
        except Exception as e:
            log.error("Poll error: %s", e)
        return None

    # -- Discord event handlers --

    async def on_ready(self):
        log.info("Connected as %s (id: %s)", self.user, self.user.id)
        log.info("ClawForge API: %s", self.clawforge_url)
        # Learn all guilds the bot is currently in
        for guild in self.guilds:
            await self._maybe_learn_guild(guild)

    async def _maybe_learn_guild(self, guild: Optional[discord.Guild]) -> None:
        """Auto-detect guild ID on first interaction and re-sync slash commands."""
        if guild is None:
            return
        gid = str(guild.id)
        if gid in self.known_guild_ids:
            return

        log.info("Auto-detected new guild: %s (id: %s)", guild.name, gid)
        self.known_guild_ids.add(gid)

        # Use as primary guild_id if none configured
        if not self.guild_id:
            self.guild_id = gid

        # Sync slash commands to this guild for instant availability
        try:
            guild_obj = discord.Object(id=int(gid))
            self.tree.copy_global_to(guild=guild_obj)
            synced = await self.tree.sync(guild=guild_obj)
            log.info("Re-synced %d slash commands to guild %s (instant)", len(synced), gid)
        except Exception as e:
            log.error("Guild sync failed for %s: %s", gid, e)

        self.save_state()

    async def on_message(self, message: discord.Message):
        if message.author.bot:
            return

        # Auto-detect guild on first message
        await self._maybe_learn_guild(message.guild)

        channel_id = str(message.channel.id)
        respond_all = self.channel_respond_all.get(channel_id, False)
        mentioned = self.user.mentioned_in(message) and not message.mention_everyone

        if not respond_all and not mentioned:
            return

        content = message.content
        if mentioned:
            for mention in message.mentions:
                if mention == self.user:
                    content = content.replace(f"<@{mention.id}>", "")
                    content = content.replace(f"<@!{mention.id}>", "")
        content = content.strip()

        # Download image attachments to /tmp so the daemon can read them.
        # Skipped for text-only messages; non-images are ignored.
        downloaded_attachments: list[dict] = []
        if message.attachments:
            downloaded_attachments = await self.download_image_attachments(message.attachments)

        if not content and not downloaded_attachments:
            if mentioned:
                await message.reply("You mentioned me but didn't say anything.", mention_author=False)
            return

        if not content and downloaded_attachments:
            content = "(image attached — please describe and respond)"

        channel_name = getattr(message.channel, "name", channel_id)
        guild_name = message.guild.name if message.guild else "DM"
        username = message.author.display_name or message.author.name

        log.info("[%s/#%s] %s: %s", guild_name, channel_name, username, content[:80])

        # If a background job is already in flight for this channel, the
        # Haiku dispatcher has no way to check on it — it will hallucinate
        # progress ("still working", "the subagent returned X"). Short-circuit
        # and give the user a deterministic status message instead. The
        # existing poll_and_deliver task will post the real result.
        existing_job = self.channel_jobs.get(channel_id)
        if existing_job:
            await message.reply(
                f"Still working on the previous task (job `{existing_job[:8]}`). "
                "I'll post the result here as soon as it finishes — no need to "
                "ask me for status, I can't check on it mid-flight.",
                mention_author=False,
            )
            return

        session_id = await self.ensure_session(channel_id, channel_name)
        prefixed = f"[Discord user: {username}] {content}"
        dispatcher_model = self.channel_models.get(channel_id)

        async with message.channel.typing():
            result = await self.dispatcher_chat(
                prefixed,
                session_id,
                dispatcher_model,
                attachments=downloaded_attachments or None,
            )

        if result.get("error"):
            await message.reply(result["error"], mention_author=False)
            return

        spawned = result.get("spawned_jobs", []) or []
        raw_text = result.get("text", "")
        # Extract media URLs from tool outputs before stripping the XML
        media_urls = extract_media_urls(raw_text)
        cleaned = strip_tool_calls(raw_text)
        # Append any media URLs the model forgot to include in its text
        for url in media_urls:
            if url not in cleaned:
                cleaned = cleaned.rstrip() + "\n" + url if cleaned else url
        if spawned:
            # Prefer the dispatcher's actual generated text as the ack so each
            # spawn feels unique. Strip XML tool-call markup first (Haiku
            # sometimes emits <function_calls> blocks in its text channel).
            # Fall back to a canned string only if nothing real survived.
            if cleaned:
                await self.send_chunked(message, cleaned)
            else:
                await message.reply(
                    "On it — working on this in the background. I'll reply with the result.",
                    mention_author=False,
                )
        else:
            if cleaned:
                await self.send_chunked(message, cleaned)

        for job_id in spawned:
            self.channel_jobs[channel_id] = job_id
            log.info("Subagent job %s spawned for #%s", job_id[:8], channel_name)
            asyncio.create_task(self.poll_and_deliver(message, job_id, channel_id))

    async def poll_and_deliver(self, original: discord.Message, job_id: str, channel_id: str):
        """Poll until background job completes, then post result."""
        shown_confirmations: set[str] = set()
        event_cursor = 0
        # Track which tool events we've posted to avoid duplicates.
        # We batch events into a single progress message per poll cycle.
        progress_msg: Optional[discord.Message] = None
        progress_lines: list[str] = []
        # Poll every 3s for up to 20 minutes. Deep investigations routinely
        # run 5-10 min; the old 6-min cap silently killed long-running jobs.
        max_iterations = 400
        try:
            for _ in range(max_iterations):
                await asyncio.sleep(3)
                try:
                    result = await self.poll_background(job_id, cursor=event_cursor)
                except Exception as e:
                    log.error("poll_background raised for %s: %s", job_id[:8], e)
                    continue
                if not result:
                    continue

                # Render new tool events as a live progress embed
                tool_events = result.get("tool_events", [])
                if tool_events:
                    for evt in tool_events:
                        etype = evt.get("type", "?")
                        tool = evt.get("tool", "?")
                        content = evt.get("content", "")
                        is_error = evt.get("is_error", False)
                        if etype == "tool_use":
                            preview = content[:120] + "..." if len(content) > 120 else content
                            progress_lines.append(f"▶ `{tool}` {preview}")
                        else:
                            status_icon = "❌" if is_error else "✓"
                            preview = content[:100] + "..." if len(content) > 100 else content
                            progress_lines.append(f"  {status_icon} {preview}")

                    # Keep only last 15 lines to stay within Discord limits
                    if len(progress_lines) > 15:
                        progress_lines = progress_lines[-15:]

                    progress_text = (
                        f"**Subagent `{job_id[:8]}`** — working...\n"
                        + "\n".join(progress_lines)
                    )
                    try:
                        if progress_msg is None:
                            progress_msg = await original.channel.send(progress_text)
                        else:
                            await progress_msg.edit(content=progress_text)
                    except Exception as e:
                        log.warning("Failed to update progress message: %s", e)

                if result.get("cursor") is not None:
                    event_cursor = result["cursor"]

                status = result.get("status", "pending")

                if status == "pending":
                    conf = result.get("pending_confirmation")
                    if conf and conf["tool_id"] not in shown_confirmations:
                        shown_confirmations.add(conf["tool_id"])
                        preview = conf.get("input_preview", "")
                        if len(preview) > 500:
                            preview = preview[:500] + "..."
                        view = ToolConfirmView(
                            self.http_session, self.clawforge_url,
                            job_id, conf["tool_id"], conf["tool_name"],
                        )
                        await original.channel.send(
                            f"**Tool request: `{conf['tool_name']}`**\n```\n{preview}\n```",
                            view=view,
                        )
                    continue

                if status == "completed":
                    raw = result.get("text", "") or ""
                    media_urls = extract_media_urls(raw)
                    cleaned = strip_tool_calls(raw)
                    for url in media_urls:
                        if url not in cleaned:
                            cleaned = cleaned.rstrip() + "\n" + url if cleaned else url
                    if cleaned:
                        await self.send_chunked(original, cleaned)
                    elif raw.strip():
                        # Subagent returned only tool-call XML / structured content.
                        # Don't drop silently — show the user what actually happened.
                        log.warning(
                            "Subagent %s returned only tool-call content after stripping (raw=%d chars). Sending raw.",
                            job_id[:8], len(raw),
                        )
                        fallback = (
                            "Subagent finished but its final response was only tool-call "
                            "markup — no user-facing text. Raw output:\n```\n"
                            + raw[:1800]
                            + ("\n...(truncated)" if len(raw) > 1800 else "")
                            + "\n```"
                        )
                        await original.channel.send(fallback)
                    else:
                        log.warning("Subagent %s completed with empty text.", job_id[:8])
                        await original.channel.send(
                            "Subagent finished but returned no text at all. "
                            "Check the daemon log for details."
                        )
                elif status == "failed":
                    err = result.get("text", "Unknown error")
                    await original.channel.send(f"Background task failed: {err}")
                elif status == "cancelled":
                    await original.channel.send("Background task was cancelled.")

                # Mark progress message as done
                if progress_msg is not None:
                    final_status = "done" if status == "completed" else status
                    try:
                        final_text = (
                            f"**Subagent `{job_id[:8]}`** — {final_status}\n"
                            + "\n".join(progress_lines[-10:])
                        )
                        await progress_msg.edit(content=final_text)
                    except Exception:
                        pass
                return
            log.warning("Subagent %s timed out in poll loop after %d iterations.", job_id[:8], max_iterations)
            await original.channel.send("Background task timed out after 20 minutes.")
        except Exception as e:
            log.exception("poll_and_deliver crashed for %s: %s", job_id[:8], e)
            try:
                await original.channel.send(
                    f"Bridge error while waiting for subagent {job_id[:8]}: {e}"
                )
            except Exception:
                pass
        finally:
            if self.channel_jobs.get(channel_id) == job_id:
                self.channel_jobs.pop(channel_id, None)

    async def send_chunked(self, original: discord.Message, text: str):
        if len(text) <= 2000:
            await original.reply(text, mention_author=False)
            return

        chunks = []
        current = ""
        for line in text.split("\n"):
            if len(current) + len(line) + 1 <= 2000:
                current += line + "\n"
            else:
                if current:
                    chunks.append(current.rstrip())
                while len(line) > 2000:
                    chunks.append(line[:2000])
                    line = line[2000:]
                current = line + "\n"
        if current.strip():
            chunks.append(current.rstrip())

        if chunks:
            await original.reply(chunks[0], mention_author=False)
            for chunk in chunks[1:]:
                await original.channel.send(chunk)

    async def send_chunked_followup(self, interaction: discord.Interaction, text: str):
        if len(text) <= 2000:
            await interaction.followup.send(text)
            return
        chunks = []
        current = ""
        for line in text.split("\n"):
            if len(current) + len(line) + 1 <= 2000:
                current += line + "\n"
            else:
                if current:
                    chunks.append(current.rstrip())
                while len(line) > 2000:
                    chunks.append(line[:2000])
                    line = line[2000:]
                current = line + "\n"
        if current.strip():
            chunks.append(current.rstrip())
        for chunk in chunks:
            await interaction.followup.send(chunk)


# ---------------------------------------------------------------------------
# Slash command registration
# ---------------------------------------------------------------------------

def register_commands(bridge: ClawForgeBridge) -> None:
    tree = bridge.tree

    # ---- /help ----
    @tree.command(name="help", description="Show all ClawForge commands")
    async def cmd_help(interaction: discord.Interaction):
        embed = discord.Embed(
            title="ClawForge Bridge Commands",
            description="Mention me in any channel to chat. Use slash commands to manage state.",
            color=0x5865F2,
        )
        embed.add_field(
            name="Personas",
            value=(
                "`/persona [name]` — set persona for this channel (no name = view current)\n"
                "`/persona_create name content` — create a new persona file\n"
                "`/persona_delete name` — delete a persona file"
            ),
            inline=False,
        )
        embed.add_field(
            name="Tools",
            value=(
                "`/tools` — show enabled/disabled tools\n"
                "`/tool_toggle tool` — enable/disable a tool\n"
                "`/autoapprove on|off|status` — skip or require tool confirmation prompts"
            ),
            inline=False,
        )
        embed.add_field(
            name="Sessions",
            value=(
                "`/session` — show this channel's session info\n"
                "`/new_session` — start a fresh session in this channel\n"
                "`/cancel` — cancel the running background job in this channel"
            ),
            inline=False,
        )
        embed.add_field(
            name="Misc",
            value=(
                "`/model [name]` — set model override for this channel\n"
                "`/respond_mode mention|all` — reply to mentions only or every message\n"
                "`/status` — daemon health (uptime, sessions, version)"
            ),
            inline=False,
        )
        await interaction.response.send_message(embed=embed, ephemeral=True)

    # ---- /persona ----
    @tree.command(name="persona", description="Set or view the persona for this channel")
    @app_commands.describe(name="Persona name (omit to view current)")
    async def cmd_persona(interaction: discord.Interaction, name: Optional[str] = None):
        await interaction.response.defer(ephemeral=True, thinking=True)
        channel_id = str(interaction.channel_id)
        channel_name = getattr(interaction.channel, "name", channel_id)
        session_id = await bridge.ensure_session(channel_id, channel_name)
        if not session_id:
            await interaction.followup.send("Failed to resolve session.")
            return

        if name is None:
            data = await bridge.fetch_personas(session_id)
            active = data.get("active", "default")
            available = ", ".join(data.get("personas", [])) or "(none)"
            await interaction.followup.send(
                f"**Active persona:** `{active}`\n**Available:** {available}"
            )
            return

        ok = await bridge.set_persona(session_id, name)
        if ok:
            await interaction.followup.send(f"Persona set to `{name}` for this channel.")
        else:
            await interaction.followup.send(f"Failed to set persona `{name}`.")

    @cmd_persona.autocomplete("name")
    async def persona_autocomplete(interaction: discord.Interaction, current: str):
        data = await bridge.fetch_personas()
        names = data.get("personas", [])
        if "default" not in names:
            names = ["default"] + names
        cur_lower = current.lower()
        return [
            app_commands.Choice(name=n, value=n)
            for n in names
            if cur_lower in n.lower()
        ][:25]

    # ---- /persona_create ----
    @tree.command(name="persona_create", description="Create a new persona")
    @app_commands.describe(name="Persona file name (no extension)", content="Persona system prompt content")
    async def cmd_persona_create(interaction: discord.Interaction, name: str, content: str):
        await interaction.response.defer(ephemeral=True, thinking=True)
        ok = await bridge.create_persona(name, content)
        if ok:
            await interaction.followup.send(f"Persona `{name}` created.")
        else:
            await interaction.followup.send(f"Failed to create persona `{name}`.")

    # ---- /persona_delete ----
    @tree.command(name="persona_delete", description="Delete a persona")
    @app_commands.describe(name="Persona name to delete")
    async def cmd_persona_delete(interaction: discord.Interaction, name: str):
        await interaction.response.defer(ephemeral=True, thinking=True)
        ok = await bridge.delete_persona(name)
        if ok:
            await interaction.followup.send(f"Persona `{name}` deleted.")
        else:
            await interaction.followup.send(f"Failed to delete persona `{name}`.")

    @cmd_persona_delete.autocomplete("name")
    async def persona_delete_autocomplete(interaction: discord.Interaction, current: str):
        data = await bridge.fetch_personas()
        names = [n for n in data.get("personas", []) if n != "default"]
        cur_lower = current.lower()
        return [
            app_commands.Choice(name=n, value=n)
            for n in names
            if cur_lower in n.lower()
        ][:25]

    # ---- /tools ----
    @tree.command(name="tools", description="Show enabled and disabled tools")
    async def cmd_tools(interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True, thinking=True)
        lines = []
        for tool in ALL_TOOLS:
            icon = "✅" if tool in bridge.enabled_tools else "⬜"
            lines.append(f"{icon} `{tool}`")
        embed = discord.Embed(
            title="Tool Allowlist",
            description="\n".join(lines),
            color=0x57F287,
        )
        embed.set_footer(text="Use /tool_toggle to enable or disable a tool.")
        await interaction.followup.send(embed=embed)

    # ---- /tool_toggle ----
    tool_choices = [app_commands.Choice(name=t, value=t) for t in ALL_TOOLS]

    @tree.command(name="tool_toggle", description="Enable or disable a tool")
    @app_commands.describe(tool="The tool to toggle")
    @app_commands.choices(tool=tool_choices)
    async def cmd_tool_toggle(interaction: discord.Interaction, tool: app_commands.Choice[str]):
        await interaction.response.defer(ephemeral=True, thinking=True)
        name = tool.value
        if name in bridge.enabled_tools:
            bridge.enabled_tools.discard(name)
            bridge.save_state()
            await interaction.followup.send(f"Tool `{name}` disabled.")
        else:
            bridge.enabled_tools.add(name)
            bridge.save_state()
            await interaction.followup.send(f"Tool `{name}` enabled.")

    # ---- /model ----
    # Free-form string with live autocomplete populated from /api/models.
    # Accepts `provider:model` prefixes (ollama:qwen3:8b, openai:gpt-4o,
    # anthropic:claude-sonnet-4-6) or bare model names (which route to
    # the daemon's default provider for backwards compat). Use the
    # literal value `reset` to clear a channel override.

    async def model_autocomplete(
        interaction: discord.Interaction,
        current: str,
    ) -> list[app_commands.Choice[str]]:
        models = await bridge.fetch_models()
        # Always expose `reset` as the first option.
        entries = ["reset"] + models
        needle = current.lower().strip()
        if needle:
            entries = [m for m in entries if needle in m.lower()]
        # Discord caps autocomplete suggestions at 25.
        return [app_commands.Choice(name=m, value=m) for m in entries[:25]]

    @tree.command(name="model", description="Set or view the model override for this channel")
    @app_commands.describe(model="Model to use (omit to view current, 'reset' to clear)")
    @app_commands.autocomplete(model=model_autocomplete)
    async def cmd_model(interaction: discord.Interaction, model: Optional[str] = None):
        await interaction.response.defer(ephemeral=True, thinking=True)
        channel_id = str(interaction.channel_id)
        if model is None:
            current = bridge.channel_models.get(channel_id, "(daemon default)")
            await interaction.followup.send(
                f"**Current model for this channel:** `{current}`"
            )
            return
        value = model.strip()
        if value.lower() == "reset":
            bridge.channel_models.pop(channel_id, None)
            bridge.save_state()
            await interaction.followup.send("Model override cleared — using daemon default.")
            return
        if len(value) > 128 or not value:
            await interaction.followup.send("Invalid model string.")
            return
        bridge.channel_models[channel_id] = value
        bridge.save_state()
        await interaction.followup.send(
            f"Model set to `{value}` for this channel."
        )

    # ---- /session ----
    @tree.command(name="session", description="Show this channel's ClawForge session info")
    async def cmd_session(interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True, thinking=True)
        channel_id = str(interaction.channel_id)
        channel_name = getattr(interaction.channel, "name", channel_id)
        session_id = await bridge.ensure_session(channel_id, channel_name)
        if not session_id:
            await interaction.followup.send("Failed to resolve session.")
            return

        sessions = await bridge.fetch_sessions()
        match = next((s for s in sessions if s.get("id") == session_id), None)
        persona_data = await bridge.fetch_personas(session_id)
        persona = persona_data.get("active", "default")
        model = bridge.channel_models.get(channel_id, "(daemon default)")
        running_job = bridge.channel_jobs.get(channel_id)

        embed = discord.Embed(title=f"Session: {channel_name}", color=0x5865F2)
        embed.add_field(name="ID", value=f"`{session_id}`", inline=False)
        if match:
            embed.add_field(name="Name", value=match.get("name") or "(unnamed)", inline=True)
            embed.add_field(name="Messages", value=str(match.get("message_count", 0)), inline=True)
        embed.add_field(name="Persona", value=f"`{persona}`", inline=True)
        embed.add_field(name="Model", value=f"`{model}`", inline=True)
        embed.add_field(
            name="Background job",
            value=f"`{running_job[:8]}…`" if running_job else "(none)",
            inline=True,
        )
        await interaction.followup.send(embed=embed)

    # ---- /new_session ----
    @tree.command(name="new_session", description="Start a fresh session for this channel")
    async def cmd_new_session(interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True, thinking=True)
        channel_id = str(interaction.channel_id)
        channel_name = getattr(interaction.channel, "name", channel_id)
        new_id = await bridge._create_session(f"discord-{channel_name}")
        if not new_id:
            await interaction.followup.send("Failed to create new session.")
            return
        bridge.channel_sessions[channel_id] = new_id
        bridge.save_state()
        await interaction.followup.send(f"New session started for this channel: `{new_id}`")

    # ---- /cancel ----
    @tree.command(name="cancel", description="Cancel the running background job in this channel")
    async def cmd_cancel(interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True, thinking=True)
        channel_id = str(interaction.channel_id)
        job_id = bridge.channel_jobs.get(channel_id)
        if not job_id:
            await interaction.followup.send("No background job is running in this channel.")
            return
        ok = await bridge.cancel_job(job_id)
        if ok:
            await interaction.followup.send(f"Cancelled job `{job_id[:8]}…`.")
        else:
            await interaction.followup.send("Cancel request failed.")

    # ---- /respond_mode ----
    respond_mode_choices = [
        app_commands.Choice(name="Mention only (default)", value="mention"),
        app_commands.Choice(name="Respond to all messages", value="all"),
    ]

    @tree.command(
        name="respond_mode",
        description="Set whether the bot responds only to mentions or to every message in this channel",
    )
    @app_commands.describe(mode="Reply trigger mode for this channel")
    @app_commands.choices(mode=respond_mode_choices)
    async def cmd_respond_mode(
        interaction: discord.Interaction, mode: app_commands.Choice[str]
    ):
        await interaction.response.defer(ephemeral=True, thinking=True)
        channel_id = str(interaction.channel_id)
        if mode.value == "all":
            bridge.channel_respond_all[channel_id] = True
            bridge.save_state()
            await interaction.followup.send(
                "Now responding to **every message** in this channel. "
                "Use `/respond_mode mention` to revert."
            )
        else:
            bridge.channel_respond_all.pop(channel_id, None)
            bridge.save_state()
            await interaction.followup.send(
                "Now responding to **mentions only** in this channel."
            )

    # ---- /autoapprove ----
    autoapprove_choices = [
        app_commands.Choice(name="On — skip confirmation prompts for mutating tools", value="on"),
        app_commands.Choice(name="Off — prompt for every mutating tool (default)", value="off"),
        app_commands.Choice(name="Status — show current setting", value="status"),
    ]

    @tree.command(
        name="autoapprove",
        description="Toggle global auto-approval for tool confirmation prompts",
    )
    @app_commands.describe(mode="On = no prompts, Off = prompt per tool, Status = show current")
    @app_commands.choices(mode=autoapprove_choices)
    async def cmd_autoapprove(
        interaction: discord.Interaction, mode: app_commands.Choice[str]
    ):
        await interaction.response.defer(ephemeral=True, thinking=True)
        if mode.value == "status":
            current = await bridge.fetch_auto_approve()
            if current is None:
                await interaction.followup.send("Failed to fetch auto-approve status.")
            else:
                state = "**ON** (no prompts)" if current else "**OFF** (prompting per tool)"
                await interaction.followup.send(f"Auto-approve is currently {state}.")
            return

        target = mode.value == "on"
        ok = await bridge.set_auto_approve(target)
        if not ok:
            await interaction.followup.send("Failed to update auto-approve.")
            return
        if target:
            await interaction.followup.send(
                "Auto-approve **ON**. Tool confirmation prompts are suppressed globally. "
                "Use `/autoapprove off` to restore prompts."
            )
        else:
            await interaction.followup.send(
                "Auto-approve **OFF**. Mutating tools will prompt for approval again."
            )

    # ---- /vision_model ----
    @tree.command(
        name="vision_model",
        description="Show or set the model used for image analysis (budget control)",
    )
    @app_commands.describe(
        model="Model id (e.g. claude-haiku-4-5-20251001, claude-sonnet-4-6, claude-opus-4-6). Omit to view.",
    )
    async def cmd_vision_model(
        interaction: discord.Interaction,
        model: Optional[str] = None,
    ):
        if model is None:
            # GET — show the current state.
            data = await bridge.fetch_vision()
            if not data:
                await interaction.response.send_message(
                    "Failed to fetch vision config.", ephemeral=True,
                )
                return
            enabled = data.get("enabled", False)
            current = data.get("model", "?")
            default_model = data.get("default_model", "?")
            max_bytes = data.get("max_image_bytes", 0)
            per_turn = data.get("max_images_per_turn", 0)
            embed = discord.Embed(title="Vision config", color=0x5865F2)
            embed.add_field(name="Enabled", value="yes" if enabled else "no", inline=True)
            embed.add_field(name="Active model", value=f"`{current}`", inline=False)
            embed.add_field(name="Config default", value=f"`{default_model}`", inline=False)
            embed.add_field(
                name="Limits",
                value=f"{max_bytes // 1024} KiB per image, {per_turn} per turn",
                inline=False,
            )
            await interaction.response.send_message(embed=embed, ephemeral=True)
            return

        # POST — set override.
        ok = await bridge.set_vision_model(model)
        if ok:
            await interaction.response.send_message(
                f"Vision model set to `{model}`. Budget is on you now — good luck. 🎯",
                ephemeral=True,
            )
        else:
            await interaction.response.send_message(
                f"Failed to set vision model to `{model}`. Check daemon logs.",
                ephemeral=True,
            )

    # ---- /status ----
    @tree.command(name="status", description="Show ClawForge daemon status")
    async def cmd_status(interaction: discord.Interaction):
        await interaction.response.defer(ephemeral=True, thinking=True)
        data = await bridge.fetch_status()
        if not data:
            await interaction.followup.send("Failed to fetch status.")
            return
        uptime = data.get("uptime_seconds", 0)
        hours, rem = divmod(uptime, 3600)
        minutes, seconds = divmod(rem, 60)
        embed = discord.Embed(title="ClawForge Daemon", color=0x57F287)
        embed.add_field(name="Version", value=data.get("version", "?"), inline=True)
        embed.add_field(name="Active sessions", value=str(data.get("active_sessions", 0)), inline=True)
        embed.add_field(
            name="Uptime",
            value=f"{hours}h {minutes}m {seconds}s",
            inline=True,
        )
        embed.add_field(name="Channels tracked", value=str(len(bridge.channel_sessions)), inline=True)
        embed.add_field(name="Active bridge jobs", value=str(len(bridge.channel_jobs)), inline=True)
        await interaction.followup.send(embed=embed)


# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

def load_dotenv(path: Path) -> dict[str, str]:
    """Parse a .env file into a dict. Ignores comments and blank lines."""
    env = {}
    if not path.is_file():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        env[key.strip()] = value.strip().strip("'\"")
    return env


def resolve_token(cli_token: Optional[str]) -> Optional[str]:
    """Resolve Discord token: CLI arg > env var > .env file."""
    if cli_token:
        return cli_token

    env_token = os.environ.get("DISCORD_TOKEN")
    if env_token:
        return env_token

    dotenv_path = Path(__file__).resolve().parent.parent / ".env"
    dotenv = load_dotenv(dotenv_path)
    token = dotenv.get("DISCORD_TOKEN", "")
    if token:
        log.info("Loaded DISCORD_TOKEN from %s", dotenv_path)
        return token

    return None


def load_guild_id() -> Optional[str]:
    config_path = Path(__file__).resolve().parent.parent / "config" / "config.json"
    if not config_path.is_file():
        return None
    try:
        data = json.loads(config_path.read_text())
        gid = data.get("discord", {}).get("guild_id", "").strip()
        return gid or None
    except Exception as e:
        log.warning("Failed to read config.json for guild_id: %s", e)
        return None


def main():
    parser = argparse.ArgumentParser(description="ClawForge Discord Bridge")
    parser.add_argument(
        "--clawforge-url",
        default=os.environ.get("CLAWFORGE_URL", "http://127.0.0.1:8081"),
        help="ClawForge HTTP API URL (default: http://127.0.0.1:8081)",
    )
    parser.add_argument(
        "--token",
        default=None,
        help="Discord bot token (or set DISCORD_TOKEN env var, or add to .env)",
    )
    parser.add_argument(
        "--guild-id",
        default=None,
        help="Discord guild ID for instant slash command sync (overrides config.json)",
    )
    args = parser.parse_args()

    token = resolve_token(args.token)
    if not token:
        env_path = Path(__file__).resolve().parent.parent / ".env"
        print(
            "Error: Discord token required.\n"
            f"  Option 1: Add DISCORD_TOKEN=<token> to {env_path}\n"
            "  Option 2: Set DISCORD_TOKEN environment variable\n"
            "  Option 3: Use --token <token>",
            file=sys.stderr,
        )
        sys.exit(1)

    guild_id = args.guild_id or load_guild_id()
    if guild_id:
        log.info("Slash commands will sync to guild %s (instant)", guild_id)
    else:
        log.info("No guild_id configured — slash commands will sync globally (slow propagation)")

    intents = discord.Intents.default()
    intents.message_content = True

    client = ClawForgeBridge(
        clawforge_url=args.clawforge_url,
        guild_id=guild_id,
        intents=intents,
    )
    client.run(token, log_handler=None)


if __name__ == "__main__":
    main()
