#!/usr/bin/env python3
"""
Capture per-project iTerm window geometry (position, size, virtual desktop/Space)
so the restore can put each project window back where it was.

Writes session-state/geometry.tsv, one line per project:
    <project-key>\t<x>\t<y>\t<w>\t<h>\t<space>
<space> is the 1-based desktop index, or -1 if it couldn't be determined
(Screen Recording permission is required to map iTerm windows to a Space).
"""
import asyncio, os, subprocess

HOME = os.path.expanduser("~")
SCRIPTS = os.path.join(HOME, ".claude", "scripts")
STATE = os.path.join(HOME, ".claude", "session-state")
OUT = os.path.join(STATE, "geometry.tsv")
SPACESCTL = os.path.join(SCRIPTS, "spacesctl", "spacesctl")
BASE = os.path.join(HOME, "Sites")

def project_key(cwd):
    if cwd == BASE:
        return "sites"
    rel = cwd[len(BASE) + 1:] if cwd.startswith(BASE + "/") else os.path.basename(cwd)
    return rel.split("/", 1)[0]

def find_windows():
    """CGWindowID list for iTerm: [(wid,x,y,w,h)], empty without Screen Recording."""
    try:
        out = subprocess.run([SPACESCTL, "find", "iTerm2"], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        f = line.split("\t")
        if len(f) >= 5:
            rows.append((int(f[0]), float(f[1]), float(f[2]), float(f[3]), float(f[4])))
    return rows

def space_for(frame, cg):
    for wid, x, y, w, h in cg:
        if abs(w - frame.size.width) < 40 and abs(h - frame.size.height) < 40:
            try:
                r = subprocess.run([SPACESCTL, "window", str(wid)], capture_output=True, text=True, timeout=5)
                return int(r.stdout.strip())
            except Exception:
                return -1
    return -1

async def main(connection):
    import iterm2
    app = await iterm2.async_get_app(connection)
    cg = find_windows()
    seen = {}
    for w in app.windows:
        try:
            cwd = await w.tabs[0].sessions[0].async_get_variable("path")
        except Exception:
            cwd = None
        if not cwd:
            continue
        key = project_key(cwd)
        if key in seen:
            continue  # first window per project wins
        frame = await w.async_get_frame()
        seen[key] = (frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                     space_for(frame, cg))
    if not seen:
        return
    os.makedirs(STATE, exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w") as fh:
        for key, (x, y, w, h, sp) in seen.items():
            fh.write(f"{key}\t{x:.0f}\t{y:.0f}\t{w:.0f}\t{h:.0f}\t{sp}\n")
    os.replace(tmp, OUT)

if __name__ == "__main__":
    import iterm2
    iterm2.run_until_complete(main)
