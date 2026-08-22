#!/usr/bin/env bash
# Builds HeadsetCompanion.app and wraps it in a drag-to-Applications DMG.
#   ./make-dmg.sh            -> dist/HeadsetCompanion-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"
./build-app.sh >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
STAGE="$(mktemp -d)"
cp -R HeadsetCompanion.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
OUT="dist/HeadsetCompanion-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "HeadsetCompanion $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "$OUT"
