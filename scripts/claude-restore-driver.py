#!/usr/bin/env python3
"""
Restore AI Windows — restore engine.

Reads the snapshot (which sessions were active) plus saved window geometry, then:
  • pre-seeds folder-trust in ~/.claude.json so the trust prompt never appears
  • groups sessions by project: one iTerm window per project, one tab per session
  • runs `claude --resume <id>` in each tab
  • auto-answers the "trust this folder" and "Resume from summary" prompts
  • restores each window's position, size, and (best-effort) virtual desktop/Space
  • injects a continuation prompt so each session summarizes + carries on

Run:  python3 claude-restore-driver.py [active.tsv] [geometry.tsv]
Env:  DRIVER_TEST_ID=<session-id>  -> drive just that one session in a new window
      RESTORE_SESSION_FILTER=sid1,sid2,...  -> only restore these session IDs
"""
import asyncio, base64, json, os, sys, subprocess

HOME = os.path.expanduser("~")
SCRIPTS = os.path.join(HOME, ".claude", "scripts")
STATE = os.path.join(HOME, ".claude", "session-state")
ACTIVE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(STATE, "active.tsv")
GEOM = sys.argv[2] if len(sys.argv) > 2 else os.path.join(STATE, "geometry.tsv")
SPACESCTL = os.path.join(SCRIPTS, "spacesctl", "spacesctl")
CONT_FILE = os.path.join(SCRIPTS, "continue-prompt.txt")
HANDOFF_DIR = os.path.join(HOME, ".claude", "handoffs")
BASE = os.path.join(HOME, "Sites")
SESSION_FILTER = set(os.environ.get("RESTORE_SESSION_FILTER", "").split(",")) if os.environ.get("RESTORE_SESSION_FILTER") else set()

def cont_prompt():
    try:
        return open(CONT_FILE).read().strip()
    except OSError:
        return "Continue where you left off. Only stop for HITL if you are blocked."

def load_handoff(cwd):
    """Load handoff summary for a cwd if it exists."""
    if not cwd:
        return ""
    # Convert cwd to slug: $HOME/Sites/foo → users-you-sites-foo
    slug = cwd.replace("/", "-").strip("-").lower()
    handoff_path = os.path.join(HANDOFF_DIR, f"{slug}.md")
    try:
        with open(handoff_path) as f:
            content = f.read().strip()
            # Extract just the body (skip frontmatter)
            if content.startswith("---"):
                parts = content.split("---", 2)
                if len(parts) >= 3:
                    return parts[2].strip()
            return content
    except OSError:
        return ""

def project_key(cwd):
    if cwd == BASE:
        return "sites"
    rel = cwd[len(BASE) + 1:] if cwd.startswith(BASE + "/") else os.path.basename(cwd)
    return rel.split("/", 1)[0]

FRIENDLY = {
    "focus-finance": "Focus Finance", "tpc-snap-shoot-share": "TPC Snap Shoot Share",
    "seo-tools": "SEO Tools", "politogy": "Politogy", "focus-forge": "Focus Forge",
    "dan-clemens": "Dan Clemens Multisite", "omega-athletics": "Omega Athletics",
    "nueraheat.com": "NueraHeat.com", "tpc-account-manager": "TPC Account Manager",
    "bartok": "Bartok", "sites": "Sites (root)",
}
def friendly(key):
    return FRIENDLY.get(key, key)

def preseed_trust(dirs):
    """Set hasTrustDialogAccepted for each dir so the trust prompt is skipped."""
    path = os.path.join(HOME, ".claude.json")
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        return
    projects = data.setdefault("projects", {})
    changed = False
    for d in dirs:
        p = projects.setdefault(d, {})
        if not p.get("hasTrustDialogAccepted"):
            p["hasTrustDialogAccepted"] = True
            changed = True
    if changed:
        tmp = path + ".tmp"
        json.dump(data, open(tmp, "w"), indent=2)
        os.replace(tmp, path)

def resume_cmd(cwd, sid, badge):
    b64 = base64.b64encode(badge.encode()).decode()
    return (f"printf '\\033]1337;SetBadgeFormat=%s\\a' '{b64}'; "
            f"printf '\\033]0;%s\\a' '{badge}'; "
            f"cd '{cwd}' && claude --resume {sid}")

def load_active():
    rows = []
    try:
        for line in open(ACTIVE):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0] and os.path.isdir(parts[1]):
                sid = parts[0]
                # Filter by RESTORE_SESSION_FILTER if set
                if SESSION_FILTER and sid not in SESSION_FILTER:
                    continue
                rows.append((sid, parts[1]))
    except OSError:
        pass
    return rows

def load_geometry():
    geo = {}
    try:
        for line in open(GEOM):
            p = line.rstrip("\n").split("\t")
            if len(p) >= 6:
                geo[p[0]] = {"x": float(p[1]), "y": float(p[2]),
                             "w": float(p[3]), "h": float(p[4]), "space": int(p[5])}
    except OSError:
        pass
    return geo

async def screen_text(session):
    try:
        c = await session.async_get_screen_contents()
        return "\n".join(c.line(i).string for i in range(c.number_of_lines))
    except Exception:
        return ""

async def drive_session(session, prompt, cwd=None):
    """Auto-answer trust + resume prompts, then inject the continuation prompt + handoff summary."""
    trust_done = resume_done = sent = False
    handoff = load_handoff(cwd) if cwd else ""
    for _ in range(180):  # up to ~3 min
        txt = await screen_text(session)
        low = txt.lower()
        if not trust_done and "trust this folder" in low:
            await session.async_send_text("1\r"); trust_done = True
            await asyncio.sleep(1.5); continue
        if not resume_done and "resume from summary" in low:
            await session.async_send_text("1\r"); resume_done = True
            await asyncio.sleep(2); continue
        if not sent and ("? for shortcuts" in low or "bypass permissions" in low
                         or "bypassing permissions" in low):
            await asyncio.sleep(1.0)
            # Inject handoff summary if available, then the continuation prompt
            if handoff:
                await session.async_send_text(handoff + "\r"); await asyncio.sleep(0.5)
            await session.async_send_text(prompt + "\r"); sent = True
            return True
        await asyncio.sleep(1)
    if not sent:  # fallback: send anyway so nothing is silently dropped
        if handoff:
            await session.async_send_text(handoff + "\r"); await asyncio.sleep(0.5)
        await session.async_send_text(prompt + "\r")
    return sent

def cgwindow_for_frame(frame):
    """Best-effort: match an iTerm CGWindowID by frame via spacesctl find (needs Screen Recording)."""
    try:
        out = subprocess.run([SPACESCTL, "find", "iTerm2"], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return None
    best = None
    for line in out.splitlines():
        f = line.split("\t")
        if len(f) < 5:
            continue
        wid, x, y, w, h = int(f[0]), float(f[1]), float(f[2]), float(f[3]), float(f[4])
        if abs(w - frame["w"]) < 40 and abs(h - frame["h"]) < 40:
            best = wid
    return best

async def apply_geometry(win, geo):
    import iterm2
    frame = await win.async_get_frame()
    frame.origin.x = int(geo["x"]); frame.origin.y = int(geo["y"])
    frame.size.width = int(geo["w"]); frame.size.height = int(geo["h"])
    await win.async_set_frame(frame)
    if geo.get("space", -1) > 0:
        await asyncio.sleep(0.5)
        wid = cgwindow_for_frame(geo)
        if wid:
            try:
                subprocess.run([SPACESCTL, "move", str(wid), str(geo["space"])], timeout=5)
            except Exception:
                pass

async def main(connection):
    import iterm2
    app = await iterm2.async_get_app(connection)
    prompt = cont_prompt()

    test_id = os.environ.get("DRIVER_TEST_ID")
    active = load_active()
    if test_id:
        active = [r for r in active if r[0] == test_id]
        if not active:
            print("test id not found in active.tsv"); return

    preseed_trust([cwd for _, cwd in active])
    geo = load_geometry()

    # group by project, preserving first-seen order
    order, groups = [], {}
    for sid, cwd in active:
        k = project_key(cwd)
        if k not in groups:
            groups[k] = []; order.append(k)
        groups[k].append((sid, cwd))

    drivers = []
    for key in order:
        members = groups[key]
        badge0 = friendly(key)
        win = await iterm2.Window.async_create(connection)
        first = win.tabs[0].sessions[0]
        sid, cwd = members[0]
        await first.async_send_text(resume_cmd(cwd, sid, badge0) + "\n")
        drivers.append(drive_session(first, prompt, cwd))
        for sid, cwd in members[1:]:
            tab = await win.async_create_tab()
            s = tab.sessions[0]
            await s.async_send_text(resume_cmd(cwd, sid, badge0) + "\n")
            drivers.append(drive_session(s, prompt, cwd))
            await asyncio.sleep(0.3)
        if key in geo:
            await apply_geometry(win, geo[key])
        print(f"opened {badge0}: {len(members)} tab(s)")
        await asyncio.sleep(0.4)

    # drive all sessions' prompts concurrently
    await asyncio.gather(*drivers)
    print(f"done: {sum(len(v) for v in groups.values())} session(s)")

if __name__ == "__main__":
    import iterm2
    iterm2.run_until_complete(main)
