#!/usr/bin/env python3
"""discord.py transport sidecar for ClawForge.

Protocol stdout is reserved for newline-delimited JSON RPC. All ClawForge
semantics, sessions, jobs, confirmations, and configuration live in the Zig
DiscordAdapter; this process only owns Discord Gateway/REST and UI rendering.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import uuid
from pathlib import Path
from typing import Any, Optional

import discord
import aiohttp
from discord import app_commands

logging.basicConfig(
    level=logging.INFO,
    stream=sys.stderr,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("clawforge.discord")

MAX_DISCORD_MESSAGE = 1900
STATE_FILE = Path(__file__).resolve().parent.parent / "data" / "discord_bridge_state.json"
DEFAULT_WEB_URL = "http://127.0.0.1:8081"
DISPATCH_CONTEXT = (
    "You are ClawForge's Discord preflight dispatcher. Reply directly and briefly to casual chat, "
    "questions answerable from context, and other requests needing no tools. For work that needs "
    "code inspection, file changes, commands, research, or multiple steps, call summon_subagent in "
    "explore mode with a concrete task and chain=true, then give the user one short natural-language "
    "acknowledgment. Never claim work completed before the background job returns. Keep Discord "
    "responses concise and never mention RPC or transport internals."
)


def rank_model_autocomplete(
    providers: list[dict[str, Any]], current: str
) -> list[str]:
    """Return Discord-sized model suggestions with OAuth Codex models first."""
    codex_models: list[str] = []
    other_models: list[str] = []
    seen = {"reset"}

    for provider in providers:
        provider_name = str(provider.get("name", "")).casefold()
        for entry in provider.get("models", []):
            value = entry.get("id", "") if isinstance(entry, dict) else entry
            if not isinstance(value, str) or not value or value in seen:
                continue
            seen.add(value)
            if provider_name == "codex" or value.casefold().startswith("codex:"):
                codex_models.append(value)
            else:
                other_models.append(value)

    needle = current.casefold().strip()
    entries = ["reset", *codex_models, *other_models]
    if needle:
        entries = [value for value in entries if needle in value.casefold()]
    return entries[:25]


class DaemonRPC:
    def __init__(self) -> None:
        self.pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self.write_lock = asyncio.Lock()
        self.reader_task: Optional[asyncio.Task[None]] = None

    async def start(self) -> None:
        self.reader_task = asyncio.create_task(self._read_loop())

    async def close(self) -> None:
        if self.reader_task:
            self.reader_task.cancel()

    async def call(self, method: str, **params: Any) -> dict[str, Any]:
        request_id = uuid.uuid4().hex
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        frame = json.dumps(
            {"id": request_id, "method": method, "params": params},
            ensure_ascii=False,
            separators=(",", ":"),
        )
        async with self.write_lock:
            sys.stdout.write(frame + "\n")
            sys.stdout.flush()
        try:
            response = await asyncio.wait_for(future, timeout=65)
        finally:
            self.pending.pop(request_id, None)
        if not response.get("ok"):
            raise RuntimeError(response.get("error_message", "daemon RPC failed"))
        return response.get("result", {})

    async def _read_loop(self) -> None:
        while True:
            line = await asyncio.to_thread(sys.stdin.readline)
            if not line:
                error = RuntimeError("daemon closed Discord RPC stdin")
                for future in self.pending.values():
                    if not future.done():
                        future.set_exception(error)
                return
            try:
                frame = json.loads(line)
                future = self.pending.get(str(frame.get("id", "")))
                if future and not future.done():
                    future.set_result(frame)
            except Exception:
                log.exception("invalid daemon RPC frame")


class CancelView(discord.ui.View):
    def __init__(self, bridge: "DiscordTransport", job_id: str) -> None:
        super().__init__(timeout=900)
        self.bridge = bridge
        self.job_id = job_id

    @discord.ui.button(label="Cancel", style=discord.ButtonStyle.danger)
    async def cancel(self, interaction: discord.Interaction, _: discord.ui.Button) -> None:
        await interaction.response.defer(ephemeral=True)
        try:
            result = await self.bridge.rpc.call("cancel", job_id=self.job_id)
            text = "Cancellation requested." if result.get("cancelled") else "Job is no longer cancellable."
        except Exception as exc:
            text = f"Cancellation failed: {exc}"
        await interaction.followup.send(text, ephemeral=True)
        self.stop()


class ConfirmationView(discord.ui.View):
    def __init__(self, bridge: "DiscordTransport", job_id: str, tool_id: str) -> None:
        super().__init__(timeout=300)
        self.bridge = bridge
        self.job_id = job_id
        self.tool_id = tool_id
        self.resolved = False

    async def resolve(self, interaction: discord.Interaction, approved: bool) -> None:
        await interaction.response.defer()
        try:
            result = await self.bridge.rpc.call(
                "confirm", job_id=self.job_id, tool_id=self.tool_id, approved=approved
            )
            text = "Approved." if approved else "Denied."
            if not result.get("resolved"):
                text = "Confirmation had already expired."
        except Exception as exc:
            text = f"Confirmation failed: {exc}"
        self.resolved = True
        self.stop()
        await interaction.edit_original_response(content=text, view=None)

    @discord.ui.button(label="Approve", style=discord.ButtonStyle.success)
    async def approve(self, interaction: discord.Interaction, _: discord.ui.Button) -> None:
        await self.resolve(interaction, True)

    @discord.ui.button(label="Deny", style=discord.ButtonStyle.danger)
    async def deny(self, interaction: discord.Interaction, _: discord.ui.Button) -> None:
        await self.resolve(interaction, False)

    async def on_timeout(self) -> None:
        if not self.resolved:
            try:
                await self.bridge.rpc.call(
                    "confirm", job_id=self.job_id, tool_id=self.tool_id, approved=False
                )
            except Exception:
                log.exception("timed-out confirmation could not be denied")


class DiscordTransport(discord.Client):
    def __init__(self, guild_id: Optional[int], attachment_spool: Path, max_attachment_bytes: int, max_attachment_count: int) -> None:
        intents = discord.Intents.default()
        intents.message_content = True
        super().__init__(intents=intents)
        self.tree = app_commands.CommandTree(self)
        self.rpc = DaemonRPC()
        self.channel_jobs: dict[int, str] = {}
        self.channel_sessions: dict[str, str] = {}
        self.channel_models: dict[str, str] = {}
        self.channel_respond_all: dict[str, bool] = {}
        self.channel_plans_required: dict[str, bool] = {}
        self.enabled_tools: set[str] = set()
        self.known_guild_ids: set[str] = {str(guild_id)} if guild_id else set()
        self.attachment_spool = attachment_spool.resolve()
        self.max_attachment_bytes = max_attachment_bytes
        self.max_attachment_count = max_attachment_count
        self.api_session: Optional[aiohttp.ClientSession] = None
        self.load_state()

    def load_state(self) -> None:
        try:
            data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return
        except Exception:
            log.exception("failed to load Discord bridge state")
            return
        self.channel_sessions = dict(data.get("channel_sessions", {}))
        self.channel_models = dict(data.get("channel_models", {}))
        self.channel_respond_all = {
            str(key): bool(value) for key, value in data.get("channel_respond_all", {}).items()
        }
        self.channel_plans_required = {
            str(key): bool(value) for key, value in data.get("channel_plans_required", {}).items()
        }
        self.enabled_tools = set(data.get("enabled_tools", []))
        self.known_guild_ids.update(str(value) for value in data.get("known_guild_ids", []))

    def save_state(self) -> None:
        payload = {
            "channel_sessions": self.channel_sessions,
            "channel_models": self.channel_models,
            "channel_respond_all": self.channel_respond_all,
            "channel_plans_required": self.channel_plans_required,
            "enabled_tools": sorted(self.enabled_tools),
            "known_guild_ids": sorted(self.known_guild_ids),
        }
        temporary = STATE_FILE.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        temporary.replace(STATE_FILE)

    async def setup_hook(self) -> None:
        await self.rpc.start()
        self.api_session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=65))
        if self.known_guild_ids:
            for guild_id in self.known_guild_ids:
                guild = discord.Object(id=int(guild_id))
                self.tree.copy_global_to(guild=guild)
                synced = await self.tree.sync(guild=guild)
                log.info("synced %d Discord commands to guild %s", len(synced), guild_id)
            self.tree.clear_commands(guild=None)
            await self.tree.sync()
            log.info("cleared stale global Discord commands")
        else:
            synced = await self.tree.sync()
            log.info("synced %d global Discord commands", len(synced))

    async def close(self) -> None:
        if self.api_session:
            await self.api_session.close()
        await self.rpc.close()
        await super().close()

    async def on_ready(self) -> None:
        log.info("Discord transport connected as %s", self.user)
        for guild in self.guilds:
            guild_id = str(guild.id)
            if guild_id in self.known_guild_ids:
                continue
            self.known_guild_ids.add(guild_id)
            self.save_state()
            target = discord.Object(id=guild.id)
            self.tree.copy_global_to(guild=target)
            synced = await self.tree.sync(guild=target)
            log.info("synced %d Discord commands to new guild %s", len(synced), guild_id)

    async def on_message(self, message: discord.Message) -> None:
        if message.author.bot or not self.user:
            return
        mentioned = self.user in message.mentions
        respond_all = self.channel_respond_all.get(str(message.channel.id), False)
        if message.guild and not mentioned and not respond_all:
            return
        content = message.content
        if mentioned:
            content = content.replace(f"<@{self.user.id}>", "").replace(f"<@!{self.user.id}>", "").strip()
        if not content:
            content = "Please respond to the attached message."
        descriptors = await self.spool_attachments(message.attachments)
        await self.submit(message.channel, content, reply_to=message, attachments=descriptors)

    async def spool_attachments(self, attachments: list[discord.Attachment]) -> list[dict[str, str]]:
        if len(attachments) > self.max_attachment_count:
            raise ValueError(f"too many attachments (maximum {self.max_attachment_count})")
        if not attachments:
            return []
        self.attachment_spool.mkdir(parents=True, exist_ok=True)
        descriptors: list[dict[str, str]] = []
        for attachment in attachments:
            if attachment.size > self.max_attachment_bytes:
                raise ValueError(f"attachment {attachment.filename!r} exceeds the size limit")
            disk_name = f"{attachment.id}-{uuid.uuid4().hex}"
            final_path = self.attachment_spool / disk_name
            part_path = self.attachment_spool / f"{disk_name}.part"
            written = 0
            try:
                assert self.api_session is not None
                async with self.api_session.get(attachment.url) as response:
                    response.raise_for_status()
                    with part_path.open("xb") as output:
                        async for chunk in response.content.iter_chunked(64 * 1024):
                            written += len(chunk)
                            if written > self.max_attachment_bytes:
                                raise ValueError(f"attachment {attachment.filename!r} exceeds the size limit")
                            output.write(chunk)
                part_path.replace(final_path)
            except Exception:
                part_path.unlink(missing_ok=True)
                raise
            descriptors.append({
                "path": str(final_path),
                "mime": attachment.content_type or "application/octet-stream",
                "name": attachment.filename,
            })
        return descriptors

    async def submit(
        self,
        channel: discord.abc.Messageable,
        prompt: str,
        *,
        reply_to: Optional[discord.Message] = None,
        model: Optional[str] = None,
        attachments: Optional[list[dict[str, str]]] = None,
    ) -> None:
        channel_id = getattr(channel, "id", None)
        if channel_id is None:
            return
        channel_key = str(channel_id)
        status_message: Optional[discord.Message] = None
        try:
            session_id = await self.ensure_session(channel_key, getattr(channel, "name", channel_key))
            selected_model = model or self.channel_models.get(channel_key)
            dispatch_context = DISPATCH_CONTEXT
            if selected_model:
                dispatch_context += (
                    f" When calling summon_subagent, set its model field to {selected_model!r}; "
                    "that is the user's selected model for background work."
                )
            async with channel.typing():
                if attachments:
                    result = await self.rpc.call(
                        "chat",
                        message=prompt,
                        channel=channel_key,
                        session_id=session_id,
                        model=selected_model,
                        plans_required=False,
                        adapter_context="Discord attachment request.",
                        attachments=attachments,
                    )
                else:
                    result = await self.rpc.call(
                        "dispatch",
                        message=prompt,
                        channel=channel_key,
                        session_id=session_id,
                        model=selected_model,
                        plans_required=False,
                        allowed_tools="summon_subagent",
                        adapter_context=dispatch_context,
                    )
            if attachments:
                job_id = result["queued"]["job_id"]
                self.channel_jobs[channel_id] = job_id
                status_message = await self._send(
                    channel, f"Working on job `{job_id[:8]}`…", view=CancelView(self, job_id), reply_to=reply_to
                )
                await self.poll_job(channel, status_message, job_id)
                return
            dispatched = result["dispatched"]
            text = dispatched.get("text", "").strip()
            spawned = [
                job_id.strip()
                for job_id in (dispatched.get("spawned_jobs") or "").split(",")
                if job_id.strip()
            ]
            if not spawned:
                await self._send(channel, text or "Done.", reply_to=reply_to)
                return

            job_id = spawned[0]
            self.channel_jobs[channel_id] = job_id
            if text:
                await self._send(channel, text, reply_to=reply_to)
            status_message = await self._send(
                channel,
                f"Working on job `{job_id[:8]}`…",
                view=CancelView(self, job_id),
                reply_to=None if text else reply_to,
            )
            await self.poll_job(channel, status_message, job_id)
        except Exception as exc:
            log.exception("Discord request failed")
            detail = str(exc) or type(exc).__name__
            error_text = f"ClawForge request failed: {detail}"
            if status_message:
                await status_message.edit(content=error_text, view=None)
            else:
                await self._send(channel, error_text, reply_to=reply_to)

    async def api(self, method: str, path: str, **kwargs: Any) -> Any:
        if not self.api_session:
            raise RuntimeError("management API is not ready")
        async with self.api_session.request(method, DEFAULT_WEB_URL + path, **kwargs) as response:
            if response.status >= 400:
                raise RuntimeError(f"daemon HTTP {response.status}: {await response.text()}")
            return await response.json()

    async def ensure_session(self, channel_id: str, channel_name: str) -> str:
        if session_id := self.channel_sessions.get(channel_id):
            return session_id
        result = await self.api("POST", "/api/sessions/new", json={"name": f"discord-{channel_name}"})
        session_id = result["id"]
        self.channel_sessions[channel_id] = session_id
        self.save_state()
        return session_id

    async def poll_job(self, channel: discord.abc.Messageable, status: discord.Message, job_id: str) -> None:
        confirmation_id: Optional[str] = None
        cursor = 0
        activity = "Waiting for the model"
        loop = asyncio.get_running_loop()
        started = loop.time()
        next_progress_update = started + 15
        while True:
            result = await self.rpc.call("poll", job_id=job_id, cursor=cursor)
            if "finished" in result:
                finished = result["finished"]
                text = finished.get("text") or f"Job ended with status `{finished.get('status', 'unknown')}`."
                await status.edit(content=text[:MAX_DISCORD_MESSAGE], view=None)
                for chunk in chunks(text[MAX_DISCORD_MESSAGE:]):
                    await channel.send(chunk)
                self.channel_jobs.pop(getattr(channel, "id", 0), None)
                return
            confirmation = result.get("confirmation")
            if confirmation and confirmation.get("tool_id") != confirmation_id:
                confirmation_id = confirmation["tool_id"]
                preview = confirmation.get("input_preview", "")
                content = f"Approve tool `{confirmation.get('tool_name', 'unknown')}`?\n```\n{preview[:1200]}\n```"
                await channel.send(
                    content,
                    view=ConfirmationView(self, job_id, confirmation_id),
                )
            pending = result.get("pending", {})
            cursor = int(pending.get("cursor", cursor))
            event = pending.get("event")
            if event:
                event_type = event.get("type", "")
                tool_name = event.get("tool", "")
                if event_type == "tool_use" and tool_name:
                    activity = f"Using `{tool_name}`"
                elif event_type == "tool_result" and tool_name:
                    activity = f"Finished `{tool_name}`"
                elif event_type == "model_wait":
                    activity = "Waiting for the model"
                elif event.get("content"):
                    activity = str(event["content"])[:120]
            now = loop.time()
            if now >= next_progress_update:
                elapsed = int(now - started)
                await status.edit(
                    content=f"{activity} — job `{job_id[:8]}` ({elapsed}s elapsed)"
                )
                next_progress_update = now + 15
            await asyncio.sleep(1)

    async def _send(
        self,
        channel: discord.abc.Messageable,
        content: str,
        *,
        view: Optional[discord.ui.View] = None,
        reply_to: Optional[discord.Message] = None,
    ) -> discord.Message:
        if reply_to:
            return await reply_to.reply(content, view=view, mention_author=False)
        return await channel.send(content, view=view)


def chunks(text: str):
    for index in range(0, len(text), MAX_DISCORD_MESSAGE):
        yield text[index : index + MAX_DISCORD_MESSAGE]


def register_commands(bot: DiscordTransport) -> None:
    @bot.tree.error
    async def command_error(
        interaction: discord.Interaction, error: app_commands.AppCommandError
    ) -> None:
        log.exception("Discord command %s failed", interaction.command, exc_info=error)
        message = f"ClawForge command failed: {error}"
        if interaction.response.is_done():
            await interaction.followup.send(message, ephemeral=True)
        else:
            await interaction.response.send_message(message, ephemeral=True)

    @bot.tree.command(name="ask", description="Ask ClawForge")
    @app_commands.describe(prompt="Message for ClawForge", model="Optional model override")
    async def ask(interaction: discord.Interaction, prompt: str, model: Optional[str] = None) -> None:
        await interaction.response.defer()
        await bot.submit(interaction.channel, prompt, model=model)
        await interaction.delete_original_response()

    async def persona_names(current: str, *, deletable: bool = False) -> list[app_commands.Choice[str]]:
        try:
            data = await bot.api("GET", "/api/persona")
            names = list(data.get("personas", []))
        except Exception:
            log.exception("persona autocomplete failed")
            names = []
        if not deletable and "default" not in names:
            names.insert(0, "default")
        if deletable:
            names = [name for name in names if name != "default"]
        needle = current.casefold()
        return [
            app_commands.Choice(name=name, value=name)
            for name in names
            if needle in name.casefold()
        ][:25]

    @bot.tree.command(name="persona", description="Set or view the persona for this channel")
    @app_commands.describe(name="Persona name (omit to view current)")
    async def persona(interaction: discord.Interaction, name: Optional[str] = None) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)
        channel_id = str(interaction.channel_id)
        session_id = await bot.ensure_session(
            channel_id, getattr(interaction.channel, "name", channel_id)
        )
        if name is None:
            data = await bot.api("GET", f"/api/persona?session_id={session_id}")
            available = ", ".join(data.get("personas", [])) or "(none)"
            await interaction.followup.send(
                f"**Active persona:** `{data.get('active', 'default')}`\n**Available:** {available}"
            )
            return
        await bot.api(
            "POST",
            "/api/persona",
            json={"action": "select", "name": name, "session_id": session_id},
        )
        await interaction.followup.send(f"Persona set to `{name}` for this channel.")

    @persona.autocomplete("name")
    async def persona_autocomplete(
        _: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        return await persona_names(current)

    @bot.tree.command(name="persona_create", description="Create a new persona")
    async def persona_create(interaction: discord.Interaction, name: str, content: str) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)
        await bot.api(
            "POST", "/api/persona", json={"action": "create", "name": name, "content": content}
        )
        await interaction.followup.send(f"Persona `{name}` created.")

    @bot.tree.command(name="persona_delete", description="Delete a persona")
    async def persona_delete(interaction: discord.Interaction, name: str) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)
        await bot.api("POST", "/api/persona", json={"action": "delete", "name": name})
        await interaction.followup.send(f"Persona `{name}` deleted.")

    @persona_delete.autocomplete("name")
    async def persona_delete_autocomplete(
        _: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        return await persona_names(current, deletable=True)

    @bot.tree.command(name="tools", description="Show enabled and disabled tools")
    async def tools(interaction: discord.Interaction) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)
        registered = await bot.api("GET", "/api/tools")
        lines = [
            f"{'✅' if item.get('name') in bot.enabled_tools else '⬜'} `{item.get('name')}`"
            for item in sorted(registered, key=lambda value: value.get("name", ""))
        ]
        await interaction.followup.send(
            embed=discord.Embed(title="Discord Tool Allowlist", description="\n".join(lines))
        )

    @bot.tree.command(name="tool_toggle", description="Enable or disable a tool")
    async def tool_toggle(interaction: discord.Interaction, tool: str) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)
        enabled = tool not in bot.enabled_tools
        if enabled:
            bot.enabled_tools.add(tool)
        else:
            bot.enabled_tools.discard(tool)
        bot.save_state()
        await interaction.followup.send(f"Tool `{tool}` {'enabled' if enabled else 'disabled'}.")

    @tool_toggle.autocomplete("tool")
    async def tool_autocomplete(
        _: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        try:
            registered = await bot.api("GET", "/api/tools")
            names = [item.get("name", "") for item in registered]
        except Exception:
            names = sorted(bot.enabled_tools)
        needle = current.casefold()
        return [app_commands.Choice(name=name, value=name) for name in names if needle in name.casefold()][
            :25
        ]

    @bot.tree.command(name="model", description="Set or view the model override for this channel")
    async def model(interaction: discord.Interaction, model: Optional[str] = None) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)
        channel_id = str(interaction.channel_id)
        if model is None:
            await interaction.followup.send(
                f"**Current model:** `{bot.channel_models.get(channel_id, '(daemon default)')}`"
            )
            return
        if model.casefold() == "reset":
            bot.channel_models.pop(channel_id, None)
            text = "Model override cleared — using daemon default."
        else:
            bot.channel_models[channel_id] = model
            text = f"Model set to `{model}` for this channel."
        bot.save_state()
        await interaction.followup.send(text)

    @model.autocomplete("model")
    async def model_autocomplete(
        _: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        entries = rank_model_autocomplete([], current)
        try:
            data = await bot.api("GET", "/api/models")
            entries = rank_model_autocomplete(data.get("providers", []), current)
        except Exception:
            log.exception("model autocomplete failed")
        return [app_commands.Choice(name=value, value=value) for value in entries]

    @bot.tree.command(name="session", description="Show this channel's ClawForge session info")
    async def session(interaction: discord.Interaction) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)
        channel_id = str(interaction.channel_id)
        session_id = await bot.ensure_session(
            channel_id, getattr(interaction.channel, "name", channel_id)
        )
        sessions = await bot.api("GET", "/api/sessions")
        info = next((item for item in sessions if item.get("id") == session_id), {})
        persona_data = await bot.api("GET", f"/api/persona?session_id={session_id}")
        embed = discord.Embed(title=f"Session: {getattr(interaction.channel, 'name', channel_id)}")
        embed.add_field(name="ID", value=f"`{session_id}`", inline=False)
        embed.add_field(name="Messages", value=str(info.get("message_count", 0)))
        embed.add_field(name="Persona", value=f"`{persona_data.get('active', 'default')}`")
        embed.add_field(name="Model", value=f"`{bot.channel_models.get(channel_id, '(daemon default)')}`")
        embed.add_field(
            name="Require plans",
            value="yes" if bot.channel_plans_required.get(channel_id, True) else "no",
        )
        embed.add_field(
            name="Background job",
            value=f"`{bot.channel_jobs[interaction.channel_id][:8]}…`"
            if interaction.channel_id in bot.channel_jobs
            else "(none)",
        )
        await interaction.followup.send(embed=embed)

    @bot.tree.command(name="new_session", description="Start a fresh session for this channel")
    async def new_session(interaction: discord.Interaction) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)
        channel_id = str(interaction.channel_id)
        channel_name = getattr(interaction.channel, "name", channel_id)
        result = await bot.api(
            "POST", "/api/sessions/new", json={"name": f"discord-{channel_name}"}
        )
        bot.channel_sessions[channel_id] = result["id"]
        bot.save_state()
        await interaction.followup.send(f"New session started: `{result['id']}`")

    @bot.tree.command(name="cancel", description="Cancel this channel's active ClawForge job")
    async def cancel(interaction: discord.Interaction) -> None:
        job_id = bot.channel_jobs.get(interaction.channel_id)
        if not job_id:
            await interaction.response.send_message("No active job in this channel.", ephemeral=True)
            return
        try:
            result = await bot.rpc.call("cancel", job_id=job_id)
            text = "Cancellation requested." if result.get("cancelled") else "Job is no longer cancellable."
        except Exception as exc:
            text = f"Cancellation failed: {exc}"
        await interaction.response.send_message(text, ephemeral=True)

    respond_choices = [
        app_commands.Choice(name="Mention only", value="mention"),
        app_commands.Choice(name="Every message", value="all"),
    ]

    @bot.tree.command(name="respond_mode", description="Choose when the bot responds in this channel")
    @app_commands.choices(mode=respond_choices)
    async def respond_mode(
        interaction: discord.Interaction, mode: app_commands.Choice[str]
    ) -> None:
        channel_id = str(interaction.channel_id)
        if mode.value == "all":
            bot.channel_respond_all[channel_id] = True
        else:
            bot.channel_respond_all.pop(channel_id, None)
        bot.save_state()
        await interaction.response.send_message(
            f"Respond mode set to **{mode.value}** for this channel.", ephemeral=True
        )

    toggle_choices = [
        app_commands.Choice(name="On", value="on"),
        app_commands.Choice(name="Off", value="off"),
        app_commands.Choice(name="Status", value="status"),
    ]

    @bot.tree.command(name="require_plans", description="Toggle required plans for this channel")
    @app_commands.choices(mode=toggle_choices)
    async def require_plans(
        interaction: discord.Interaction, mode: app_commands.Choice[str]
    ) -> None:
        channel_id = str(interaction.channel_id)
        if mode.value != "status":
            bot.channel_plans_required[channel_id] = mode.value == "on"
            bot.save_state()
        enabled = bot.channel_plans_required.get(channel_id, True)
        await interaction.response.send_message(
            f"Require plans is **{'ON' if enabled else 'OFF'}** for this channel.", ephemeral=True
        )

    @bot.tree.command(name="autoapprove", description="Toggle global tool auto-approval")
    @app_commands.choices(mode=toggle_choices)
    async def autoapprove(
        interaction: discord.Interaction, mode: app_commands.Choice[str]
    ) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)
        if mode.value != "status":
            await bot.api(
                "POST", "/api/tools/autoapprove", json={"enabled": mode.value == "on"}
            )
        result = await bot.api("GET", "/api/tools/autoapprove")
        await interaction.followup.send(
            f"Auto-approve is **{'ON' if result.get('enabled') else 'OFF'}**."
        )

    @bot.tree.command(name="vision_model", description="Show or set the image-analysis model")
    async def vision_model(
        interaction: discord.Interaction, model: Optional[str] = None
    ) -> None:
        await interaction.response.defer(ephemeral=True, thinking=True)
        if model is not None:
            await bot.api("POST", "/api/vision", json={"model": model})
        result = await bot.api("GET", "/api/vision")
        embed = discord.Embed(title="Vision config")
        embed.add_field(name="Enabled", value="yes" if result.get("enabled") else "no")
        embed.add_field(name="Active model", value=f"`{result.get('model', '?')}`", inline=False)
        embed.add_field(
            name="Config default", value=f"`{result.get('default_model', '?')}`", inline=False
        )
        await interaction.followup.send(embed=embed)

    @bot.tree.command(name="restart", description="Schedule a ClawForge daemon rebuild and restart")
    @app_commands.default_permissions(administrator=True)
    async def restart(interaction: discord.Interaction) -> None:
        member = interaction.user
        if not isinstance(member, discord.Member) or not member.guild_permissions.administrator:
            await interaction.response.send_message("Only administrators can restart ClawForge.", ephemeral=True)
            return
        script = Path(
            os.environ.get("CLAWFORGE_REBUILD_SCRIPT", str(Path.home() / ".local/bin/clawforge-rebuild.sh"))
        )
        if not script.is_file():
            await interaction.response.send_message(f"Restart script not found: `{script}`", ephemeral=True)
            return
        await interaction.response.defer(ephemeral=True, thinking=True)
        process = await asyncio.create_subprocess_exec(
            "/bin/bash", str(script), "3", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        detail = (stdout if process.returncode == 0 else stderr).decode(errors="replace").strip()
        await interaction.followup.send(
            f"{'Restart scheduled' if process.returncode == 0 else 'Restart failed'}: `{detail or 'no details'}`"
        )

    @bot.tree.command(name="status", description="Show ClawForge daemon and Discord bridge status")
    async def status(interaction: discord.Interaction) -> None:
        await interaction.response.defer(ephemeral=True)
        try:
            result = await bot.api("GET", "/api/status")
            uptime = int(result.get("uptime_seconds", 0))
            hours, remainder = divmod(uptime, 3600)
            minutes, seconds = divmod(remainder, 60)
            embed = discord.Embed(title="ClawForge Daemon", color=0x57F287)
            embed.add_field(name="Version", value=result.get("version", "?"))
            embed.add_field(name="Active sessions", value=str(result.get("active_sessions", 0)))
            embed.add_field(name="Uptime", value=f"{hours}h {minutes}m {seconds}s")
            embed.add_field(name="Channels tracked", value=str(len(bot.channel_sessions)))
            embed.add_field(name="Active Discord jobs", value=str(len(bot.channel_jobs)))
        except Exception as exc:
            log.exception("Discord status request failed")
            await interaction.followup.send(f"ClawForge status request failed: {exc}", ephemeral=True)
            return
        await interaction.followup.send(embed=embed, ephemeral=True)

    @bot.tree.command(name="help", description="Show all ClawForge commands")
    async def help_command(interaction: discord.Interaction) -> None:
        embed = discord.Embed(title="ClawForge Commands")
        embed.add_field(
            name="Chat and sessions",
            value="`/ask` `/session` `/new_session` `/cancel` `/model` `/respond_mode`",
            inline=False,
        )
        embed.add_field(
            name="Personas",
            value="`/persona` `/persona_create` `/persona_delete`",
            inline=False,
        )
        embed.add_field(
            name="Tools and configuration",
            value="`/tools` `/tool_toggle` `/autoapprove` `/require_plans` `/vision_model`",
            inline=False,
        )
        embed.add_field(name="Daemon", value="`/status` `/restart`", inline=False)
        await interaction.response.send_message(embed=embed, ephemeral=True)


def resolve_token(token_file: str) -> str:
    """Resolve the Discord token without putting the secret on the command line."""
    if token_file:
        token = Path(token_file).read_text(encoding="utf-8").strip()
        if token:
            return token

    token = os.environ.get("DISCORD_TOKEN", "").strip()
    if token:
        return token

    dotenv_path = Path(__file__).resolve().parent.parent / ".env"
    try:
        for raw_line in dotenv_path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key.strip() == "DISCORD_TOKEN":
                return value.strip().strip("\"'")
    except FileNotFoundError:
        pass

    raise RuntimeError(
        "Discord token is missing; set discord.token_file, DISCORD_TOKEN, or DISCORD_TOKEN in .env"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="ClawForge Discord protocol transport")
    parser.add_argument("--token-file", default="")
    parser.add_argument("--guild-id", default="")
    parser.add_argument("--attachment-spool", default="data/discord_attachments")
    parser.add_argument("--max-attachment-bytes", type=int, default=25 * 1024 * 1024)
    parser.add_argument("--max-attachment-count", type=int, default=10)
    args = parser.parse_args()
    token = resolve_token(args.token_file)
    guild_id = int(args.guild_id) if args.guild_id else None
    bot = DiscordTransport(
        guild_id,
        Path(args.attachment_spool),
        args.max_attachment_bytes,
        args.max_attachment_count,
    )
    register_commands(bot)
    bot.run(token, log_handler=None)


if __name__ == "__main__":
    main()
