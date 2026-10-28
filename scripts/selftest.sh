#!/usr/bin/env bash
# Runs the real, sandboxed app (launched through LaunchServices so it gets a
# proper GUI session) against test recordings. Inputs/outputs live in
# ~/Downloads because the sandbox only grants access there.
set -uo pipefail
cd "$(dirname "$0")/.."
BASE="$HOME/Downloads/meteora-selftest"
rm -rf "$BASE"; mkdir -p "$BASE/in" "$BASE/out"
cp Tests/MeteoraCoreTests/Fixtures/*.webm "$BASE/in/"
# Rare-format fixtures for the isolated converter (MKV, AVI, OGG, WMV).
mkdir -p "$BASE/in/convert"
cp Tests/MeteoraCoreTests/Fixtures/convert/* "$BASE/in/convert/"
[ -f /tmp/long-1920.webm ] && cp /tmp/long-1920.webm "$BASE/in/"
[ -f /tmp/ru-example.wav ] && cp /tmp/ru-example.wav "$BASE/in/"
APP="$PWD/build/Meteora.app"
status=0

run() { # input-name [extra app arguments…]
  local name=$1 out="$BASE/out/$1"; shift
  [ -f "$BASE/in/$name.webm" ] || return 0
  mkdir -p "$out"
  echo "== selftest $name"
  open -n -W --env METEORA_SELFTEST=1 --env METEORA_SELFTEST_ASR=1 --stdout "$out/stdout.txt" --stderr "$out/stderr.txt" \
       -a "$APP" --args --selftest "$BASE/in/$name.webm" "$out" --asr-wav "$BASE/in/ru-example.wav" "$@" &
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

run slides || status=1
run long-1920 || status=1
# --convert-fixtures <dir>: SelfTest converts every file in <dir> through the
# converter XPC service (MediaConverter.runSelfTest) into <out>/convert.
run audio-only --convert-fixtures "$BASE/in/convert" || status=1
mkdir -p selftest-out && cp -R "$BASE/out/." selftest-out/
exit $status
