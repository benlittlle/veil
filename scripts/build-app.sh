#!/bin/bash
# Builds build/Veil.app (menu bar app + the veil-mcp relay inside it).
#   scripts/build-app.sh            build and sign
#   scripts/build-app.sh --install  also copy to ~/Applications
# Signing: uses your "Developer ID Application" certificate if you have one, otherwise your first
# "Apple Development" certificate, so macOS permissions (Full Disk Access, Contacts) survive rebuilds.
# Override with SIGN_IDENTITY=..., or "-" for ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Veil.app
BUNDLE_ID=${BUNDLE_ID:-io.github.benlittlle.veil}
# Updates: Sparkle reads this feed and only installs updates signed with the matching private key.
FEED_URL=${FEED_URL:-https://github.com/benlittlle/veil/releases/latest/download/appcast.xml}
SPARKLE_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-jtTvzHPo3uWT0aDKGkEipARyReGhPhBShbzvlGnCRF8=}
VERSION=${VERSION:-1.0.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}

swift build -c release --product Veil
swift build -c release --product veil-mcp
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Veil" "$APP/Contents/MacOS/Veil"
# Sparkle (auto-updates). Veil isn't sandboxed, so Sparkle's XPC services aren't needed.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Veil" 2>/dev/null || true
cp "$BIN/veil-mcp" "$APP/Contents/MacOS/veil-mcp"

# App icon: built from the branding artwork on every build (graphite, the default accent).
# The 1024px PNG is already a rounded tile with a transparent surround.
ICON_SRC=Branding/icon/app
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_SRC/veil-icon-graphite.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ICON_SRC/veil-icon-graphite.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Dock icons: one per accent, swapped in at runtime (Settings → Accent). Sage uses the forest colourway.
mkdir -p "$APP/Contents/Resources/DockIcons"
for c in graphite clay forest ocean plum; do
  sips -z 512 512 "$ICON_SRC/veil-icon-$c.png" --out "$APP/Contents/Resources/DockIcons/veil-icon-$c.png" >/dev/null
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Veil</string>
  <key>CFBundleDisplayName</key><string>Veil</string>
  <key>CFBundleExecutable</key><string>Veil</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSContactsUsageDescription</key><string>Veil shows contact names instead of phone numbers. Names never leave your Mac unless you share a chat.</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>NSAppleEventsUsageDescription</key><string>Veil sends a message through Messages only after you click Send on it.</string>
</dict>
</plist>
PLIST

IDS=$(security find-identity -v -p codesigning)
IDENTITY=${SIGN_IDENTITY:-$(awk -F'"' '/Developer ID Application/{print $2; exit}' <<<"$IDS")}
IDENTITY=${IDENTITY:-$(awk -F'"' '/Apple Development/{print $2; exit}' <<<"$IDS")}
IDENTITY=${IDENTITY:--}
echo "Signing with: $IDENTITY"
# Developer ID builds (for download) need the hardened runtime and a secure timestamp to notarize.
SIGN_FLAGS=()
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
  SIGN_FLAGS=(--options runtime --timestamp --entitlements scripts/Veil.entitlements)
fi
RUNTIME=(); [[ "$IDENTITY" == "Developer ID Application:"* ]] && RUNTIME=(--options runtime --timestamp)
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$SPK/Autoupdate"
codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$SPK/Updater.app"
codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} --identifier "$BUNDLE_ID.mcp" "$APP/Contents/MacOS/veil-mcp"
codesign --force --sign "$IDENTITY" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x Veil 2>/dev/null || true
  rm -rf "$HOME/Applications/Veil.app"
  cp -R "$APP" "$HOME/Applications/Veil.app"
  echo "Installed to ~/Applications/Veil.app"
fi
