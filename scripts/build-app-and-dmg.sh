#!/bin/bash
# Build a distributable macOS app bundle + DMG for Restore AI Windows.
#
# Usage:
#   bash scripts/build-app-and-dmg.sh [VERSION]
#
# Default VERSION is 1.1.0. Creates:
#   dist/Restore AI Windows.app/
#   dist/RestoreAIWindows-<VERSION>.dmg
#
# Signing: Dev ID Application if available (with notarization if secrets present),
# otherwise ad-hoc sign.

set -e

VERSION="${1:-1.1.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS_DIR="$REPO_ROOT/macos"
DIST_DIR="$REPO_ROOT/dist"
APP_DIR="$DIST_DIR/Restore AI Windows.app"
STAGE_DIR="/tmp/restore-ai-windows-stage-$$"
ASSETS_DIR="$REPO_ROOT/assets"

# Clean and create output directory
rm -rf "$DIST_DIR" "$STAGE_DIR"
mkdir -p "$DIST_DIR" "$STAGE_DIR"

echo "→ Building Swift release executable…"
swift build -c release --package-path "$MACOS_DIR" 2>&1 | grep -E "^(Building|Linking|Build complete)" || true

# Locate the release executable
RELEASE_BIN="$MACOS_DIR/.build/release/RestoreAIWindows"
if [ ! -f "$RELEASE_BIN" ]; then
  echo "✗ Release executable not found at $RELEASE_BIN"
  exit 1
fi
echo "✓ Executable: $RELEASE_BIN"

echo ""
echo "→ Creating app bundle structure…"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Resources/engine"

# Copy executable
cp "$RELEASE_BIN" "$APP_DIR/Contents/MacOS/RestoreAIWindows"
chmod +x "$APP_DIR/Contents/MacOS/RestoreAIWindows"
echo "✓ Executable copied to app bundle"

echo ""
echo "→ Converting icon…"
# Convert PNG to icns using sips + iconutil
ICONSET="/tmp/restore-ai-windows-iconset-$$"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

if [ -f "$ASSETS_DIR/icon.png" ]; then
  ICON_OK=true
  for size in 16 32 64 128 256 512; do
    sips -z $size $size "$ASSETS_DIR/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1 || ICON_OK=false
    sips -z $((size*2)) $((size*2)) "$ASSETS_DIR/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || ICON_OK=false
  done

  if [ "$ICON_OK" = "true" ] && iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns" >/dev/null 2>&1; then
    echo "✓ Icon created: AppIcon.icns"
  else
    echo "⚠ Icon conversion failed, app will use default icon"
  fi
else
  echo "⚠ icon.png not found, skipping icon creation"
fi

echo ""
echo "→ Creating Info.plist…"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>RestoreAIWindows</string>
	<key>CFBundleIdentifier</key>
	<string>com.theportlandcompany.restoreaiwindows</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Restore AI Windows</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>VERSION_PLACEHOLDER</string>
	<key>CFBundleVersion</key>
	<string>VERSION_PLACEHOLDER</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
</dict>
</plist>
PLIST

# Replace version placeholder
sed -i '' "s/VERSION_PLACEHOLDER/$VERSION/g" "$APP_DIR/Contents/Info.plist"
echo "✓ Info.plist created (version: $VERSION)"

echo ""
echo "→ Bundling engine scripts…"
# Copy engine scripts from repo/scripts to app bundle
for script in \
  claude-session-restore.sh \
  claude-session-snapshot.sh \
  claude-session-list.sh \
  browser-snapshot.py \
  browser-restore.py \
  claude-restore-driver.py \
  claude-geometry-snapshot.py \
  continue-prompt.txt; do
  if [ -f "$REPO_ROOT/scripts/$script" ]; then
    cp "$REPO_ROOT/scripts/$script" "$APP_DIR/Contents/Resources/engine/"
    if [[ "$script" == *.sh ]] || [[ "$script" == *.py ]]; then
      chmod +x "$APP_DIR/Contents/Resources/engine/$script"
    fi
  else
    echo "  ⚠ Missing: $script"
  fi
done

# Copy spacesctl directory
if [ -d "$REPO_ROOT/scripts/spacesctl" ]; then
  mkdir -p "$APP_DIR/Contents/Resources/engine/spacesctl"
  cp "$REPO_ROOT/scripts/spacesctl/spacesctl.m" "$APP_DIR/Contents/Resources/engine/spacesctl/" 2>/dev/null || true
  if [ -f "$REPO_ROOT/scripts/spacesctl/spacesctl" ]; then
    cp "$REPO_ROOT/scripts/spacesctl/spacesctl" "$APP_DIR/Contents/Resources/engine/spacesctl/"
    chmod +x "$APP_DIR/Contents/Resources/engine/spacesctl/spacesctl"
  fi
fi

# Copy install.sh
if [ -f "$REPO_ROOT/install.sh" ]; then
  cp "$REPO_ROOT/install.sh" "$APP_DIR/Contents/Resources/engine/"
  chmod +x "$APP_DIR/Contents/Resources/engine/install.sh"
fi

echo "✓ Engine scripts bundled"

echo ""
echo "→ Signing app…"

# Check for Developer ID Application certificate
DEV_ID_CERT=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | grep -oE '"[^"]+"' | tr -d '"' || true)

if [ -n "$DEV_ID_CERT" ]; then
  echo "✓ Found Developer ID Application certificate: $DEV_ID_CERT"

  # Sign with developer ID
  codesign --deep --options runtime --sign "$DEV_ID_CERT" "$APP_DIR" 2>&1 | grep -v "^$" || true
  echo "✓ Signed with Developer ID"

  # Attempt notarization if secrets are present
  if [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
    echo "✓ Notarization secrets found, notarizing…"

    # Create a temporary zip for notarization
    NOTARY_ZIP="/tmp/restore-ai-windows-notary-$$.zip"
    ditto -c -k --sequesterRsrc "$APP_DIR" "$NOTARY_ZIP"

    # Submit for notarization
    NOTARY_REQUEST=$(xcrun notarytool submit "$NOTARY_ZIP" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER" \
      --key <(echo "$NOTARY_KEY") \
      --output-format json 2>/dev/null | jq -r '.id' || echo "")

    if [ -n "$NOTARY_REQUEST" ] && [ "$NOTARY_REQUEST" != "null" ]; then
      echo "  Notarization submitted: $NOTARY_REQUEST"

      # Wait for notarization (with timeout)
      for i in {1..60}; do
        STATUS=$(xcrun notarytool info "$NOTARY_REQUEST" \
          --key-id "$NOTARY_KEY_ID" \
          --issuer "$NOTARY_ISSUER" \
          --key <(echo "$NOTARY_KEY") \
          --output-format json 2>/dev/null | jq -r '.status' || echo "")

        if [ "$STATUS" = "Accepted" ]; then
          echo "  ✓ Notarization accepted"
          xcrun stapler staple "$APP_DIR" >/dev/null 2>&1
          echo "  ✓ Stapled"
          break
        elif [ "$STATUS" = "Rejected" ]; then
          echo "  ✗ Notarization rejected"
          break
        fi
        sleep 10
      done
    else
      echo "  ⚠ Notarization submission failed"
    fi

    rm -f "$NOTARY_ZIP"
  else
    echo "  ⓘ Notarization skipped (no NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER env vars)"
  fi
else
  echo "ⓘ No Developer ID Application certificate found; using ad-hoc signing"
  codesign --force --deep -s - "$APP_DIR" 2>&1 | grep -v "^$" || true
  echo "✓ Ad-hoc signed"
fi

echo ""
echo "→ Building DMG…"

# Stage the app + Applications symlink
cp -r "$APP_DIR" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# Create DMG
hdiutil create \
  -volname "Restore AI Windows" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/RestoreAIWindows-$VERSION.dmg" \
  >/dev/null 2>&1

echo "✓ DMG created: RestoreAIWindows-$VERSION.dmg"

# Clean up temp directory
rm -rf "$STAGE_DIR" "$ICONSET"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Build complete!"
echo ""
echo "  App:  $APP_DIR"
echo "  DMG:  $DIST_DIR/RestoreAIWindows-$VERSION.dmg"
echo ""
