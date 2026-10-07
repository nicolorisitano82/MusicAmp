#!/bin/bash
# Builds build/MusicAmp.app (release, ad-hoc signed) and build/MusicAmp-<version>.dmg.
# --no-dmg skips the disk image (faster when only the app is needed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/MusicAmp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MusicAmp "$APP/Contents/MacOS/MusicAmp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "OK: $APP"

[[ "${1:-}" == "--no-dmg" ]] && exit 0

# Disk image: the app next to a link to /Applications, compressed (UDZO).
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/MusicAmp-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE.txt"
rm -f "$DMG"
# (hdiutil still works; only its "deprecated" notice is filtered out, real errors still show.)
hdiutil create -volname "MusicAmp $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" \
    > /dev/null 2> >(grep -v "is deprecated" >&2)
echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"
