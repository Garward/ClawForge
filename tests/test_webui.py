#!/usr/bin/env python3
"""
Playwright tests for ClawForge Web UI.
Run with: python tests/test_webui.py
Requires: pip install playwright && playwright install chromium
"""

import os
import subprocess
import time
import sys
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

_ROOT = Path(os.environ.get("CLAWFORGE_ROOT") or Path(__file__).resolve().parent.parent)
DAEMON_PATH = os.environ.get("CLAWFORGE_DAEMON") or str(_ROOT / "zig-out" / "bin" / "clawforged")
WEB_URL = "http://127.0.0.1:8081"


def start_daemon():
    """Start the ClawForge daemon."""
    # Kill any existing daemon
    subprocess.run(["pkill", "clawforged"], capture_output=True)
    time.sleep(0.3)

    # Start daemon
    proc = subprocess.Popen(
        [DAEMON_PATH],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    time.sleep(2)  # Wait for startup
    return proc


def stop_daemon(proc):
    """Stop the daemon."""
    proc.kill()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    # Also ensure cleanup via pkill
    subprocess.run(["pkill", "-9", "clawforged"], capture_output=True)


def test_page_loads(page):
    """Test that the main page loads correctly."""
    page.goto(WEB_URL)

    # Check title
    expect(page).to_have_title("ClawForge")

    # Check header
    expect(page.locator("header h1")).to_have_text("ClawForge")

    # Check sidebar exists
    expect(page.locator("#sidebar")).to_be_visible()

    # Check chat area exists
    expect(page.locator("#chat-area")).to_be_visible()

    # Check input form exists
    expect(page.locator("#message-input")).to_be_visible()
    expect(page.locator("#send-btn")).to_be_visible()

    print("  [PASS] Page loads correctly")


def test_status_displayed(page):
    """Test that status is displayed in header."""
    page.goto(WEB_URL)

    # Wait for status to load
    page.wait_for_timeout(1000)

    # Status should show version
    status = page.locator("#status")
    expect(status).to_contain_text("v0.1.0")

    print("  [PASS] Status displayed")


def test_send_message(page):
    """Test sending a message and receiving a response."""
    page.goto(WEB_URL)

    # Type a message
    input_field = page.locator("#message-input")
    input_field.fill("Say exactly: test response")

    # Click send
    page.locator("#send-btn").click()

    # Wait for response (with timeout)
    page.wait_for_timeout(15000)  # API can take a while

    # Check that messages appeared
    messages = page.locator(".message")
    expect(messages).to_have_count(2)  # User message + assistant response

    # Check user message
    user_msg = page.locator(".message.user")
    expect(user_msg).to_contain_text("Say exactly: test response")

    # Check assistant message exists
    assistant_msg = page.locator(".message.assistant")
    expect(assistant_msg).to_be_visible()

    print("  [PASS] Message send/receive works")


def test_new_session_button(page):
    """Test the new session button clears messages."""
    page.goto(WEB_URL)

    # Send a message first
    page.locator("#message-input").fill("Hello")
    page.locator("#send-btn").click()
    page.wait_for_timeout(10000)

    # Verify message exists
    expect(page.locator(".message")).to_have_count(2)

    # Click new session
    page.locator("#new-session").click()
    page.wait_for_timeout(500)

    # Messages should be cleared
    expect(page.locator(".message")).to_have_count(0)

    print("  [PASS] New session button works")


def run_tests():
    """Run all tests."""
    daemon = start_daemon()

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            page = browser.new_page()

            print("\nRunning ClawForge Web UI Tests...")
            print("-" * 40)

            try:
                test_page_loads(page)
                test_status_displayed(page)
                test_send_message(page)
                test_new_session_button(page)

                print("-" * 40)
                print("All tests passed!")

            except Exception as e:
                print(f"\n  [FAIL] {e}")
                # Take screenshot on failure
                page.screenshot(path="/tmp/clawforge_test_failure.png")
                print("  Screenshot saved to /tmp/clawforge_test_failure.png")
                sys.exit(1)
            finally:
                browser.close()
    finally:
        stop_daemon(daemon)


if __name__ == "__main__":
    run_tests()
