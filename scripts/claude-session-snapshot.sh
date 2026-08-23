#!/bin/bash
# Snapshot currently-active Claude Code sessions so they can be restored after a crash.
# Runs every couple minutes via launchd. Writes the set of transcripts touched in the
# last ACTIVE_MIN minutes to session-state/active.tsv (atomic replace).
# Format per line:  <session-id>\t<cwd>

set -uo pipefail

PROJECTS="$HOME/.claude/projects"
STATE_DIR="$HOME/.claude/session-state"
OUT="$STATE_DIR/active.tsv"
TMP="$STATE_DIR/.active.tsv.$$"
ACTIVE_MIN=15

mkdir -p "$STATE_DIR"
: > "$TMP"

# Top-level session transcripts only (skip subagents/ subdirs), modified recently.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  id="$(basename "$f" .jsonl)"
  # Most recent cwd: scan the tail of the file first, fall back to a full scan.
  cwd="$(tail -c 1000000 "$f" 2>/dev/null | grep -o '"cwd":"[^"]*"' | tail -1 | sed 's/.*"cwd":"//; s/"$//')"
  [ -n "$cwd" ] || cwd="$(grep -o '"cwd":"[^"]*"' "$f" 2>/dev/null | tail -1 | sed 's/.*"cwd":"//; s/"$//')"
  [ -n "$cwd" ] || continue
  [ -d "$cwd" ] || continue
  printf '%s\t%s\n' "$id" "$cwd" >> "$TMP"
done < <(find "$PROJECTS" -maxdepth 2 -name '*.jsonl' -not -path '*/subagents/*' -mmin -"$ACTIVE_MIN" 2>/dev/null)

# Only replace the snapshot if we actually found active sessions, so a crash that
# happens during a quiet moment doesn't wipe the last good set.
if [ -s "$TMP" ]; then
  mv "$TMP" "$OUT"
else
  rm -f "$TMP"
fi

# Also capture per-project window geometry (position/size/Space) while iTerm is up.
# Best-effort, time-boxed, never blocks the snapshot.
VENV_PY="$HOME/.claude/scripts/itermvenv/bin/python"
GEO_PY="$HOME/.claude/scripts/claude-geometry-snapshot.py"
if pgrep -xq iTerm2 2>/dev/null && [ -x "$VENV_PY" ] && [ -f "$GEO_PY" ]; then
  "$VENV_PY" "$GEO_PY" >/dev/null 2>&1 &
  gpid=$!
  ( sleep 25; kill "$gpid" 2>/dev/null ) >/dev/null 2>&1 &
  wait "$gpid" 2>/dev/null
fi
