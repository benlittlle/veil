#!/bin/bash
# Builds a signed, notarized Veil-<version>.dmg for download.
#   VERSION=1.0.0 scripts/release.sh
# Needs a "Developer ID Application" certificate in the login Keychain and a notarytool
# Keychain profile (default "veil-notary"; see CONTRIBUTING.md → Releasing).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:?set VERSION, e.g. VERSION=1.0.0}
PROFILE=${NOTARY_PROFILE:-veil-notary}
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate found." >&2; exit 1; }

BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
SIGN_IDENTITY="$IDENTITY" VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" scripts/build-app.sh

DMG=build/Veil-$VERSION.dmg
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R build/Veil.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Veil $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "Notarizing (usually a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# Sparkle feed: one item for this version, signed with the EdDSA key in the login Keychain
# (account "veil"). Upload the DMG and appcast.xml to the GitHub release tagged v$VERSION;
# the app reads releases/latest/download/appcast.xml.
REPO=${REPO:-benlittlle/veil}
SPARKLE_BIN=$(swift build -c release --show-bin-path)/../artifacts/sparkle/Sparkle/bin
[ -x "$SPARKLE_BIN/sign_update" ] || SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
SIG=$("$SPARKLE_BIN/sign_update" --account veil "$DMG")   # sparkle:edSignature="…" length="…"
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Veil</title>
    <item>
      <title>Veil $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Veil-$VERSION.dmg" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML

shasum -a 256 "$DMG"
echo "Ready: $DMG and build/appcast.xml"
echo "Publish: gh release create v$VERSION $DMG build/appcast.xml --title \"Veil $VERSION\" --notes-file <notes>"
