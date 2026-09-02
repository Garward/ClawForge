#!/usr/bin/env python3
"""
Visual frontend audit tool for ClawForge.

First pass:
- Render URL/local HTML targets with Playwright.
- Capture desktop/tablet/mobile screenshots.
- Collect DOM boxes, visible text, console/page errors, and layout heuristics.
- Audit static image/screenshot paths enough to hand them to a vision model.

This is deliberately evidence-oriented: the tool finds hard visual/layout
signals and returns screenshot paths; the LLM can then critique and prioritize.
"""

from __future__ import annotations

import asyncio
import json
import mimetypes
import os
import re
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlparse

try:
    from playwright.async_api import async_playwright

    PLAYWRIGHT_AVAILABLE = True
except Exception:
    async_playwright = None
    PLAYWRIGHT_AVAILABLE = False


DEFAULT_VIEWPORTS = {
    "desktop": {"width": 1440, "height": 900},
    "tablet": {"width": 1024, "height": 768},
    "mobile": {"width": 390, "height": 844},
}

INTERACTIVE_TAGS = {"A", "BUTTON", "INPUT", "SELECT", "TEXTAREA", "SUMMARY"}
OUTPUT_ROOT = Path("/tmp/clawforge_visual_audit")


@dataclass
class Issue:
    severity: str
    type: str
    message: str
    viewport: Optional[str] = None
    selector: Optional[str] = None
    evidence: Optional[dict[str, Any]] = None


def main() -> int:
    if len(sys.argv) < 2:
        print('Usage: visual_audit.py \'{"target":"http://127.0.0.1:5173"}\'')
        return 1

    try:
        params = json.loads(sys.argv[1])
    except json.JSONDecodeError:
        print(json.dumps({"success": False, "error": "Invalid JSON input"}))
        return 1

    result = run(params)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if result.get("success") else 1


def run(params: dict[str, Any]) -> dict[str, Any]:
    target = str(params.get("target") or params.get("url") or params.get("path") or "").strip()
    if not target:
        return {"success": False, "error": "Missing target/url/path"}

    target_type = str(params.get("target_type") or "auto").lower()
    viewports = parse_viewports(params.get("viewports"))
    wait_ms = clamp_int(params.get("wait_ms", 800), 0, 10000, 800)
    timeout_ms = clamp_int(params.get("timeout_ms", 20000), 1000, 60000, 20000)
    full_page = parse_bool(params.get("full_page"), True)
    max_elements = clamp_int(params.get("max_elements", 80), 10, 300, 80)
    prompt = str(params.get("prompt") or "")

    resolved = resolve_target(target, target_type)
    if not resolved["ok"]:
        return {"success": False, "error": resolved["error"], "target": target}

    output_dir = make_output_dir()
    if resolved["kind"] == "image":
        return audit_static_image(resolved["target"], output_dir, prompt)

    if not PLAYWRIGHT_AVAILABLE:
        return {
            "success": False,
            "error": "Playwright is not available. Install with `pip install playwright` and `playwright install chromium`.",
            "target": target,
            "target_type": resolved["kind"],
        }

    return asyncio.run(
        audit_rendered_target(
            resolved["target"],
            output_dir,
            viewports,
            wait_ms=wait_ms,
            timeout_ms=timeout_ms,
            full_page=full_page,
            max_elements=max_elements,
            prompt=prompt,
        )
    )


async def audit_rendered_target(
    target: str,
    output_dir: Path,
    viewports: dict[str, dict[str, int]],
    wait_ms: int,
    timeout_ms: int,
    full_page: bool,
    max_elements: int,
    prompt: str,
) -> dict[str, Any]:
    all_issues: list[Issue] = []
    captures: list[dict[str, Any]] = []
    warnings: list[str] = []

    async with async_playwright() as p:
        try:
            browser = await p.chromium.launch(
                headless=True,
                args=[
                    "--no-sandbox",
                    "--disable-setuid-sandbox",
                    "--disable-dev-shm-usage",
                    "--disable-gpu",
                    "--disable-blink-features=AutomationControlled",
                    "--no-first-run",
                    "--disable-extensions",
                ],
            )
        except Exception as exc:
            return {
                "success": False,
                "error": f"Could not launch Playwright Chromium: {exc}",
                "target": target,
                "target_type": "rendered",
                "output_dir": str(output_dir),
                "warnings": [
                    "Rendered visual audits require a host environment that allows Chromium to launch. "
                    "Static image targets still work without Playwright."
                ],
            }
        try:
            for name, viewport in viewports.items():
                context = await browser.new_context(
                    viewport=viewport,
                    device_scale_factor=1,
                    ignore_https_errors=True,
                )
                page = await context.new_page()
                console_errors: list[str] = []
                page_errors: list[str] = []
                failed_requests: list[str] = []

                page.on("console", lambda msg: console_errors.append(msg.text) if msg.type == "error" else None)
                page.on("pageerror", lambda exc: page_errors.append(str(exc)))
                page.on("requestfailed", lambda req: failed_requests.append(req.url))

                started = time.time()
                try:
                    await page.goto(target, wait_until="networkidle", timeout=timeout_ms)
                except Exception as exc:
                    warnings.append(f"{name}: navigation warning: {exc}")
                    try:
                        await page.goto(target, wait_until="domcontentloaded", timeout=timeout_ms)
                    except Exception as retry_exc:
                        all_issues.append(
                            Issue(
                                severity="high",
                                type="navigation_failed",
                                message=f"Could not load target in {name}: {retry_exc}",
                                viewport=name,
                            )
                        )
                        await context.close()
                        continue

                if wait_ms > 0:
                    await page.wait_for_timeout(wait_ms)

                screenshot_path = output_dir / f"{name}.png"
                await page.screenshot(path=str(screenshot_path), full_page=full_page)

                metrics = await page.evaluate(JS_AUDIT, {"maxElements": max_elements})
                title = await page.title()
                capture_issues = issues_from_metrics(name, metrics, console_errors, page_errors, failed_requests)
                all_issues.extend(capture_issues)

                captures.append(
                    {
                        "viewport": name,
                        "width": viewport["width"],
                        "height": viewport["height"],
                        "title": title,
                        "url": page.url,
                        "screenshot": str(screenshot_path),
                        "load_ms": round((time.time() - started) * 1000),
                        "metrics": compact_metrics(metrics),
                        "top_elements": metrics.get("elements", [])[:20],
                        "console_errors": console_errors[:20],
                        "page_errors": page_errors[:10],
                        "failed_requests": failed_requests[:20],
                    }
                )
                await context.close()
        finally:
            await browser.close()

    issue_dicts = [asdict(issue) for issue in rank_issues(all_issues)]
    return {
        "success": True,
        "target": target,
        "target_type": "rendered",
        "output_dir": str(output_dir),
        "prompt": prompt,
        "captures": captures,
        "issues": issue_dicts,
        "summary": summarize(issue_dicts, captures),
        "warnings": warnings,
        "vision_next_step": {
            "recommended": True,
            "instructions": (
                "Send the screenshot paths plus issues to a strong vision model. Ask it to judge hierarchy, "
                "spacing, clipping, visual polish, responsive behavior, and whether the UI matches the target product style."
            ),
        },
    }


def audit_static_image(image_path: str, output_dir: Path, prompt: str) -> dict[str, Any]:
    path = Path(image_path).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    if not path.is_file():
        return {"success": False, "error": f"Image not found: {path}"}

    copied = output_dir / path.name
    try:
        copied.write_bytes(path.read_bytes())
    except Exception:
        copied = path

    width, height, image_type = image_dimensions(path)
    issues: list[Issue] = []
    if width and height:
        if width < 320 or height < 240:
            issues.append(
                Issue(
                    severity="medium",
                    type="low_resolution",
                    message="Screenshot is low resolution; visual judging may miss layout/detail issues.",
                    evidence={"width": width, "height": height},
                )
            )
        aspect = width / max(1, height)
        if aspect > 3.0 or aspect < 0.25:
            issues.append(
                Issue(
                    severity="low",
                    type="unusual_aspect_ratio",
                    message="Screenshot has an unusual aspect ratio; include viewport/device context for the vision judge.",
                    evidence={"width": width, "height": height, "aspect_ratio": round(aspect, 3)},
                )
            )

    return {
        "success": True,
        "target": str(path),
        "target_type": "image",
        "output_dir": str(output_dir),
        "prompt": prompt,
        "captures": [
            {
                "viewport": "static_image",
                "width": width,
                "height": height,
                "image_type": image_type,
                "screenshot": str(copied),
                "metrics": {"mode": "static_image", "file_size": path.stat().st_size},
            }
        ],
        "issues": [asdict(issue) for issue in issues],
        "summary": f"Prepared static image for visual audit ({width or '?'}x{height or '?'}, {image_type or 'unknown'}).",
        "warnings": [],
        "vision_next_step": {
            "recommended": True,
            "instructions": (
                "Use the screenshot path with a vision model. Ask for layout, hierarchy, polish, clipping, "
                "legibility, affordance, and responsive-context gaps. Static images do not expose DOM boxes."
            ),
        },
    }


JS_AUDIT = r"""
({ maxElements }) => {
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const doc = document.documentElement;
  const body = document.body;

  function visible(el, rect) {
    const style = window.getComputedStyle(el);
    const intersectsViewport = rect.right > 0 && rect.left < vw && rect.bottom > 0 && rect.top < vh;
    return style && style.visibility !== 'hidden' && style.display !== 'none' &&
      Number(style.opacity || 1) > 0.01 && rect.width > 0 && rect.height > 0 && intersectsViewport;
  }

  function selectorFor(el) {
    if (el.id) return '#' + CSS.escape(el.id);
    const cls = Array.from(el.classList || []).slice(0, 2).map(c => '.' + CSS.escape(c)).join('');
    const tag = el.tagName.toLowerCase();
    return tag + cls;
  }

  function roleFor(el) {
    return el.getAttribute('role') || '';
  }

  function labelFor(el) {
    return el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('alt') || '';
  }

  function colorParts(value) {
    const m = String(value).match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const nums = m[1].split(',').map(x => Number.parseFloat(x.trim()));
    if (nums.length < 3) return null;
    return { r: nums[0], g: nums[1], b: nums[2], a: nums.length > 3 ? nums[3] : 1 };
  }

  function relLum(c) {
    const vals = [c.r, c.g, c.b].map(v => {
      v = v / 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * vals[0] + 0.7152 * vals[1] + 0.0722 * vals[2];
  }

  function contrast(fg, bg) {
    const f = colorParts(fg);
    const b = colorParts(bg);
    if (!f || !b || b.a === 0) return null;
    const l1 = relLum(f);
    const l2 = relLum(b);
    return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
  }

  function effectiveBg(el) {
    let cur = el;
    while (cur && cur !== document) {
      const bg = window.getComputedStyle(cur).backgroundColor;
      const c = colorParts(bg);
      if (c && c.a > 0.05) return bg;
      cur = cur.parentElement;
    }
    return 'rgb(255,255,255)';
  }

  const elements = [];
  const clipped = [];
  const offscreen = [];
  const smallTargets = [];
  const lowContrast = [];
  const fixed = [];

  for (const el of Array.from(document.querySelectorAll('body *'))) {
    const rect = el.getBoundingClientRect();
    if (!visible(el, rect)) continue;
    const style = window.getComputedStyle(el);
    const text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
    const tag = el.tagName;
    const interactive = ['A', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'SUMMARY'].includes(tag) ||
      el.hasAttribute('onclick') || roleFor(el).match(/button|link|checkbox|tab|menuitem|switch/);
    const selector = selectorFor(el);

    if ((el.scrollWidth > el.clientWidth + 2 || el.scrollHeight > el.clientHeight + 2) && text.length > 0) {
      clipped.push({ selector, tag, text: text.slice(0, 120), rect: rectJson(rect), scrollWidth: el.scrollWidth, clientWidth: el.clientWidth, scrollHeight: el.scrollHeight, clientHeight: el.clientHeight });
    }

    if (rect.right < 0 || rect.left > vw || rect.bottom < 0 || rect.top > vh) {
      offscreen.push({ selector, tag, text: text.slice(0, 80), rect: rectJson(rect) });
    }

    if (interactive && (rect.width < 44 || rect.height < 36)) {
      smallTargets.push({ selector, tag, text: text.slice(0, 80) || labelFor(el), rect: rectJson(rect) });
    }

    if (text.length > 0 && rect.width > 12 && rect.height > 8) {
      const ratio = contrast(style.color, effectiveBg(el));
      const fontSize = Number.parseFloat(style.fontSize || '16');
      if (ratio !== null && ratio < (fontSize >= 18 ? 3.0 : 4.5)) {
        lowContrast.push({ selector, tag, text: text.slice(0, 80), contrast: Math.round(ratio * 100) / 100, color: style.color, background: effectiveBg(el), fontSize });
      }
    }

    if (style.position === 'fixed' || style.position === 'sticky') {
      fixed.push({ selector, tag, text: text.slice(0, 80), position: style.position, rect: rectJson(rect), zIndex: style.zIndex });
    }

    const useful = interactive || ['H1', 'H2', 'H3', 'NAV', 'MAIN', 'HEADER', 'FOOTER', 'FORM', 'LABEL'].includes(tag) || text.length > 0;
    if (useful && elements.length < maxElements) {
      elements.push({
        selector,
        tag,
        role: roleFor(el),
        label: labelFor(el),
        text: text.slice(0, 180),
        interactive,
        rect: rectJson(rect),
        fontSize: style.fontSize,
        fontWeight: style.fontWeight,
        color: style.color,
        background: effectiveBg(el),
      });
    }
  }

  const overlaps = [];
  const interactives = elements.filter(e => e.interactive && e.rect.width > 0 && e.rect.height > 0).slice(0, 80);
  for (let i = 0; i < interactives.length; i++) {
    for (let j = i + 1; j < interactives.length; j++) {
      const a = interactives[i], b = interactives[j];
      const area = overlapArea(a.rect, b.rect);
      if (area > 32) overlaps.push({ a: a.selector, b: b.selector, area, aText: a.text, bText: b.text });
      if (overlaps.length >= 20) break;
    }
    if (overlaps.length >= 20) break;
  }

  return {
    viewport: { width: vw, height: vh },
    document: {
      scrollWidth: doc.scrollWidth,
      scrollHeight: doc.scrollHeight,
      bodyScrollWidth: body ? body.scrollWidth : 0,
      bodyScrollHeight: body ? body.scrollHeight : 0,
      title: document.title,
      lang: doc.lang || '',
    },
    counts: {
      visibleElements: elements.length,
      buttons: document.querySelectorAll('button,[role=button]').length,
      links: document.querySelectorAll('a[href]').length,
      inputs: document.querySelectorAll('input,textarea,select').length,
      images: document.querySelectorAll('img').length,
      headings: document.querySelectorAll('h1,h2,h3,h4,h5,h6').length,
    },
    elements,
    clipped: clipped.slice(0, 30),
    offscreen: offscreen.slice(0, 30),
    smallTargets: smallTargets.slice(0, 30),
    lowContrast: lowContrast.slice(0, 30),
    fixed: fixed.slice(0, 20),
    overlaps,
    visibleTextSample: (document.body ? document.body.innerText : '').replace(/\s+/g, ' ').trim().slice(0, 2500),
  };

  function rectJson(rect) {
    return { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height), top: Math.round(rect.top), left: Math.round(rect.left), right: Math.round(rect.right), bottom: Math.round(rect.bottom) };
  }

  function overlapArea(a, b) {
    const x = Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left));
    const y = Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
    return Math.round(x * y);
  }
}
"""


def issues_from_metrics(
    viewport: str,
    metrics: dict[str, Any],
    console_errors: list[str],
    page_errors: list[str],
    failed_requests: list[str],
) -> list[Issue]:
    issues: list[Issue] = []
    doc = metrics.get("document", {})
    vp = metrics.get("viewport", {})
    if doc.get("scrollWidth", 0) > vp.get("width", 0) + 2:
        issues.append(
            Issue(
                severity="high",
                type="horizontal_overflow",
                message="Document is wider than the viewport; users may see horizontal scrolling or clipped layout.",
                viewport=viewport,
                evidence={"viewport_width": vp.get("width"), "scroll_width": doc.get("scrollWidth")},
            )
        )

    for item in metrics.get("clipped", [])[:10]:
        issues.append(
            Issue(
                severity="high",
                type="clipped_content",
                message="Visible text/content appears clipped or overflowing its element.",
                viewport=viewport,
                selector=item.get("selector"),
                evidence=item,
            )
        )

    for item in metrics.get("smallTargets", [])[:10]:
        issues.append(
            Issue(
                severity="medium",
                type="small_tap_target",
                message="Interactive target is smaller than comfortable touch/click sizing.",
                viewport=viewport,
                selector=item.get("selector"),
                evidence=item,
            )
        )

    for item in metrics.get("lowContrast", [])[:10]:
        issues.append(
            Issue(
                severity="medium",
                type="low_contrast",
                message="Text contrast appears below common WCAG thresholds.",
                viewport=viewport,
                selector=item.get("selector"),
                evidence=item,
            )
        )

    for item in metrics.get("overlaps", [])[:10]:
        issues.append(
            Issue(
                severity="medium",
                type="interactive_overlap",
                message="Interactive elements overlap each other.",
                viewport=viewport,
                selector=item.get("a"),
                evidence=item,
            )
        )

    for item in metrics.get("offscreen", [])[:5]:
        issues.append(
            Issue(
                severity="low",
                type="offscreen_visible_element",
                message="A visible element is positioned outside the viewport.",
                viewport=viewport,
                selector=item.get("selector"),
                evidence=item,
            )
        )

    for error in page_errors[:5]:
        issues.append(Issue(severity="high", type="page_error", message=error, viewport=viewport))
    for error in console_errors[:5]:
        issues.append(Issue(severity="medium", type="console_error", message=error, viewport=viewport))
    for url in failed_requests[:5]:
        issues.append(Issue(severity="low", type="failed_request", message="Page request failed", viewport=viewport, evidence={"url": url}))

    return issues


def compact_metrics(metrics: dict[str, Any]) -> dict[str, Any]:
    return {
        "viewport": metrics.get("viewport"),
        "document": metrics.get("document"),
        "counts": metrics.get("counts"),
        "issue_counts": {
            "clipped": len(metrics.get("clipped", [])),
            "offscreen": len(metrics.get("offscreen", [])),
            "smallTargets": len(metrics.get("smallTargets", [])),
            "lowContrast": len(metrics.get("lowContrast", [])),
            "overlaps": len(metrics.get("overlaps", [])),
            "fixed": len(metrics.get("fixed", [])),
        },
        "visibleTextSample": metrics.get("visibleTextSample", ""),
    }


def rank_issues(issues: list[Issue]) -> list[Issue]:
    order = {"high": 0, "medium": 1, "low": 2}
    return sorted(issues, key=lambda issue: (order.get(issue.severity, 9), issue.viewport or "", issue.type))[:80]


def summarize(issues: list[dict[str, Any]], captures: list[dict[str, Any]]) -> str:
    high = sum(1 for issue in issues if issue.get("severity") == "high")
    medium = sum(1 for issue in issues if issue.get("severity") == "medium")
    low = sum(1 for issue in issues if issue.get("severity") == "low")
    viewports = ", ".join(capture["viewport"] for capture in captures)
    return f"Captured {len(captures)} viewport(s) ({viewports}). Issues: {high} high, {medium} medium, {low} low."


def resolve_target(target: str, target_type: str) -> dict[str, Any]:
    if target_type == "auto":
        if is_url(target):
            target_type = "url"
        else:
            suffix = Path(target).suffix.lower()
            if suffix in {".png", ".jpg", ".jpeg", ".gif", ".webp"}:
                target_type = "image"
            else:
                target_type = "file"

    if target_type == "url":
        if not is_url(target):
            return {"ok": False, "error": "URL target must start with http:// or https://"}
        return {"ok": True, "kind": "url", "target": target}

    if target_type == "image":
        return {"ok": True, "kind": "image", "target": target}

    if target_type in {"file", "html"}:
        path = Path(target).expanduser()
        if not path.is_absolute():
            path = Path.cwd() / path
        if not path.exists():
            return {"ok": False, "error": f"File target not found: {path}"}
        return {"ok": True, "kind": "file", "target": path.resolve().as_uri()}

    return {"ok": False, "error": f"Unsupported target_type: {target_type}"}


def parse_viewports(value: Any) -> dict[str, dict[str, int]]:
    if not value:
        return DEFAULT_VIEWPORTS
    out: dict[str, dict[str, int]] = {}
    if isinstance(value, list):
        for item in value:
            if isinstance(item, str) and item in DEFAULT_VIEWPORTS:
                out[item] = DEFAULT_VIEWPORTS[item]
            elif isinstance(item, dict):
                name = str(item.get("name") or f"{item.get('width')}x{item.get('height')}")
                width = clamp_int(item.get("width"), 240, 3840, 1440)
                height = clamp_int(item.get("height"), 240, 3000, 900)
                out[name] = {"width": width, "height": height}
    return out or DEFAULT_VIEWPORTS


def make_output_dir() -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    output_dir = OUTPUT_ROOT / f"audit-{stamp}-{os.getpid()}"
    output_dir.mkdir(parents=True, exist_ok=True)
    return output_dir


def is_url(target: str) -> bool:
    parsed = urlparse(target)
    return parsed.scheme in {"http", "https"}


def parse_bool(value: Any, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() in {"1", "true", "yes", "on"}
    if value is None:
        return default
    return bool(value)


def clamp_int(value: Any, low: int, high: int, default: int) -> int:
    try:
        parsed = int(value)
    except Exception:
        return default
    return max(low, min(high, parsed))


def image_dimensions(path: Path) -> tuple[Optional[int], Optional[int], Optional[str]]:
    data = path.read_bytes()[:64]
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24:
        return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big"), "png"
    if data.startswith(b"GIF87a") or data.startswith(b"GIF89a"):
        return int.from_bytes(data[6:8], "little"), int.from_bytes(data[8:10], "little"), "gif"
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        dims = webp_dimensions(path)
        return dims[0], dims[1], "webp"
    if data.startswith(b"\xff\xd8"):
        dims = jpeg_dimensions(path)
        return dims[0], dims[1], "jpeg"
    mime, _ = mimetypes.guess_type(str(path))
    return None, None, mime or "unknown"


def jpeg_dimensions(path: Path) -> tuple[Optional[int], Optional[int]]:
    data = path.read_bytes()
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        block_len = int.from_bytes(data[i + 2 : i + 4], "big")
        if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}:
            height = int.from_bytes(data[i + 5 : i + 7], "big")
            width = int.from_bytes(data[i + 7 : i + 9], "big")
            return width, height
        i += 2 + max(block_len, 2)
    return None, None


def webp_dimensions(path: Path) -> tuple[Optional[int], Optional[int]]:
    data = path.read_bytes()[:64]
    if data[12:16] == b"VP8X" and len(data) >= 30:
        width = 1 + int.from_bytes(data[24:27], "little")
        height = 1 + int.from_bytes(data[27:30], "little")
        return width, height
    return None, None


if __name__ == "__main__":
    raise SystemExit(main())
