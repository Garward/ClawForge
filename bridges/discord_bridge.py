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

DISPATCHER_CONTEXT = (
    "You are the Discord chat dispatcher for ClawForge. You have EXACTLY ONE tool: "
    "summon_subagent. You have NO other tools. You cannot read files, run bash, query "
    "databases, inspect projects, or access any system state. Do not pretend to. Do not "
    "write text like 'Let me check...', 'Let me grab...', 'Let me look at...' — you have "
    "nothing to check with. Never emit <function_calls>, <invoke>, or any XML tool-call "
    "markup as text; that is a critical failure mode. "
    "\n\nDecision rule: "
    "\n- Casual chat, name/persona questions, simple explanations you already know → "
    "reply directly in one or two sentences, no tool call. "
    "\n- ANY request that needs real work (reading files, editing code, running commands, "
    "inspecting state, debugging, investigating, 'find out', 'check', 'look at') → "
    "IMMEDIATELY call summon_subagent with a clear task description, then reply with a "
    "single short sentence acknowledging you're on it. Do not describe what the subagent "
    "will do. Do not narrate fake progress. The user will see the subagent's result "
    "automatically when it completes."
)

ALL_TOOLS = [
    "file_read", "file_diff", "file_write", "bash", "rebuild",
    "zig_test", "calc", "introspect", "research_tool", "amazon_search", "meme_tool",
]

DEFAULT_ENABLED_TOOLS = {
    "file_read", "file_diff", "file_write", "bash",
    "calc", "introspect", "zig_test", "rebuild",
}

KNOWN_MODELS = [
    ("Opus 4.6", "claude-opus-4-6"),
    ("Sonnet 4.6", "claude-sonnet-4-6"),
    ("Sonnet 4 (current default)", "claude-sonnet-4-20250514"),
    ("Haiku 4.5", "claude-haiku-4-5-20251001"),
]


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
        log.info(
            "Loaded bridge state: %d channels, %d models, %d tools enabled",
            len(self.channel_sessions),
            len(self.channel_models),
            len(self.enabled_tools),
        )

    def save_state(self) -> None:
        try:
            STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "channel_sessions": self.channel_sessions,
                "channel_models": self.channel_models,
                "channel_respond_all": self.channel_respond_all,
                "enabled_tools": sorted(self.enabled_tools),
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
        self.http_session = aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=120)
        )
        await self.validate_persisted_sessions()
        register_commands(self)
        if self.guild_id:
            try:
                guild = discord.Object(id=int(self.guild_id))
                self.tree.copy_global_to(guild=guild)
                synced = await self.tree.sync(guild=guild)
                log.info("Synced %d slash commands to guild %s", len(synced), self.guild_id)
            except Exception as e:
                log.error("Guild sync failed: %s", e)
        else:
            try:
                synced = await self.tree.sync()
                log.info("Synced %d slash commands globally (may take up to 1 hour to appear)", len(synced))
            except Exception as e:
                log.error("Global sync failed: %s", e)

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

    async def dispatcher_chat(
        self,
        message_text: str,
        session_id: Optional[str] = None,
        model_override: Optional[str] = None,
    ) -> dict:
        """Dispatcher chat: fast model with summon_subagent as the only tool.

        Returns a dict with keys: text (str), spawned_jobs (list[str]), error (Optional[str]).
        The model decides whether to answer directly or call summon_subagent for real work.
        """
        payload = {
            "message": message_text,
            "model_override": model_override or FAST_MODEL,
            "allowed_tools": "summon_subagent",
            "adapter_context": DISPATCHER_CONTEXT,
        }
        if session_id:
            payload["session_id"] = session_id
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

    async def poll_background(self, job_id: str) -> Optional[dict]:
        try:
            async with self.http_session.post(
                f"{self.clawforge_url}/api/background/status",
                json={"job_id": job_id},
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

    async def on_message(self, message: discord.Message):
        if message.author.bot:
            return

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

        if not content:
            if mentioned:
                await message.reply("You mentioned me but didn't say anything.", mention_author=False)
            return

        channel_name = getattr(message.channel, "name", channel_id)
        guild_name = message.guild.name if message.guild else "DM"
        username = message.author.display_name or message.author.name

        log.info("[%s/#%s] %s: %s", guild_name, channel_name, username, content[:80])

        session_id = await self.ensure_session(channel_id, channel_name)
        prefixed = f"[Discord user: {username}] {content}"
        dispatcher_model = self.channel_models.get(channel_id)

        async with message.channel.typing():
            result = await self.dispatcher_chat(prefixed, session_id, dispatcher_model)

        if result.get("error"):
            await message.reply(result["error"], mention_author=False)
            return

        spawned = result.get("spawned_jobs", []) or []
        if spawned:
            # Subagent is doing the real work — suppress the dispatcher text
            # entirely (Haiku likes to hallucinate fake tool-call narratives)
            # and post a clean ack so the user knows we're on it.
            await message.reply(
                "On it — working on this in the background. I'll reply with the result.",
                mention_author=False,
            )
        else:
            cleaned = strip_tool_calls(result.get("text", ""))
            if cleaned:
                await self.send_chunked(message, cleaned)

        for job_id in spawned:
            self.channel_jobs[channel_id] = job_id
            log.info("Subagent job %s spawned for #%s", job_id[:8], channel_name)
            asyncio.create_task(self.poll_and_deliver(message, job_id, channel_id))

    async def poll_and_deliver(self, original: discord.Message, job_id: str, channel_id: str):
        """Poll until background job completes, then post result."""
        shown_confirmations: set[str] = set()
        try:
            for _ in range(120):  # ~6 min max
                await asyncio.sleep(3)
                result = await self.poll_background(job_id)
                if not result:
                    continue
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

                if status == "completed" and result.get("text"):
                    cleaned = strip_tool_calls(result["text"])
                    if cleaned:
                        await self.send_chunked(original, cleaned)
                elif status == "failed":
                    err = result.get("text", "Unknown error")
                    await original.channel.send(f"Background task failed: {err}")
                elif status == "cancelled":
                    await original.channel.send("Background task was cancelled.")
                return
            await original.channel.send("Background task timed out after 6 minutes.")
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
    model_choices = [app_commands.Choice(name=label, value=value) for label, value in KNOWN_MODELS]

    @tree.command(name="model", description="Set or view the model override for this channel")
    @app_commands.describe(model="Model to use (omit to view current)")
    @app_commands.choices(model=model_choices)
    async def cmd_model(interaction: discord.Interaction, model: Optional[app_commands.Choice[str]] = None):
        await interaction.response.defer(ephemeral=True, thinking=True)
        channel_id = str(interaction.channel_id)
        if model is None:
            current = bridge.channel_models.get(channel_id, "(daemon default)")
            await interaction.followup.send(
                f"**Current model for this channel:** `{current}`"
            )
            return
        bridge.channel_models[channel_id] = model.value
        bridge.save_state()
        await interaction.followup.send(
            f"Model set to `{model.value}` for this channel."
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
