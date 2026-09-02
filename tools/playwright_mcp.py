#!/usr/bin/env python3
"""ClawForge wrapper for the Playwright MCP server.

Starts the Playwright MCP stdio server configured in ~/.codex/config.toml,
performs one or more MCP tool calls, returns compact JSON, then shuts it down.
"""

from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import sys
import threading
import time
import base64
from pathlib import Path
from typing import Any

try:
    import tomllib
except ImportError:  # pragma: no cover - Python <3.11 fallback
    tomllib = None


DEFAULT_COMMAND = ["npx", "-y", "@playwright/mcp@latest"]
PROTOCOL_VERSION = "2024-11-05"
OUTPUT_ROOT = Path("/tmp/clawforge_playwright_mcp")

ACTION_TOOL_MAP = {
    "navigate": "browser_navigate",
    "snapshot": "browser_snapshot",
    "screenshot": "browser_take_screenshot",
    "click": "browser_click",
    "type": "browser_type",
    "press_key": "browser_press_key",
    "wait": "browser_wait_for",
    "evaluate": "browser_evaluate",
    "resize": "browser_resize",
    "close": "browser_close",
}


class McpError(RuntimeError):
    pass


class McpClient:
    def __init__(self, command: list[str], timeout_s: float) -> None:
        self.command = command
        self.timeout_s = timeout_s
        self.next_id = 1
        self.stderr_chunks: list[str] = []
        self.proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=os.getcwd(),
        )
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=2)

    def _drain_stderr(self) -> None:
        if self.proc.stderr is None:
            return
        while True:
            data = self.proc.stderr.readline()
            if not data:
                return
            text = data.decode("utf-8", errors="replace").rstrip()
            if text:
                self.stderr_chunks.append(text)
                if len(self.stderr_chunks) > 80:
                    del self.stderr_chunks[:20]

    def request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        req_id = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}})
        deadline = time.monotonic() + self.timeout_s
        while time.monotonic() < deadline:
            msg = self._read_message(deadline)
            if msg is None:
                continue
            if msg.get("id") != req_id:
                continue
            if "error" in msg:
                raise McpError(json.dumps(msg["error"], ensure_ascii=False))
            return msg.get("result")
        raise TimeoutError(f"Timed out waiting for MCP response to {method}")

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def _send(self, payload: dict[str, Any]) -> None:
        if self.proc.stdin is None:
            raise McpError("MCP server stdin is closed")
        # MCP stdio uses one compact JSON-RPC message per line. It does not
        # use the Content-Length framing used by the Language Server Protocol.
        data = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.proc.stdin.write(data + b"\n")
        self.proc.stdin.flush()

    def _read_message(self, deadline: float) -> dict[str, Any] | None:
        if self.proc.stdout is None:
            raise McpError("MCP server stdout is closed")

        fd = self.proc.stdout.fileno()
        remaining = max(0.0, deadline - time.monotonic())
        ready, _, _ = select.select([fd], [], [], min(remaining, 0.25))
        if not ready:
            if self.proc.poll() is not None:
                raise McpError(
                    "MCP server exited early"
                    + (": " + "\n".join(self.stderr_chunks[-10:]) if self.stderr_chunks else "")
                )
            return None

        line = self.proc.stdout.readline()
        if not line:
            raise McpError("MCP server closed stdout")
        if not line.strip():
            return None
        try:
            return json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            preview = line[:300].decode("utf-8", errors="replace").rstrip()
            raise McpError(f"Invalid newline-delimited MCP message: {preview}") from exc


def load_playwright_command() -> list[str]:
    cfg = Path.home() / ".codex" / "config.toml"
    if tomllib is None or not cfg.exists():
        return DEFAULT_COMMAND
    try:
        data = tomllib.loads(cfg.read_text())
        server = data.get("mcp_servers", {}).get("playwright", {})
        command = server.get("command")
        args = server.get("args", [])
        if isinstance(command, str) and isinstance(args, list) and all(isinstance(x, str) for x in args):
            return [command, *args]
    except Exception:
        pass
    return DEFAULT_COMMAND


def ensure_headless_playwright_command(command: list[str]) -> list[str]:
    """Run the daemon's configured Playwright MCP browser without a GUI."""
    is_playwright_mcp = any(
        arg == "@playwright/mcp" or arg.startswith("@playwright/mcp@") for arg in command
    )
    if is_playwright_mcp and "--headless" not in command:
        return [*command, "--headless"]
    return command


def prefer_cached_playwright_command(command: list[str]) -> list[str]:
    """Bypass npx registry resolution when Playwright MCP is already cached."""
    if not command or Path(command[0]).name not in {"npx", "npx.cmd"}:
        return command

    package_index = next(
        (index for index, arg in enumerate(command) if arg == "@playwright/mcp" or arg.startswith("@playwright/mcp@")),
        None,
    )
    node = shutil.which("node")
    if package_index is None or node is None:
        return command

    npm_cache = Path(os.environ.get("npm_config_cache", Path.home() / ".npm"))
    candidates = list(npm_cache.glob("_npx/*/node_modules/@playwright/mcp/cli.js"))
    if not candidates:
        return command

    # npx cache directories are content-addressed. The newest CLI is the best
    # match for an @latest configuration, and launching it directly avoids a
    # registry lookup on every short-lived MCP invocation.
    cli = max(candidates, key=lambda path: path.stat().st_mtime)
    return [node, str(cli), *command[package_index + 1 :]]


def normalize_step(step: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    if "tool_name" in step:
        tool_name = str(step["tool_name"])
        args = step.get("arguments", {})
        if not isinstance(args, dict):
            raise ValueError("step.arguments must be an object")
        return tool_name, args

    action = str(step.get("action", ""))
    tool_name = ACTION_TOOL_MAP.get(action)
    if not tool_name:
        raise ValueError(f"Unknown step action: {action}")

    args = dict(step.get("arguments", {})) if isinstance(step.get("arguments", {}), dict) else {}
    for key in ("url", "element", "ref", "text", "key", "time", "function", "width", "height"):
        if key in step:
            args[key] = step[key]
    return tool_name, args


def compact_content(value: Any, max_chars: int = 12000) -> Any:
    if isinstance(value, str):
        return value if len(value) <= max_chars else value[:max_chars] + f"\n...[truncated {len(value) - max_chars} chars]"
    if isinstance(value, list):
        return [compact_content(v, max_chars) for v in value]
    if isinstance(value, dict):
        return {k: compact_content(v, max_chars) for k, v in value.items()}
    return value


def extension_for_mime(mime: str) -> str:
    return {
        "image/png": ".png",
        "image/jpeg": ".jpg",
        "image/jpg": ".jpg",
        "image/webp": ".webp",
        "image/gif": ".gif",
    }.get(mime.lower(), ".png")


def materialize_inline_images(value: Any, label: str, counter: list[int]) -> Any:
    """Write MCP inline image blocks to /tmp and replace base64 with paths."""
    if isinstance(value, list):
        return [materialize_inline_images(item, label, counter) for item in value]

    if isinstance(value, dict):
        mime = value.get("mimeType") or value.get("mime_type") or "image/png"
        data = value.get("data")
        if value.get("type") == "image" and isinstance(data, str):
            try:
                raw = base64.b64decode(data, validate=False)
            except Exception:
                return {**value, "data": "[invalid base64 image data omitted]"}

            OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
            counter[0] += 1
            ext = extension_for_mime(str(mime))
            path = OUTPUT_ROOT / f"{int(time.time() * 1000)}_{label}_{counter[0]}{ext}"
            path.write_bytes(raw)
            return {
                "type": "image",
                "mimeType": mime,
                "path": str(path),
                "bytes": len(raw),
                "vision_next_step": "Call vision_read with this path to inspect/OCR the screenshot.",
            }
        return {key: materialize_inline_images(item, label, counter) for key, item in value.items()}

    return value


def main() -> int:
    try:
        params = json.loads(sys.argv[1] if len(sys.argv) > 1 else "{}")
    except json.JSONDecodeError as exc:
        print(json.dumps({"success": False, "error": f"Invalid JSON: {exc}"}))
        return 1

    timeout_ms = int(params.get("timeout_ms", 30000))
    timeout_s = max(3.0, min(timeout_ms / 1000.0, 120.0))
    command = params.get("command")
    if isinstance(command, list) and all(isinstance(x, str) for x in command):
        mcp_command = command
    else:
        configured_command = ensure_headless_playwright_command(load_playwright_command())
        mcp_command = prefer_cached_playwright_command(configured_command)

    action = params.get("action", "run")
    client = McpClient(mcp_command, timeout_s)
    try:
        init = client.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "clawforge-playwright-mcp", "version": "0.1.0"},
            },
        )
        client.notify("notifications/initialized")

        if action == "list_tools":
            result = client.request("tools/list", {})
            print(json.dumps({"success": True, "command": mcp_command, "initialize": init, "tools": result}, ensure_ascii=False))
            return 0

        if action == "call":
            tool_name = params.get("tool_name")
            if not isinstance(tool_name, str) or not tool_name:
                raise ValueError("tool_name is required for action=call")
            arguments = params.get("arguments", {})
            if not isinstance(arguments, dict):
                raise ValueError("arguments must be an object")
            steps = [{"tool_name": tool_name, "arguments": arguments}]
        else:
            raw_steps = params.get("steps")
            if not isinstance(raw_steps, list) or not raw_steps:
                raise ValueError("steps array is required for action=run")
            steps = raw_steps

        outputs: list[dict[str, Any]] = []
        for index, raw_step in enumerate(steps, start=1):
            if not isinstance(raw_step, dict):
                raise ValueError("each step must be an object")
            tool_name, arguments = normalize_step(raw_step)
            started = time.monotonic()
            raw_result = client.request("tools/call", {"name": tool_name, "arguments": arguments})
            result = materialize_inline_images(raw_result, f"step{index}", [0])
            outputs.append(
                {
                    "step": index,
                    "tool_name": tool_name,
                    "arguments": arguments,
                    "elapsed_ms": int((time.monotonic() - started) * 1000),
                    "result": compact_content(result),
                }
            )

        print(json.dumps({"success": True, "command": mcp_command, "results": outputs}, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(
            json.dumps(
                {
                    "success": False,
                    "command": mcp_command,
                    "error": str(exc),
                    "stderr_tail": client.stderr_chunks[-20:],
                },
                ensure_ascii=False,
            )
        )
        return 1
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
