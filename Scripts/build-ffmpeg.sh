#!/bin/bash
# Builds the FFmpeg bundled in MusicAmp.app: ffmpeg + ffprobe, LGPL only (no --enable-gpl, no nonfree),
# audio decoding only, no network (radio bytes arrive on stdin), static, universal (arm64 + x86_64).
# Output: vendor/ffmpeg/{ffmpeg,ffprobe,LICENSE.txt,SOURCE.txt}. Source: https://ffmpeg.org/releases/.
# Rebuilds only when the version changes. Usage: Scripts/build-ffmpeg.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-9.0.2}"
OUT=vendor/ffmpeg
WORK=.build-ffmpeg
if [[ -x $OUT/ffmpeg && -x $OUT/ffprobe && "$(cat $OUT/VERSION 2>/dev/null)" == "$VERSION" ]]; then
    echo "FFmpeg $VERSION già pronto in $OUT"
    exit 0
fi
mkdir -p "$WORK" "$OUT"
TARBALL="$WORK/ffmpeg-$VERSION.tar.xz"
[[ -f "$TARBALL" ]] || curl -fL "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$TARBALL"
rm -rf "$WORK/src" && mkdir -p "$WORK/src"
tar xf "$TARBALL" -C "$WORK/src" --strip-components 1

DECODERS="vorbis,opus,flac,wavpack,tta,ape,mpc7,mpc8,wmav1,wmav2,wmapro,wmalossless,wmavoice,dsd_lsbf,dsd_lsbf_planar,dsd_msbf,dsd_msbf_planar,tak,shorten,alac,aac,aac_latm,mp3float,mp3,mp2float,mp2,ac3,eac3,dca,truehd,mlp,speex,cook,atrac1,atrac3,atrac3p,atrac9,amrnb,amrwb,ra_144,ra_288,wavarc,pcm_*,adpcm_*"
DEMUXERS="ogg,matroska,flac,wv,tta,ape,mpc,mpc8,asf,aiff,wav,w64,mp3,aac,mov,dsf,iff,tak,shorten,ac3,eac3,dts,truehd,mlp,au,voc,amr,rm,caf,loas,xwma,wavarc"
PARSERS="aac,aac_latm,ac3,dca,flac,mlp,mpegaudio,opus,tak,vorbis"

for ARCH in arm64 x86_64; do
    B="$WORK/build-$ARCH"
    rm -rf "$B" && mkdir -p "$B"
    EXTRA=()
    [[ $ARCH == x86_64 ]] && EXTRA+=(--disable-x86asm)   # cross build without nasm
    (cd "$B" && ../src/configure \
        --prefix=/ --arch=$ARCH --target-os=darwin --enable-cross-compile \
        --cc="clang -arch $ARCH" \
        --extra-cflags="-mmacosx-version-min=13.0" --extra-ldflags="-mmacosx-version-min=13.0 -arch $ARCH" \
        --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug \
        --disable-ffplay --enable-ffmpeg --enable-ffprobe --enable-static --disable-shared \
        --disable-swscale --disable-avdevice \
        --enable-protocol=file,pipe \
        --enable-decoder="$DECODERS" --enable-demuxer="$DEMUXERS" --enable-parser="$PARSERS" \
        --enable-encoder=pcm_f32le --enable-muxer=pcm_f32le \
        --enable-filter=aresample,aformat,anull,atrim,volume \
        ${EXTRA[@]+"${EXTRA[@]}"} > configure.log)
    grep -q "^License: LGPL" "$B/configure.log" || { echo "FFmpeg non è LGPL: interrompo"; exit 1; }
    make -C "$B" -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe > "$B/make.log"
done

for T in ffmpeg ffprobe; do
    lipo -create "$WORK/build-arm64/$T" "$WORK/build-x86_64/$T" -output "$OUT/$T"
    strip -x "$OUT/$T"
done
cp "$WORK/src/COPYING.LGPLv2.1" "$OUT/LICENSE.txt"
cat > "$OUT/SOURCE.txt" <<EOF
FFmpeg $VERSION (https://ffmpeg.org), LGPL v2.1 or later.
Source code: https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz
Built by MusicAmp's Scripts/build-ffmpeg.sh with:
$(grep -m1 "FFMPEG_CONFIGURATION" "$WORK/build-arm64/config.h" | sed "s/^#define FFMPEG_CONFIGURATION //")
EOF
echo "$VERSION" > "$OUT/VERSION"
echo "OK: $OUT ($(du -sh "$OUT" | cut -f1))"
