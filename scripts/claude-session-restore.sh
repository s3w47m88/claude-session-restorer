#!/bin/bash
# Reopen the Claude Code sessions that were active at the last snapshot.
# Opens one iTerm2 tab per session and runs `claude --resume <id>` in its cwd.
# Invoked at login by launchd, or manually any time.
#
# Flags:
#   --force   restore even if a restore ran in the last GUARD_MIN minutes

set -uo pipefail

STATE_DIR="$HOME/.claude/session-state"
ACTIVE="$STATE_DIR/active.tsv"
STAMP="$STATE_DIR/.last-restore"
LOG="$HOME/.claude/logs/session-restore.log"
GUARD_MIN=10

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

[ -f "$ACTIVE" ] || { log "no active.tsv; nothing to restore"; exit 0; }

# De-dupe repeat logins: skip if we restored very recently, unless --force.
if [ "$FORCE" -eq 0 ] && [ -f "$STAMP" ]; then
  if find "$STAMP" -mmin -"$GUARD_MIN" | grep -q .; then
    log "skip: restored < ${GUARD_MIN}m ago (use --force to override)"
    exit 0
  fi
fi

CLAUDE_BIN="$(command -v claude || echo claude)"
count=0

open_tab() {
  local id="$1" dir="$2"
  local name; name="$(basename "$dir")"
  local b64; b64="$(printf '%s' "$name" | base64)"
  # Prelude sets the iTerm badge + window/tab title, then resumes the session.
  local cmd="printf '\\033]1337;SetBadgeFormat=%s\\a' '$b64'; printf '\\033]0;%s\\a' '$name'; cd '$dir' && $CLAUDE_BIN --resume $id"
  /usr/bin/osascript <<EOF
tell application "iTerm2"
  activate
  create window with default profile
  tell current session of current window
    set name to "$name"
    write text "$cmd"
  end tell
end tell
EOF
}

# iTerm must be running to hold a "current window"; launch it if needed.
open -ga iTerm 2>/dev/null || true
sleep 2

while IFS=$'\t' read -r id dir; do
  [ -n "$id" ] || continue
  [ -d "$dir" ] || { log "skip $id: dir gone ($dir)"; continue; }
  open_tab "$id" "$dir"
  log "restored $id in $dir"
  count=$((count+1))
done < "$ACTIVE"

touch "$STAMP"
log "done: $count session(s) restored"
