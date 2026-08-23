#!/bin/bash
# Build "Restore AI Windows.app" — a one-click Dock app that runs the restore driver.
# The app just fires claude-session-restore.sh --force (which delegates to the driver)
# and shows a notification.
#
# ICON-CACHE NOTE: macOS caches app icons by bundle PATH. If the Dock shows the generic
# AppleScript scroll after a rebuild at the SAME path, the fix without sudo is a fresh
# path. The resource-fork icon below is what actually beats the Finder/Dock cache.
set -e

APP="/Applications/Restore AI Windows.app"
RESTORE="$HOME/.claude/scripts/claude-session-restore.sh"
PNG="$HOME/.claude/scripts/restorer-icon.png"
SRC="/tmp/restore-ai-windows.applescript"
ICNS="/tmp/restore-ai-windows.icns"

cat > "$SRC" <<AS
on run
	set restoreScript to "$RESTORE"
	do shell script "nohup bash " & quoted form of restoreScript & " --force > /dev/null 2>&1 &"
	display notification "Restoring your Claude windows…" with title "Restore AI Windows"
end run
AS

rm -rf "$APP"
osacompile -o "$APP" "$SRC"

PLIST="$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Add :CFBundleName string Restore AI Windows" "$PLIST" 2>/dev/null || "$PB" -c "Set :CFBundleName Restore AI Windows" "$PLIST"
"$PB" -c "Add :CFBundleDisplayName string Restore AI Windows" "$PLIST" 2>/dev/null || "$PB" -c "Set :CFBundleDisplayName Restore AI Windows" "$PLIST"
"$PB" -c "Add :CFBundleIdentifier string com.spencer.restoreaiwindows" "$PLIST" 2>/dev/null || "$PB" -c "Set :CFBundleIdentifier com.spencer.restoreaiwindows" "$PLIST"

# Custom icon (best-effort; needs the icon PNG present).
if [ -f "$PNG" ]; then
  if [ ! -f "$ICNS" ]; then
    ISET=/tmp/restore-ai.iconset; rm -rf "$ISET"; mkdir -p "$ISET"
    for s in 16 32 64 128 256 512; do
      sips -z $s $s "$PNG" --out "$ISET/icon_${s}x${s}.png" >/dev/null
      d=$((s*2)); sips -z $d $d "$PNG" --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ISET" -o "$ICNS"
  fi
  rm -f "$APP/Contents/Resources/Assets.car" "$APP/Contents/Resources/applet.icns"
  cp "$ICNS" "$APP/Contents/Resources/applet.icns"
  "$PB" -c "Set :CFBundleIconFile applet" "$PLIST" 2>/dev/null || true
  cp "$PNG" /tmp/iconimg.png; sips -i /tmp/iconimg.png >/dev/null
  DeRez -only icns /tmp/iconimg.png > /tmp/icns.rsrc
  ICONFILE="$APP/Icon"$'\r'; rm -f "$ICONFILE"
  Rez -append /tmp/icns.rsrc -o "$ICONFILE"
  SetFile -a C "$APP"; SetFile -a V "$ICONFILE"
fi

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
killall Dock Finder 2>/dev/null || true
echo "Built $APP."
