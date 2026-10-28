#!/usr/bin/env bash
# Runs the real, sandboxed app (launched through LaunchServices so it gets a
# proper GUI session) against test recordings. Inputs/outputs live in
# ~/Downloads because the sandbox only grants access there.
set -uo pipefail
cd "$(dirname "$0")/.."
BASE="$HOME/Downloads/meteora-selftest"
rm -rf "$BASE"; mkdir -p "$BASE/in" "$BASE/out"
cp Tests/MeteoraCoreTests/Fixtures/*.webm "$BASE/in/"
[ -f /tmp/long-1920.webm ] && cp /tmp/long-1920.webm "$BASE/in/"
[ -f /tmp/ru-example.wav ] && cp /tmp/ru-example.wav "$BASE/in/"
# Formats macOS opens itself (the native AVFoundation path).
if command -v swift >/dev/null; then
  swift scripts/make_native_fixtures.swift "$BASE/in" "$BASE/in/ru-example.wav" || echo "no mp4 fixture"
fi
if [ -f "$BASE/in/ru-example.wav" ]; then
  afconvert -f m4af -d aac "$BASE/in/ru-example.wav" "$BASE/in/speech.m4a" || true
  afconvert -f flac -d flac "$BASE/in/ru-example.wav" "$BASE/in/speech.flac" || true
fi
APP="$PWD/build/Meteora.app"
status=0

run() { # input-file-name
  local file=$1 name="${1%.*}-${1##*.}" out="$BASE/out/${1%.*}-${1##*.}"
  [ -f "$BASE/in/$file" ] || return 0
  mkdir -p "$out"
  echo "== selftest $name"
  open -n -W --env METEORA_SELFTEST=1 --env METEORA_SELFTEST_ASR=1 --stdout "$out/stdout.txt" --stderr "$out/stderr.txt" \
       -a "$APP" --args --selftest "$BASE/in/$file" "$out" --asr-wav "$BASE/in/ru-example.wav" &
  local pid=$!
  for _ in $(seq 1 420); do kill -0 $pid 2>/dev/null || break; sleep 1; done
  if kill -0 $pid 2>/dev/null; then
    echo "timeout"; pkill -9 -f "Meteora.app/Contents/MacOS/Meteora" || true; kill $pid 2>/dev/null
    echo '{"ok":false,"errors":["timeout"]}' > "$out/report.json"
  fi
  wait $pid 2>/dev/null
  cat "$out/report.json" 2>/dev/null || echo '{"ok":false,"errors":["no report"]}' > "$out/report.json"
  python3 -c "import json,sys; sys.exit(0 if json.load(open('$out/report.json')).get('ok') else 1)"
}

for f in slides.webm long-1920.webm audio-only.webm slides.mp4 speech.m4a speech.flac; do run "$f" || status=1; done
mkdir -p selftest-out && cp -R "$BASE/out/." selftest-out/
exit $status
