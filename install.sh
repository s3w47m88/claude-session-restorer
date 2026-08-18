#!/bin/bash
# Claude Session Restorer — installer.
# Installs the scripts, the Claude Code skill, the launchd auto-restore agents,
# and builds + Dock-pins the macOS app. Safe to re-run (idempotent).
#
#   bash install.sh
#
# Requires: macOS, iTerm2, Claude Code CLI (`claude`).

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HOME/.claude/scripts"
SKILLS="$HOME/.claude/skills/restore-claude-sessions"
LAGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/.claude/logs"
STATE="$HOME/.claude/session-state"
APP="/Applications/ClaudeSessionRestorer.app"

echo "› Checking prerequisites…"
[ "$(uname)" = "Darwin" ] || { echo "This tool is macOS-only."; exit 1; }
command -v claude >/dev/null || echo "  ⚠ 'claude' CLI not on PATH — restore will fail until Claude Code is installed."
[ -d "/Applications/iTerm.app" ] || echo "  ⚠ iTerm2 not found in /Applications — this tool drives iTerm2."

echo "› Installing scripts → $SCRIPTS"
mkdir -p "$SCRIPTS" "$SKILLS" "$LAGENTS" "$LOGS" "$STATE"
cp "$HERE/scripts/"*.sh "$SCRIPTS/"
cp "$HERE/scripts/ClaudeSessionRestorer.applescript" "$SCRIPTS/"
cp "$HERE/assets/icon.png" "$SCRIPTS/restorer-icon.png"
chmod +x "$SCRIPTS/"*.sh

echo "› Installing Claude Code skill → $SKILLS"
cp "$HERE/skill/SKILL.md" "$SKILLS/"

echo "› Writing launchd agents (with your home path)…"
for name in com.spencer.claude-snapshot com.spencer.claude-restore; do
  sed "s#__HOME__#$HOME#g" "$HERE/launchagents/$name.plist" > "$LAGENTS/$name.plist"
  launchctl unload "$LAGENTS/$name.plist" 2>/dev/null || true
  launchctl load -w "$LAGENTS/$name.plist"
done

echo "› Building the macOS app + icon…"
bash "$SCRIPTS/build-restorer-app.sh"

echo "› Pinning to Dock…"
if ! defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "ClaudeSessionRestorer.app"; then
  defaults write com.apple.dock persistent-apps -array-add \
    "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file://${APP}/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
  killall Dock 2>/dev/null || true
fi

echo ""
echo "✓ Installed."
echo "  • Dock app:      $APP  (click to pick + reopen sessions)"
echo "  • Auto-restore:  reopens your last active sessions at each login"
echo "  • Snapshot:      records active sessions every 2 min"
echo "  • Skill:         say 'restore my sessions' in Claude Code"
echo "  • Manual run:    bash ~/.claude/scripts/claude-session-restore.sh --force"