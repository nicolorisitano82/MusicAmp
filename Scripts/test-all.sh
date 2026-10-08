#!/bin/bash
# Runs every MusicAmp test suite and prints a summary; exits 1 if any suite failed.
#
#   Scripts/test-all.sh               debug build, all suites (network ones only when online)
#   Scripts/test-all.sh --offline     skip the suites that need the internet
#   Scripts/test-all.sh --release     test the optimised build (what ships)
#   Scripts/test-all.sh --package     also check build/MusicAmp.app: Apple Silicon/macOS 26, signature, widget,
#                                     Shortcuts metadata, versions (run ./build-app.sh first)
#   Scripts/test-all.sh --ui          also the window tests (they open MusicAmp windows for a few seconds)
#   Scripts/test-all.sh suite …       only the named suites, e.g. `Scripts/test-all.sh sonic vocal`
#
# Audio suites play generated sound through the engine at volume 0: nothing is audible, and the output
# device's sample rate is never changed. Suites that need a full FFmpeg (to encode test files) are skipped
# when Homebrew's ffmpeg is missing; set MUSICAMP_TEST_RADIO_URL to also test a live radio stream.
set -uo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
OFFLINE=0
PACKAGE=0
UI=0
ONLY=()
for a in "$@"; do
    case "$a" in
        --offline) OFFLINE=1 ;;
        --release) CONFIG=release ;;
        --package) PACKAGE=1 ;;
        --ui) UI=1 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) ONLY+=("$a") ;;
    esac
done

# Suite name | command-line flag | requirement (none, net, ffmpeg, radio, ui) | timeout (s) | what it covers
# | success line (regex, default "ALL PASSED|ALL OK": a suite must say it passed, not just stay quiet)
SUITES=(
    "self|--self-test|none|120|EQ presets, queue, drop insertion, Retina skins, playlist tree and search"
    "transitions|--test-transitions|none|180|gapless, crossfade, EBU R128 loudness, ReplayGain tags"
    "smart|--test-smart|none|120|smart transitions: silence trimming, albums kept gapless"
    "cue|--test-cue|none|120|cue sheets: parsing, folders, segments, gapless into the next track"
    "waveform|--test-waveform|none|120|waveform seek bar: levels, cue segments, cache, skin pixels untouched"
    "vocal|--test-vocal|none|60|vocal remover: centre removed, sides and bass kept"
    "crossfeed|--test-crossfeed|none|90|headphone crossfeed: feed levels, highs, mono level"
    "spoken|--test-spoken|none|90|podcasts: pause detection, shortened silences, Voice Boost levels"
    "bitperfect|--test-bitperfect|none|60|device rate choice, chain rebuilt at another rate (device untouched)"
    "sonic|--test-sonic|none|120|sonic analysis (tempo, key, timbre), radio, journey, smoothing"
    "stats|--test-stats|none|60|play counts, skips, ratings, smart playlist rules (genre, year, BPM, key)"
    "schedule|--test-schedule|none|30|alarm times, fades, widget state, musicamp:// URLs"
    "dock|--test-dock|none|60|Dock mode: icon click plays/pauses, Dock menu, live icon, mini tile"
    "ai|--test-ai|none|300|Apple Intelligence: podcast transcript/chapters/summary/ads, tag clean-up, playlists in words"
    "milkdrop|--test-milkdrop|none|300|NS-EEL, .milk parsing, HLSL→Metal shaders, offscreen renders"
    "karaoke|--karaoke-sweep|none|120|karaoke rendering: no flicker, no layout jumps|flickers 0"
    "tags|--test-tags|ffmpeg|180|tag writing: MP3 ID3v2.3/2.4, FLAC, M4A, ratings (POPM, RATING), playlist genre/year"
    "ffmpeg|--test-ffmpeg|ffmpeg|180|FFmpeg formats (Ogg, Opus, WavPack, TTA) through the engine"
    "peq|--test-peq|net|120|parametric EQ maths and engine level, live AutoEq catalogue"
    "lyrics|--test-lyrics|net|120|LRC parsing, word timing, LRCLIB lookups"
    "podcast|--test-podcast|net|240|RSS, OPML, real feed, streamed episode with resume"
    "musicbrainz|--test-musicbrainz|net|120|MusicBrainz / Cover Art Archive lookups, file mapping"
    "radio|--test-radio|radio|60|a live radio stream (MUSICAMP_TEST_RADIO_URL)|state=playing.*error=none"
    "drag|MUSICAMP_TEST_DRAG|ui|60|window drag: docked windows follow, groups rebuilt|DRAG OK"
)

bold=$(tput bold 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
green=$(tput setaf 2 2>/dev/null || true); red=$(tput setaf 1 2>/dev/null || true); yellow=$(tput setaf 3 2>/dev/null || true)

echo "${bold}Building ($CONFIG)…${reset}"
if ! swift build -c "$CONFIG" 2>&1 | grep -E "error:|Build complete" ; then :; fi
BIN=".build/$CONFIG/MusicAmp"
[[ -x "$BIN" ]] || { echo "${red}build failed${reset}"; exit 1; }

ONLINE=1
if (( OFFLINE )) || ! curl -sfI --max-time 5 https://musicbrainz.org >/dev/null 2>&1; then ONLINE=0; fi
HAVE_FFMPEG=0
for f in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do [[ -x "$f" ]] && HAVE_FFMPEG=1; done

LOGDIR=$(mktemp -d "${TMPDIR:-/tmp}/musicamp-tests.XXXX")
passed=0; failed=0; skipped=0
FAILED_NAMES=()
printf "\n%-13s %-8s %7s  %s\n" "SUITE" "RESULT" "TIME" "DETAIL"

run_with_timeout() {   # seconds, log, command…
    local t=$1 log=$2; shift 2
    "$@" >"$log" 2>&1 &
    local pid=$!
    ( sleep "$t"; kill -9 "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null; local code=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    return $code
}

for entry in "${SUITES[@]}"; do
    IFS='|' read -r name flag req limit what marker <<<"$entry"
    [[ -n "$marker" ]] || marker="ALL PASSED|ALL OK"
    if (( ${#ONLY[@]} )); then
        [[ " ${ONLY[*]} " == *" $name "* ]] || continue
    fi
    skip=""
    case "$req" in
        net) (( ONLINE )) || skip="offline" ;;
        ffmpeg) (( HAVE_FFMPEG )) || skip="needs Homebrew ffmpeg to encode test files" ;;
        radio) [[ -n "${MUSICAMP_TEST_RADIO_URL:-}" ]] && (( ONLINE )) || skip="set MUSICAMP_TEST_RADIO_URL" ;;
        ui) (( UI )) || skip="window test: use --ui" ;;
    esac
    if [[ -n "$skip" ]]; then
        printf "%-13s ${yellow}%-8s${reset} %7s  %s\n" "$name" "SKIP" "" "$skip"
        skipped=$((skipped + 1))
        continue
    fi
    log="$LOGDIR/$name.log"
    start=$(date +%s)
    case "$req" in
        radio) run_with_timeout "$limit" "$log" "$BIN" --test-radio "$MUSICAMP_TEST_RADIO_URL" 8 ;;
        ui) MUSICAMP_TEST_DRAG=1 run_with_timeout "$limit" "$log" "$BIN" ;;
        *) run_with_timeout "$limit" "$log" "$BIN" $flag ;;
    esac
    code=$?
    secs=$(( $(date +%s) - start ))
    # A suite that reports "SKIP …" (e.g. Apple Intelligence turned off) is skipped, not failed.
    if grep -q "^SKIP" "$log" && [[ $code -eq 2 ]]; then
        printf "%-13s ${yellow}%-8s${reset} %6ss  %s\n" "$name" "SKIP" "$secs" "$(grep -m1 '^SKIP' "$log" | cut -c6-)"
        skipped=$((skipped + 1))
        continue
    fi
    # A suite passes only with a zero exit, its success line, and no FAIL line; a timeout is a failure.
    fails=$(grep -cE "^FAIL|FAILED|DRAG FAIL|Fatal error" "$log" || true)
    if [[ $code -eq 0 && $fails -eq 0 ]] && grep -qE "$marker" "$log"; then
        printf "%-13s ${green}%-8s${reset} %6ss  %s\n" "$name" "PASS" "$secs" "$what"
        passed=$((passed + 1))
    else
        reason="exit $code"; (( code == 137 )) && reason="timed out after ${limit}s"
        [[ $code -eq 0 && $fails -eq 0 ]] && reason="no success line"
        printf "%-13s ${red}%-8s${reset} %6ss  %s (%s)\n" "$name" "FAIL" "$secs" "$what" "$reason"
        grep -E "^FAIL|FAILED|Fatal error|error" "$log" | head -5 | sed 's/^/                 │ /'
        failed=$((failed + 1))
        FAILED_NAMES+=("$name")
    fi
done

# Packaged app checks.
if (( PACKAGE )); then
    echo
    APP=build/MusicAmp.app
    check() {   # description, command…
        local what=$1; shift
        if "$@" >/dev/null 2>&1; then printf "%-13s ${green}%-8s${reset} %7s  %s\n" "package" "PASS" "" "$what"; passed=$((passed + 1))
        else printf "%-13s ${red}%-8s${reset} %7s  %s\n" "package" "FAIL" "" "$what"; failed=$((failed + 1)); FAILED_NAMES+=("package: $what"); fi
    }
    arm64only() { [[ $(lipo -archs "$1") == arm64 ]] && otool -l "$1" | grep -A3 LC_BUILD_VERSION | grep -q "minos 26"; }
    actions() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if len(d['actions']) >= int(sys.argv[2]) else 1)" "$1" "$2"; }
    plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }
    if [[ ! -d "$APP" ]]; then
        printf "%-13s ${red}%-8s${reset} %7s  %s\n" "package" "FAIL" "" "$APP missing: run ./build-app.sh first"; failed=$((failed + 1)); FAILED_NAMES+=("package")
    else
        WX="$APP/Contents/PlugIns/MusicAmpWidget.appex"
        check "app binary is Apple Silicon only, macOS 26" arm64only "$APP/Contents/MacOS/MusicAmp"
        check "widget binary is Apple Silicon only, macOS 26" arm64only "$WX/Contents/MacOS/MusicAmpWidget"
        check "bundled ffmpeg and ffprobe are Apple Silicon" bash -c "[[ \$(lipo -archs '$APP/Contents/Helpers/ffmpeg') == arm64 && \$(lipo -archs '$APP/Contents/Helpers/ffprobe') == arm64 ]]"
        check "Info.plist requires macOS 26" bash -c "[[ \$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' '$APP/Contents/Info.plist') == 26.0 ]]"
        check "code signature valid (deep, strict)" codesign --verify --deep --strict "$APP"
        check "widget starts in NSExtensionMain" bash -c "nm -u '$WX/Contents/MacOS/MusicAmpWidget' | grep -q _NSExtensionMain"
        check "widget is sandboxed, reads only the widget folder" bash -c "codesign -d --entitlements - '$WX' 2>/dev/null | grep -q app-sandbox && codesign -d --entitlements - '$WX' 2>/dev/null | grep -q 'MusicAmp/Widget'"
        check "Shortcuts metadata: all 19 app actions" actions "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" 19
        check "widget button actions present" actions "$WX/Contents/Resources/Metadata.appintents/extract.actionsdata" 3
        check "app and widget versions match" bash -c "[[ '$(plist "$APP/Contents/Info.plist" CFBundleShortVersionString)' == '$(plist "$WX/Contents/Info.plist" CFBundleShortVersionString)' ]]"
        check "musicamp:// URL scheme declared" bash -c "/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' '$APP/Contents/Info.plist' | grep -qx musicamp"
        check "FFmpeg licence shipped" test -f "$APP/Contents/Resources/FFmpeg/LICENSE.txt"
        check "packaged binary runs: --test-schedule" "$APP/Contents/MacOS/MusicAmp" --test-schedule
    fi
fi

echo
total=$((passed + failed))
if (( failed == 0 )); then
    echo "${green}${bold}All $total checks passed${reset}, $skipped skipped.  Logs: $LOGDIR"
    exit 0
fi
echo "${red}${bold}$failed of $total failed${reset} (${FAILED_NAMES[*]}), $skipped skipped.  Logs: $LOGDIR"
exit 1
