#!/usr/bin/env bash
# CI helper: puts one summary model (GGUF) into ~/Downloads/Meteora-CI-models/
# so the app self-test can import it instead of downloading it inside the
# sandbox on every run (the folder is cached by actions/cache).
#
# Usage: fetch_summary_model.sh [light|medium|strong] [dir]
# Model pins (repo, revision, file, size, SHA-256) are read from
# Sources/MeteoraLLM/SummaryModelStore.swift — the single source of truth.
# The chosen file is verified here AND again by the app before use. For all
# three tiers the script also checks that the pinned revision serves a file
# of exactly the pinned size (catches a wrong pin without downloading it).
set -euo pipefail
cd "$(dirname "$0")/.."
TIER="${1:-light}"
DIR="${2:-$HOME/Downloads/Meteora-CI-models}"
SRC=Sources/MeteoraLLM/SummaryModelStore.swift

spec() { # tier → "repo revision file size sha"
  python3 - "$SRC" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = src.split(f"case .{sys.argv[2]}:", 1)[1].split("case .", 1)[0]
get = lambda k: re.search(k + r':\s*"([^"]+)"', block).group(1)
size = re.search(r'fileSize:\s*([0-9_]+)', block).group(1).replace("_", "")
print(get("repo"), get("revision"), get("fileName"), size, get("sha256"))
PY
}

for t in light medium strong; do
  read -r REPO REV FILE SIZE SHA < <(spec "$t")
  got=$(curl -sSIL --proto '=https' --max-time 30 "https://huggingface.co/$REPO/resolve/$REV/$FILE" \
        | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} tolower($1)=="x-linked-size:"{l=$2} END{print (l!=""?l:v)}')
  echo "pin check $t: $FILE size $got (expected $SIZE)"
  [ "$got" = "$SIZE" ] || { echo "PIN MISMATCH for $t"; exit 1; }
done

read -r REPO REV FILE SIZE SHA < <(spec "$TIER")
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
