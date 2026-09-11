#!/usr/bin/env python3
"""
Capture currently-open BrowserOS windows (position, size, virtual desktop/Space,
and tab URLs) so a later restore step can reopen tabs grouped into their
original windows, on their original Space, position and size.

Writes session-state/browser.tsv, one line per window:
    <window_index>\t<space>\t<x>\t<y>\t<w>\t<h>\t<tab_count>\t<urls joined by |>

<space> is the 1-based desktop index, or -1 if it couldn't be determined
(Screen Recording permission is required to map windows to a Space).

Tab URLs are pulled live via AppleScript (BrowserOS is a Chromium fork and
exposes standard Chrome-style window/tab scripting). If AppleScript is
unavailable or returns nothing (e.g. BrowserOS isn't running), falls back to
parsing the newest Chromium SNSS session file in the BrowserOS profile.
"""
import os
import struct
import subprocess

HOME = os.path.expanduser("~")
SCRIPTS = os.path.join(HOME, ".claude", "scripts")
STATE = os.path.join(HOME, ".claude", "session-state")
OUT = os.path.join(STATE, "browser.tsv")
SPACESCTL = os.path.join(SCRIPTS, "spacesctl", "spacesctl")
PROFILE_DIR = os.path.join(HOME, "Library", "Application Support", "BrowserOS", "Default")
SESSIONS_DIR = os.path.join(PROFILE_DIR, "Sessions")

HEADER = "window_index\tspace_id\tx\ty\tw\th\ttab_count\turls\n"


def write_out(rows):
    os.makedirs(STATE, exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(HEADER)
        for row in rows:
            fh.write("\t".join(str(v) for v in row) + "\n")
    os.replace(tmp, OUT)


def is_running():
    try:
        r = subprocess.run(["pgrep", "-xq", "BrowserOS"], timeout=5)
        return r.returncode == 0
    except Exception:
        return False


def find_windows_cg():
    """CGWindowID list for BrowserOS: [(wid,x,y,w,h)], empty without Screen Recording."""
    try:
        out = subprocess.run([SPACESCTL, "find", "BrowserOS"], capture_output=True,
                              text=True, timeout=5).stdout
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        f = line.split("\t")
        if len(f) >= 5:
            try:
                rows.append((int(f[0]), float(f[1]), float(f[2]), float(f[3]), float(f[4])))
            except ValueError:
                continue
    return rows


def space_for(x, y, w, h, cg):
    for wid, cx, cy, cw, ch in cg:
        if abs(cx - x) < 40 and abs(cy - y) < 40 and abs(cw - w) < 40 and abs(ch - h) < 40:
            try:
                r = subprocess.run([SPACESCTL, "window", str(wid)], capture_output=True,
                                    text=True, timeout=5)
                return int(r.stdout.strip())
            except Exception:
                return -1
    return -1


def get_tabs_via_applescript():
    """Returns list of (bounds, [urls]) per window via AppleScript, or None on failure."""
    try:
        urls_out = subprocess.run(
            ["osascript", "-e", 'tell application "BrowserOS" to get URL of tabs of windows'],
            capture_output=True, text=True, timeout=10)
        bounds_out = subprocess.run(
            ["osascript", "-e", 'tell application "BrowserOS" to get bounds of windows'],
            capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    if urls_out.returncode != 0 or not urls_out.stdout.strip():
        return None

    # AppleScript list-of-lists prints as "a, b, c, {d, e}, f" when flattened by
    # `get`, but "get URL of tabs of windows" with >1 window returns a nested
    # list rendered as "{{a, b}, {c, d}}". Handle both single- and multi-window.
    raw = urls_out.stdout.strip()
    if raw.startswith("{{"):
        window_blobs = raw[1:-1]
        # split on "}, {" at the top level
        parts = []
        depth = 0
        cur = ""
        i = 0
        while i < len(window_blobs):
            ch = window_blobs[i]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            if depth == 0 and window_blobs[i:i + 3] == "}, ":
                parts.append(cur)
                cur = ""
                i += 3
                continue
            cur += ch
            i += 1
        if cur:
            parts.append(cur)
        url_lists = [[u.strip() for u in p.strip("{}").split(", ") if u.strip()] for p in parts]
    else:
        # single window: flat comma-separated list
        url_lists = [[u.strip() for u in raw.split(", ") if u.strip()]]

    bounds_raw = bounds_out.stdout.strip()
    bounds_lists = []
    if bounds_raw:
        nums = [n.strip() for n in bounds_raw.split(", ")]
        if len(url_lists) <= 1:
            if len(nums) >= 4:
                bounds_lists = [tuple(float(n) for n in nums[:4])]
        else:
            # one bounds tuple of 4 numbers per window, flattened
            for i in range(0, len(nums) - 3, 4):
                bounds_lists.append(tuple(float(n) for n in nums[i:i + 4]))

    result = []
    for i, urls in enumerate(url_lists):
        # AppleScript "bounds" is {x1, y1, x2, y2}, not {x, y, w, h}.
        x1, y1, x2, y2 = bounds_lists[i] if i < len(bounds_lists) else (0.0, 0.0, 0.0, 0.0)
        b = (x1, y1, x2 - x1, y2 - y1)
        result.append((b, urls))
    return result


# --- Minimal Chromium SNSS pickle reader (fallback, URLs only) ---

SNSS_MAGIC = b"SNSS"
TAB_NAVIGATION_PATH = 6  # TabNavigationPathPruned/Prune commands not needed; we scan for URL strings


def newest_session_file():
    if not os.path.isdir(SESSIONS_DIR):
        return None
    candidates = []
    for name in os.listdir(SESSIONS_DIR):
        if name.startswith("Session_") or name.startswith("Tabs_"):
            path = os.path.join(SESSIONS_DIR, name)
            try:
                candidates.append((os.path.getmtime(path), path))
            except OSError:
                continue
    if not candidates:
        return None
    candidates.sort()
    return candidates[-1][1]


def extract_urls_from_snss(path):
    """Best-effort extraction of tab URLs from a Chromium SNSS session file.

    SNSS files are a custom pickle format of typed commands; a full parser
    needs the exact command schema. Instead of reimplementing that schema
    (which drifts across Chromium versions), scan the pickle payload for
    length-prefixed UTF-16LE strings that look like http(s) URLs. This is
    robust to minor format changes and sufficient for a URL-only fallback.
    """
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return []
    if data[:4] != SNSS_MAGIC:
        return []

    urls = []
    seen = set()
    i = 0
    n = len(data)
    while i < n - 4:
        length = struct.unpack_from("<I", data, i)[0]
        # candidate UTF-16LE string of `length` UTF-16 code units
        if 8 <= length <= 2048 and i + 4 + length * 2 <= n:
            try:
                s = data[i + 4:i + 4 + length * 2].decode("utf-16-le")
            except UnicodeDecodeError:
                s = None
            if s and (s.startswith("http://") or s.startswith("https://")) and s not in seen:
                seen.add(s)
                urls.append(s)
        i += 1
    return urls


def get_tabs_via_snss():
    path = newest_session_file()
    if not path:
        return None
    urls = extract_urls_from_snss(path)
    if not urls:
        return None
    # SNSS scanning can't reliably recover window grouping, so treat all
    # recovered URLs as a single window.
    return [((0.0, 0.0, 0.0, 0.0), urls)]


def main():
    if not is_running():
        write_out([])
        return

    windows = get_tabs_via_applescript()
    if not windows:
        windows = get_tabs_via_snss()
    if not windows:
        write_out([])
        return

    cg = find_windows_cg()
    rows = []
    for idx, (bounds, urls) in enumerate(windows):
        if not urls:
            continue
        x, y, w, h = bounds
        sp = space_for(x, y, w, h, cg)
        rows.append((idx, sp, int(x), int(y), int(w), int(h), len(urls), "|".join(urls)))
    write_out(rows)


if __name__ == "__main__":
    main()
