#!/usr/bin/env bash
# Downloads third-party binaries used at build time and verifies their SHA-256.
# Nothing is used unless its hash matches the value pinned here.
set -euo pipefail
cd "$(dirname "$0")/.."

SHERPA_VERSION=v2.0.1
SHERPA_TAR=sherpa-onnx-${SHERPA_VERSION}-osx-universal2-static-no-tts-lib.tar.bz2
SHERPA_SHA256=bd4cdc1c4122d249c46187fb36528733186f7bf52e8ceae716bd37255550a567
VAD_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
VAD_SHA256=9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6

verify() { # file expected
  local got; got=$(shasum -a 256 "$1" | cut -d' ' -f1)
  echo "sha256 $(basename "$1") = $got"
  if [ "$2" = "UNPINNED" ]; then echo "WARNING: $(basename "$1") hash not pinned yet"; return 0; fi
  [ "$got" = "$2" ] || { echo "HASH MISMATCH for $1 (expected $2)"; rm -f "$1"; exit 1; }
}

mkdir -p Vendor/download Vendor/sherpa-onnx Vendor/models
if [ ! -f Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.a ]; then
  curl -fsSL --retry 3 -o "Vendor/download/$SHERPA_TAR" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/${SHERPA_TAR}"
  verify "Vendor/download/$SHERPA_TAR" "$SHERPA_SHA256"
  tar -xjf "Vendor/download/$SHERPA_TAR" -C Vendor/download
  rm -rf Vendor/sherpa-onnx/lib
  mv "Vendor/download/${SHERPA_TAR%.tar.bz2}/lib" Vendor/sherpa-onnx/lib
fi
if [ ! -f Vendor/models/silero_vad.onnx ]; then
  curl -fsSL --retry 3 -o Vendor/models/silero_vad.onnx "$VAD_URL"
fi
verify Vendor/models/silero_vad.onnx "$VAD_SHA256"
ls -la Vendor/sherpa-onnx/lib Vendor/models
