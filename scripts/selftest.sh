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

run() { # app input-name out-name
  local app=$1 name=$2 out=$3
  [ -f "$BASE/in/$name.webm" ] || return 0
  mkdir -p "$BASE/out/$out"
  echo "== selftest $out ($app)"
  "$app/Contents/MacOS/Volant" --selftest "$BASE/in/$name.webm" "$BASE/out/$out" > "$BASE/out/$out/stdout.txt" 2>&1 &
  local pid=$!
  for _ in $(seq 1 600); do kill -0 $pid 2>/dev/null || break; sleep 1; done
  if kill -0 $pid 2>/dev/null; then echo "timeout"; kill -9 $pid; echo '{"ok":false,"errors":["timeout"]}' > "$BASE/out/$out/report.json"; fi
  wait $pid; local rc=$?
  echo "exit $rc"
  cat "$BASE/out/$out/report.json" 2>/dev/null || echo "no report"
  return $rc
}

for name in slides long-1920 audio-only; do
  run build/Volant.app "$name" "$name" || status=1
done

if [ "${VOLANT_EXPERIMENTS:-1}" = "1" ]; then
  # Diagnostic variants (never shipped): isolate sandbox/network effects on WebKit.
  cp Resources/Volant.entitlements /tmp/net.entitlements
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.network.client bool true" /tmp/net.entitlements
  rm -rf build/exp-net.app && cp -R build/Volant.app build/exp-net.app
  codesign --force --options runtime --entitlements /tmp/net.entitlements -s - build/exp-net.app
  run build/exp-net.app slides slides-exp-network || true
  rm -rf build/exp-nosandbox.app && cp -R build/Volant.app build/exp-nosandbox.app
  codesign --force --options runtime -s - build/exp-nosandbox.app
  run build/exp-nosandbox.app slides slides-exp-nosandbox || true
  rm -rf build/exp-*.app
fi

mkdir -p selftest-out && cp -R "$BASE/out/." selftest-out/
exit $status
