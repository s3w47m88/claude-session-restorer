#!/usr/bin/env python3
"""
claude-iterm-snapshot.py — capture side of Restore AI Windows v2.

Walks iTerm2 via AppleScript (osascript) — iTerm is the source of truth for
what windows/tabs/sessions currently exist, not transcript mtimes — and
writes ~/.claude/session-state/windows.json per WINDOWS_SCHEMA.md.

Also keeps writing the legacy ~/.claude/session-state/active.tsv (same
<session-id>\\t<cwd> format as claude-session-snapshot.sh) so anything that
still reads it keeps working.

Never clobbers a good windows.json with an empty capture.
"""

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(HOME, ".claude", "session-state")
WINDOWS_JSON = os.path.join(STATE_DIR, "windows.json")
ACTIVE_TSV = os.path.join(STATE_DIR, "active.tsv")
PROJECTS_DIR = os.path.join(HOME, ".claude", "projects")
SPACESCTL = os.path.join(HOME, ".claude", "scripts", "spacesctl", "spacesctl")

# Field/record separators used by the AppleScript dump — must match the
# `character id` values used there.
FS = chr(31)  # field separator (within a record)
RS = chr(30)  # window-record separator
WS = chr(29)  # session-record separator (within a tab)
TS = chr(28)  # tab-record separator (within a window)

APPLESCRIPT = r'''
set FS to character id 31
set RS to character id 30
set WS to character id 29
set TS to character id 28
set output to ""
tell application "iTerm2"
  set winList to windows
  repeat with w in winList
    set wid to (id of w) as text
    set wtitle to ""
    try
      set wtitle to (name of w) as text
    end try
    set b to bounds of w
    set x1 to item 1 of b
    set y1 to item 2 of b
    set x2 to item 3 of b
    set y2 to item 4 of b
    set wrec to wid & FS & wtitle & FS & (x1 as text) & FS & (y1 as text) & FS & ((x2 - x1) as text) & FS & ((y2 - y1) as text)
    set tabRecs to {}
    set tabList to tabs of w
    repeat with tIdx from 1 to (count of tabList)
      set t to item tIdx of tabList
      set ttitle to ""
      try
        set ttitle to (name of t) as text
      end try
      set sessRecs to {}
      set sessList to sessions of t
      repeat with s in sessList
        set stty to ""
        try
          set stty to (tty of s) as text
        end try
        set sname to ""
        try
          set nv to (variable named "autoName") of s
          if nv is not missing value then set sname to nv as text
        end try
        if sname is "" then
          try
            set sname to (name of s) as text
          end try
        end if
        set sbadge to ""
        try
          set bv to (variable named "badge") of s
          if bv is not missing value then set sbadge to bv as text
        end try
        set scsid to "\\N"
        try
          set v to (variable named "user.claude_session_id") of s
          if v is not missing value then set scsid to v as text
        end try
        set scwd to "\\N"
        try
          set cv to (variable named "user.claude_cwd") of s
          if cv is not missing value then set scwd to cv as text
        end try
        set srec to stty & FS & sname & FS & sbadge & FS & scsid & FS & scwd
        set end of sessRecs to srec
      end repeat
      set AppleScript's text item delimiters to WS
      set sessJoined to sessRecs as text
      set AppleScript's text item delimiters to ""
      set trec to (tIdx as text) & FS & ttitle & FS & sessJoined
      set end of tabRecs to trec
    end repeat
    set AppleScript's text item delimiters to TS
    set tabsJoined to tabRecs as text
    set AppleScript's text item delimiters to ""
    set output to output & wrec & FS & tabsJoined & RS
  end repeat
end tell
return output
'''


def run_osascript(script):
    try:
        p = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=30,
        )
    except Exception:
        return None
    if p.returncode != 0:
        return None
    return p.stdout


def display_for_frame(x, y):
    """Best-effort display identifier for a window origin. Returns 'Main' for
    the primary display, else None — real multi-display mapping needs Cocoa,
    which this AppleScript-only script doesn't have."""
    return "Main"


def slug_for_cwd(cwd):
    return re.sub(r"[/.]", "-", cwd)


_mission_cache = {}


# Wrapper blocks Claude Code injects into the transcript that are not the
# human's own words: skip them and keep looking for the real first prompt.
_WRAPPER_PREFIXES = (
    "<local-command-caveat>",
    "<command-name>",
    "<command-message>",
    "<system-reminder>",
    "Caveat: The messages below",
    "This session is being continued",
)

_TAG_RE = re.compile(r"<(pasted_content|system-reminder|local-command-caveat)\b[^>]*>.*?</\1>", re.S)
_ANY_TAG_RE = re.compile(r"</?[a-z_-]+(?:\s[^>]*)?>")


def _clean_mission(text):
    """One-line human-readable gist, or None if the message is a wrapper."""
    stripped = text.strip()
    for prefix in _WRAPPER_PREFIXES:
        if stripped.startswith(prefix):
            return None
    stripped = _TAG_RE.sub(" ", stripped)
    stripped = _ANY_TAG_RE.sub(" ", stripped)
    stripped = " ".join(stripped.split())
    return stripped or None


def mission_for_session(session_id, cwd):
    if not session_id or session_id == "\\N":
        return None
    if session_id in _mission_cache:
        return _mission_cache[session_id]
    path = find_transcript(session_id, cwd)
    mission = None
    if path:
        try:
            with open(path, "r", errors="ignore") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    if obj.get("type") != "user" or obj.get("isSidechain"):
                        continue
                    msg = obj.get("message") or {}
                    content = msg.get("content")
                    text = None
                    if isinstance(content, str):
                        text = content
                    elif isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get("type") == "text":
                                text = block.get("text")
                                break
                    if text:
                        text = _clean_mission(text)
                        if text:
                            mission = text[:200]
                            break
        except Exception:
            mission = None
    _mission_cache[session_id] = mission
    return mission


# --- Retroactive session-id inference -------------------------------------
# The tagging hook only labels sessions started after it was installed. For a
# session that was already running, the Claude process start time matches the
# first timestamp in its transcript to within a couple of seconds, which is a
# reliable enough bijection to resume by. Measured offsets: +1s to +10s.

_live_procs = None
_slug_first_ts = {}
_claimed_ids = set()


def _live_claude_procs():
    """[(pid, tty, start_epoch)] for every running `claude` process."""
    global _live_procs
    if _live_procs is not None:
        return _live_procs
    _live_procs = []
    try:
        ps = subprocess.run(
            ["ps", "-eo", "pid=,tty=,lstart=,command="],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return _live_procs
    pat = re.compile(r"\s*(\d+)\s+(\S+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})\s+(.*)$")
    for line in ps.stdout.splitlines():
        m = pat.match(line)
        if not m:
            continue
        pid, tty, lstart, cmd = m.groups()
        if cmd.strip() != "claude":
            continue
        try:
            start = datetime.strptime(lstart, "%a %b %d %H:%M:%S %Y").timestamp()
        except Exception:
            continue
        _live_procs.append((pid, tty, start))
    return _live_procs


def _transcript_first_ts(path):
    """Epoch of the first timestamped record, scanning past summary headers."""
    try:
        with open(path, "r", errors="ignore") as fh:
            for i, line in enumerate(fh):
                if i > 30:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    ts = json.loads(line).get("timestamp")
                except Exception:
                    continue
                if ts:
                    return datetime.fromisoformat(
                        ts.replace("Z", "+00:00")
                    ).timestamp()
    except Exception:
        pass
    return None


def _slug_transcripts(slug):
    if slug in _slug_first_ts:
        return _slug_first_ts[slug]
    rows = []
    d = os.path.join(PROJECTS_DIR, slug)
    if os.path.isdir(d):
        for name in os.listdir(d):
            if not name.endswith(".jsonl"):
                continue
            ts = _transcript_first_ts(os.path.join(d, name))
            if ts is not None:
                rows.append((name[:-6], ts))
    _slug_first_ts[slug] = rows
    return rows


def find_transcript(session_id, cwd=None):
    """Path to a session's transcript, or None.

    A transcript lives under the directory `claude` was launched from, which is
    not always the pane's cwd — cd into a subdirectory and the two diverge. Try
    the pane's slug first, then every project directory, so a still-valid tag
    is never mistaken for a stale one."""
    if not session_id:
        return None
    name = f"{session_id}.jsonl"
    if cwd:
        direct = os.path.join(PROJECTS_DIR, slug_for_cwd(cwd), name)
        if os.path.isfile(direct):
            return direct
    try:
        entries = os.listdir(PROJECTS_DIR)
    except OSError:
        return None
    for slug in entries:
        path = os.path.join(PROJECTS_DIR, slug, name)
        if os.path.isfile(path):
            return path
    return None


def transcript_exists(session_id, cwd):
    return find_transcript(session_id, cwd) is not None


def resume_cwd_for(session_id, cwd):
    """The directory `claude --resume <id>` must run from.

    Resume resolves the id against the project directory for the shell's cwd,
    so restoring into the pane's last cwd can miss a session that was launched
    somewhere else. The transcript records where it started; use that."""
    path = find_transcript(session_id, cwd)
    if not path:
        return cwd
    try:
        with open(path, "r", errors="ignore") as fh:
            for _ in range(200):
                line = fh.readline()
                if not line:
                    break
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict) and rec.get("cwd"):
                    return rec["cwd"]
    except OSError:
        pass
    return cwd


def tag_session(tty, session_id, cwd):
    """Write the id back into the iTerm session so it never needs inferring again."""
    if not tty or not session_id:
        return
    try:
        payload = ""
        for key, value in (("claude_session_id", session_id), ("claude_cwd", cwd)):
            b64 = base64.b64encode(value.encode()).decode()
            payload += f"\033]1337;SetUserVar={key}={b64}\007"
        with open(tty, "w") as fh:
            fh.write(payload)
    except Exception:
        pass


def infer_session_id(tty, cwd):
    """Session id for an untagged but live session, or None."""
    dev = (tty or "").replace("/dev/", "")
    start = None
    for _pid, ptty, pstart in _live_claude_procs():
        if ptty == dev:
            start = pstart
            break
    if start is None:
        return None
    best, best_delta = None, None
    for sid, first in _slug_transcripts(slug_for_cwd(cwd)):
        if sid in _claimed_ids:
            continue
        delta = first - start
        # The transcript is created just after the process starts.
        if delta < -5 or delta > 180:
            continue
        if best_delta is None or abs(delta) < abs(best_delta):
            best, best_delta = sid, delta
    if best:
        _claimed_ids.add(best)
    return best


def cwd_from_ps_lsof(tty):
    """Fallback cwd lookup when the user var isn't set: tty -> pid -> cwd."""
    dev = tty.replace("/dev/", "") if tty else ""
    if not dev:
        return None
    try:
        ps = subprocess.run(
            ["ps", "-eo", "pid,tty,command"],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return None
    pid = None
    for line in ps.stdout.splitlines()[1:]:
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        p_pid, p_tty, p_cmd = parts
        if p_tty != dev:
            continue
        # Prefer a shell/login process on that tty; last match wins (deepest
        # foreground-ish process tends to appear later in ps -e output for a
        # given tty in practice, but any match beats none).
        pid = p_pid
    if not pid:
        return None
    try:
        lsof = subprocess.run(
            ["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return None
    for line in lsof.stdout.splitlines():
        if line.startswith("n"):
            return line[1:]
    return None


def space_for_window(window_id):
    if not os.path.isfile(SPACESCTL) or not os.access(SPACESCTL, os.X_OK):
        return -1
    try:
        p = subprocess.run(
            [SPACESCTL, "window", str(window_id)],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return -1
    out = p.stdout.strip()
    if p.returncode == 0 and out.isdigit():
        return int(out)
    return -1


def parse_dump(raw):
    windows = []
    active_lines = []
    if not raw:
        return windows, active_lines

    raw = raw.rstrip("\n")
    for wrec in raw.split(RS):
        if not wrec:
            continue
        fields = wrec.split(FS)
        # fields: wid, wtitle, x, y, w, h, <tabsJoined...>
        if len(fields) < 7:
            continue
        wid, wtitle, x, y, w, h = fields[0:6]
        # everything from index 6 onward was the tabsJoined text, but it was
        # split on FS too since tab records also contain FS-delimited data.
        # Rejoin it back since we only wanted to split window-level fields.
        tabs_joined = FS.join(fields[6:])

        try:
            window_id = int(wid)
        except ValueError:
            continue
        try:
            frame = {"x": int(float(x)), "y": int(float(y)), "w": int(float(w)), "h": int(float(h))}
        except ValueError:
            frame = {"x": 0, "y": 0, "w": 0, "h": 0}

        tabs = []
        for trec in tabs_joined.split(TS):
            if not trec:
                continue
            tfields = trec.split(FS)
            if len(tfields) < 2:
                continue
            tidx, ttitle = tfields[0], tfields[1]
            sessions_joined = FS.join(tfields[2:])
            try:
                tab_index = int(tidx)
            except ValueError:
                tab_index = len(tabs) + 1

            sessions = []
            for srec in sessions_joined.split(WS):
                if not srec:
                    continue
                sfields = srec.split(FS)
                if len(sfields) < 4:
                    continue
                stty, sname, sbadge, scsid = sfields[0], sfields[1], sfields[2], sfields[3]
                scwd = sfields[4] if len(sfields) > 4 else "\\N"
                claude_session_id = None if scsid == "\\N" else scsid

                cwd = None
                if scwd and scwd != "\\N":
                    cwd = scwd
                if not cwd:
                    cwd = cwd_from_ps_lsof(stty)
                if not cwd:
                    cwd = HOME

                claude_running = False
                try:
                    lsof_check = subprocess.run(
                        ["ps", "-t", stty.replace("/dev/", ""), "-o", "command="],
                        capture_output=True, text=True, timeout=5,
                    )
                    claude_running = any(
                        line.strip().endswith("claude") or " claude " in line or line.strip() == "claude"
                        for line in lsof_check.stdout.splitlines()
                    )
                except Exception:
                    pass

                session_id_source = "tag" if claude_session_id else None
                # A tag left behind by an earlier session in the same pane points
                # at a transcript that no longer matches. Distrust it and re-infer.
                if claude_session_id and not transcript_exists(claude_session_id, cwd):
                    claude_session_id = None
                    session_id_source = None
                if not claude_session_id and claude_running:
                    claude_session_id = infer_session_id(stty, cwd)
                    if claude_session_id:
                        session_id_source = "inferred-from-process-start"
                        tag_session(stty, claude_session_id, cwd)

                mission = mission_for_session(claude_session_id, cwd)

                sessions.append({
                    "tty": stty,
                    "name": sname,
                    "badge": sbadge,
                    "cwd": cwd,
                    "claude_session_id": claude_session_id,
                    "session_id_source": session_id_source,
                    "resume_cwd": resume_cwd_for(claude_session_id, cwd),
                    "claude_running": claude_running,
                    "mission": mission,
                })

                if claude_session_id:
                    active_lines.append(f"{claude_session_id}\t{cwd}")

            tabs.append({"index": tab_index, "title": ttitle, "sessions": sessions})

        space = space_for_window(window_id)

        windows.append({
            "window_id": window_id,
            "title": wtitle,
            "frame": frame,
            "display": display_for_frame(frame["x"], frame["y"]),
            "space": space,
            "tabs": tabs,
        })

    return windows, active_lines


def atomic_write(path, content):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise


def main():
    os.makedirs(STATE_DIR, exist_ok=True)

    raw = run_osascript(APPLESCRIPT)
    windows, active_lines = parse_dump(raw)

    if not windows:
        sys.stderr.write("claude-iterm-snapshot: zero windows captured, leaving existing windows.json untouched\n")
        return 1

    doc = {
        "captured_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "windows": windows,
    }
    atomic_write(WINDOWS_JSON, json.dumps(doc, indent=2) + "\n")

    if active_lines:
        atomic_write(ACTIVE_TSV, "\n".join(active_lines) + "\n")

    n_tabs = sum(len(w["tabs"]) for w in windows)
    n_sessions = sum(len(t["sessions"]) for w in windows for t in w["tabs"])
    print(f"wrote {WINDOWS_JSON}: {len(windows)} windows, {n_tabs} tabs, {n_sessions} sessions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
