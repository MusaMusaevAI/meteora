#!/usr/bin/env bash
# CI helper: puts the summary model (GGUF, ~2.7 GB) into
# ~/Downloads/Meteora-CI-models/ so the app self-test can import it instead of
# downloading it inside the sandbox on every run. The folder is restored from
# and saved to the actions cache (key = the pinned SHA-256).
#
# The file name, revision, size and SHA-256 are read from
# Sources/MeteoraLLM/SummaryModelStore.swift — the single source of truth — and
# the file is verified here AND again by the app before use.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=Sources/MeteoraLLM/SummaryModelStore.swift
field() { sed -n "s/.*static let $1[^=]*= \"\\(.*\\)\".*/\\1/p" "$SRC" | head -1; }
REPO=$(field repo); REV=$(field revision); FILE=$(field fileName); SHA=$(field sha256)
SIZE=$(sed -n 's/.*static let fileSize: Int64 = \([0-9_]*\).*/\1/p' "$SRC" | tr -d _)
for v in REPO REV FILE SHA SIZE; do [ -n "${!v}" ] || { echo "could not read $v from $SRC"; exit 1; }; done

DIR="${1:-$HOME/Downloads/Meteora-CI-models}"
mkdir -p "$DIR"
OUT="$DIR/$FILE"
if [ -f "$OUT" ] && [ "$(shasum -a 256 "$OUT" | cut -d' ' -f1)" = "$SHA" ]; then
  echo "summary model cached and verified: $OUT"; exit 0
fi
rm -f "$OUT" "$OUT.part"
curl -fSL --proto '=https' --proto-redir '=https' --retry 3 --max-filesize $((SIZE + 1024)) \
  -o "$OUT.part" "https://huggingface.co/$REPO/resolve/$REV/$FILE"
got=$(shasum -a 256 "$OUT.part" | cut -d' ' -f1)
echo "sha256 $FILE = $got"
[ "$got" = "$SHA" ] || { echo "HASH MISMATCH (expected $SHA)"; rm -f "$OUT.part"; exit 1; }
mv "$OUT.part" "$OUT"
ls -la "$DIR"
