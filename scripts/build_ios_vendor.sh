#!/usr/bin/env bash
# Native libraries for the iPhone app, as xcframeworks (device arm64 +
# simulator arm64), into Vendor/ios:
#
#   sherpa-onnx.xcframework     speech recognition, VAD, speakers (static)
#   onnxruntime.xcframework     its runtime (static, prebuilt by sherpa-onnx's
#                               author, the exact build sherpa-onnx pins)
#   meteora-llama.xcframework   llama.cpp for on-device summaries (static)
#
# Same pins as the Mac build: sherpa-onnx v2.0.1 and llama.cpp b11970, each
# checked against a pinned commit (and, for llama.cpp, the full tree hash —
# see build_llama.sh) before anything is compiled. Static on purpose: one
# signature (the app's own), nothing to embed.
#
# Reused when Vendor/ios/STAMP matches (versions + hash of this script),
# which is also the CI cache key.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

SHERPA_TAG=v2.0.1
SHERPA_GIT=https://github.com/k2-fsa/sherpa-onnx.git
SHERPA_COMMIT=af2d8d81dbfa61c4cea4c568da78f3982edca005
ORT_VERSION=1.28.2
ORT_ZIP=onnxruntime-ios-static-xcframework-${ORT_VERSION}.xcframework.zip
ORT_URL=https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VERSION}/${ORT_ZIP}
ORT_SHA256=2c2299acbb461d26d4bac4bc85985d40e7c7177ed6072703ae0846d88b0b4599
IOS_MIN=17.0

# llama.cpp pins come from build_llama.sh so the two builds never drift.
LLAMA_TAG=$(sed -n 's/^LLAMA_TAG=//p' scripts/build_llama.sh)
LLAMA_GIT=$(sed -n 's/^LLAMA_GIT=//p' scripts/build_llama.sh)
LLAMA_COMMIT=$(sed -n 's/^LLAMA_COMMIT=//p' scripts/build_llama.sh)
LLAMA_TREE_SHA256=$(sed -n 's/^LLAMA_TREE_SHA256=//p' scripts/build_llama.sh)
[ -n "$LLAMA_TAG" ] && [ -n "$LLAMA_COMMIT" ] && [ -n "$LLAMA_TREE_SHA256" ] || { echo "llama pins not found"; exit 1; }

OUT=Vendor/ios
WORK=Vendor/ios-build
STAMP="sherpa $SHERPA_TAG ort $ORT_VERSION llama $LLAMA_TAG $(shasum -a 256 "$ROOT/scripts/build_ios_vendor.sh" | cut -d' ' -f1)"

if [ -d "$OUT/sherpa-onnx.xcframework" ] && [ -d "$OUT/onnxruntime.xcframework" ] \
   && [ -d "$OUT/meteora-llama.xcframework" ] && [ "$(cat "$OUT/STAMP" 2>/dev/null)" = "$STAMP" ]; then
  echo "iOS libraries already built ($OUT)"; ls "$OUT"; exit 0
fi
[ "$(uname -s)" = Darwin ] || { echo "build_ios_vendor.sh must run on macOS"; exit 1; }
command -v cmake >/dev/null || { echo "cmake is required"; exit 1; }
JOBS=$(sysctl -n hw.ncpu)

rm -rf "$WORK" && mkdir -p "$WORK"
mkdir -p "$OUT"

# ------------------------------------------------------------ onnxruntime
curl -fsSL --retry 3 -o "$WORK/$ORT_ZIP" "$ORT_URL"
got=$(shasum -a 256 "$WORK/$ORT_ZIP" | cut -d' ' -f1)
echo "sha256 $ORT_ZIP = $got"
[ "$got" = "$ORT_SHA256" ] || { echo "HASH MISMATCH for $ORT_ZIP"; exit 1; }
(cd "$WORK" && unzip -q "$ORT_ZIP")
ORT="$ROOT/$WORK/onnxruntime.xcframework"

# ------------------------------------------------------------ sherpa-onnx
SSRC=$WORK/sherpa-onnx
GIT_LFS_SKIP_SMUDGE=1 git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$SHERPA_TAG" "$SHERPA_GIT" "$SSRC"
got_commit=$(git -C "$SSRC" rev-parse HEAD)
echo "sherpa-onnx $SHERPA_TAG commit = $got_commit"
[ "$got_commit" = "$SHERPA_COMMIT" ] || { echo "COMMIT MISMATCH (expected $SHERPA_COMMIT)"; exit 1; }
cmp -s "$SSRC/sherpa-onnx/c-api/c-api.h" Sources/CSherpaOnnx/include/sherpa-onnx-c-api.h \
  || { echo "Sources/CSherpaOnnx/include/sherpa-onnx-c-api.h differs from $SHERPA_TAG"; exit 1; }

SHERPA_LIBS=(libkaldi-native-fbank-core.a libkissfft-float.a libsherpa-onnx-c-api.a libsherpa-onnx-core.a
             libsherpa-onnx-fst.a libsherpa-onnx-fstfar.a libsherpa-onnx-kaldifst-core.a libkaldi-decoder-core.a
             libssentencepiece_core.a libutf8proc.a)

build_sherpa() { # PLATFORM(OS64|SIMULATORARM64) ort-slice name
  local platform=$1 slice=$2 name=$3 dir="$ROOT/$WORK/sherpa-$3"
  SHERPA_ONNXRUNTIME_LIB_DIR="$ORT/$slice" \
  SHERPA_ONNXRUNTIME_INCLUDE_DIR="$ORT/$slice/onnxruntime.framework/Headers" \
  cmake -S "$ROOT/$SSRC" -B "$dir" \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/$SSRC/toolchains/ios.toolchain.cmake" \
    -DPLATFORM="$platform" -DDEPLOYMENT_TARGET=$IOS_MIN \
    -DENABLE_BITCODE=0 -DENABLE_ARC=1 -DENABLE_VISIBILITY=0 \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DSHERPA_ONNX_ENABLE_TTS=OFF -DSHERPA_ONNX_ENABLE_PYTHON=OFF -DSHERPA_ONNX_ENABLE_BINARY=OFF \
    -DSHERPA_ONNX_ENABLE_TESTS=OFF -DSHERPA_ONNX_ENABLE_CHECK=OFF -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
    -DSHERPA_ONNX_ENABLE_JNI=OFF -DSHERPA_ONNX_ENABLE_C_API=ON -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
    > "$WORK/sherpa-cmake-$name.log" 2>&1 || { tail -60 "$WORK/sherpa-cmake-$name.log"; exit 1; }
  cmake --build "$dir" -j "$JOBS" > "$WORK/sherpa-make-$name.log" 2>&1 \
    || { tail -80 "$WORK/sherpa-make-$name.log"; exit 1; }
  local libs=()
  for f in "${SHERPA_LIBS[@]}"; do libs+=("$dir/lib/$f"); done
  mkdir -p "$ROOT/$WORK/sherpa-out-$name"
  xcrun libtool -static -o "$ROOT/$WORK/sherpa-out-$name/libsherpa-onnx.a" "${libs[@]}"
  echo "sherpa-onnx $name: $(lipo -info "$ROOT/$WORK/sherpa-out-$name/libsherpa-onnx.a")"
}
build_sherpa OS64 ios-arm64 device
build_sherpa SIMULATORARM64 ios-arm64_x86_64-simulator simulator

rm -rf "$OUT/sherpa-onnx.xcframework" "$OUT/onnxruntime.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/sherpa-out-device/libsherpa-onnx.a" \
  -library "$WORK/sherpa-out-simulator/libsherpa-onnx.a" \
  -output "$OUT/sherpa-onnx.xcframework"
cp -R "$ORT" "$OUT/onnxruntime.xcframework"
cp "$SSRC/LICENSE" "$OUT/LICENSE-sherpa-onnx"

# ------------------------------------------------------------ llama.cpp
LSRC=$WORK/llama.cpp
GIT_LFS_SKIP_SMUDGE=1 git -c advice.detachedHead=false -c core.autocrlf=false \
  clone --quiet --depth 1 --branch "$LLAMA_TAG" "$LLAMA_GIT" "$LSRC"
got_commit=$(git -C "$LSRC" rev-parse HEAD)
[ "$got_commit" = "$LLAMA_COMMIT" ] || { echo "llama.cpp COMMIT MISMATCH"; exit 1; }
got_tree=$(cd "$LSRC" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z \
  | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
[ "$got_tree" = "$LLAMA_TREE_SHA256" ] || { echo "llama.cpp TREE HASH MISMATCH"; exit 1; }
echo "llama.cpp $LLAMA_TAG verified"

build_llama() { # iphoneos|iphonesimulator name
  local sdk=$1 name=$2 dir="$ROOT/$WORK/llama-$2"
  cmake -S "$ROOT/$LSRC" -B "$dir" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_MTMD=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_CONNECT=OFF -DLLAMA_CURL=OFF \
    -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF -DGGML_BACKEND_DL=OFF \
    -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DGGML_ACCELERATE=ON \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DCMAKE_C_FLAGS=-Wno-shorten-64-to-32 -DCMAKE_CXX_FLAGS=-Wno-shorten-64-to-32 \
    > "$WORK/llama-cmake-$name.log" 2>&1 || { tail -60 "$WORK/llama-cmake-$name.log"; exit 1; }
  cmake --build "$dir" --config Release --target llama -j "$JOBS" > "$WORK/llama-make-$name.log" 2>&1 \
    || { tail -80 "$WORK/llama-make-$name.log"; exit 1; }
  local libs=()
  while IFS= read -r -d '' f; do libs+=("$f"); done < <(find "$dir" -name 'lib*.a' -print0 | LC_ALL=C sort -z)
  mkdir -p "$ROOT/$WORK/llama-out-$name"
  xcrun libtool -static -o "$ROOT/$WORK/llama-out-$name/libmeteora-llama.a" "${libs[@]}" 2>/dev/null
  echo "llama $name: $(lipo -info "$ROOT/$WORK/llama-out-$name/libmeteora-llama.a")"
}
build_llama iphoneos device
build_llama iphonesimulator simulator

rm -rf "$OUT/meteora-llama.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/llama-out-device/libmeteora-llama.a" \
  -library "$WORK/llama-out-simulator/libmeteora-llama.a" \
  -output "$OUT/meteora-llama.xcframework"
cp "$LSRC/LICENSE" "$OUT/LICENSE-llama.cpp"

# ------------------------------------------------------------ checks
# (nm output goes to a variable first: `nm | grep -q` under pipefail fails
# when grep stops reading early.)
for lib in "$OUT"/sherpa-onnx.xcframework/*/libsherpa-onnx.a; do
  SYMS=$(nm -g "$lib" 2>/dev/null || true)
  grep -Eq " T _SherpaOnnxCreateOfflineRecognizer\$" <<<"$SYMS" || { echo "$lib lacks the C API"; exit 1; }
done
for lib in "$OUT"/meteora-llama.xcframework/*/libmeteora-llama.a; do
  SYMS=$(nm -g "$lib" 2>/dev/null || true)
  grep -Eq " T _llama_decode\$" <<<"$SYMS" || { echo "$lib lacks llama_decode"; exit 1; }
  UNDEF=$(nm -u "$lib" 2>/dev/null || true)
  if grep -Eq '_(curl_|SSL_|NSURLSession)' <<<"$UNDEF"; then echo "$lib references networking"; exit 1; fi
done

echo "$STAMP" > "$OUT/STAMP"
rm -rf "$WORK"
du -sh "$OUT"/*
