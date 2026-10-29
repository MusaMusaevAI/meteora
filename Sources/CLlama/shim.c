// Empty translation unit: lets SwiftPM treat CLlama as a C target whose only
// purpose is to expose the llama.cpp C API headers (vendored, unmodified) and
// link the static archive built from pinned, verified source by
// scripts/build_llama.sh (Vendor/llama/lib/libmeteora-llama.a).
#include "llama.h"
