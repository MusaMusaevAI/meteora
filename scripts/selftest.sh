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
APP="$PWD/build/Meteora.app"
status=0

run() { # input-name
  local name=$1 out="$BASE/out/$1"
  [ -f "$BASE/in/$name.webm" ] || return 0
  mkdir -p "$out"
  echo "== selftest $name"
  open -n -W --env METEORA_SELFTEST=1 --env METEORA_SELFTEST_ASR=1 --stdout "$out/stdout.txt" --stderr "$out/stderr.txt" \
       -a "$APP" --args --selftest "$BASE/in/$name.webm" "$out" --asr-wav "$BASE/in/ru-example.wav" &
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

for name in slides long-1920 audio-only; do run "$name" || status=1; done
mkdir -p selftest-out && cp -R "$BASE/out/." selftest-out/
exit $status
