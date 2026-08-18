#!/bin/bash
# Emit restorable Claude Code sessions, most-recently-active first.
# One line per session:  <id>\t<cwd>\t<display>
#   display is a human label with an emoji marker + smart name + last-active time,
#   built here so the GUI can show it verbatim.
# Arg 1: lookback window in minutes (default 2880 = 2 days).

PROJECTS="$HOME/.claude/projects"
WIN_MIN="${1:-2880}"
NOW=$(date +%s)

# Stable emoji marker per project name (visual distinction in a flat list).
EMOJI=(🟥 🟧 🟨 🟩 🟦 🟪 🟫 ⬛ 🔶 🔷 🔸 🔹 ⭐ 🌀 🔥 🌱 ⚡ 🍋 🫐 🌊)
pick_emoji() {
  local s="$1" sum=0 i c
  for ((i=0; i<${#s}; i++)); do printf -v c '%d' "'${s:i:1}"; sum=$((sum + c)); done
  echo "${EMOJI[$((sum % ${#EMOJI[@]}))]}"
}

reltime() {
  local d=$(( NOW - $1 ))
  if   [ "$d" -lt 60 ];    then echo "just now"
  elif [ "$d" -lt 3600 ];  then echo "$((d/60))m ago"
  elif [ "$d" -lt 86400 ]; then echo "$((d/3600))h ago"
  else echo "$((d/86400))d ago"; fi
}

# Ambiguous basenames get their parent folder prepended for clarity.
smart_label() {
  local dir="$1" base parent
  base="$(basename "$dir")"
  case "$base" in
    web|core|app|api|src|Sites|packages|server|client|frontend|backend)
      parent="$(basename "$(dirname "$dir")")"
      echo "$parent/$base" ;;
    *) echo "$base" ;;
  esac
}

find "$PROJECTS" -maxdepth 2 -name '*.jsonl' -not -path '*/subagents/*' -mmin -"$WIN_MIN" -print0 2>/dev/null \
 | xargs -0 ls -t 2>/dev/null \
 | while IFS= read -r f; do
     id="$(basename "$f" .jsonl)"
     cwd="$(tail -c 1000000 "$f" 2>/dev/null | grep -o '"cwd":"[^"]*"' | tail -1 | sed 's/.*"cwd":"//; s/"$//')"
     [ -n "$cwd" ] || cwd="$(grep -o '"cwd":"[^"]*"' "$f" 2>/dev/null | tail -1 | sed 's/.*"cwd":"//; s/"$//')"
     [ -n "$cwd" ] || continue
     [ -d "$cwd" ] || continue
     mtime=$(stat -f %m "$f" 2>/dev/null || echo "$NOW")
     label="$(smart_label "$cwd")"
     emoji="$(pick_emoji "$label")"
     short="${id:0:8}"
     display="$emoji  $label   ·   $(reltime "$mtime")   ·   $cwd   [$short]"
     printf '%s\t%s\t%s\n' "$id" "$cwd" "$display"
   done