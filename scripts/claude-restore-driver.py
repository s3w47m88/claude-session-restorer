#!/usr/bin/env python3
"""
Restore AI Windows — restore engine (v2).

Reads ~/.claude/session-state/windows.json (written by claude-iterm-snapshot.py)
and rebuilds iTerm2 exactly as captured:

  • one iTerm window per windows[] entry, in array order (never regrouped by project)
  • tabs recreated in tabs[].index order inside their original window
  • each window's frame (x,y,w,h) and Space applied (space -1 = skip)
  • each session's identity restored verbatim: iTerm session name, badge, tab
    title, window title — no synthesised names
  • each session: cd to cwd, then `claude --resume <id>` when an id was
    captured, else plain `claude`
  • every reopen prompt answered (trust dialog, resume picker, first-run
    theme/setup screens), polled with a timeout so nothing hangs forever
  • once the CLI is live: replay the handoff (if any), then a one-line
    reminder of the session's prior mission, then the continuation prompt

Run:    python3 claude-restore-driver.py [windows.json] [--dry-run]
Env:    RESTORE_SESSION_FILTER=id1,id2,...  -> only restore these claude_session_ids
        (sessions with no claude_session_id are never filtered out by this)
"""
import asyncio, base64, json, os, re, shlex, sys, subprocess

HOME = os.path.expanduser("~")
SCRIPTS = os.path.join(HOME, ".claude", "scripts")
STATE = os.path.join(HOME, ".claude", "session-state")
SPACESCTL = os.path.join(SCRIPTS, "spacesctl", "spacesctl")
CONT_FILE = os.path.join(SCRIPTS, "continue-prompt.txt")
HANDOFF_DIR = os.path.join(HOME, ".claude", "handoffs")

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
DRY_RUN = "--dry-run" in sys.argv[1:]
WINDOWS_JSON = ARGS[0] if ARGS else os.path.join(STATE, "windows.json")
SESSION_FILTER = set(os.environ.get("RESTORE_SESSION_FILTER", "").split(",")) if os.environ.get("RESTORE_SESSION_FILTER") else set()

PROMPT_HANDLERS = [
    # (substring to match in lowercased screen text, keystrokes to send, description)
    ("trust this folder", "1\r", "trust-folder dialog"),
    ("resume from summary", "1\r", "resume-from-summary picker"),
    ("resume this session", "1\r", "resume-session picker"),
    ("continue with", "\r", "continue-with prompt"),
    ("choose the text color", "\r", "first-run theme prompt"),
    ("choose your terminal theme", "\r", "first-run theme prompt"),
    ("dark mode", "\r", "first-run theme prompt"),
    ("select login method", "1\r", "first-run login-method prompt"),
]
READY_MARKERS = ("? for shortcuts", "bypass permissions", "bypassing permissions")


def cont_prompt():
    try:
        return open(CONT_FILE).read().strip()
    except OSError:
        return "Continue where you left off. Only stop for HITL if you are blocked."


def load_handoff(cwd):
    """Load handoff summary for a cwd if it exists."""
    if not cwd:
        return ""
    # Slug must match write-handoff.mjs exactly: non-alphanumeric runs -> "-", no lowercasing.
    slug = re.sub(r"[^A-Za-z0-9]+", "-", cwd).strip("-")
    handoff_path = os.path.join(HANDOFF_DIR, f"{slug}.md")
    try:
        with open(handoff_path) as f:
            content = f.read().strip()
            if content.startswith("---"):
                parts = content.split("---", 2)
                if len(parts) >= 3:
                    return parts[2].strip()
            return content
    except OSError:
        return ""


def mission_reminder(mission):
    if not mission:
        return ""
    return f"Reminder of what you were working on in this session: {mission}"


def load_windows(path):
    with open(path) as f:
        data = json.load(f)
    return data.get("windows", [])


def preseed_trust(dirs):
    """Set hasTrustDialogAccepted for each dir so the trust prompt never appears."""
    path = os.path.join(HOME, ".claude.json")
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        return
    projects = data.setdefault("projects", {})
    changed = False
    for d in dirs:
        if not d:
            continue
        p = projects.setdefault(d, {})
        if not p.get("hasTrustDialogAccepted"):
            p["hasTrustDialogAccepted"] = True
            changed = True
    if changed:
        tmp = path + ".tmp"
        json.dump(data, open(tmp, "w"), indent=2)
        os.replace(tmp, path)


def _osc(code, text):
    # Titles carry apostrophes and unicode; quote so the shell line stays intact.
    return f"printf '\\033]{code};%s\\007' {shlex.quote(text)}"


def build_cmd(sdef):
    """One shell command line: set badge + tab/window title, cd, launch claude."""
    parts = []
    badge = sdef.get("badge") or ""
    if badge:
        parts.append(
            "printf '\\033]1337;SetBadgeFormat=%s\\007' "
            f"\"$(printf '%s' {shlex.quote(badge)} | base64)\""
        )
    name = sdef.get("name") or ""
    if name:
        parts.append(_osc(1, name))  # OSC 1: tab/icon title == captured session name
    cwd = sdef["cwd"]
    sid = sdef.get("claude_session_id")
    claude_cmd = f"claude --resume {shlex.quote(sid)}" if sid else "claude"
    parts.append(f"cd {shlex.quote(cwd)} && {claude_cmd}")
    return "; ".join(parts)


async def screen_text(session):
    try:
        c = await session.async_get_screen_contents()
        return "\n".join(c.line(i).string for i in range(c.number_of_lines))
    except Exception:
        return ""


async def drive_session(session, prompt, cwd, mission, log):
    """Auto-answer every reopen prompt, then inject handoff + mission reminder + continuation prompt."""
    answered = set()
    sent = False
    handoff = load_handoff(cwd) if cwd else ""
    reminder = mission_reminder(mission)
    for _ in range(180):  # up to ~3 min
        txt = await screen_text(session)
        low = txt.lower()
        fired = False
        for trigger, keys, desc in PROMPT_HANDLERS:
            if trigger in answered:
                continue
            if trigger in low:
                await session.async_send_text(keys)
                answered.add(trigger)
                log(f"answered: {desc}")
                await asyncio.sleep(1.5)
                fired = True
                break
        if fired:
            continue
        if not sent and any(m in low for m in READY_MARKERS):
            await asyncio.sleep(1.0)
            if handoff:
                await session.async_send_text(handoff + "\r"); await asyncio.sleep(0.5)
            if reminder:
                await session.async_send_text(reminder + "\r"); await asyncio.sleep(0.5)
            await session.async_send_text(prompt + "\r")
            sent = True
            log("sent mission reminder + continuation prompt")
            return True
        await asyncio.sleep(1)
    if not sent:  # fallback: send anyway so nothing is silently dropped
        if handoff:
            await session.async_send_text(handoff + "\r"); await asyncio.sleep(0.5)
        if reminder:
            await session.async_send_text(reminder + "\r"); await asyncio.sleep(0.5)
        await session.async_send_text(prompt + "\r")
        log("timed out waiting for ready marker; sent prompt anyway")
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


async def apply_geometry(win, frame, space):
    import iterm2
    if frame:
        fr = await win.async_get_frame()
        fr.origin.x = int(frame["x"]); fr.origin.y = int(frame["y"])
        fr.size.width = int(frame["w"]); fr.size.height = int(frame["h"])
        await win.async_set_frame(fr)
    if space and space > 0:
        await asyncio.sleep(0.5)
        wid = cgwindow_for_frame(frame) if frame else None
        if wid and os.path.exists(SPACESCTL):
            try:
                subprocess.run([SPACESCTL, "move", str(wid), str(space)], timeout=5)
            except Exception:
                pass


def build_plan(windows):
    """Flatten windows.json into an ordered list of dry-run log lines. Also used
    to sanity-check window/tab counts before a real run."""
    lines = []
    for wi, w in enumerate(windows, 1):
        frame = w.get("frame") or {}
        lines.append(
            f"[window {wi}] id={w.get('window_id')} title={w.get('title')!r} "
            f"frame=({frame.get('x')},{frame.get('y')},{frame.get('w')},{frame.get('h')}) "
            f"space={w.get('space')}"
        )
        tabs = sorted(w.get("tabs", []), key=lambda t: t["index"])
        for t in tabs:
            lines.append(f"  [tab {t['index']}] title={t.get('title')!r}")
            for s in t.get("sessions", []):
                sid = s.get("claude_session_id")
                cmd = f"claude --resume {sid}" if sid else "claude"
                if SESSION_FILTER and sid not in SESSION_FILTER and sid is not None:
                    lines.append(f"    [session] SKIPPED by RESTORE_SESSION_FILTER: {s.get('cwd')}")
                    continue
                lines.append(
                    f"    [session] name={s.get('name')!r} badge={s.get('badge')!r} "
                    f"cwd={s.get('cwd')} cmd='{cmd}' mission={s.get('mission')!r}"
                )
        if w.get("space", -1) and w.get("space", -1) > 0:
            lines.append(f"  -> spacesctl move <new-window-id> {w['space']}")
        else:
            lines.append("  -> space unknown (-1), skip Space placement")
    return lines


async def main(connection):
    import iterm2
    app = await iterm2.async_get_app(connection)
    prompt = cont_prompt()
    windows = load_windows(WINDOWS_JSON)

    all_cwds = [s.get("cwd") for w in windows for t in w.get("tabs", []) for s in t.get("sessions", [])]
    preseed_trust(all_cwds)

    drivers = []
    for wi, w in enumerate(windows, 1):
        iterm_win = await iterm2.Window.async_create(connection)
        tabs = sorted(w.get("tabs", []), key=lambda t: t["index"])
        window_title_set = False
        for ti, tdef in enumerate(tabs):
            tab = iterm_win.tabs[0] if ti == 0 else await iterm_win.async_create_tab()
            sessions = tdef.get("sessions", [])
            for si, sdef in enumerate(sessions):
                sid = sdef.get("claude_session_id")
                if SESSION_FILTER and sid not in SESSION_FILTER and sid is not None:
                    continue
                sess = tab.sessions[0] if si == 0 else await tab.sessions[-1].async_split_pane(vertical=True)
                await sess.async_send_text(build_cmd(sdef) + "\n")
                if not window_title_set and w.get("title"):
                    await sess.async_send_text(_osc(2, w["title"]) + "\n")  # OSC 2: window title
                    window_title_set = True
                log = lambda msg, wi=wi, ti=ti, si=si: print(f"[window {wi}][tab {ti+1}][session {si+1}] {msg}")
                drivers.append(drive_session(sess, prompt, sdef.get("cwd"), sdef.get("mission"), log))
                await asyncio.sleep(0.3)
            if tdef.get("title"):
                # last-written OSC1 wins per tab; re-assert the captured tab title
                await tab.sessions[-1].async_send_text(_osc(1, tdef["title"]) + "\n")
        await apply_geometry(iterm_win, w.get("frame"), w.get("space"))
        print(f"[window {wi}] opened: {len(tabs)} tab(s)")
        await asyncio.sleep(0.4)

    await asyncio.gather(*drivers)
    print(f"done: {len(windows)} window(s)")


if __name__ == "__main__":
    if DRY_RUN:
        try:
            wins = load_windows(WINDOWS_JSON)
        except OSError as e:
            print(f"cannot read {WINDOWS_JSON}: {e}")
            sys.exit(1)
        print(f"DRY RUN — {WINDOWS_JSON}: {len(wins)} window(s)\n")
        for line in build_plan(wins):
            print(line)
        sys.exit(0)

    import iterm2
    iterm2.run_until_complete(main)
