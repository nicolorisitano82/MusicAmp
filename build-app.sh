#!/bin/bash
# Builds build/MusicAmp.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/MusicAmp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MusicAmp "$APP/Contents/MacOS/MusicAmp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "OK: $APP"
