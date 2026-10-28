#!/usr/bin/env bash
# Generates the tiny 3-second fixtures used by the converter self-test
# (Tests/MeteoraCoreTests/Fixtures/convert). Needs an ffmpeg with libvpx,
# libopus, libvorbis and libmp3lame (e.g. Ubuntu's). Not run in CI: the
# fixtures are committed.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Tests/MeteoraCoreTests/Fixtures/convert
mkdir -p "$OUT"
FF=(ffmpeg -hide_banner -loglevel error -y)
SRC=(-f lavfi -i "testsrc2=size=320x240:rate=15:duration=3"
     -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=3")
COMMON=(-map_metadata -1 -fflags +bitexact -flags:v +bitexact -flags:a +bitexact)

# MKV: VP9 + Opus
"${FF[@]}" "${SRC[@]}" "${COMMON[@]}" -c:v libvpx-vp9 -b:v 200k -deadline realtime -cpu-used 8 \
  -g 15 -c:a libopus -b:a 32k -ac 1 "$OUT/vp9-opus.mkv"
# AVI: MPEG-4 Part 2 + MP3
"${FF[@]}" "${SRC[@]}" "${COMMON[@]}" -c:v mpeg4 -q:v 10 -g 15 \
  -c:a libmp3lame -b:a 48k -ac 1 -ar 44100 "$OUT/mpeg4-mp3.avi"
# OGG: Vorbis audio only
"${FF[@]}" -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=3" "${COMMON[@]}" \
  -c:a libvorbis -q:a 1 -ac 1 "$OUT/vorbis.ogg"
# WMV: WMV2 + WMA2 (ASF)
"${FF[@]}" "${SRC[@]}" "${COMMON[@]}" -c:v wmv2 -b:v 300k -g 15 \
  -c:a wmav2 -b:a 48k -ac 1 -ar 44100 "$OUT/wmv2-wma2.wmv"
ls -la "$OUT"
