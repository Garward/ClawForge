#!/usr/bin/env python3
"""
Evidence-oriented web research tool for ClawForge.

The tool keeps the old JSON CLI contract, but upgrades the work from
"search snippets" to "search, normalize, fetch, extract, and cite evidence".
It has no required API keys. DuckDuckGo HTML is still used as a fallback
search source, while page fetching/extraction provides the evidence.
"""

from __future__ import annotations

import hashlib
import html
import json
import os
import re
import sys
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any, Optional
from urllib.parse import parse_qs, quote, unquote, urlencode, urljoin, urlparse, urlunparse

import requests
from bs4 import BeautifulSoup

try:
    from browser_fetch import BrowserFetcher

    BROWSER_FETCH_AVAILABLE = True
except Exception:
    BrowserFetcher = None
    BROWSER_FETCH_AVAILABLE = False


USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
)

TRACKING_PARAMS = {
    "fbclid",
    "gclid",
    "mc_cid",
    "mc_eid",
    "mkt_tok",
    "ref",
    "spm",
}

MONTHS = {
    "jan": 1,
    "january": 1,
    "feb": 2,
    "february": 2,
    "mar": 3,
    "march": 3,
    "apr": 4,
    "april": 4,
    "may": 5,
    "jun": 6,
    "june": 6,
    "jul": 7,
    "july": 7,
    "aug": 8,
    "august": 8,
    "sep": 9,
    "sept": 9,
    "september": 9,
    "oct": 10,
    "october": 10,
    "nov": 11,
    "november": 11,
    "dec": 12,
    "december": 12,
}

HIGH_SIGNAL_DOMAINS = {
    "software": {
        "infoworld.com": 0.08,
        "github.blog": 0.08,
        "stackoverflow.blog": 0.07,
        "martinfowler.com": 0.07,
        "acm.org": 0.06,
        "ieee.org": 0.06,
        "arxiv.org": 0.05,
    },
    "hardware": {
        "anandtech.com": 0.08,
        "arstechnica.com": 0.07,
        "techpowerup.com": 0.07,
        "tomshardware.com": 0.07,
        "pcmag.com": 0.06,
        "gamersnexus.net": 0.06,
        "phoronix.com": 0.06,
    },
    "academic": {
        "arxiv.org": 0.09,
        "semanticscholar.org": 0.08,
        "pubmed.ncbi.nlm.nih.gov": 0.08,
        "dl.acm.org": 0.08,
        "ieeexplore.ieee.org": 0.08,
        "nature.com": 0.07,
        "science.org": 0.07,
    },
    "news": {
        "arstechnica.com": 0.06,
        "reuters.com": 0.06,
        "apnews.com": 0.06,
        "bbc.com": 0.05,
        "theverge.com": 0.04,
    },
}

LOW_SIGNAL_AGGREGATORS = {
    "aiagentstore.ai",
    "aiweekly.co",
    "xix.ai",
    "aiaiy.com",
}


@dataclass
class SearchResult:
    title: str
    url: str
    snippet: str
    source: str = "web"
    domain: str = ""
    date: Optional[str] = None
    relevance_score: float = 0.0
    excerpt: str = ""
    fetch_status: str = "not_fetched"
    content_chars: int = 0


class ResearchCache:
    def __init__(self, cache_dir: Optional[str] = None, ttl_seconds: int = 3600) -> None:
        root = cache_dir or os.environ.get("CLAWFORGE_RESEARCH_CACHE") or "/tmp/clawforge_research_cache"
        self.root = Path(root)
        self.ttl_seconds = ttl_seconds
        try:
            self.root.mkdir(parents=True, exist_ok=True)
        except OSError:
            self.root = Path("/tmp")

    def _path(self, namespace: str, key: str) -> Path:
        digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
        return self.root / f"{namespace}-{digest}.json"

    def get(self, namespace: str, key: str) -> Optional[dict[str, Any]]:
        path = self._path(namespace, key)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if time.time() - float(data.get("timestamp", 0)) > self.ttl_seconds:
                return None
            return data.get("value")
        except Exception:
            return None

    def set(self, namespace: str, key: str, value: dict[str, Any]) -> None:
        path = self._path(namespace, key)
        payload = {"timestamp": time.time(), "value": value}
        try:
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        except Exception:
            pass


class WebResearcher:
    def __init__(self, cache_ttl_seconds: int = 3600) -> None:
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": USER_AGENT, "Accept-Language": "en-US,en;q=0.9"})
        self.cache = ResearchCache(ttl_seconds=cache_ttl_seconds)
        self.warnings: list[str] = []

    def warn(self, message: str) -> None:
        if message not in self.warnings:
            self.warnings.append(message)

    def search_duckduckgo(self, query: str, max_results: int = 10, freshness: Optional[str] = None) -> list[SearchResult]:
        results: list[SearchResult] = []

        try:
            instant_url = f"https://api.duckduckgo.com/?q={quote(query)}&format=json&no_html=1"
            response = self.session.get(instant_url, timeout=8)
            if response.status_code == 200:
                data = response.json()
                if data.get("Abstract"):
                    url = normalize_url(data.get("AbstractURL", ""))
                    results.append(
                        SearchResult(
                            title=data.get("Heading", "DuckDuckGo Answer"),
                            url=url,
                            domain=get_domain(url),
                            snippet=clean_text(data["Abstract"])[:500],
                            source="instant_answer",
                            relevance_score=0.92,
                        )
                    )

                for topic in data.get("RelatedTopics", [])[:3]:
                    if isinstance(topic, dict) and topic.get("Text"):
                        url = normalize_url(topic.get("FirstURL", ""))
                        results.append(
                            SearchResult(
                                title=topic.get("FirstURL", "").split("/")[-1].replace("_", " ") or "Related topic",
                                url=url,
                                domain=get_domain(url),
                                snippet=clean_text(topic["Text"])[:350],
                                source="related_topic",
                                relevance_score=0.68,
                            )
                        )
        except Exception as exc:
            self.warn(f"DuckDuckGo instant answer failed: {exc}")

        if len(results) < max_results:
            results.extend(self._search_duckduckgo_web(query, max_results - len(results), freshness=freshness))

        return results[:max_results]

    def _search_duckduckgo_web(
        self,
        query: str,
        max_results: int,
        source: str = "web_search",
        freshness: Optional[str] = None,
    ) -> list[SearchResult]:
        cache_key = json.dumps({"q": query, "n": max_results, "freshness": freshness, "source": source}, sort_keys=True)
        cached = self.cache.get("search", cache_key)
        if cached:
            return [SearchResult(**item) for item in cached.get("results", [])]

        results: list[SearchResult] = []
        try:
            params = {"q": query}
            ddg_freshness = duckduckgo_freshness(freshness)
            if ddg_freshness:
                params["df"] = ddg_freshness
            search_url = f"https://html.duckduckgo.com/html/?{urlencode(params)}"
            response = self.session.get(search_url, timeout=12)
            if response.status_code != 200:
                self.warn(f"DuckDuckGo HTML returned HTTP {response.status_code}")
                return results

            soup = BeautifulSoup(response.content, "html.parser")
            for result_div in soup.select("div.result")[: max_results * 2]:
                title_elem = result_div.select_one("a.result__a")
                snippet_elem = result_div.select_one(".result__snippet")
                date_elem = result_div.select_one(".result__timestamp")
                if not title_elem:
                    continue

                title = clean_text(title_elem.get_text(" ", strip=True))
                url = normalize_url(title_elem.get("href", ""))
                if not title or not url:
                    continue

                snippet = clean_text(snippet_elem.get_text(" ", strip=True) if snippet_elem else "")
                date = clean_text(date_elem.get_text(" ", strip=True)) if date_elem else None
                results.append(
                    SearchResult(
                        title=title,
                        url=url,
                        domain=get_domain(url),
                        snippet=snippet[:500],
                        source=source,
                        date=date,
                        relevance_score=score_text(query, f"{title} {snippet}", base=0.72),
                    )
                )
                if len(results) >= max_results:
                    break
        except Exception as exc:
            self.warn(f"DuckDuckGo HTML search failed: {exc}")

        self.cache.set("search", cache_key, {"results": [asdict(result) for result in results]})
        return results

    def search_wikipedia(self, query: str, max_results: int = 5) -> list[SearchResult]:
        results: list[SearchResult] = []
        try:
            summary_url = "https://en.wikipedia.org/api/rest_v1/page/summary/" + quote(query.replace(" ", "_"))
            response = self.session.get(summary_url, timeout=8)
            if response.status_code == 200:
                data = response.json()
                title = data.get("title", "Wikipedia Article")
                extract = clean_text(data.get("extract", ""))
                if extract and wikipedia_match_ok(query, title, extract):
                    url = normalize_url(data.get("content_urls", {}).get("desktop", {}).get("page", ""))
                    results.append(
                        SearchResult(
                            title=title,
                            url=url,
                            domain=get_domain(url),
                            snippet=extract[:600],
                            excerpt=extract[:900],
                            source="wikipedia",
                            fetch_status="api_summary",
                            content_chars=len(extract),
                            relevance_score=0.86,
                        )
                    )

            if not results:
                search_api = (
                    "https://en.wikipedia.org/w/api.php?action=query&list=search&format=json"
                    f"&srlimit={max_results}&srsearch={quote(query)}"
                )
                response = self.session.get(search_api, timeout=8)
                if response.status_code == 200:
                    data = response.json()
                    for page in data.get("query", {}).get("search", []):
                        title = clean_text(page.get("title", ""))
                        snippet = clean_html_snippet(page.get("snippet", ""))
                        url = f"https://en.wikipedia.org/wiki/{quote(title.replace(' ', '_'))}"
                        results.append(
                            SearchResult(
                                title=title,
                                url=url,
                                domain="wikipedia.org",
                                snippet=snippet[:500],
                                source="wikipedia",
                                relevance_score=score_text(query, f"{title} {snippet}", base=0.70),
                            )
                        )
        except Exception as exc:
            self.warn(f"Wikipedia search failed: {exc}")

        return results[:max_results]

    def search_news(self, query: str, max_results: int = 5, freshness: Optional[str] = None) -> list[SearchResult]:
        news_query = f"{query} news"
        return self._search_duckduckgo_web(news_query, max_results, source="news", freshness=freshness or "month")

    def search_academic(self, query: str, max_results: int = 5) -> list[SearchResult]:
        results = self.search_arxiv(query, max_results=max(1, max_results // 2))
        if len(results) < max_results:
            ddg_query = f"{query} site:arxiv.org OR site:pubmed.ncbi.nlm.nih.gov OR site:semanticscholar.org OR site:acm.org OR site:ieee.org"
            results.extend(
                self._search_duckduckgo_web(ddg_query, max_results - len(results), source="academic")
            )
        return results[:max_results]

    def search_arxiv(self, query: str, max_results: int = 5) -> list[SearchResult]:
        results: list[SearchResult] = []
        try:
            url = (
                "https://export.arxiv.org/api/query?"
                f"search_query=all:{quote(query)}&start=0&max_results={max_results}"
            )
            response = self.session.get(url, timeout=10)
            if response.status_code != 200:
                self.warn(f"arXiv returned HTTP {response.status_code}")
                return results

            root = ET.fromstring(response.text)
            ns = {"atom": "http://www.w3.org/2005/Atom"}
            for entry in root.findall("atom:entry", ns):
                title = clean_text(entry.findtext("atom:title", default="", namespaces=ns))
                summary = clean_text(entry.findtext("atom:summary", default="", namespaces=ns))
                published = entry.findtext("atom:published", default="", namespaces=ns)[:10] or None
                link = ""
                for link_elem in entry.findall("atom:link", ns):
                    if link_elem.attrib.get("rel") == "alternate":
                        link = link_elem.attrib.get("href", "")
                        break
                link = normalize_url(link)
                results.append(
                    SearchResult(
                        title=title,
                        url=link,
                        domain=get_domain(link),
                        snippet=summary[:600],
                        excerpt=summary[:900],
                        source="arxiv",
                        date=published,
                        fetch_status="api_summary",
                        content_chars=len(summary),
                        relevance_score=score_text(query, f"{title} {summary}", base=0.82),
                    )
                )
        except Exception as exc:
            self.warn(f"arXiv search failed: {exc}")
        return results

    def fetch_result_pages(
        self,
        results: list[SearchResult],
        query: str,
        max_fetches: int = 5,
        use_browser_fallback: bool = False,
    ) -> None:
        fetched = 0
        for result in results:
            if fetched >= max_fetches:
                break
            if result.fetch_status != "not_fetched":
                continue
            if not result.url.startswith(("http://", "https://")):
                result.fetch_status = "skipped_non_http"
                continue

            fetched += 1
            page = self.fetch_page(result.url, query=query, use_browser_fallback=use_browser_fallback)
            result.fetch_status = page["status"]
            result.content_chars = int(page.get("content_chars", 0))
            if page.get("title") and len(result.title) < 8:
                result.title = str(page["title"])
            if page.get("date") and not result.date:
                result.date = str(page["date"])
            if page.get("excerpt"):
                result.excerpt = str(page["excerpt"])
                result.relevance_score = max(
                    result.relevance_score,
                    score_text(query, f"{result.title} {result.excerpt}", base=0.76),
                )

    def fetch_page(self, url: str, query: str, use_browser_fallback: bool = False) -> dict[str, Any]:
        normalized = normalize_url(url)
        cached = self.cache.get("fetch", normalized)
        if cached:
            cached["status"] = "cache_hit" if cached.get("status") == "fetched" else cached.get("status", "cache_hit")
            return cached

        result: dict[str, Any] = {"status": "fetch_failed", "content_chars": 0}
        try:
            response = self.session.get(normalized, timeout=9, stream=True, allow_redirects=True)
            content_type = response.headers.get("content-type", "")
            if response.status_code >= 400:
                result["status"] = f"http_{response.status_code}"
                self.warn(f"Fetch failed for {get_domain(normalized)}: HTTP {response.status_code}")
                return result
            if "text/html" not in content_type and "application/xhtml" not in content_type and "text/plain" not in content_type:
                result["status"] = f"skipped_content_type:{content_type.split(';')[0]}"
                return result

            chunks: list[bytes] = []
            total = 0
            max_bytes = 1_500_000
            for chunk in response.iter_content(chunk_size=32768):
                if not chunk:
                    continue
                chunks.append(chunk)
                total += len(chunk)
                if total >= max_bytes:
                    break

            body = b"".join(chunks)
            encoding = response.encoding or response.apparent_encoding or "utf-8"
            text = body.decode(encoding, errors="replace")
            extracted = extract_page(text, response.url, query)
            if extracted["content_chars"] < 400 and use_browser_fallback:
                browser_result = self.fetch_with_browser(normalized, query)
                if browser_result.get("content_chars", 0) > extracted["content_chars"]:
                    extracted = browser_result

            result = {
                "status": classify_extract_status(extracted),
                "title": extracted.get("title", ""),
                "date": extracted.get("date") or normalize_http_date(response.headers.get("last-modified")),
                "excerpt": extracted.get("excerpt", "") if classify_extract_status(extracted) in {"fetched", "browser_fetched"} else "",
                "content_chars": extracted.get("content_chars", 0),
            }
            if result["status"] in {"bot_check", "thin_extract", "empty_extract"}:
                self.warn(f"Could not extract strong evidence from {get_domain(normalized)}: {result['status']}")
            self.cache.set("fetch", normalized, result)
        except Exception as exc:
            result["status"] = "fetch_error"
            self.warn(f"Fetch error for {get_domain(normalized)}: {exc}")
        return result

    def fetch_with_browser(self, url: str, query: str) -> dict[str, Any]:
        if not BROWSER_FETCH_AVAILABLE or BrowserFetcher is None:
            return {"status": "browser_unavailable", "content_chars": 0}
        try:
            fetcher = BrowserFetcher(timeout_ms=12000, max_concurrent=1)
            browser_result = fetcher.fetch(url)
            if not browser_result.success:
                return {"status": "browser_failed", "content_chars": 0}
            return {
                "status": "browser_fetched",
                "title": browser_result.title,
                "date": None,
                "excerpt": choose_excerpt(browser_result.content, query),
                "content_chars": browser_result.content_length,
            }
        except Exception as exc:
            self.warn(f"Browser fallback failed for {get_domain(url)}: {exc}")
            return {"status": "browser_error", "content_chars": 0}


def research(
    query: str,
    search_type: str = "general",
    max_results: int = 10,
    include_wikipedia: bool = True,
    include_news: bool = False,
    fetch_pages: bool = True,
    max_fetches: int = 5,
    freshness: Optional[str] = None,
    use_browser_fallback: bool = False,
    cache_ttl_seconds: int = 3600,
) -> dict[str, Any]:
    researcher = WebResearcher(cache_ttl_seconds=cache_ttl_seconds)
    max_results = clamp_int(max_results, 1, 20, 10)
    max_fetches = clamp_int(max_fetches, 0, min(max_results, 10), 5)
    search_type = (search_type or "general").lower()

    try:
        if search_type == "general":
            web_results = researcher.search_duckduckgo(query, max(1, max_results - 2), freshness=freshness)
            all_results = web_results
            if include_wikipedia:
                all_results.extend(researcher.search_wikipedia(query, 2))
            if include_news:
                all_results.extend(researcher.search_news(query, 2, freshness=freshness))
        elif search_type == "wikipedia":
            all_results = researcher.search_wikipedia(query, max_results)
        elif search_type == "news":
            all_results = researcher.search_news(query, max_results, freshness=freshness)
        elif search_type == "academic":
            all_results = researcher.search_academic(query, max_results)
        else:
            all_results = researcher.search_duckduckgo(query, max_results, freshness=freshness)

        all_results = dedupe_results(all_results)
        apply_score_adjustments(all_results, query, search_type, freshness)
        all_results.sort(key=lambda item: item.relevance_score, reverse=True)
        all_results = all_results[:max_results]

        if fetch_pages:
            researcher.fetch_result_pages(
                all_results,
                query=query,
                max_fetches=max_fetches,
                use_browser_fallback=use_browser_fallback,
            )
            apply_score_adjustments(all_results, query, search_type, freshness)
            all_results.sort(
                key=lambda item: (
                    1 if item.excerpt else 0,
                    item.relevance_score,
                    item.content_chars,
                ),
                reverse=True,
            )

        formatted_results = [format_result(result) for result in all_results[:max_results]]
        evidence_count = sum(1 for result in all_results if is_evidence_result(result))

        return {
            "success": True,
            "query": query,
            "search_type": search_type,
            "freshness": freshness,
            "total_results": len(formatted_results),
            "evidence_results": evidence_count,
            "results": formatted_results,
            "warnings": researcher.warnings,
            "summary": (
                f"Found {len(formatted_results)} results for '{query}'"
                f"; extracted evidence from {evidence_count} page(s)"
            ),
        }
    except Exception as exc:
        return {
            "success": False,
            "error": f"Research error: {exc}",
            "query": query,
            "results": [],
            "warnings": researcher.warnings,
        }


def research_batch(
    queries: list[Any],
    search_type: str = "general",
    max_results: int = 6,
    include_wikipedia: bool = True,
    include_news: bool = False,
    fetch_pages: bool = True,
    max_fetches: int = 3,
    freshness: Optional[str] = None,
    use_browser_fallback: bool = False,
    cache_ttl_seconds: int = 3600,
    max_queries: int = 8,
    max_workers: int = 4,
    combined_max_results: int = 20,
) -> dict[str, Any]:
    normalized = normalize_batch_queries(
        queries,
        defaults={
            "search_type": search_type,
            "max_results": clamp_int(max_results, 1, 20, 6),
            "include_wikipedia": include_wikipedia,
            "include_news": include_news,
            "fetch_pages": fetch_pages,
            "max_fetches": clamp_int(max_fetches, 0, 10, 3),
            "freshness": freshness,
            "use_browser_fallback": use_browser_fallback,
            "cache_ttl_seconds": cache_ttl_seconds,
        },
        max_queries=clamp_int(max_queries, 1, 12, 8),
    )
    if not normalized:
        return {
            "success": False,
            "error": "Batch research requires at least one non-empty query.",
            "queries": [],
            "results": [],
            "warnings": [],
        }

    def run_one(spec: dict[str, Any]) -> dict[str, Any]:
        return research(
            query=spec["query"],
            search_type=spec["search_type"],
            max_results=spec["max_results"],
            include_wikipedia=spec["include_wikipedia"],
            include_news=spec["include_news"],
            fetch_pages=spec["fetch_pages"],
            max_fetches=spec["max_fetches"],
            freshness=spec["freshness"],
            use_browser_fallback=spec["use_browser_fallback"],
            cache_ttl_seconds=spec["cache_ttl_seconds"],
        )

    per_query: list[Optional[dict[str, Any]]] = [None] * len(normalized)
    workers = min(clamp_int(max_workers, 1, 8, 4), len(normalized))
    with ThreadPoolExecutor(max_workers=workers) as executor:
        future_to_index = {executor.submit(run_one, spec): i for i, spec in enumerate(normalized)}
        for future in as_completed(future_to_index):
            idx = future_to_index[future]
            try:
                per_query[idx] = future.result()
            except Exception as exc:
                per_query[idx] = {
                    "success": False,
                    "error": f"Batch query failed: {exc}",
                    "query": normalized[idx]["query"],
                    "results": [],
                    "warnings": [],
                }

    completed = [item for item in per_query if item is not None]
    combined = combine_batch_results(completed, clamp_int(combined_max_results, 1, 50, 20))
    warnings: list[str] = []
    for result in completed:
        for warning in result.get("warnings", []) or []:
            if warning not in warnings:
                warnings.append(warning)

    success_count = sum(1 for result in completed if result.get("success"))
    evidence_count = sum(int(result.get("evidence_results", 0) or 0) for result in completed)
    return {
        "success": success_count > 0,
        "queries": [spec["query"] for spec in normalized],
        "query_count": len(completed),
        "successful_queries": success_count,
        "evidence_results": evidence_count,
        "total_results": len(combined),
        "combined_results": combined,
        "per_query": completed,
        "warnings": warnings,
        "summary": (
            f"Ran {len(completed)} search queries; {success_count} succeeded; "
            f"combined {len(combined)} deduped result(s); extracted evidence from {evidence_count} page(s)"
        ),
    }


def normalize_batch_queries(queries: list[Any], defaults: dict[str, Any], max_queries: int) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for item in queries[:max_queries]:
        spec = dict(defaults)
        if isinstance(item, str):
            query = item.strip()
        elif isinstance(item, dict):
            query = str(item.get("query", "")).strip()
            if "search_type" in item:
                spec["search_type"] = str(item.get("search_type") or spec["search_type"]).lower()
            if "max_results" in item:
                spec["max_results"] = clamp_int(item.get("max_results"), 1, 20, spec["max_results"])
            if "include_wikipedia" in item:
                spec["include_wikipedia"] = parse_bool(item.get("include_wikipedia"), spec["include_wikipedia"])
            if "include_news" in item:
                spec["include_news"] = parse_bool(item.get("include_news"), spec["include_news"])
            if "fetch_pages" in item:
                spec["fetch_pages"] = parse_bool(item.get("fetch_pages"), spec["fetch_pages"])
            if "max_fetches" in item:
                spec["max_fetches"] = clamp_int(item.get("max_fetches"), 0, 10, spec["max_fetches"])
            if "freshness" in item:
                spec["freshness"] = item.get("freshness")
            if "use_browser_fallback" in item:
                spec["use_browser_fallback"] = parse_bool(item.get("use_browser_fallback"), spec["use_browser_fallback"])
        else:
            continue
        if not query:
            continue
        spec["query"] = query
        normalized.append(spec)
    return normalized


def combine_batch_results(results: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    by_key: dict[str, dict[str, Any]] = {}
    for result in results:
        query = result.get("query", "")
        for item in result.get("results", []) or []:
            url = str(item.get("url", ""))
            key = canonical_key(url) or f"{item.get('source','')}:{str(item.get('title','')).lower()}"
            if not key:
                continue
            enriched = dict(item)
            matched = enriched.get("matched_queries")
            if not isinstance(matched, list):
                matched = []
            if query and query not in matched:
                matched.append(query)
            enriched["matched_queries"] = matched

            existing = by_key.get(key)
            if existing is None:
                by_key[key] = enriched
                continue

            existing_queries = existing.get("matched_queries")
            if not isinstance(existing_queries, list):
                existing_queries = []
            for q in matched:
                if q not in existing_queries:
                    existing_queries.append(q)
            existing["matched_queries"] = existing_queries

            if float(enriched.get("relevance", 0) or 0) > float(existing.get("relevance", 0) or 0):
                enriched["matched_queries"] = existing_queries
                by_key[key] = enriched

    combined = list(by_key.values())
    combined.sort(
        key=lambda item: (
            1 if item.get("excerpt") else 0,
            float(item.get("relevance", 0) or 0),
            int(item.get("content_chars", 0) or 0),
        ),
        reverse=True,
    )
    return combined[:limit]


def format_result(result: SearchResult) -> dict[str, Any]:
    return {
        "title": result.title,
        "url": result.url,
        "domain": result.domain or get_domain(result.url),
        "snippet": result.snippet,
        "excerpt": result.excerpt,
        "source": result.source,
        "date": result.date,
        "fetch_status": result.fetch_status,
        "content_chars": result.content_chars,
        "relevance": round(result.relevance_score, 3),
    }


def normalize_url(url: str) -> str:
    url = html.unescape((url or "").strip())
    if not url:
        return ""
    if url.startswith("//"):
        url = "https:" + url
    if url.startswith("/"):
        url = urljoin("https://duckduckgo.com", url)

    parsed = urlparse(url)
    if "duckduckgo.com" in parsed.netloc and parsed.path.startswith("/l/"):
        qs = parse_qs(parsed.query)
        if qs.get("uddg"):
            url = unquote(qs["uddg"][0])
            parsed = urlparse(url)

    if not parsed.scheme and parsed.netloc:
        parsed = parsed._replace(scheme="https")
    if parsed.scheme not in {"http", "https"}:
        return url

    netloc = parsed.netloc.lower()
    if netloc.startswith("www."):
        netloc = netloc[4:]

    query_items = []
    for key, vals in parse_qs(parsed.query, keep_blank_values=False).items():
        key_lower = key.lower()
        if key_lower.startswith("utm_") or key_lower in TRACKING_PARAMS:
            continue
        for val in vals:
            query_items.append((key, val))

    path = re.sub(r"/+$", "", parsed.path) or "/"
    return urlunparse((parsed.scheme, netloc, path, "", urlencode(query_items, doseq=True), ""))


def get_domain(url: str) -> str:
    try:
        netloc = urlparse(url).netloc.lower()
        return netloc[4:] if netloc.startswith("www.") else netloc
    except Exception:
        return ""


def dedupe_results(results: list[SearchResult]) -> list[SearchResult]:
    deduped: dict[str, SearchResult] = {}
    for result in results:
        result.url = normalize_url(result.url)
        result.domain = result.domain or get_domain(result.url)
        key = canonical_key(result.url) or f"{result.source}:{result.title.lower()}"
        existing = deduped.get(key)
        if existing is None or result.relevance_score > existing.relevance_score:
            deduped[key] = result
        elif result.snippet and result.snippet not in existing.snippet:
            existing.snippet = clean_text(f"{existing.snippet} {result.snippet}")[:700]
    return list(deduped.values())


def canonical_key(url: str) -> str:
    parsed = urlparse(url)
    if not parsed.netloc:
        return ""
    return f"{parsed.netloc.lower()}{re.sub(r'/+$', '', parsed.path)}"


def extract_page(page_html: str, base_url: str, query: str) -> dict[str, Any]:
    soup = BeautifulSoup(page_html, "html.parser")
    for tag in soup(["script", "style", "noscript", "svg", "nav", "header", "footer", "form"]):
        tag.decompose()

    title = ""
    if soup.title and soup.title.string:
        title = clean_text(soup.title.string)
    title = meta_content(soup, "og:title") or title
    date = (
        meta_content(soup, "article:published_time")
        or meta_content(soup, "article:modified_time")
        or meta_content(soup, "datePublished")
        or meta_content(soup, "dateModified")
        or meta_content(soup, "dc.date")
        or meta_content(soup, "dc.date.issued")
        or meta_content(soup, "sailthru.date")
        or meta_content(soup, "pubdate")
        or meta_content(soup, "date")
    )

    candidates = []
    for selector in ("article", "main", '[role="main"]', ".post", ".entry-content", ".content", "#content", "body"):
        for elem in soup.select(selector):
            text = clean_text(elem.get_text(" ", strip=True))
            if len(text) > 250:
                candidates.append(text)
        if candidates:
            break

    content = max(candidates, key=len) if candidates else clean_text(soup.get_text(" ", strip=True))
    date = date or time_tag_date(soup) or date_from_text(content)
    return {
        "title": title,
        "date": normalize_date(date),
        "excerpt": choose_excerpt(content, query),
        "content_chars": len(content),
        "url": base_url,
    }


def classify_extract_status(extracted: dict[str, Any]) -> str:
    excerpt = str(extracted.get("excerpt", ""))
    content_chars = int(extracted.get("content_chars", 0) or 0)
    lower = excerpt.lower()
    if not excerpt:
        return "empty_extract"
    if any(marker in lower for marker in ("automated bot check", "checking your browser", "enable javascript", "captcha")):
        return "bot_check"
    if content_chars < 400:
        return "thin_extract"
    return "fetched"


def is_evidence_result(result: SearchResult) -> bool:
    if not result.excerpt:
        return False
    return result.fetch_status in {"fetched", "browser_fetched", "api_summary", "cache_hit"}


def apply_score_adjustments(
    results: list[SearchResult],
    query: str,
    search_type: str,
    freshness: Optional[str],
) -> None:
    category = query_category(query, search_type, freshness)
    for result in results:
        base_score = getattr(result, "_base_relevance_score", result.relevance_score)
        setattr(result, "_base_relevance_score", base_score)
        boost = 0.0
        domain = result.domain or get_domain(result.url)
        if result.excerpt:
            boost += 0.035
        if result.fetch_status in {"bot_check", "empty_extract", "thin_extract"}:
            boost -= 0.04
        if result.source in {"wikipedia", "arxiv"}:
            boost += 0.02
        boost += domain_boost(domain, category)
        boost += recency_boost(result.date, freshness, search_type)
        result.relevance_score = max(0.05, min(0.99, base_score + boost))


def query_category(query: str, search_type: str, freshness: Optional[str] = None) -> str:
    lower = query.lower()
    if search_type == "academic":
        return "academic"
    if contains_any(lower, ("cpu", "gpu", "ryzen", "radeon", "geforce", "motherboard", "ram", "ddr", "pc build")):
        return "hardware"
    if contains_any(
        lower,
        (
            "software",
            "developer",
            "development",
            "coding",
            "programming",
            "agent",
            "agents",
            "llm",
            "code",
            "github",
            "ci",
            "security patch",
        ),
    ):
        return "software"
    if search_type == "news":
        return "news"
    return "news" if freshness else "general"


def domain_boost(domain: str, category: str) -> float:
    if not domain:
        return 0.0
    boost = 0.0
    categories = [category]
    if category not in {"news", "academic"}:
        categories.append("news")
    for cat in categories:
        for known, value in HIGH_SIGNAL_DOMAINS.get(cat, {}).items():
            if domain == known or domain.endswith("." + known):
                boost = max(boost, value)
    if category == "software" and domain in LOW_SIGNAL_AGGREGATORS:
        boost -= 0.035
    return boost


def recency_boost(date_value: Optional[str], freshness: Optional[str], search_type: str) -> float:
    parsed = parse_date_to_datetime(date_value)
    if not parsed:
        return 0.0
    age_days = max(0, (datetime.now(timezone.utc) - parsed).days)
    if freshness or search_type == "news":
        if age_days <= 7:
            return 0.045
        if age_days <= 31:
            return 0.025
        if age_days <= 370:
            return 0.01
    return 0.0


def contains_any(haystack: str, needles: tuple[str, ...]) -> bool:
    return any(needle in haystack for needle in needles)


def meta_content(soup: BeautifulSoup, name: str) -> Optional[str]:
    selectors = [
        {"property": name},
        {"name": name},
        {"itemprop": name},
    ]
    for attrs in selectors:
        tag = soup.find("meta", attrs=attrs)
        if tag and tag.get("content"):
            return clean_text(str(tag["content"]))
    return None


def time_tag_date(soup: BeautifulSoup) -> Optional[str]:
    for tag in soup.find_all("time"):
        for attr in ("datetime", "dateTime", "content"):
            value = tag.get(attr)
            if value:
                normalized = normalize_date(str(value))
                if normalized:
                    return normalized
        text = clean_text(tag.get_text(" ", strip=True))
        normalized = normalize_date(text)
        if normalized:
            return normalized
    return None


def choose_excerpt(content: str, query: str, max_chars: int = 950) -> str:
    content = clean_text(content)
    if not content:
        return ""
    sentences = split_sentences(content)
    if not sentences:
        return content[:max_chars]

    terms = query_terms(query)
    scored = []
    for idx, sentence in enumerate(sentences):
        lower = sentence.lower()
        hits = sum(1 for term in terms if term in lower)
        score = hits * 4 + min(len(sentence), 300) / 300 - idx * 0.02
        scored.append((score, idx, sentence))

    scored.sort(reverse=True)
    selected = sorted(scored[:4], key=lambda item: item[1])
    excerpt = " ".join(sentence for _, _, sentence in selected)
    if len(excerpt) < 180:
        excerpt = " ".join(sentences[:4])
    return excerpt[:max_chars].strip()


def split_sentences(content: str) -> list[str]:
    parts = re.split(r"(?<=[.!?])\s+", content)
    return [part.strip() for part in parts if 40 <= len(part.strip()) <= 600]


def score_text(query: str, text: str, base: float = 0.7) -> float:
    terms = query_terms(query)
    if not terms:
        return base
    lower = text.lower()
    hits = sum(1 for term in terms if term in lower)
    coverage = hits / max(1, len(terms))
    return min(0.98, base + coverage * 0.22)


def wikipedia_match_ok(query: str, title: str, extract: str) -> bool:
    terms = query_terms(query)
    if not terms:
        return True
    title_lower = title.lower()
    first_terms = terms[:2]
    if any(term in title_lower for term in first_terms):
        return True
    title_hits = sum(1 for term in terms if term in title_lower)
    all_hits = sum(1 for term in terms if term in f"{title} {extract}".lower())
    return title_hits >= 2 or all_hits >= max(3, len(terms) // 2 + 1)


def query_terms(query: str) -> list[str]:
    stop = {
        "the",
        "and",
        "for",
        "with",
        "that",
        "this",
        "from",
        "what",
        "when",
        "where",
        "which",
        "about",
        "best",
        "latest",
    }
    terms = re.findall(r"[a-z0-9][a-z0-9.+#-]{2,}", query.lower())
    return [term for term in terms if term not in stop][:12]


def clean_html_snippet(value: str) -> str:
    return clean_text(BeautifulSoup(value, "html.parser").get_text(" ", strip=True))


def clean_text(value: str) -> str:
    value = html.unescape(value or "")
    value = re.sub(r"\s+", " ", value)
    return value.strip()


def normalize_date(value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    value = clean_text(value)
    match = re.search(r"\d{4}-\d{2}-\d{2}", value)
    if match:
        return match.group(0)

    match = re.search(r"\b([A-Z][a-z]{2,8})\.?\s+(\d{1,2}),\s+(\d{4})\b", value)
    if match:
        month = MONTHS.get(match.group(1).lower().rstrip("."))
        if month:
            return f"{int(match.group(3)):04d}-{month:02d}-{int(match.group(2)):02d}"

    match = re.search(r"\b(\d{1,2})\s+([A-Z][a-z]{2,8})\.?\s+(\d{4})\b", value)
    if match:
        month = MONTHS.get(match.group(2).lower().rstrip("."))
        if month:
            return f"{int(match.group(3)):04d}-{month:02d}-{int(match.group(1)):02d}"

    match = re.search(r"\b(\d{1,2})/(\d{1,2})/(\d{4})\b", value)
    if match:
        first = int(match.group(1))
        second = int(match.group(2))
        year = int(match.group(3))
        if first <= 12 and second <= 31:
            return f"{year:04d}-{first:02d}-{second:02d}"

    relative = relative_date(value)
    if relative:
        return relative

    return value[:40]


def normalize_http_date(value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    try:
        parsed = parsedate_to_datetime(value)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc).date().isoformat()
    except Exception:
        return None


def date_from_text(content: str) -> Optional[str]:
    head = content[:2500]
    patterns = [
        r"\b(?:Published|Updated|Posted|Last updated)\s*(?:on)?\s*[:\-]?\s*([A-Z][a-z]{2,8}\.?\s+\d{1,2},\s+\d{4})",
        r"\b(?:Published|Updated|Posted|Last updated)\s*(?:on)?\s*[:\-]?\s*(\d{4}-\d{2}-\d{2})",
        r"\b([A-Z][a-z]{2,8}\.?\s+\d{1,2},\s+\d{4})",
    ]
    for pattern in patterns:
        match = re.search(pattern, head)
        if match:
            normalized = normalize_date(match.group(1))
            if normalized:
                return normalized
    return None


def relative_date(value: str) -> Optional[str]:
    lower = value.lower()
    match = re.search(r"\b(\d+)\s+(minute|hour|day|week|month|year)s?\s+ago\b", lower)
    if not match:
        return None
    amount = int(match.group(1))
    unit = match.group(2)
    if unit == "minute":
        delta = timedelta(minutes=amount)
    elif unit == "hour":
        delta = timedelta(hours=amount)
    elif unit == "day":
        delta = timedelta(days=amount)
    elif unit == "week":
        delta = timedelta(weeks=amount)
    elif unit == "month":
        delta = timedelta(days=amount * 30)
    else:
        delta = timedelta(days=amount * 365)
    return (datetime.now(timezone.utc) - delta).date().isoformat()


def parse_date_to_datetime(value: Optional[str]) -> Optional[datetime]:
    normalized = normalize_date(value)
    if not normalized:
        return None
    try:
        return datetime.fromisoformat(normalized[:10]).replace(tzinfo=timezone.utc)
    except Exception:
        return None


def duckduckgo_freshness(freshness: Optional[str]) -> Optional[str]:
    if not freshness:
        return None
    value = freshness.lower().strip()
    mapping = {
        "day": "d",
        "24h": "d",
        "today": "d",
        "week": "w",
        "7d": "w",
        "month": "m",
        "30d": "m",
        "year": "y",
        "365d": "y",
    }
    return mapping.get(value)


def clamp_int(value: Any, low: int, high: int, default: int) -> int:
    try:
        parsed = int(value)
    except Exception:
        return default
    return max(low, min(high, parsed))


def parse_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() in {"1", "true", "yes", "on"}
    if value is None:
        return default
    return bool(value)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python research_tool.py '{\"query\":\"AI safety\",\"search_type\":\"general\"}'")
        sys.exit(1)

    try:
        params = json.loads(sys.argv[1])
        common_options = {
            "search_type": params.get("search_type", "general"),
            "max_results": params.get("max_results", 10),
            "include_wikipedia": parse_bool(params.get("include_wikipedia"), True),
            "include_news": parse_bool(params.get("include_news"), False),
            "fetch_pages": parse_bool(params.get("fetch_pages"), True),
            "max_fetches": params.get("max_fetches", 5),
            "freshness": params.get("freshness"),
            "use_browser_fallback": parse_bool(params.get("use_browser_fallback"), False),
            "cache_ttl_seconds": clamp_int(params.get("cache_ttl_seconds", 3600), 0, 86400, 3600),
        }

        queries = params.get("queries")
        if isinstance(queries, list) and queries:
            result = research_batch(
                queries=queries,
                **common_options,
                max_queries=clamp_int(params.get("max_queries", 8), 1, 12, 8),
                max_workers=clamp_int(params.get("max_workers", 4), 1, 8, 4),
                combined_max_results=clamp_int(params.get("combined_max_results", 20), 1, 50, 20),
            )
        else:
            query = str(params.get("query", "")).strip()
            if not query:
                print("Error: query or queries parameter is required")
                sys.exit(1)

            result = research(query=query, **common_options)

        print(json.dumps(result, indent=2, ensure_ascii=False))
    except json.JSONDecodeError:
        print("Error: Invalid JSON input")
        sys.exit(1)
    except Exception as exc:
        print(f"Error: {exc}")
        sys.exit(1)
