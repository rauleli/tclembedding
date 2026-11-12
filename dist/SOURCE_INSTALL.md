# Building and installing the source distribution

This source package requires Linux x86-64, Tcl 8.6 development files and
`tclConfig.sh`, a C11 compiler, C++ compiler, GNU make, Autoconf, genuine TEA
3.13 `tcl.m4` and `install-sh`, Rust/Cargo and the crate sources specified by
`tokenizer-native/Cargo.lock`. ONNX Runtime C headers and library must be
provided externally and correspond to a compatible version. API 20 and 31 were
previously exercised on Linux x86-64; this does not guarantee other versions.
Python 3 is only required by the existing optional synthetic ONNX fixture
generator; it is not a production dependency. Crate licenses are supplied by
their respective upstream projects. Nothing in this archive vendors TEA,
Cargo crates, ONNX Runtime, Tcl, CUDA, models or tokenizers for models.

Choose an empty build directory outside the extracted source, an installation
prefix, the directory containing `tclConfig.sh`, the directory containing TEA
3.13 `tcl.m4` and `install-sh`, and an ONNX Runtime installation. For example:

```sh
cd "$BUILD_DIR"
TEA_CONFIG_DIR="$TEA_CONFIG_DIR" "$SOURCE_DIR/autogen.sh"
CPPFLAGS="-I$ORT_DIR/include" LDFLAGS="-L$ORT_DIR/lib" \
  ./configure --srcdir="$SOURCE_DIR" --prefix="$PREFIX" --with-tcl="$TCL_CONFIG_DIR"
make
make install
```

Supply an appropriate runtime loader configuration for the external ONNX
Runtime if it is not in the system loader's search path. An application-specific
launcher or a suitable link-time RUNPATH may be used; do not assume that moving
the prefix also moves external dependencies. To stage an installation use
`make install DESTDIR="$STAGE_DIR"`. The `--with-simd=scalar` configure option
selects the conservative optional similarity build. CPU is the default provider;
CUDA is opt-in and needs a compatible external ONNX Runtime CUDA provider and
NVIDIA runtime dependencies. A CUDA session can still assign nodes to CPU.

From a fresh Tcl process, select the installed package directory as appropriate:

```sh
TCLLIBPATH="$PREFIX/lib/tclembedding1.0" tclsh <<'TCL'
package require tokenizer
package require tclembedding
puts "packages loaded"
TCL
```

Load success alone is not an inference test. Supply compatible model and
model-tokenizer files separately; examples/01-in-memory-rag demonstrates use.
The focused test `tests/embedding_provider_test.tcl MODEL EMPTY_DIRECTORY`
checks CPU inference, optional profiling and CUDA-unavailable errors; use it
only on a machine without CUDA and with the newly installed package selected.
For the build-tree equivalent, run `make test-embedding-provider` with
`MODEL_ONNX` and `PROVIDER_TEST_DIR` set to a readable model and an existing
empty private directory respectively.
The `make test` target additionally requires the exact historical MiniLM model,
tokenizer and synthetic safety fixtures. The generator for those synthetic
fixtures is included; it requires Python 3 and a new empty directory. The
full suite does not silently skip missing fixtures.

To remove an installation from a dedicated private prefix, remove the installed
`tclembedding1.0` package directory after confirming that no other installation
uses it. For shared prefixes use the package manager or an administrator's
inventory; do not remove the external ONNX Runtime or unrelated packages.
