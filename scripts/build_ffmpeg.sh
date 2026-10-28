#!/usr/bin/env bash
# Builds the minimal, LGPL-only, static, universal (arm64 + x86_64) `ffmpeg`
# CLI used by the isolated converter service (MeteoraConverter.xpc).
#
# Source: the official FFmpeg git repository at a pinned release tag. The
# checkout is verified twice before anything is compiled:
#   1. the tag must resolve to the pinned commit (git object id), and
#   2. a SHA-256 over every file of the tree (sorted, `.git` excluded) must
#      match the pinned value.
# Release tarballs from ffmpeg.org could not be fetched (and hashed) from the
# environment where this pin was made, so the tree hash is pinned instead.
# The tree hash is computed exactly like this, on Linux or macOS:
#   find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z \
#     | xargs -0 shasum -a 256 | shasum -a 256
#
# Output: Vendor/ffmpeg/bin/ffmpeg (universal), Vendor/ffmpeg/CONFIGURE.txt,
# Vendor/ffmpeg/COPYING.LGPLv2.1.
# The result is reused when Vendor/ffmpeg/STAMP matches (version + hash of
# this script), which is also what the CI cache key is made of.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

FFMPEG_VERSION=7.1.5
FFMPEG_TAG=n7.1.5
FFMPEG_GIT=https://github.com/FFmpeg/FFmpeg.git
FFMPEG_COMMIT=3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587
FFMPEG_TREE_SHA256=abb9354ece9823b639f8fa744bda414174c221cacbefc7adf12da3cc659427a2
MACOS_MIN=14.0

OUT=Vendor/ffmpeg
WORK=Vendor/ffmpeg-build
SRC=$WORK/ffmpeg-$FFMPEG_VERSION
STAMP="$FFMPEG_VERSION $(shasum -a 256 "$ROOT/scripts/build_ffmpeg.sh" | cut -d' ' -f1)"

if [ -x "$OUT/bin/ffmpeg" ] && [ "$(cat "$OUT/STAMP" 2>/dev/null)" = "$STAMP" ]; then
  echo "ffmpeg $FFMPEG_VERSION already built ($OUT/bin/ffmpeg)"
  lipo -info "$OUT/bin/ffmpeg"
  exit 0
fi
[ "$(uname -s)" = Darwin ] || { echo "build_ffmpeg.sh must run on macOS"; exit 1; }

# ---------------------------------------------------------------- source
rm -rf "$WORK" && mkdir -p "$WORK"
git -c advice.detachedHead=false -c core.autocrlf=false \
  clone --quiet --depth 1 --branch "$FFMPEG_TAG" "$FFMPEG_GIT" "$SRC"
got_commit=$(git -C "$SRC" rev-parse HEAD)
echo "ffmpeg $FFMPEG_TAG commit = $got_commit"
[ "$got_commit" = "$FFMPEG_COMMIT" ] || { echo "COMMIT MISMATCH (expected $FFMPEG_COMMIT)"; exit 1; }
got_tree=$(cd "$SRC" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z \
  | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
echo "ffmpeg source tree sha256 = $got_tree"
[ "$got_tree" = "$FFMPEG_TREE_SHA256" ] || { echo "TREE HASH MISMATCH (expected $FFMPEG_TREE_SHA256)"; exit 1; }

# ---------------------------------------------------------------- configuration
# LGPL only: no --enable-gpl, no --enable-nonfree, no external libraries
# except Apple system frameworks (VideoToolbox, AudioToolbox, CoreMedia,
# CoreVideo, CoreFoundation) and the system zlib (compressed Matroska tracks).
# No network code at all; the only protocols are fd/pipe/file.
DEMUXERS=matroska,avi,asf,flv,mpegps,mpegts,mpegvideo,ogg,mov,mp3,wav,aiff,flac,aac,ac3,eac3,amr,caf,au,w64
DECODERS=h264,hevc,mpeg4,mpeg1video,mpeg2video,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,wmv3,vc1,vp8,vp9,flv,h263,theora,mjpeg
DECODERS+=,aac,aac_latm,mp1,mp2,mp3,mp1float,mp2float,mp3float,opus,vorbis,flac,alac,wmav1,wmav2,wmapro,wmavoice,wmalossless
DECODERS+=,ac3,eac3,dca,truehd,mlp,amrnb,amrwb,pcm_*,adpcm_ima_wav,adpcm_ima_qt,adpcm_ms,gsm,gsm_ms
# mpeg4 is the software fallback if VideoToolbox can't open an H.264 session.
ENCODERS=aac,h264_videotoolbox,mpeg4,pcm_s16le
MUXERS=mp4,mov,ipod
PARSERS=aac,aac_latm,ac3,amr,dca,flac,gsm,h263,h264,hevc,mjpeg,mlp,mpeg4video,mpegaudio,mpegvideo,opus,vc1,vorbis,vp3,vp8,vp9
BSFS=aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb,mpeg4_unpack_bframes,null,vp9_superframe_split
# bwdif (LGPL) deinterlaces only frames flagged interlaced (DVD/VOB, AVCHD).
FILTERS=aresample,scale,format,null,anull,aformat,bwdif
PROTOCOLS=fd,pipe,file

COMMON_FLAGS=(
  --enable-cross-compile --target-os=darwin
  --disable-shared --enable-static --disable-debug --enable-stripping
  --disable-autodetect --disable-everything --disable-network
  --disable-doc --disable-ffplay --disable-ffprobe
  --disable-avdevice --disable-postproc --disable-iconv
  --enable-zlib --enable-videotoolbox --enable-audiotoolbox
  --enable-demuxer="$DEMUXERS" --enable-decoder="$DECODERS" --enable-encoder="$ENCODERS"
  --enable-muxer="$MUXERS" --enable-parser="$PARSERS" --enable-bsf="$BSFS"
  --enable-filter="$FILTERS" --enable-protocol="$PROTOCOLS"
)

build_arch() { # arm64 | x86_64
  local arch=$1 dir="$ROOT/$WORK/build-$1"
  local extra=()
  # NASM is not part of the runner image and nothing is installed from
  # Homebrew; the Intel slice uses C (+ inline asm) code paths only.
  if [ "$arch" = x86_64 ]; then extra+=(--disable-x86asm); fi
  mkdir -p "$dir"
  ( cd "$dir"
    "$ROOT/$SRC/configure" --arch="$arch" --cc="clang -arch $arch" \
      --extra-cflags="-mmacosx-version-min=$MACOS_MIN" \
      --extra-ldflags="-mmacosx-version-min=$MACOS_MIN" \
      "${COMMON_FLAGS[@]}" ${extra[@]+"${extra[@]}"} > configure.log 2>&1 \
      || { tail -50 configure.log; tail -80 ffbuild/config.log; exit 1; }
    grep -q '^License: LGPL' configure.log || { echo "configure did not select an LGPL license"; tail -5 configure.log; exit 1; }
    grep '^WARNING' configure.log || true
    make -j"$(sysctl -n hw.ncpu)" ffmpeg > make.log 2>&1 || { tail -80 make.log; exit 1; }
  )
  echo "built $arch: $(lipo -info "$dir/ffmpeg")"
}

build_arch arm64
build_arch x86_64

rm -rf "$OUT" && mkdir -p "$OUT/bin"
lipo -create "$WORK/build-arm64/ffmpeg" "$WORK/build-x86_64/ffmpeg" -output "$OUT/bin/ffmpeg"
chmod 755 "$OUT/bin/ffmpeg"

# ---------------------------------------------------------------- checks
lipo -info "$OUT/bin/ffmpeg"
echo "linked libraries:"; otool -L "$OUT/bin/ffmpeg"
# Only Apple system libraries may be linked dynamically. (Outputs are captured
# first: `cmd | grep -q` can fail spuriously under pipefail.)
LIBS=$(otool -L "$OUT/bin/ffmpeg")
if tail -n +2 <<<"$LIBS" | grep -v ':$' | grep -v -E '^[[:space:]]+(/usr/lib/|/System/Library/)' | grep .; then
  echo "ffmpeg links a non-system library"; exit 1
fi
# The universal binary runs natively on the build machine.
BIN="$OUT/bin/ffmpeg"
LICENSE_TEXT=$("$BIN" -hide_banner -L)
head -4 <<<"$LICENSE_TEXT"
grep -q 'Lesser General Public' <<<"$LICENSE_TEXT" || { echo "ffmpeg is not LGPL"; exit 1; }
BUILDCONF=$("$BIN" -hide_banner -buildconf)
if grep -E -- '--enable-(gpl|nonfree|version3)' <<<"$BUILDCONF"; then echo "forbidden configure flag"; exit 1; fi
PROTOS=$("$BIN" -hide_banner -protocols 2>/dev/null | grep -E '^[[:space:]]+[a-z]' | tr -d ' ' | sort -u | tr '\n' ' ')
echo "protocols: $PROTOS"
[ "$PROTOS" = "fd file pipe " ] || { echo "unexpected protocols: $PROTOS"; exit 1; }
ENCODERS_LIST=$("$BIN" -hide_banner -encoders 2>/dev/null)
grep -q h264_videotoolbox <<<"$ENCODERS_LIST" || { echo "h264_videotoolbox missing"; exit 1; }

# Exact configure line for THIRD_PARTY_NOTICES / LGPL source offer.
{
  echo "FFmpeg $FFMPEG_VERSION ($FFMPEG_TAG, commit $FFMPEG_COMMIT)"
  echo "Source: $FFMPEG_GIT (tag $FFMPEG_TAG)"
  echo "Configure (per arch, arch = arm64 | x86_64; x86_64 adds --disable-x86asm):"
  echo "./configure --arch=<arch> --cc='clang -arch <arch>' --extra-cflags=-mmacosx-version-min=$MACOS_MIN --extra-ldflags=-mmacosx-version-min=$MACOS_MIN ${COMMON_FLAGS[*]}"
} > "$OUT/CONFIGURE.txt"
cat "$OUT/CONFIGURE.txt"
cp "$SRC/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1"
echo "$STAMP" > "$OUT/STAMP"
rm -rf "$WORK"
du -h "$OUT/bin/ffmpeg"
