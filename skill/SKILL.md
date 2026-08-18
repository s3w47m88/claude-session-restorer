---
name: restore-claude-sessions
description: Restore Claude Code sessions that were open before a crash, restart, or reboot — reopen them as iTerm windows or tabs running `claude --resume`. Use when the user says their computer crashed and wants sessions back, asks to "restore my sessions", "reopen my Claude tabs", "bring back what was open", or wants to list/snapshot which sessions were recently active. Also covers the always-on auto-restore (launchd) and the Dock app.
---

# Restore Claude Sessions

Reopens previously-active Claude Code sessions after a crash/reboot by resuming their
JSONL transcripts. Each session becomes an iTerm window (or tab) that runs
`claude --resume <id>` in the project's working directory, with the project name set as
the iTerm window/tab title, session name, and badge.

## The system on this machine

| Piece | Path | Role |
| --- | --- | --- |
| Session lister | `~/.claude/scripts/claude-session-list.sh [minutes]` | Prints `<id>\t<cwd>` for sessions active in the last N minutes (default 2 days), newest first |
| Snapshot | `~/.claude/scripts/claude-session-snapshot.sh` | Writes currently-active sessions to `~/.claude/session-state/active.tsv`; runs every 2 min via launchd |
| Restore | `~/.claude/scripts/claude-session-restore.sh [--force]` | Reopens the sessions in `active.tsv`, one iTerm window each; runs at login via launchd |
| launchd | `~/Library/LaunchAgents/com.spencer.claude-snapshot.plist`, `com.spencer.claude-restore.plist` | Drive snapshot (every 120s) + restore (at login) |
| Dock app | `/Applications/ClaudeSessionRestorer.app` | GUI: pick which sessions to reopen + choose separate windows vs tabs |

## How to help the user

**"My computer crashed, restore my sessions"** — run the restore of the last snapshot:
```bash
bash ~/.claude/scripts/claude-session-restore.sh --force
```
`--force` bypasses the 10-minute de-dupe guard. Without it, a restore that ran in the
last 10 min is skipped.

**"What sessions were recently open?"** — list them (default 2-day window; pass minutes to narrow):
```bash
bash ~/.claude/scripts/claude-session-list.sh 2880
```
Each line is `<session-id>\t<working-dir>`. To resume one by hand:
`cd <dir> && claude --resume <id>`.

**"Restore only these specific ones"** — either tell the user to open the Dock app
(**Claude Session Restorer**) and use its checklist, or build a small ad-hoc loop:
open one iTerm window per chosen session with the naming prelude. Match the pattern in
`claude-session-restore.sh`'s `open_tab()` — it sets badge + title via escape sequences
and `set name` via AppleScript.

**"Separate windows vs tabs"** — the login auto-restore and the Dock app default to
**separate windows** (one per session). The Dock app offers tabs-in-one-window as an
option in its second dialog.

## How a session's working dir is recovered

Each transcript (`~/.claude/projects/<slug>/<id>.jsonl`) records `"cwd":"..."`. The
scripts read the **last** `cwd` in the file (tail-first for speed) and skip any session
whose dir no longer exists. Subagent transcripts (`*/subagents/*`) are excluded.

## Verifying / maintaining

- Are the agents loaded? `launchctl list | grep claude`
- Snapshot output: `cat ~/.claude/session-state/active.tsv`
- Logs: `~/.claude/logs/session-restore.log`, `~/.claude/logs/session-snapshot.log`
- These scripts target **iTerm2**. To switch to Terminal.app, rewrite the osascript
  blocks in `claude-session-restore.sh` and the app's AppleScript.
