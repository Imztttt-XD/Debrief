#!/bin/zsh
# Packs build/Debrief.app into build/Debrief-<version>.dmg (drag-to-Applications layout).
# Usage: scripts/make-dmg.sh [version]   (default: CFBundleShortVersionString of the built app)
set -euo pipefail
cd "${0:A:h}/.."
APP=build/Debrief.app
[[ -d "$APP" ]] || { echo "Run ./build-app.sh first" >&2; exit 1; }
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
DMG="build/Debrief-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Debrief $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG" >/dev/null
echo "$DMG"
