#!/bin/bash
# Reopen the Claude Code sessions that were active at the last snapshot.
# Sessions are grouped by project (one iTerm window per project, one tab per session),
# each running `claude --resume <id>`. Window position/size/Space are restored, the
# trust + resume prompts are auto-answered, and a continuation prompt is injected.
# Heavy lifting is in claude-restore-driver.py (iTerm2 Python API); the browser
# side is driven by browser-restore.py (BrowserOS windows/tabs).
#
# Invoked at login by launchd, or manually any time.
# Flags:
#   --force    restore even if a restore ran in the last GUARD_MIN minutes
#   --browser  restore only the browser windows (skip iTerm)
#   --all      restore both iTerm and browser (same as default)
# Env:
#   RESTORE_SKIP_BROWSER=1   skip the browser restore step

set -uo pipefail

STATE_DIR="$HOME/.claude/session-state"
SCRIPTS="$HOME/.claude/scripts"
ACTIVE="$STATE_DIR/active.tsv"
STAMP="$STATE_DIR/.last-restore"
LOG="$HOME/.claude/logs/session-restore.log"
GUARD_MIN=10
VENV_PY="$SCRIPTS/itermvenv/bin/python"
DRIVER="$SCRIPTS/claude-restore-driver.py"
BROWSER_RESTORE="$SCRIPTS/browser-restore.py"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

FORCE=0
BROWSER_ONLY=0
DO_ITERM=1
DO_BROWSER=1
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --browser) BROWSER_ONLY=1; DO_ITERM=0; DO_BROWSER=1 ;;
    --all)     DO_ITERM=1; DO_BROWSER=1 ;;
  esac
done
[ "${RESTORE_SKIP_BROWSER:-0}" = "1" ] && DO_BROWSER=0

rc=0

if [ "$DO_ITERM" -eq 1 ]; then
  [ -f "$ACTIVE" ] || { log "no active.tsv; nothing to restore"; DO_ITERM=0; }
fi
if [ "$DO_ITERM" -eq 1 ]; then
  [ -x "$VENV_PY" ] || { log "missing venv python ($VENV_PY)"; exit 1; }
  [ -f "$DRIVER" ]  || { log "missing driver ($DRIVER)"; exit 1; }

  # De-dupe repeat logins: skip if we restored very recently, unless --force.
  if [ "$FORCE" -eq 0 ] && [ -f "$STAMP" ]; then
    if find "$STAMP" -mmin -"$GUARD_MIN" | grep -q .; then
      log "skip: restored < ${GUARD_MIN}m ago (use --force to override)"
      DO_ITERM=0
    fi
  fi
fi

if [ "$DO_ITERM" -eq 1 ]; then
  # iTerm must be running for the Python API to attach.
  open -ga iTerm 2>/dev/null || true
  sleep 2

  log "restore starting"
  "$VENV_PY" "$DRIVER" >> "$LOG" 2>&1
  rc=$?
  touch "$STAMP"
  log "restore finished (rc=$rc)"
fi

# Browser restore is best-effort and never fails the overall run.
if [ "$DO_BROWSER" -eq 1 ]; then
  if [ -f "$BROWSER_RESTORE" ]; then
    log "browser restore starting"
    python3 "$BROWSER_RESTORE" >> "$LOG" 2>&1 || log "browser restore failed (non-fatal)"
    log "browser restore finished"
  else
    log "missing browser-restore.py ($BROWSER_RESTORE) — skipping"
  fi
fi

exit "$rc"
