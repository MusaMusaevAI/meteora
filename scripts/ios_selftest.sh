#!/usr/bin/env bash
# Runs the iPhone app's self-test in a fresh simulator: copies fixtures into
# the app's Documents, launches it with METEORA_SELFTEST=1 and collects
# Documents/selftest (screens + report.json) into ios-selftest-out/.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=ios-selftest-out
rm -rf "$OUT" && mkdir -p "$OUT"
APP=build/ios-sim/Build/Products/Debug-iphonesimulator/Meteora.app
BUNDLE=com.musamusaev.meteora.ios

TYPE=$(xcrun simctl list devicetypes -j | python3 -c "
import json,sys
import re
def gen(d):
    m=re.search(r'iPhone (\d+)', d['name']); return int(m.group(1)) if m else 0
c=[d for d in json.load(sys.stdin)['devicetypes'] if re.fullmatch(r'iPhone \d+ Pro', d['name'])]
c.sort(key=gen)
print(c[-1]['identifier'] if c else '')")
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "
import json,sys
r=[x['identifier'] for x in json.load(sys.stdin)['runtimes'] if x.get('isAvailable') and 'iOS' in x['name']]
print(r[-1] if r else '')")
echo "device type: $TYPE, runtime: $RUNTIME"
UDID=$(xcrun simctl create meteora-selftest "$TYPE" "$RUNTIME")
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1 || sleep 20
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
mkdir -p "$DATA/Documents/Fixtures"
cp Tests/MeteoraCoreTests/Fixtures/audio-only.webm Tests/MeteoraCoreTests/Fixtures/slides.webm "$DATA/Documents/Fixtures/" 2>/dev/null || true
if [ -f /tmp/ru-example.wav ]; then
  afconvert -f m4af -d aac /tmp/ru-example.wav "$DATA/Documents/Fixtures/speech.m4a" || true
fi
ls -la "$DATA/Documents/Fixtures"

SIMCTL_CHILD_METEORA_SELFTEST=1 SIMCTL_CHILD_METEORA_SELFTEST_LLM=1 SIMCTL_CHILD_METEORA_LLM_FORCE_CPU=1 \
  xcrun simctl launch --console-pty "$UDID" "$BUNDLE" > "$OUT/console.txt" 2>&1 &
LPID=$!
status=1
for _ in $(seq 1 1500); do
  if [ -f "$DATA/Documents/selftest/report.json" ]; then status=0; break; fi
  sleep 1
done
sleep 2
cp -R "$DATA/Documents/selftest/." "$OUT/" 2>/dev/null || true
kill $LPID 2>/dev/null || true
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl delete "$UDID" 2>/dev/null || true
if [ $status -ne 0 ]; then
  echo "{\"ok\":false,\"errors\":[\"timeout after: $(tail -1 "$OUT/progress.txt" 2>/dev/null)\"]}" > "$OUT/report.json"
fi
cat "$OUT/report.json"
python3 -c "import json,sys; sys.exit(0 if json.load(open('$OUT/report.json')).get('ok') else 1)"
