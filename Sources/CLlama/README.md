`include/*.h` (except `module.modulemap`) are the public headers of
https://github.com/ggml-org/llama.cpp at tag b11970
(commit 522021325546ea322b0b1e58a50f9dbf03a5f197, MIT), unmodified:
`include/llama.h` and `ggml/include/{ggml,ggml-cpu,ggml-backend,ggml-alloc,ggml-opt,gguf}.h`.

The matching static library is compiled from the same verified source tree by
`scripts/build_llama.sh`, which also checks that these headers are
byte-identical to the ones in that tree.
