// Empty translation unit: lets SwiftPM treat CSherpaOnnx as a C target whose
// only purpose is to expose the vendored sherpa-onnx C API header and link
// the static libraries fetched by scripts/fetch_vendor.sh (hash-pinned).
#include "sherpa-onnx-c-api.h"
