#!/bin/sh
# Packages build/Tach.app into build/Tach-<version>.dmg with a link to /Applications.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Tach.app"
[ -d "$APP" ] || { echo "build/Tach.app is missing; run scripts/build.sh first" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Tach.app"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/build/Tach-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Tach $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "built $DMG"
