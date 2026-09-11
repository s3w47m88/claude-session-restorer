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
SKILLS="$HOME/.claude/skills/restore-claude-sessions"
LAGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/.claude/logs"
STATE="$HOME/.claude/session-state"
VENV="$SCRIPTS/itermvenv"
APP="/Applications/Restore AI Windows.app"

echo "› Checking prerequisites…"
[ "$(uname)" = "Darwin" ] || { echo "This tool is macOS-only."; exit 1; }
command -v claude  >/dev/null || echo "  ⚠ 'claude' CLI not on PATH — restore will fail until Claude Code is installed."
command -v python3 >/dev/null || { echo "  ✗ python3 required."; exit 1; }
[ -d "/Applications/iTerm.app" ] || echo "  ⚠ iTerm2 not found in /Applications — this tool drives iTerm2."

echo "› Installing scripts → $SCRIPTS"
mkdir -p "$SCRIPTS/spacesctl" "$SKILLS" "$LAGENTS" "$LOGS" "$STATE"
cp "$HERE/scripts/"*.sh "$SCRIPTS/"
cp "$HERE/scripts/"*.py "$SCRIPTS/"
cp "$HERE/scripts/continue-prompt.txt" "$SCRIPTS/"
cp "$HERE/scripts/spacesctl/spacesctl.m" "$SCRIPTS/spacesctl/"
cp "$HERE/assets/icon.png" "$SCRIPTS/restorer-icon.png"
chmod +x "$SCRIPTS/"*.sh

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
echo "  • Auto-restore:  reopens your last active sessions at each login,"
echo "                   grouped by project, at their saved position/size/Space,"
echo "                   auto-answering the trust + resume prompts, then continuing."
echo "  • Snapshot:      records active sessions + window geometry every 2 min"
echo "  • Skill:         say 'restore my sessions' in Claude Code"
echo "  • Manual run:    bash ~/.claude/scripts/claude-session-restore.sh --force"
echo ""
echo "  ⚠ Virtual-desktop/Space restore needs Screen Recording permission:"
echo "    System Settings → Privacy & Security → Screen Recording → add"
echo "    'Restore AI Windows' (and iTerm). Position + size work without it."
