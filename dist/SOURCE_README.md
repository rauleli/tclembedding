# tclembedding source distribution

This package contains the Tcl/C/Rust source for `tokenizer` and `tclembedding`,
an optional similarity kernel, a small synthetic example and focused tests.
The Tcl package version is 1.0.0; `SOURCE_REVISION` identifies the exact source
commit. This archive is not a declaration of a new stable release.

See [API.md](API.md) for commands and [INSTALL.md](INSTALL.md) for prerequisites, isolated build, installation,
tests and removal. Models, model tokenizers, Tcl, TEA, Cargo crates and ONNX
Runtime are external and are not contained in this package. GPU use requires a
compatible external ONNX Runtime CUDA provider and its NVIDIA dependencies.
CPU is the default and does not require CUDA.

Verify `MANIFEST.sha256` with `sha256sum -c MANIFEST.sha256` from this directory.
The project and its full historical documentation are available at
https://github.com/rauleli/tclembedding. The source package does not include
historical experiments, private data, models or compiled libraries.
