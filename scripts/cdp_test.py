#!/usr/bin/env python3
"""
Minimal CDP test: launch Chrome with debug profile, connect, check what
SimplePractice sees. This helps us figure out what's different vs the Swift app.
"""

import asyncio
import json
import subprocess
import time
import os
import signal
import urllib.request

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT = 9222
PROFILE_DIR = os.path.expanduser(
    "~/Library/Application Support/Pablo/ChromeDebugProfile"
)
SP_URL = "https://secure.simplepractice.com/calendar/appointments"


def kill_chrome():
    """Kill all Chrome processes and wait for them to die."""
    subprocess.run(["pkill", "-9", "-f", "Google Chrome"], capture_output=True)
    for _ in range(20):
        result = subprocess.run(["pgrep", "-f", "Google Chrome"], capture_output=True)
        if result.returncode != 0:
            return
        time.sleep(0.3)


def launch_chrome():
    """Launch Chrome with remote debugging."""
    os.makedirs(PROFILE_DIR, exist_ok=True)
    args = [
        CHROME,
        f"--remote-debugging-port={PORT}",
        "--remote-allow-origins=*",
        "--disable-blink-features=AutomationControlled",
        f"--user-data-dir={PROFILE_DIR}",
        "--no-default-browser-check",
        "--no-first-run",
        SP_URL,
    ]
    proc = subprocess.Popen(
        args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    print(f"Chrome launched (pid {proc.pid})")
    return proc


def get_ws_url():
    """Get the WebSocket debugger URL from Chrome's /json endpoint."""
    for attempt in range(30):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json") as resp:
                targets = json.loads(resp.read())
                for t in targets:
                    if t.get("type") == "page" and not t.get("url", "").startswith(
                        "chrome://"
                    ):
                        url = t["webSocketDebuggerUrl"]
                        return url.replace("ws://localhost:", "ws://127.0.0.1:")
                # No non-chrome page yet, wait
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("Could not get WebSocket URL from Chrome")


async def cdp_test():
    import websockets

    kill_chrome()
    time.sleep(1)
    chrome_proc = launch_chrome()

    try:
        print("Waiting for Chrome to start...")
        ws_url = get_ws_url()
        print(f"Connecting to {ws_url}")

        async with websockets.connect(ws_url, max_size=10_000_000) as ws:
            msg_id = 0

            async def send_cmd(method, params=None):
                nonlocal msg_id
                msg_id += 1
                cmd = {"id": msg_id, "method": method, "params": params or {}}
                await ws.send(json.dumps(cmd))
                while True:
                    resp = json.loads(await ws.recv())
                    if resp.get("id") == msg_id:
                        return resp
                    # skip events

            async def evaluate(expr):
                resp = await send_cmd(
                    "Runtime.evaluate",
                    {"expression": expr, "returnByValue": True},
                )
                result = resp.get("result", {}).get("result", {})
                return result.get("value", result.get("description", str(result)))

            # Check connection
            ok = await evaluate("'cdp_ok'")
            print(f"CDP connected: {ok}")

            # Check what Chrome reports
            ua = await evaluate("navigator.userAgent")
            print(f"User agent: {ua}")

            wd = await evaluate("navigator.webdriver")
            print(f"navigator.webdriver: {wd}")

            plugins = await evaluate("navigator.plugins.length")
            print(f"navigator.plugins.length: {plugins}")

            chrome_rt = await evaluate("typeof window.chrome?.runtime")
            print(f"window.chrome.runtime: {chrome_rt}")

            langs = await evaluate("JSON.stringify(navigator.languages)")
            print(f"navigator.languages: {langs}")

            # Wait for page to load
            print(f"\nWaiting 5s for page to load...")
            await asyncio.sleep(5)

            # Check current URL and page title
            url = await evaluate("window.location.href")
            print(f"Current URL: {url}")

            title = await evaluate("document.title")
            print(f"Page title: {title}")

            # Check for "browser outdated" text
            has_outdated = await evaluate(
                "document.body.innerText.includes('browser is outdated')"
            )
            print(f"Has 'browser is outdated': {has_outdated}")

            # Get the full page text (first 500 chars)
            page_text = await evaluate("document.body.innerText.substring(0, 500)")
            print(f"\nPage text (first 500 chars):\n{page_text}")

            # Now try with anti-detection
            if has_outdated:
                print("\n--- Applying anti-detection and reloading ---")

                # Set UA override with metadata
                await send_cmd(
                    "Emulation.setUserAgentOverride",
                    {
                        "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
                    },
                )

                # Inject anti-detection script
                await send_cmd(
                    "Page.addScriptToEvaluateOnNewDocument",
                    {
                        "source": """
                        Object.defineProperty(Navigator.prototype, 'webdriver', {
                            get: () => false, configurable: true
                        });
                        if (!window.chrome) window.chrome = {};
                        if (!window.chrome.runtime) window.chrome.runtime = {};
                    """
                    },
                )

                # Reload
                await evaluate("window.location.reload(true)")
                await asyncio.sleep(5)

                url2 = await evaluate("window.location.href")
                print(f"URL after reload: {url2}")

                has_outdated2 = await evaluate(
                    "document.body.innerText.includes('browser is outdated')"
                )
                print(f"Still has 'browser outdated': {has_outdated2}")

                page_text2 = await evaluate(
                    "document.body.innerText.substring(0, 500)"
                )
                print(f"\nPage text after reload:\n{page_text2}")

            print("\n--- Done. Press Ctrl+C to exit ---")
            await asyncio.sleep(300)

    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        chrome_proc.send_signal(signal.SIGTERM)


if __name__ == "__main__":
    asyncio.run(cdp_test())
