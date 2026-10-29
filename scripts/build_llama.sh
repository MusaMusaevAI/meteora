#!/usr/bin/env bash
# Builds llama.cpp (on-device meeting summaries) as ONE static, universal
# (arm64 + x86_64) archive that is linked into the Meteora executable.
#
# Why static and not the prebuilt llama-<tag>-xcframework.zip: that framework
# is a dynamic library. Meteora is ad-hoc signed with the hardened runtime and
# library validation ON; such a process may only load Apple platform
# libraries (an ad-hoc signature has no Team ID), so an embedded llama.framework
# would make the whole app fail to launch. A static archive becomes part of the
# Meteora binary and is covered by its own signature.
#
# Source: the official llama.cpp git repository at a pinned release tag. The
# checkout is verified twice before anything is compiled:
#   1. the tag must resolve to the pinned commit (git object id), and
#   2. a SHA-256 over every file of the tree (sorted, `.git` excluded) must
#      match the pinned value (computed exactly like build_ffmpeg.sh does):
#   find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z \
#     | xargs -0 shasum -a 256 | shasum -a 256
# The public headers vendored in Sources/CLlama/include must be byte-identical
# to the ones in the verified tree (checked below), so the Swift API always
# matches the compiled library.
#
# Configuration: library only (no tools, server, examples, tests, common, UI,
# OpenSSL/curl) — llama.cpp's own downloader is not even compiled in. Metal
# shaders are embedded as source (GGML_METAL_EMBED_LIBRARY) and compiled by the
# system at run time, so there is no default.metallib to ship and no Metal
# toolchain is needed at build time. The Intel slice is CPU-only (AVX2/FMA,
# every Intel Mac that runs macOS 14 has them).
#
# Output: Vendor/llama/lib/libmeteora-llama.a (universal), Vendor/llama/LICENSE,
# Vendor/llama/CONFIGURE.txt. Reused when Vendor/llama/STAMP matches (version +
# hash of this script), which is also what the CI cache key is made of.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

LLAMA_TAG=b11970
LLAMA_GIT=https://github.com/ggml-org/llama.cpp.git
LLAMA_COMMIT=522021325546ea322b0b1e58a50f9dbf03a5f197
LLAMA_TREE_SHA256=04b25bed2e34f24d4ed969deec4b19184d3658adf78dca71ce8007eb97fbc590
MACOS_MIN=14.0

OUT=Vendor/llama
WORK=Vendor/llama-build
SRC=$WORK/llama.cpp-$LLAMA_TAG
STAMP="$LLAMA_TAG $(shasum -a 256 "$ROOT/scripts/build_llama.sh" | cut -d' ' -f1)"
HEADERS=(include/llama.h ggml/include/ggml.h ggml/include/ggml-cpu.h ggml/include/ggml-backend.h
         ggml/include/ggml-alloc.h ggml/include/ggml-opt.h ggml/include/gguf.h)

if [ -f "$OUT/lib/libmeteora-llama.a" ] && [ "$(cat "$OUT/STAMP" 2>/dev/null)" = "$STAMP" ]; then
  echo "llama.cpp $LLAMA_TAG already built ($OUT/lib/libmeteora-llama.a)"
  lipo -info "$OUT/lib/libmeteora-llama.a"
  exit 0
fi
[ "$(uname -s)" = Darwin ] || { echo "build_llama.sh must run on macOS"; exit 1; }
command -v cmake >/dev/null || { echo "cmake is required (preinstalled on GitHub macOS runners)"; exit 1; }

# ---------------------------------------------------------------- source
rm -rf "$WORK" && mkdir -p "$WORK"
GIT_LFS_SKIP_SMUDGE=1 git -c advice.detachedHead=false -c core.autocrlf=false \
  clone --quiet --depth 1 --branch "$LLAMA_TAG" "$LLAMA_GIT" "$SRC"
got_commit=$(git -C "$SRC" rev-parse HEAD)
echo "llama.cpp $LLAMA_TAG commit = $got_commit"
[ "$got_commit" = "$LLAMA_COMMIT" ] || { echo "COMMIT MISMATCH (expected $LLAMA_COMMIT)"; exit 1; }
got_tree=$(cd "$SRC" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z \
  | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
echo "llama.cpp source tree sha256 = $got_tree"
[ "$got_tree" = "$LLAMA_TREE_SHA256" ] || { echo "TREE HASH MISMATCH (expected $LLAMA_TREE_SHA256)"; exit 1; }

for h in "${HEADERS[@]}"; do
  cmp -s "$SRC/$h" "Sources/CLlama/include/$(basename "$h")" \
    || { echo "Sources/CLlama/include/$(basename "$h") differs from $LLAMA_TAG/$h"; exit 1; }
done
echo "vendored headers match $LLAMA_TAG"

# ---------------------------------------------------------------- configuration
COMMON_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN
  -DBUILD_SHARED_LIBS=OFF
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF
  -DLLAMA_BUILD_MTMD=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_CONNECT=OFF
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF -DGGML_BACKEND_DL=OFF
  -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DGGML_ACCELERATE=ON
  -DCMAKE_C_FLAGS=-Wno-shorten-64-to-32 -DCMAKE_CXX_FLAGS=-Wno-shorten-64-to-32
)

build_arch() { # arm64 | x86_64
  local arch=$1 dir="$ROOT/$WORK/build-$1"
  local extra=()
  if [ "$arch" = arm64 ]; then
    extra+=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
  else
    extra+=(-DGGML_METAL=OFF -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_BMI2=ON
            -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_AVX512=OFF)
  fi
  cmake -S "$ROOT/$SRC" -B "$dir" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    "${COMMON_FLAGS[@]}" "${extra[@]}" > "$WORK/cmake-$arch.log" 2>&1 \
    || { tail -60 "$WORK/cmake-$arch.log"; exit 1; }
  cmake --build "$dir" --config Release --target llama -j "$(sysctl -n hw.ncpu)" \
    > "$WORK/make-$arch.log" 2>&1 || { tail -80 "$WORK/make-$arch.log"; exit 1; }
  # One archive per arch: llama + ggml + every backend that was built.
  local libs=()
  while IFS= read -r -d '' f; do libs+=("$f"); done < <(find "$dir" -name 'lib*.a' -print0 | LC_ALL=C sort -z)
  printf '  %s\n' "${libs[@]#$dir/}"
  xcrun libtool -static -o "$ROOT/$WORK/libmeteora-llama-$arch.a" "${libs[@]}" 2> "$WORK/libtool-$arch.log" \
    || { cat "$WORK/libtool-$arch.log"; exit 1; }
  echo "built $arch: $(lipo -info "$ROOT/$WORK/libmeteora-llama-$arch.a")"
}

build_arch arm64
build_arch x86_64

rm -rf "$OUT" && mkdir -p "$OUT/lib"
lipo -create "$WORK/libmeteora-llama-arm64.a" "$WORK/libmeteora-llama-x86_64.a" -output "$OUT/lib/libmeteora-llama.a"

# ---------------------------------------------------------------- checks
lipo -info "$OUT/lib/libmeteora-llama.a"
SYMS=$(nm -g -arch arm64 "$OUT/lib/libmeteora-llama.a" 2>/dev/null || true)
for s in _llama_model_load_from_file _llama_decode _ggml_backend_metal_reg _ggml_metallib_mul_mm_start; do
  grep -Eq " [TDS] ${s}\$" <<<"$SYMS" || { echo "arm64 slice lacks $s"; exit 1; }
done
SYMS=$(nm -g -arch x86_64 "$OUT/lib/libmeteora-llama.a" 2>/dev/null || true)
grep -Eq " T _llama_decode\$" <<<"$SYMS" || { echo "x86_64 slice lacks _llama_decode"; exit 1; }
# No networking code may be linked in (llama.cpp's downloader lives in
# `common`, which is not built).
if nm -u "$OUT/lib/libmeteora-llama.a" 2>/dev/null | grep -E '_(curl_|SSL_|CFNetwork|NSURLSession|socket$|connect$)'; then
  echo "llama.cpp archive references networking symbols"; exit 1
fi

{
  echo "llama.cpp $LLAMA_TAG (commit $LLAMA_COMMIT)"
  echo "Source: $LLAMA_GIT (tag $LLAMA_TAG), tree sha256 $LLAMA_TREE_SHA256"
  echo "CMake (per arch): -DCMAKE_OSX_ARCHITECTURES=<arch> ${COMMON_FLAGS[*]}"
  echo "  arm64:  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON"
  echo "  x86_64: -DGGML_METAL=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON (no AVX-512)"
  echo "Target: llama (static), combined with libtool into libmeteora-llama.a, lipo'd."
} > "$OUT/CONFIGURE.txt"
cat "$OUT/CONFIGURE.txt"
cp "$SRC/LICENSE" "$OUT/LICENSE"
echo "$STAMP" > "$OUT/STAMP"
rm -rf "$WORK"
du -h "$OUT/lib/libmeteora-llama.a"
