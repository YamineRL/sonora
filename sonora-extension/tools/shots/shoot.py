#!/usr/bin/env python3
"""Render the Chrome Web Store screenshots at exactly 1280x800.

Headless Chrome writes the PNG and then hangs, because the cockpit polls on
a setInterval and --virtual-time-budget never drains. So: give it a budget,
kill it once the file lands, and move on.
"""
import os, shutil, subprocess, tempfile, sys

BROWSER = "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "store-assets")
SHOTS = ["list", "transport", "palette", "bridge", "settings"]
# Served over HTTP, not file://, so the stage can measure the cockpit inside
# the iframe (same-origin) and fit it to the frame.
BASE = "http://127.0.0.1:8911/tools/shots"

# The bridge shot reuses the menu-bar app screenshots that already ship on the
# project page. Copy them in at render time rather than keeping a second copy
# in git, so the two can never drift apart.
ASSETS = os.path.join(HERE, "assets")
DOCS_IMG = os.path.join(HERE, "..", "..", "..", "docs", "img")
os.makedirs(ASSETS, exist_ok=True)
for name in ("menu.png", "menubar-styles.png"):
    src = os.path.join(DOCS_IMG, name)
    if not os.path.exists(src):
        sys.exit(f"missing {src} — the bridge shot needs the project-page screenshots")
    shutil.copy2(src, os.path.join(ASSETS, name))

os.makedirs(OUT, exist_ok=True)
for shot in SHOTS:
    dest = os.path.abspath(os.path.join(OUT, f"{shot}.png"))
    if os.path.exists(dest):
        os.remove(dest)
    tmp = tempfile.mkdtemp()
    cmd = [
        BROWSER, "--headless=new", "--no-sandbox", "--no-first-run",
        "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
        "--window-size=1280,800", "--virtual-time-budget=6000",
        f"--user-data-dir={tmp}", f"--screenshot={dest}",
        f"{BASE}/stage.html?shot={shot}",
    ]
    try:
        subprocess.run(cmd, capture_output=True, timeout=25)
    except subprocess.TimeoutExpired:
        pass
    shutil.rmtree(tmp, ignore_errors=True)
    ok = os.path.exists(dest)
    print(f"  {shot}.png  {'ok' if ok else 'MISSING'}")
    if not ok:
        sys.exit(1)
