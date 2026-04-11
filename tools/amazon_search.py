#!/home/garward/Scripts/Tools/.venv/bin/python3
"""
Amazon product search tool for ClawForge.
Uses browser_fetch.py (Playwright) to render Amazon search pages,
then extracts product names, prices, availability, and URLs.

Usage:
    python3 amazon_search.py "rice cooker"
    python3 amazon_search.py "protein powder" --max-results 5
    python3 amazon_search.py "B08N5WRWNW"  # ASIN lookup

Output: JSON array of product results to stdout.
"""

import asyncio
import json
import re
import sys
import urllib.parse
from html.parser import HTMLParser

sys.path.insert(0, "/home/garward/Scripts/Tools")
from browser_fetch import BrowserFetcher, PLAYWRIGHT_AVAILABLE

if PLAYWRIGHT_AVAILABLE:
    from playwright.async_api import async_playwright


def parse_search_results(html: str) -> list[dict]:
    """Extract product data from Amazon search results HTML using regex.

    Amazon's HTML is deeply nested and changes frequently, so regex on
    known attribute patterns is more reliable than DOM walking.
    """
    products = []

    # Split HTML into individual search result blocks
    # Each result starts with data-component-type="s-search-result" data-asin="..."
    result_pattern = re.compile(
        r'data-component-type="s-search-result"[^>]*data-asin="([A-Z0-9]{10})"'
        r'(.*?)(?=data-component-type="s-search-result"|<div[^>]*class="s-main-slot[^"]*"[^>]*>.*$)',
        re.DOTALL,
    )

    # Simpler: find all asin blocks by splitting on the marker
    blocks = re.split(r'(?=data-component-type="s-search-result")', html)

    for block in blocks:
        asin_match = re.search(r'data-asin="([A-Z0-9]{10})"', block)
        if not asin_match:
            continue
        asin = asin_match.group(1)
        if not asin or asin == "0000000000":
            continue

        product = {
            "asin": asin,
            "title": "",
            "price": None,
            "rating": None,
            "review_count": None,
            "url": f"https://www.amazon.com/dp/{asin}",
            "sponsored": False,
        }

        # Title: <h2> tag with aria-label (most reliable) or inner <span> text
        title_match = re.search(r'<h2[^>]*aria-label="([^"]+)"', block)
        if title_match:
            product["title"] = title_match.group(1).strip()
            # Strip "Sponsored Ad - " prefix
            product["title"] = re.sub(r'^Sponsored\s+Ad\s*-\s*', '', product["title"])
        else:
            # Fallback: inner span text
            title_match2 = re.search(
                r'<h2[^>]*>.*?<span[^>]*>(.*?)</span>', block, re.DOTALL
            )
            if title_match2:
                product["title"] = re.sub(r'<[^>]+>', '', title_match2.group(1)).strip()

        # Skip results without a real product title
        if not product["title"] or len(product["title"]) < 10:
            continue

        # Price: a-price-whole and a-price-fraction
        # Pattern: class="a-price-whole">87<span...  or  class="a-price-whole">87.
        whole_match = re.search(r'a-price-whole[^>]*>(\d[\d,]*)', block)
        frac_match = re.search(r'a-price-fraction[^>]*>(\d+)', block)
        if whole_match:
            whole = whole_match.group(1).replace(",", "")
            frac = frac_match.group(1) if frac_match else "00"
            try:
                product["price"] = float(f"{whole}.{frac}")
            except ValueError:
                pass

        # Rating: "X.Y out of 5 stars"
        rating_match = re.search(r'(\d+\.?\d*)\s+out\s+of\s+5\s+star', block)
        if rating_match:
            product["rating"] = float(rating_match.group(1))

        # Clean HTML entities in title
        import html as html_mod
        product["title"] = html_mod.unescape(product["title"])

        # Review count: look for the link to #customerReviews with a count
        review_patterns = [
            r'aria-label="([\d,]+)\s+ratings?"',
            r'href="[^"]*#customerReviews[^"]*"[^>]*><span[^>]*>([\d,]+)</span>',
            r'<span[^>]*aria-label="([\d,]+)"[^>]*class="[^"]*s-underline-text',
        ]
        for rp in review_patterns:
            rv = re.search(rp, block)
            if rv:
                try:
                    product["review_count"] = int(rv.group(1).replace(",", ""))
                    break
                except ValueError:
                    pass

        # Sponsored
        if "puis-label-popover" in block or "Sponsored" in block[:500]:
            product["sponsored"] = True

        products.append(product)

    return products


def extract_size_info(title: str, price: float | None) -> dict:
    """Parse unit size, pack count, and compute price-per-oz from a product title.

    Handles patterns like:
        "12.5 oz. (Pack of 12)"
        "5 Oz"
        "2.03 lb (Packaging May Vary)"
        "5 oz (Pack of 24)"
        "3 Pound (Pack of 1)"
        "16-Count, 1.76 oz Bars"
        "12 x 5 oz"
    """
    result: dict = {
        "unit_size_oz": None,
        "pack_count": 1,
        "total_oz": None,
        "price_per_oz": None,
    }

    t = title.lower()

    # --- Extract unit size ---
    # Try oz first: "12.5 oz", "5 Oz", "4.5-ounce"
    oz_match = re.search(r'(\d+\.?\d*)\s*(?:-?\s*)?(?:oz\.?|ounce)', t)
    # Try lb/pound: "2.03 lb", "3 Pound"
    lb_match = re.search(r'(\d+\.?\d*)\s*(?:-?\s*)?(?:lb\.?|pound)', t)
    # Try fl oz (treat same as oz for volume comparison)
    floz_match = re.search(r'(\d+\.?\d*)\s*fl\.?\s*oz', t)

    if floz_match:
        result["unit_size_oz"] = float(floz_match.group(1))
    elif oz_match:
        result["unit_size_oz"] = float(oz_match.group(1))
    elif lb_match:
        result["unit_size_oz"] = round(float(lb_match.group(1)) * 16, 2)

    # --- Extract pack count ---
    # "Pack of 12", "12-Pack", "12 Count", "12-Count", "(12 x ...)"
    pack_patterns = [
        r'pack\s+of\s+(\d+)',
        r'(\d+)\s*-?\s*pack\b',
        r'(\d+)\s*-?\s*count\b',
        r'\((\d+)\s*x\s',
        r'case\s+of\s+(\d+)',
    ]
    for pp in pack_patterns:
        pm = re.search(pp, t)
        if pm:
            result["pack_count"] = int(pm.group(1))
            break

    # Also catch "6-pack x2" or "6-pack (2)" style double-packing
    double_pack = re.search(r'(\d+)\s*-?\s*pack\s*(?:x|×)\s*(\d+)', t)
    if double_pack:
        result["pack_count"] = int(double_pack.group(1)) * int(double_pack.group(2))

    # --- Compute totals ---
    if result["unit_size_oz"] is not None:
        result["total_oz"] = round(result["unit_size_oz"] * result["pack_count"], 2)
        if price is not None and result["total_oz"] > 0:
            result["price_per_oz"] = round(price / result["total_oz"], 4)

    return result


def is_asin(query: str) -> bool:
    """Check if query looks like an Amazon ASIN (10 char alphanumeric starting with B)."""
    return bool(re.match(r"^B[0-9A-Z]{9}$", query.strip()))


BROWSER_ARGS = [
    '--disable-blink-features=AutomationControlled',
    '--no-first-run',
    '--disable-background-timer-throttling',
]
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
)
MAX_CONCURRENT = 4  # Max parallel browser contexts


async def _fetch_page(browser, url: str, wait_selector: str | None = None) -> str:
    """Fetch a single page using a new context on an existing browser."""
    context = await browser.new_context(
        user_agent=USER_AGENT,
        viewport={"width": 1920, "height": 1080},
        ignore_https_errors=True,
    )
    try:
        page = await context.new_page()
        await page.route("**/*.{png,jpg,jpeg,gif,webp,svg,woff,woff2}",
                         lambda route: route.abort())
        await page.goto(url, wait_until='domcontentloaded', timeout=20000)
        if wait_selector:
            try:
                await page.wait_for_selector(wait_selector, timeout=8000)
            except Exception:
                pass
        await asyncio.sleep(1.5)
        html = await page.content()
        return html
    finally:
        await context.close()


async def _fetch_many(urls_and_selectors: list[tuple[str, str | None]]) -> list[str | Exception]:
    """Fetch multiple pages in parallel using one browser, multiple contexts."""
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, args=BROWSER_ARGS)
        sem = asyncio.Semaphore(MAX_CONCURRENT)

        async def fetch_one(url: str, selector: str | None) -> str:
            async with sem:
                return await _fetch_page(browser, url, selector)

        tasks = [fetch_one(url, sel) for url, sel in urls_and_selectors]
        results = await asyncio.gather(*tasks, return_exceptions=True)
        await browser.close()
        return results


def _enrich_and_sort(results: list[dict], max_results: int) -> list[dict]:
    """Add size info, deduplicate, sort by value."""
    for p in results:
        size_info = extract_size_info(p["title"], p.get("price"))
        p.update(size_info)

    # Deduplicate by ASIN
    seen = set()
    unique = []
    for p in results:
        if p["asin"] not in seen:
            seen.add(p["asin"])
            unique.append(p)

    trimmed = unique[:max_results]

    # Sort by price_per_oz (cheapest first), nulls at end
    with_ppo = [p for p in trimmed if p.get("price_per_oz") is not None]
    without_ppo = [p for p in trimmed if p.get("price_per_oz") is None]
    with_ppo.sort(key=lambda p: p["price_per_oz"])
    sorted_results = with_ppo + without_ppo

    for i, p in enumerate(sorted_results):
        p["value_rank"] = i + 1 if p.get("price_per_oz") is not None else None

    return sorted_results


def search_amazon(queries: str | list[str], max_results: int = 10) -> list[dict] | dict[str, list[dict]]:
    """Search Amazon for one or more queries in parallel.

    Single query: returns a list of products.
    Multiple queries: returns a dict mapping each query to its product list.
    """
    single = isinstance(queries, str)
    if single:
        queries = [queries]

    # Build URL list: (url, wait_selector) for each query
    fetch_jobs: list[tuple[str, str | None, str]] = []  # (url, selector, query)
    asin_queries: list[tuple[str, str]] = []  # (asin, query_key)

    for q in queries:
        q = q.strip()
        if is_asin(q):
            fetch_jobs.append((f"https://www.amazon.com/dp/{q}", "#productTitle", q))
            asin_queries.append((q, q))
        else:
            encoded = urllib.parse.quote_plus(q)
            fetch_jobs.append((
                f"https://www.amazon.com/s?k={encoded}",
                '[data-component-type="s-search-result"]',
                q,
            ))

    # Fetch all pages in parallel
    urls_and_selectors = [(url, sel) for url, sel, _ in fetch_jobs]
    try:
        html_results = asyncio.run(_fetch_many(urls_and_selectors))
    except Exception as e:
        err = [{"error": f"Browser launch failed: {e}"}]
        return err if single else {q: err for q in queries}

    # Parse results per query
    all_results: dict[str, list[dict]] = {}
    asin_set = {a for a, _ in asin_queries}

    for i, (url, sel, query) in enumerate(fetch_jobs):
        html = html_results[i]
        if isinstance(html, Exception):
            all_results[query] = [{"error": f"Fetch failed: {html}"}]
            continue

        if query in asin_set:
            # ASIN direct lookup
            import html as html_mod
            title_match = re.search(r'id="productTitle"[^>]*>(.*?)</span>', html, re.DOTALL)
            price_match = re.search(r'"priceAmount":\s*"?([\d.]+)"?', html)
            product = {
                "asin": query,
                "title": html_mod.unescape(title_match.group(1).strip()) if title_match else "Unknown",
                "price": float(price_match.group(1)) if price_match else None,
                "url": f"https://www.amazon.com/dp/{query}",
            }
            size_info = extract_size_info(product["title"], product.get("price"))
            product.update(size_info)
            all_results[query] = [product]
        else:
            # Search results
            products = parse_search_results(html)
            all_results[query] = _enrich_and_sort(products, max_results)

    if single:
        return all_results[queries[0]]
    return all_results


def main():
    import argparse
    ap = argparse.ArgumentParser(description="Search Amazon products")
    ap.add_argument("query", nargs="+", help="Search query/queries or ASINs")
    ap.add_argument("--max-results", type=int, default=10, help="Maximum results per query")
    args = ap.parse_args()

    if len(args.query) == 1:
        results = search_amazon(args.query[0], args.max_results)
    else:
        results = search_amazon(args.query, args.max_results)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
