#!/home/garward/Scripts/Tools/.venv/bin/python3
"""
Generic Playwright-based browser fetcher with stealth mode.

Fetches web pages using a headless browser, bypassing bot detection
and executing JavaScript for dynamic content.

Usage:
    from browser_fetch import BrowserFetcher

    fetcher = BrowserFetcher()
    result = fetcher.fetch("https://example.com")
    print(result["content"])

    # Or fetch multiple URLs concurrently
    results = fetcher.fetch_many(["https://a.com", "https://b.com"])

Requirements:
    pip install playwright
    playwright install chromium
"""

import asyncio
import re
from dataclasses import dataclass, field
from typing import Optional

try:
    from playwright.async_api import async_playwright, Browser, Page
    PLAYWRIGHT_AVAILABLE = True
except ImportError:
    PLAYWRIGHT_AVAILABLE = False


@dataclass
class FetchResult:
    """Result from fetching a URL."""
    url: str
    title: str = ""
    content: str = ""
    content_length: int = 0
    error: Optional[str] = None

    @property
    def success(self) -> bool:
        return self.error is None and len(self.content) > 0


class BrowserFetcher:
    """
    Fetches web page content using a headless browser with stealth mode.
    Bypasses basic bot detection and executes JavaScript.
    """

    # Stealth browser args to avoid detection
    STEALTH_ARGS = [
        '--disable-blink-features=AutomationControlled',
        '--no-first-run',
        '--disable-background-timer-throttling',
        '--disable-backgrounding-occluded-windows',
        '--disable-renderer-backgrounding',
        '--disable-extensions',
    ]

    # Default content selectors (override via extract_selectors param)
    DEFAULT_SELECTORS = [
        '[role="main"]', 'main', 'article',
        '.content', '.main-content', '#content',
        'body',
    ]

    # Patterns to clean from content (navigation, cookies, etc.)
    CLEANUP_PATTERNS = [
        r'Skip to (?:main )?content',
        r'Toggle navigation',
        r'Sign in\s*Sign up',
        r'Cookie (?:Policy|Settings|Notice)',
        r'Accept (?:all )?cookies',
    ]

    def __init__(
        self,
        headless: bool = True,
        timeout_ms: int = 30000,
        max_concurrent: int = 3,
        user_agent: Optional[str] = None,
        extract_selectors: Optional[list[str]] = None,
        cleanup_patterns: Optional[list[str]] = None,
        viewport: tuple[int, int] = (1920, 1080),
    ):
        """
        Initialize the browser fetcher.

        Args:
            headless: Run browser in headless mode (default True)
            timeout_ms: Page load timeout in milliseconds
            max_concurrent: Max concurrent fetches
            user_agent: Custom user agent string
            extract_selectors: CSS selectors to try for content extraction
            cleanup_patterns: Regex patterns to remove from content
            viewport: Browser viewport size (width, height)
        """
        if not PLAYWRIGHT_AVAILABLE:
            raise ImportError(
                "Playwright is required. Install with:\n"
                "  pip install playwright\n"
                "  playwright install chromium"
            )

        self.headless = headless
        self.timeout_ms = timeout_ms
        self.max_concurrent = max_concurrent
        self.viewport = {"width": viewport[0], "height": viewport[1]}

        self.user_agent = user_agent or (
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
        )

        self.selectors = extract_selectors or self.DEFAULT_SELECTORS
        self.cleanup_patterns = cleanup_patterns or self.CLEANUP_PATTERNS

        self._browser: Optional[Browser] = None

    def fetch(self, url: str) -> FetchResult:
        """
        Fetch a single URL synchronously.

        Args:
            url: The URL to fetch

        Returns:
            FetchResult with content or error
        """
        return asyncio.run(self._fetch_single_async(url))

    def fetch_many(self, urls: list[str]) -> list[FetchResult]:
        """
        Fetch multiple URLs concurrently.

        Args:
            urls: List of URLs to fetch

        Returns:
            List of FetchResult objects
        """
        return asyncio.run(self._fetch_many_async(urls))

    async def _fetch_single_async(self, url: str) -> FetchResult:
        """Async fetch of a single URL."""
        async with async_playwright() as p:
            browser = await p.chromium.launch(
                headless=self.headless,
                args=self.STEALTH_ARGS,
            )
            result = await self._fetch_with_browser(browser, url)
            await browser.close()
            return result

    async def _fetch_many_async(self, urls: list[str]) -> list[FetchResult]:
        """Async fetch of multiple URLs with concurrency control."""
        async with async_playwright() as p:
            browser = await p.chromium.launch(
                headless=self.headless,
                args=self.STEALTH_ARGS,
            )

            semaphore = asyncio.Semaphore(self.max_concurrent)

            async def fetch_with_limit(url: str) -> FetchResult:
                async with semaphore:
                    return await self._fetch_with_browser(browser, url)

            tasks = [fetch_with_limit(url) for url in urls]
            results = await asyncio.gather(*tasks, return_exceptions=True)

            await browser.close()

            # Convert exceptions to FetchResult errors
            processed = []
            for i, result in enumerate(results):
                if isinstance(result, Exception):
                    processed.append(FetchResult(
                        url=urls[i],
                        error=str(result),
                    ))
                else:
                    processed.append(result)

            return processed

    async def _fetch_with_browser(self, browser: Browser, url: str) -> FetchResult:
        """Fetch a URL using an existing browser instance."""
        context = await browser.new_context(
            user_agent=self.user_agent,
            viewport=self.viewport,
            ignore_https_errors=True,
        )

        try:
            page = await context.new_page()
            await page.goto(url, wait_until='networkidle', timeout=self.timeout_ms)
            await asyncio.sleep(0.5)  # Let JS settle

            title = await page.title()
            content = await self._extract_content(page)

            await page.close()
            await context.close()

            return FetchResult(
                url=url,
                title=title,
                content=content,
                content_length=len(content),
            )

        except Exception as e:
            await context.close()
            return FetchResult(url=url, error=str(e))

    async def _extract_content(self, page: Page) -> str:
        """Extract main content from page using configured selectors."""
        best_content = ""

        for selector in self.selectors:
            try:
                element = await page.query_selector(selector)
                if element:
                    text = await element.inner_text()
                    # Use longest content found
                    if len(text) > len(best_content):
                        best_content = text
            except:
                continue

        return self._clean_content(best_content)

    def _clean_content(self, content: str) -> str:
        """Remove navigation, cookie banners, and normalize whitespace."""
        cleaned = content

        for pattern in self.cleanup_patterns:
            cleaned = re.sub(pattern, '', cleaned, flags=re.IGNORECASE)

        # Normalize whitespace
        cleaned = re.sub(r'\n\s*\n\s*\n+', '\n\n', cleaned)
        cleaned = re.sub(r'[ \t]+', ' ', cleaned)

        return cleaned.strip()


# CLI interface
if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python browser_fetch.py <url> [url2] [url3] ...")
        print("\nFetches web pages using a headless browser with stealth mode.")
        sys.exit(1)

    urls = sys.argv[1:]
    fetcher = BrowserFetcher()

    if len(urls) == 1:
        result = fetcher.fetch(urls[0])
        if result.success:
            print(f"Title: {result.title}")
            print(f"Length: {result.content_length} chars")
            print("-" * 40)
            print(result.content)
        else:
            print(f"Error: {result.error}", file=sys.stderr)
            sys.exit(1)
    else:
        results = fetcher.fetch_many(urls)
        for result in results:
            print(f"\n{'='*60}")
            print(f"URL: {result.url}")
            if result.success:
                print(f"Title: {result.title}")
                print(f"Length: {result.content_length} chars")
                print("-" * 40)
                print(result.content[:500] + "..." if len(result.content) > 500 else result.content)
            else:
                print(f"Error: {result.error}")
