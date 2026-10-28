#!/usr/bin/env bash
# Runs the real, sandboxed app against test recordings. Inputs/outputs live
# in ~/Downloads because the sandbox only grants access there.
set -uo pipefail
cd "$(dirname "$0")/.."
BASE="$HOME/Downloads/volant-selftest"
rm -rf "$BASE"; mkdir -p "$BASE/in" "$BASE/out"
cp Tests/VolantCoreTests/Fixtures/*.webm "$BASE/in/"
[ -f /tmp/long-1920.webm ] && cp /tmp/long-1920.webm "$BASE/in/"
status=0
for name in slides long-1920 audio-only; do
  [ -f "$BASE/in/$name.webm" ] || continue
  mkdir -p "$BASE/out/$name"
  echo "== selftest $name"
  build/Volant.app/Contents/MacOS/Volant --selftest "$BASE/in/$name.webm" "$BASE/out/$name" > "$BASE/out/$name/stdout.txt" 2>&1 &
  pid=$!
  for _ in $(seq 1 600); do kill -0 $pid 2>/dev/null || break; sleep 1; done
  if kill -0 $pid 2>/dev/null; then echo "timeout"; kill -9 $pid; status=1; echo '{"ok":false,"errors":["timeout"]}' > "$BASE/out/$name/report.json"; fi
  wait $pid; rc=$?
  echo "exit $rc"; [ $rc -eq 0 ] || status=1
  cat "$BASE/out/$name/report.json" 2>/dev/null || { echo "no report"; status=1; }
done
mkdir -p selftest-out && cp -R "$BASE/out/." selftest-out/
exit $status
