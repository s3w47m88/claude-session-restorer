#!/bin/bash
# tag-iterm-session.sh — Claude Code SessionStart hook.
#
# Tags the iTerm2 session this `claude` process is running in with two user
# variables (claude_session_id, claude_cwd), read back later by
# claude-iterm-snapshot.py so restore knows which tty maps to which
# transcript. Must be silent and must always exit 0 — any stdout here would
# be interpreted as a hook decision, and any failure here must never break
# session start.
#
# The hook process's own shell has no controlling tty (this is verified —
# /dev/tty does not work here), so we walk up the process tree from our
# parent pid via `ps -o ppid=,tty=` until we find an ancestor that does have
# one, and write to that tty's device node directly.

set -u

fail() { exit 0; }
trap fail ERR

input="$(cat 2>/dev/null)" || fail
[ -n "$input" ] || fail

command -v jq >/dev/null 2>&1 || fail

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$session_id" ] || fail
[ -n "$cwd" ] || fail

# Walk up the process tree looking for an ancestor with a real controlling
# tty (not "?" / "??", which is what a hook's own detached shell reports).
find_tty() {
  local pid="$1" tty ppid line
  local hops=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$hops" -lt 50 ]; do
    line="$(ps -o ppid=,tty= -p "$pid" 2>/dev/null)" || return 1
    ppid="$(printf '%s' "$line" | awk '{print $1}')"
    tty="$(printf '%s' "$line" | awk '{print $2}')"
    if [ -n "$tty" ] && [ "$tty" != "?" ] && [ "$tty" != "??" ] && [ "$tty" != "-" ]; then
      printf '%s\n' "$tty"
      return 0
    fi
    pid="$ppid"
    hops=$((hops + 1))
  done
  return 1
}

tty_name="$(find_tty "${PPID:-$$}")" || fail
[ -n "$tty_name" ] || fail

case "$tty_name" in
  /dev/*) tty_dev="$tty_name" ;;
  *) tty_dev="/dev/$tty_name" ;;
esac
[ -w "$tty_dev" ] || fail

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

sid_b64="$(b64 "$session_id")"
cwd_b64="$(b64 "$cwd")"
[ -n "$sid_b64" ] || fail
[ -n "$cwd_b64" ] || fail

{
  printf '\033]1337;SetUserVar=%s=%s\007' "claude_session_id" "$sid_b64"
  printf '\033]1337;SetUserVar=%s=%s\007' "claude_cwd" "$cwd_b64"
} > "$tty_dev" 2>/dev/null || fail

exit 0
