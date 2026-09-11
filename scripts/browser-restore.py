#!/usr/bin/env python3
"""
Restore BrowserOS windows from the snapshot written by browser-snapshot.py
(~/.claude/session-state/browser.tsv). For each saved window, opens ONE
BrowserOS window containing all its tabs, then moves it to the saved
position/size and Space, reusing the same spacesctl mechanism
claude-restore-driver.py uses for iTerm windows.

Usage:
    python3 browser-restore.py [--dry-run]
"""
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
SCRIPTS = os.path.join(HOME, ".claude", "scripts")
STATE = os.path.join(HOME, ".claude", "session-state")
IN = os.path.join(STATE, "browser.tsv")
SPACESCTL = os.path.join(SCRIPTS, "spacesctl", "spacesctl")

DRY_RUN = "--dry-run" in sys.argv


def load_windows():
    if not os.path.exists(IN):
        return []
    windows = []
    with open(IN) as fh:
        lines = fh.read().splitlines()
    if not lines:
        return []
    # first line is the header (window_index, space_id, x, y, w, h, tab_count, urls)
    for line in lines[1:]:
        f = line.split("\t")
        if len(f) < 8:
            continue
        try:
            window_index = int(f[0])
            space_id = int(f[1])
            x, y, w, h = float(f[2]), float(f[3]), float(f[4]), float(f[5])
            tab_count = int(f[6])
        except ValueError:
            continue
        urls = f[7].split("|") if f[7] else []
        windows.append({
            "window_index": window_index, "space_id": space_id,
            "x": x, "y": y, "w": w, "h": h,
            "tab_count": tab_count, "urls": urls,
        })
    return windows


def is_running():
    try:
        r = subprocess.run(["pgrep", "-xq", "BrowserOS"], timeout=5)
        return r.returncode == 0
    except Exception:
        return False


def ensure_running():
    if is_running():
        return
    subprocess.run(["open", "-a", "BrowserOS"])
    for _ in range(20):
        if is_running():
            time.sleep(1)  # let it settle before AppleScript talks to it
            return
        time.sleep(0.5)


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=15)


def open_window_applescript(urls):
    """Open one new BrowserOS window with urls[0], then add the rest as tabs
    in that same window. Returns True on success."""
    if not urls:
        return False
    first = urls[0].replace('"', '\\"')
    r = osa(f'tell application "BrowserOS" to make new window with properties {{URL:"{first}"}}')
    if r.returncode != 0:
        return False
    for url in urls[1:]:
        u = url.replace('"', '\\"')
        r = osa(f'tell application "BrowserOS" to tell window 1 to make new tab with properties {{URL:"{u}"}}')
        if r.returncode != 0:
            return False
    return True


def open_window_fallback(urls):
    """Fall back to `open -na BrowserOS --args --new-window url1 url2 ...`."""
    if not urls:
        return False
    try:
        subprocess.run(["open", "-na", "BrowserOS", "--args", "--new-window"] + urls, timeout=15)
        return True
    except Exception:
        return False


def set_bounds(x, y, w, h):
    x1, y1, x2, y2 = int(x), int(y), int(x + w), int(y + h)
    osa(f'tell application "BrowserOS" to set bounds of window 1 to {{{x1}, {y1}, {x2}, {y2}}}')


def move_to_space(space_id):
    if space_id <= 0:
        return
    try:
        out = subprocess.run([SPACESCTL, "find", "BrowserOS"], capture_output=True,
                              text=True, timeout=5).stdout
    except Exception:
        return
    wid = None
    for line in out.splitlines():
        f = line.split("\t")
        if len(f) >= 1:
            try:
                wid = int(f[0])
            except ValueError:
                continue
    if wid is None:
        return
    try:
        subprocess.run([SPACESCTL, "move", str(wid), str(space_id)], timeout=5)
    except Exception:
        pass


def restore_window(win):
    urls = win["urls"]
    if not urls:
        print(f"  window {win['window_index']}: no tabs, skipping")
        return
    if DRY_RUN:
        print(f"  window {win['window_index']}: would open {len(urls)} tab(s) "
              f"at ({win['x']:.0f},{win['y']:.0f} {win['w']:.0f}x{win['h']:.0f}) "
              f"space {win['space_id']}")
        for u in urls:
            print(f"    - {u}")
        return

    ok = open_window_applescript(urls)
    if not ok:
        ok = open_window_fallback(urls)
    if not ok:
        print(f"  window {win['window_index']}: FAILED to open")
        return

    time.sleep(0.5)
    set_bounds(win["x"], win["y"], win["w"], win["h"])
    if win["space_id"] > 0:
        time.sleep(0.5)
        move_to_space(win["space_id"])
    print(f"  window {win['window_index']}: restored ({len(urls)} tabs)")


def main():
    windows = load_windows()
    if not windows:
        print(f"No windows found in {IN}")
        return

    print(f"Loaded {len(windows)} window(s) from {IN}")
    if not DRY_RUN:
        ensure_running()

    for win in windows:
        restore_window(win)


if __name__ == "__main__":
    main()
