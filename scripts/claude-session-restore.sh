#!/bin/bash
# Reopen the Claude Code sessions that were active at the last snapshot.
# Sessions are grouped by project (one iTerm window per project, one tab per session),
# each running `claude --resume <id>`. Window position/size/Space are restored, the
# trust + resume prompts are auto-answered, and a continuation prompt is injected.
# Heavy lifting is in claude-restore-driver.py (iTerm2 Python API).
#
# Invoked at login by launchd, or manually any time.
# Flags:
#   --force   restore even if a restore ran in the last GUARD_MIN minutes

set -uo pipefail

STATE_DIR="$HOME/.claude/session-state"
ACTIVE="$STATE_DIR/active.tsv"
STAMP="$STATE_DIR/.last-restore"
LOG="$HOME/.claude/logs/session-restore.log"
GUARD_MIN=10
VENV_PY="$HOME/.claude/scripts/itermvenv/bin/python"
DRIVER="$HOME/.claude/scripts/claude-restore-driver.py"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

[ -f "$ACTIVE" ] || { log "no active.tsv; nothing to restore"; exit 0; }
[ -x "$VENV_PY" ] || { log "missing venv python ($VENV_PY)"; exit 1; }
[ -f "$DRIVER" ]  || { log "missing driver ($DRIVER)"; exit 1; }

# De-dupe repeat logins: skip if we restored very recently, unless --force.
if [ "$FORCE" -eq 0 ] && [ -f "$STAMP" ]; then
  if find "$STAMP" -mmin -"$GUARD_MIN" | grep -q .; then
    log "skip: restored < ${GUARD_MIN}m ago (use --force to override)"
    exit 0
  fi
fi

# iTerm must be running for the Python API to attach.
open -ga iTerm 2>/dev/null || true
sleep 2

log "restore starting"
"$VENV_PY" "$DRIVER" >> "$LOG" 2>&1
rc=$?
touch "$STAMP"
log "restore finished (rc=$rc)"
exit "$rc"
