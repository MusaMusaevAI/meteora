#!/usr/bin/env bash
# Gathers the DMG, logs and self-test results into out/ (uploaded as an artifact).
set -uo pipefail
cd "$(dirname "$0")/.."
rm -rf out && mkdir -p out
cp build/Meteora.dmg build/Meteora.dmg.sha256 out/ 2>/dev/null || true
cp -R logs out/ 2>/dev/null || true
cp build/actool/log.txt out/logs/actool.txt 2>/dev/null || true
if [ -d selftest-out ]; then
  mkdir -p out/selftest
  (cd selftest-out && find . -type f \( -name '*.json' -o -name '*.png' -o -name '*.txt' -o -name '*.md' -o -name '*.pdf' -o -name 'audio-medium.m4a' \) -size -8M -print0 | xargs -0 -I{} rsync -R {} ../out/selftest/)
fi
exit 0
