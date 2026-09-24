#!/bin/bash
# Build "Restore AI Windows.app" — the Dock app.
#
# This builds the SwiftUI app in macos/ (session picker + permissions + actions).
# It used to compile a bare AppleScript applet that fired the restore immediately
# with no UI; that gave no way to pick which sessions come back, and a blind
# restore-everything is what makes login restores expensive.
#
# ICON-CACHE NOTE: macOS caches app icons by bundle PATH. If the Dock shows a
# generic icon after a rebuild at the SAME path, the resource-fork icon appended
# below is what actually beats the Finder/Dock cache.
set -e

APP="/Applications/Restore AI Windows.app"
PNG="$HOME/.claude/scripts/restorer-icon.png"
ICNS="/tmp/restore-ai-windows.icns"

# Repo root: this script lives in <repo>/scripts (or is run from the installed
# copy in ~/.claude/scripts, in which case the sources sit beside the repo).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFTPKG=""
for cand in "$HERE/../macos" "$HOME/Sites/claude-session-restorer/macos"; do
  [ -f "$cand/Package.swift" ] && SWIFTPKG="$(cd "$cand" && pwd)" && break
done
if [ -z "$SWIFTPKG" ]; then
  echo "ERROR: cannot find the SwiftUI package (macos/Package.swift)." >&2
  exit 1
fi

echo "Building SwiftUI app from $SWIFTPKG ..."
swift build --package-path "$SWIFTPKG" -c release
BIN="$(swift build --package-path "$SWIFTPKG" -c release --show-bin-path)/RestoreAIWindows"
[ -x "$BIN" ] || { echo "ERROR: build produced no binary at $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RestoreAIWindows"

PLIST="$APP/Contents/Info.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Restore AI Windows</string>
	<key>CFBundleDisplayName</key><string>Restore AI Windows</string>
	<key>CFBundleIdentifier</key><string>com.theportlandcompany.restoreaiwindows</string>
	<key>CFBundleExecutable</key><string>RestoreAIWindows</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.2</string>
	<key>CFBundleVersion</key><string>2</string>
	<key>CFBundleIconFile</key><string>applet</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Restore AI Windows drives iTerm2 and your browser to reopen saved sessions.</string>
</dict>
</plist>
PL

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
  cp "$ICNS" "$APP/Contents/Resources/applet.icns"
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
echo "Built $APP (SwiftUI session picker)."
