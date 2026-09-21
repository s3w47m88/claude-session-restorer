#!/bin/bash
# Restore AI Windows — installer.
# Installs the scripts, a Python venv (iterm2), the Spaces helper, the Claude Code
# skill, the launchd agents, and builds + Dock-pins the macOS app. Idempotent.
#
#   bash install.sh
#
# Requires: macOS, iTerm2, Claude Code CLI (`claude`), python3, Xcode CLT (clang).

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HOME/.claude/scripts"
HOOKS="$HOME/.claude/hooks"
SKILLS="$HOME/.claude/skills/restore-claude-sessions"
LAGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/.claude/logs"
STATE="$HOME/.claude/session-state"
VENV="$SCRIPTS/itermvenv"
APP="/Applications/Restore AI Windows.app"
SETTINGS="$HOME/.claude/settings.json"

echo "› Checking prerequisites…"
[ "$(uname)" = "Darwin" ] || { echo "This tool is macOS-only."; exit 1; }
command -v claude  >/dev/null || echo "  ⚠ 'claude' CLI not on PATH — restore will fail until Claude Code is installed."
command -v python3 >/dev/null || { echo "  ✗ python3 required."; exit 1; }
[ -d "/Applications/iTerm.app" ] || echo "  ⚠ iTerm2 not found in /Applications — this tool drives iTerm2."

echo "› Installing scripts → $SCRIPTS"
mkdir -p "$SCRIPTS/spacesctl" "$SKILLS" "$LAGENTS" "$LOGS" "$STATE" "$HOOKS"
cp "$HERE/scripts/"*.sh "$SCRIPTS/"
cp "$HERE/scripts/"*.py "$SCRIPTS/"
cp "$HERE/scripts/continue-prompt.txt" "$SCRIPTS/"
cp "$HERE/scripts/spacesctl/spacesctl.m" "$SCRIPTS/spacesctl/"
cp "$HERE/assets/icon.png" "$SCRIPTS/restorer-icon.png"
chmod +x "$SCRIPTS/"*.sh

echo "› Installing iTerm-truth snapshot + tagging hook…"
# claude-iterm-snapshot.py already landed in $SCRIPTS above (via *.py). The
# SessionStart tagging hook lives in ~/.claude/hooks/, not ~/.claude/scripts/,
# so Claude Code's hook runner finds it.
cp "$HERE/scripts/tag-iterm-session.sh" "$HOOKS/tag-iterm-session.sh"
chmod +x "$HOOKS/tag-iterm-session.sh"

echo "› Registering the SessionStart tagging hook in settings.json…"
if command -v jq >/dev/null && command -v python3 >/dev/null; then
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$SETTINGS" "$HOOKS/tag-iterm-session.sh" <<'PYEOF'
import json, sys
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    data = json.load(f)
hooks = data.setdefault("hooks", {})
session_start = hooks.setdefault("SessionStart", [])
already = any(
    h.get("command") == hook_cmd
    for entry in session_start
    for h in entry.get("hooks", [])
)
if not already:
    session_start.append({
        "hooks": [{"type": "command", "command": hook_cmd, "timeout": 5}]
    })
    with open(settings_path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("  ✓ SessionStart hook registered")
else:
    print("  ✓ SessionStart hook already registered")
PYEOF
else
  echo "  ⚠ jq/python3 not found — add the SessionStart hook to settings.json manually:"
  echo "    command: $HOOKS/tag-iterm-session.sh"
fi

echo "› Creating Python venv + installing iterm2 → $VENV"
[ -d "$VENV" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 || true
"$VENV/bin/pip" install --quiet iterm2

echo "› Compiling the Spaces helper (spacesctl)…"
if command -v clang >/dev/null; then
  clang -fobjc-arc -framework Foundation -framework CoreGraphics \
    -o "$SCRIPTS/spacesctl/spacesctl" "$SCRIPTS/spacesctl/spacesctl.m" \
    && echo "  ✓ spacesctl built" \
    || echo "  ⚠ spacesctl failed to build — position/size still restore, Space won't."
else
  echo "  ⚠ clang not found (install Xcode Command Line Tools) — Space restore disabled."
fi

echo "› Installing Claude Code skill → $SKILLS"
cp "$HERE/skill/SKILL.md" "$SKILLS/"

echo "› Enabling the iTerm2 Python API…"
defaults write com.googlecode.iterm2 EnableAPIServer -bool true 2>/dev/null || true

echo "› Writing launchd agents (with your home path)…"
for name in com.theportlandcompany.claude-snapshot com.theportlandcompany.claude-restore; do
  sed "s#__HOME__#$HOME#g" "$HERE/launchagents/$name.plist" > "$LAGENTS/$name.plist"
  launchctl bootout "gui/$(id -u)" "$LAGENTS/$name.plist" 2>/dev/null || true
  launchctl unload "$LAGENTS/$name.plist" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$LAGENTS/$name.plist" 2>/dev/null \
    || launchctl load -w "$LAGENTS/$name.plist"
done

echo "› Building the macOS app…"
bash "$SCRIPTS/build-restorer-app.sh"

echo "› Pinning to Dock…"
if ! defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "Restore%20AI%20Windows.app"; then
  defaults write com.apple.dock persistent-apps -array-add \
    "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file:///Applications/Restore%20AI%20Windows.app/</string><key>_CFURLStringType</key><integer>15</integer></dict><key>file-label</key><string>Restore AI Windows</string></dict><key>tile-type</key><string>file-tile</string></dict>"
  killall Dock 2>/dev/null || true
fi

echo ""
echo "✓ Installed."
echo "  • Dock app:      $APP  (click to restore)"
echo "  • At login:      the picker OPENS if a snapshot exists — it never restores on"
echo "                   its own. Check the sessions you actually want; they reopen"
echo "                   in their original windows and tabs, with their saved names,"
echo "                   badges, position, size and Space, each resumed by session id"
echo "                   and reminded of the mission it was working on."
echo "  • Snapshot:      asks iTerm what is actually open every 2 min — every window,"
echo "                   tab and split, idle ones included"
echo "  • Skill:         say 'restore my sessions' in Claude Code"
echo "  • Manual run:    bash ~/.claude/scripts/claude-session-restore.sh --force"
echo ""
echo "  Note: Space (virtual desktop) placement works without any extra permission."
echo "  Screen Recording is only needed to read window TITLES; without it, windows"
echo "  still reopen in the right place on the right Space."
