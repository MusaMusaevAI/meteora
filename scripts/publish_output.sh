#!/usr/bin/env bash
# Pushes the DMG, logs and self-test results to the `build-output` branch.
set -uo pipefail
cd "$(dirname "$0")/.."
rm -rf out && mkdir -p out
cp build/Volant.dmg build/Volant.dmg.sha256 out/ 2>/dev/null || true
cp -R logs out/ 2>/dev/null || true
cp build/actool/log.txt out/logs/actool.txt 2>/dev/null || true
if [ -d selftest-out ]; then
  mkdir -p out/selftest
  (cd selftest-out && find . -type f \( -name '*.json' -o -name '*.png' -o -name '*.txt' -o -name '*.md' -o -name '*.pdf' -o -name 'audio-medium.m4a' \) -size -8M -print0 | xargs -0 -I{} rsync -R {} ../out/selftest/)
fi
echo "${GITHUB_SHA:-local}" > out/SOURCE_SHA
echo "${JOB_STATUS:-unknown}" > out/STATUS
cd out
git init -q -b build-output
git -c user.name="volant-ci" -c user.email="volant-ci@users.noreply.github.com" add -A
git -c user.name="volant-ci" -c user.email="volant-ci@users.noreply.github.com" commit -qm "build ${GITHUB_SHA:-local}"
git push -qf "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" build-output
