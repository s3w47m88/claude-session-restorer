---
name: restore-claude-sessions
description: Restore Claude Code sessions that were open before a crash, restart, or reboot — reopen them as iTerm windows or tabs running `claude --resume`. Use when the user says their computer crashed and wants sessions back, asks to "restore my sessions", "reopen my Claude tabs", "bring back what was open", or wants to list/snapshot which sessions were recently active. Also covers the always-on auto-restore (launchd) and the Dock app.
---

# Restore Claude Sessions

Reopens previously-active Claude Code sessions after a crash/reboot by resuming their
JSONL transcripts. Sessions are **grouped by project**: one iTerm window per project,
one tab per session, each running `claude --resume <id>` in its working directory. The
friendly project name (e.g. `focus-finance` → "Focus Finance") is set as the badge/title
prelude before `claude` launches. Project key = first path segment under `~/Sites`;
friendly-name and grouping logic live in `claude-session-restore.sh` (`project_key()` /
`friendly()`).

Note: Claude Code overwrites the terminal *title* with its own `✳ task` string after
launch, so the durable friendly label shows in the iTerm **badge** overlay, not the tab
label. iTerm exposes no API to move a live tab between existing windows (AppleScript
`move` and the Python API's `async_set_tabs`/`async_move_to_window` don't reparent), so
regrouping already-open windows requires closing + re-resuming them as tabs.

## The system on this machine

| Piece | Path | Role |
| --- | --- | --- |
| Session lister | `~/.claude/scripts/claude-session-list.sh [minutes]` | Prints `<id>\t<cwd>` for sessions active in the last N minutes (default 2 days), newest first |
| Snapshot | `~/.claude/scripts/claude-session-snapshot.sh` | Writes active sessions to `active.tsv`; also runs the geometry snapshot. Every 2 min via launchd |
| Geometry snapshot | `~/.claude/scripts/claude-geometry-snapshot.py` | Per-project window position/size/Space → `session-state/geometry.tsv` (iTerm2 Python API) |
| Restore (entry) | `~/.claude/scripts/claude-session-restore.sh [--force]` | Guard + launch iTerm, then delegates to the driver. Runs at login via launchd |
| Restore driver | `~/.claude/scripts/claude-restore-driver.py` | The engine: group-by-project tabs, resume, auto-answer trust/resume prompts, restore geometry+Space, inject the continuation prompt |
| Spaces helper | `~/.claude/scripts/spacesctl/spacesctl` | Private-CGS binary: `current` / `window <cgid>` / `move <cgid> <desktop>` / `find [owner]`. Needs Screen Recording to see/move windows |
| Continue prompt | `~/.claude/scripts/continue-prompt.txt` | Editable text injected into each restored session after it loads |
| venv | `~/.claude/scripts/itermvenv` | Persistent Python venv with the `iterm2` module (driver + geometry snapshot use it) |
| launchd | `~/Library/LaunchAgents/com.spencer.claude-snapshot.plist`, `com.spencer.claude-restore.plist` | Drive snapshot (every 120s) + restore (at login) |
| Dock app | `/Applications/Restore AI Windows.app` | One-click: runs the restore driver (`--force`) with a notification. Pinned to the Dock |

**Trust + resume prompts.** The driver pre-seeds `hasTrustDialogAccepted` in `~/.claude.json`
for every restored dir (so the "Is this a project you trust?" prompt never shows), and also
watches each session's screen to auto-pick **1. Yes, I trust this folder** and
**1. Resume from summary** if either prompt appears. Then it types the continue-prompt and Enter.

**Virtual desktop / Space** restore is best-effort: it needs **Screen Recording** permission
granted to whatever runs the restore (the Dock app, or the terminal for a manual run) so
`spacesctl find` can map iTerm windows → CGWindowIDs. Without it, position + size still restore
but `Space` is recorded/applied as `-1` (no move). Position and size never need permission.

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

**"Restore only these specific ones"** — trim `active.tsv` (or pass a custom one as the
driver's first arg) to just the sessions you want, then run the restore. The driver reads
`active.tsv` + `geometry.tsv`; `DRIVER_TEST_ID=<id>` drives a single session in one window.

**Grouping** — sessions are grouped by project (first path segment under `~/Sites`): one
iTerm **window per project, one tab per session**. Friendly names (`focus-finance` →
"Focus Finance") live in `friendly()` in both the driver and `claude-geometry-snapshot.py` —
keep the two in sync. Claude overwrites the tab *title*, so the friendly label shows in the
persistent **badge** overlay, not the tab label.

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
