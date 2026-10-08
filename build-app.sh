#!/bin/bash
# Builds build/MusicAmp.app (release, universal arm64 + x86_64, ad-hoc signed, with a bundled LGPL FFmpeg)
# and build/MusicAmp-<version>.dmg.
# --no-dmg skips the disk image (faster when only the app is needed).
set -euo pipefail
cd "$(dirname "$0")"

# One release build per architecture (each one alone keeps the constant-values flags of Package.swift working;
# a single multi-arch build drops them), copied aside and joined with lipo. Apple Silicon last: its
# .build/<module>.swiftconstvalues feed the App Intents metadata below.
ARCHDIR=.build/universal
rm -rf "$ARCHDIR"
# The constant values are written only when a module compiles: if one is missing, make it compile.
for m in MusicAmp MusicAmpWidget; do
    [[ -f ".build/$m.swiftconstvalues" ]] || touch Sources/$m/*.swift
done
for arch in x86_64 arm64; do
    swift build -c release --triple "$arch-apple-macosx14.0"
    bin=$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)
    mkdir -p "$ARCHDIR/$arch"
    cp "$bin/MusicAmp" "$bin/MusicAmpWidget" "$ARCHDIR/$arch/"
done
universal() {   # product, destination
    lipo -create "$ARCHDIR/arm64/$1" "$ARCHDIR/x86_64/$1" -output "$2"
}
APP=build/MusicAmp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
universal MusicAmp "$APP/Contents/MacOS/MusicAmp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# App Intents metadata (Shortcuts actions, widget buttons): what Xcode does, from the constant values the
# release build wrote (see Package.swift).
appintents() {   # module, destination Resources folder
    local list cv out
    list=$(mktemp); cv=$(mktemp); out=$(mktemp -d)
    ls "$PWD/Sources/$1"/*.swift > "$list"
    echo "$PWD/.build/$1.swiftconstvalues" > "$cv"
    xcrun appintentsmetadataprocessor --output "$out" --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
        --module-name "$1" --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
        --platform-family macOS --deployment-target 14.0 --target-triple "$(uname -m)-apple-macos14.0" \
        --source-file-list "$list" --swift-const-vals-list "$cv" --force --quiet-warnings 2>&1 | grep -iE "error|warning" >&2 || true
    cp -R "$out/Metadata.appintents" "$2/"
    rm -rf "$list" "$cv" "$out"
}
appintents MusicAmp "$APP/Contents/Resources"

# Widget extension (WidgetKit, sandboxed).
APPEX="$APP/Contents/PlugIns/MusicAmpWidget.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
universal MusicAmpWidget "$APPEX/Contents/MacOS/MusicAmpWidget"
cp Resources/Widget/Info.plist "$APPEX/Contents/Info.plist"
appintents MusicAmpWidget "$APPEX/Contents/Resources"
codesign --force --sign - --entitlements Resources/Widget/Widget.entitlements "$APPEX" >/dev/null

# Bundled FFmpeg (LGPL, decode only): built once from ffmpeg.org sources into vendor/ffmpeg.
Scripts/build-ffmpeg.sh
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/FFmpeg"
cp vendor/ffmpeg/ffmpeg vendor/ffmpeg/ffprobe "$APP/Contents/Helpers/"
cp vendor/ffmpeg/LICENSE.txt vendor/ffmpeg/SOURCE.txt "$APP/Contents/Resources/FFmpeg/"
codesign --force --sign - "$APP/Contents/Helpers/ffmpeg" "$APP/Contents/Helpers/ffprobe" >/dev/null
codesign --force --sign - "$APP" >/dev/null
# Keep this build copy out of Launch Services: two apps with the same bundle id (this one and the installed one)
# make the widget extension record flip between them and the widget gallery drop MusicAmp's widgets.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" >/dev/null 2>&1 || true
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
mkdir -p "$STAGE/FFmpeg"
cp vendor/ffmpeg/LICENSE.txt vendor/ffmpeg/SOURCE.txt "$STAGE/FFmpeg/"
rm -f "$DMG"
# (hdiutil still works; only its "deprecated" notice is filtered out, real errors still show.)
hdiutil create -volname "MusicAmp $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" \
    > /dev/null 2> >(grep -v "is deprecated" >&2)
echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"
