#!/bin/bash
# Login-time OFFER, not a restore.
#
# A blind login restore reopens every session cold, and a cold resume rewrites the
# whole prompt prefix at 2x input price (~$6 for a 300k-token session). So at login
# we only surface the picker, and only when there is actually something to restore.
# Nothing is spent until a human checks boxes and presses Restore.
set -e
ACTIVE="$HOME/.claude/session-state/active.tsv"
APP="/Applications/Restore AI Windows.app"
LOG="$HOME/.claude/logs/session-restore.log"

stamp() { echo "$(date '+%Y-%m-%d %H:%M:%S') offer: $*" >> "$LOG"; }

[ -s "$ACTIVE" ] || { stamp "no snapshot, nothing to offer"; exit 0; }
[ -d "$APP" ]    || { stamp "app not installed at $APP"; exit 0; }

count=$(grep -c . "$ACTIVE" 2>/dev/null || echo 0)
stamp "offering $count session(s)"
open -a "$APP"
