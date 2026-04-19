#!/usr/bin/env python3
"""
Discord Channel History Tool for ClawForge
Fetches recent messages from a Discord channel using the bot token.
Useful for giving ClawForge ambient awareness of what's happening in a channel.
"""

import json
import sys
import os
import requests
from typing import Optional

DISCORD_API = "https://discord.com/api/v10"


def get_channel_history(
    channel_id: str,
    limit: int = 50,
    include_bots: bool = True,
    before: Optional[str] = None
) -> dict:
    token = os.environ.get("DISCORD_TOKEN")
    if not token:
        # fallback: try loading from .env relative to this script
        env_path = os.path.join(os.path.dirname(__file__), "..", ".env")
        if os.path.exists(env_path):
            with open(env_path) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("DISCORD_TOKEN="):
                        token = line.split("=", 1)[1].strip()
                        break

    if not token:
        return {"success": False, "error": "No DISCORD_TOKEN found in environment or .env"}

    headers = {
        "Authorization": f"Bot {token}",
        "Content-Type": "application/json"
    }

    params = {"limit": min(limit, 100)}
    if before:
        params["before"] = before

    try:
        resp = requests.get(
            f"{DISCORD_API}/channels/{channel_id}/messages",
            headers=headers,
            params=params,
            timeout=10
        )

        if resp.status_code == 401:
            return {"success": False, "error": "Invalid bot token or missing permissions"}
        if resp.status_code == 403:
            return {"success": False, "error": "Bot does not have access to this channel"}
        if resp.status_code == 404:
            return {"success": False, "error": f"Channel {channel_id} not found"}
        if resp.status_code != 200:
            return {"success": False, "error": f"Discord API error: {resp.status_code} {resp.text}"}

        messages = resp.json()

        # Discord returns newest first — reverse so it reads chronologically
        messages = list(reversed(messages))

        if not include_bots:
            messages = [m for m in messages if not m.get("author", {}).get("bot", False)]

        formatted = []
        for m in messages:
            author = m.get("author", {})
            username = author.get("global_name") or author.get("username", "unknown")
            is_bot = author.get("bot", False)
            content = m.get("content", "")
            timestamp = m.get("timestamp", "")[:19].replace("T", " ")  # YYYY-MM-DD HH:MM:SS

            # include embeds/attachments note if no text content
            if not content:
                if m.get("attachments"):
                    content = f"[{len(m['attachments'])} attachment(s)]"
                elif m.get("embeds"):
                    content = f"[embed: {m['embeds'][0].get('title', 'no title')}]"
                else:
                    content = "[no content]"

            formatted.append({
                "id": m["id"],
                "timestamp": timestamp,
                "author": username,
                "bot": is_bot,
                "content": content
            })

        # build a readable plain-text log too
        log_lines = []
        for msg in formatted:
            bot_tag = " [BOT]" if msg["bot"] else ""
            log_lines.append(f"[{msg['timestamp']}] {msg['author']}{bot_tag}: {msg['content']}")

        return {
            "success": True,
            "channel_id": channel_id,
            "count": len(formatted),
            "messages": formatted,
            "log": "\n".join(log_lines)
        }

    except requests.exceptions.Timeout:
        return {"success": False, "error": "Discord API request timed out"}
    except Exception as e:
        return {"success": False, "error": str(e)}


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python discord_history.py '{\"channel_id\":\"123456789\",\"limit\":50}'")
        sys.exit(1)

    try:
        params = json.loads(sys.argv[1])
        channel_id = params.get("channel_id", "")
        if not channel_id:
            print(json.dumps({"success": False, "error": "channel_id is required"}))
            sys.exit(1)

        result = get_channel_history(
            channel_id=channel_id,
            limit=params.get("limit", 50),
            include_bots=params.get("include_bots", True),
            before=params.get("before", None)
        )
        print(json.dumps(result, indent=2))

    except json.JSONDecodeError:
        print(json.dumps({"success": False, "error": "Invalid JSON input"}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e)}))
        sys.exit(1)
