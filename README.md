# Claude Session Restorer

Reopen your [Claude Code](https://claude.com/claude-code) sessions after a crash, restart, or reboot — as named iTerm2 windows (or tabs) each running `claude --resume`. If your Mac goes down with a dozen sessions open, you get them all back.

![icon](assets/icon.png)

## What you get

| Piece | What it does |
| --- | --- |
| **Dock app** | Click it → checklist of your recent sessions → choose **separate windows** or **tabs** → each reopens in its project directory |
| **Auto-restore** | A launchd agent reopens your last active session set automatically at every login |
| **Snapshot** | A launchd agent records which sessions are active every 2 minutes (this is what auto-restore reads) |
| **Claude Code skill** | Say *"restore my sessions"* inside Claude Code to run it hands-free |

Each reopened session gets the project name as its iTerm **window title, tab title, session name, and badge**. Ambiguous folder names (`web`, `core`, `app`) are shown as `parent/base`, with an emoji marker and a "last active" time, so a long list stays scannable.

## Install

```bash
git clone https://github.com/s3w47m88/claude-session-restorer.git
cd claude-session-restorer
bash install.sh
```

Requirements: macOS, [iTerm2](https://iterm2.com), and the `claude` CLI on your PATH.

## How it works

Claude Code stores each session as a JSONL transcript under `~/.claude/projects/<slug>/<id>.jsonl`, and each transcript records the session's working directory. The scripts read the most-recent `cwd` from every recently-modified transcript and reopen `claude --resume <id>` there. Subagent transcripts are skipped; sessions whose directory no longer exists are skipped.

- `scripts/claude-session-list.sh [minutes]` — list restorable sessions (default 2-day window)
- `scripts/claude-session-snapshot.sh` — write active sessions to `~/.claude/session-state/active.tsv`
- `scripts/claude-session-restore.sh [--force]` — reopen the snapshot (one window each)
- `scripts/build-restorer-app.sh` — (re)build the Dock app from the AppleScript source

## Manual use

```bash
# Reopen the last snapshot right now
bash ~/.claude/scripts/claude-session-restore.sh --force

# List what would be restored
bash ~/.claude/scripts/claude-session-list.sh
```

## Notes

- **iTerm2 only.** The window automation targets iTerm2. Terminal.app would need the AppleScript rewritten.
- **Icon cache gotcha:** macOS caches app icons by bundle *path*. If you rebuild the app and the Dock shows a generic icon, build at a fresh path — that is why the bundle is `ClaudeSessionRestorer.app` (no spaces). Clearing `/Library/Caches/com.apple.iconservices.store` needs sudo; changing the path does not.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.spencer.claude-{snapshot,restore}.plist
rm ~/Library/LaunchAgents/com.spencer.claude-{snapshot,restore}.plist
rm -rf "/Applications/ClaudeSessionRestorer.app" ~/.claude/skills/restore-claude-sessions
# scripts in ~/.claude/scripts and state in ~/.claude/session-state can be removed too
```

## License

MIT
