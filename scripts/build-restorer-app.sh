#!/bin/bash
# Rebuild ClaudeSessionRestorer.app from source, with the custom icon.
# Run after editing ClaudeSessionRestorer.applescript.
#
# ICON-CACHE NOTE: macOS caches app icons by bundle PATH. If the Dock shows the
# generic AppleScript scroll after a rebuild at the SAME path, the fix that works
# without sudo is to build at a NEW path (the current path already is the "fresh"
# one). Clearing /Library/Caches/com.apple.iconservices.store needs sudo; changing
# the path does not. Keep the folder name as ClaudeSessionRestorer.app.
set -e

SRC="$HOME/.claude/scripts/ClaudeSessionRestorer.applescript"
APP="/Applications/ClaudeSessionRestorer.app"
ICNS="/tmp/appicon.icns"
PNG="$HOME/.claude/scripts/restorer-icon.png"

# Regenerate icon art if missing
[ -f "$PNG" ] || { echo "missing $PNG (icon source)"; exit 1; }
if [ ! -f "$ICNS" ]; then
  ISET=/tmp/claude-restore.iconset; rm -rf "$ISET"; mkdir -p "$ISET"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s "$PNG" --out "$ISET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d "$PNG" --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ISET" -o "$ICNS"
fi

rm -rf "$APP"
osacompile -o "$APP" "$SRC"

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true
rm -f "$APP/Contents/Resources/Assets.car"
# Icon file is named appicon.icns (NOT applet.icns) — the rename helps dodge the
# icon-services cache. See note below about the new bundle path being the real fix.
cp "$ICNS" "$APP/Contents/Resources/appicon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Claude Session Restorer" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :CFBundleName Claude Session Restorer" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Claude Session Restorer" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Claude Session Restorer" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.spencer.claudesessionrestorer" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.spencer.claudesessionrestorer" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile appicon" "$PLIST" 2>/dev/null || true

# Custom-icon resource fork — the part that actually beats the Dock/Finder icon cache.
cp "$PNG" /tmp/iconimg.png
sips -i /tmp/iconimg.png >/dev/null
DeRez -only icns /tmp/iconimg.png > /tmp/icns.rsrc
ICONFILE="$APP/Icon"$'\r'
rm -f "$ICONFILE"
Rez -append /tmp/icns.rsrc -o "$ICONFILE"
SetFile -a C "$APP"
SetFile -a V "$ICONFILE"

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
killall Dock Finder 2>/dev/null || true
echo "Built $APP with custom icon."