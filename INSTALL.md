# Installation instructions

The configured Unix build was exercised with Tcl 8.6, ONNX Runtime 1.20.1, TEA 3.13 and the locked Rust tokenizer dependencies on Linux x86-64. Other Tcl/ONNX versions, platforms, full distribution packaging and offline dependency provisioning remain unverified. Python is not a production dependency.

## Prerequisites

* Autoconf, GNU Make, a C11 compiler with atomics support, and a C++ compiler for native Rust dependencies.
* Tcl 8.6 development headers, shared library and `tclConfig.sh`.
* ONNX Runtime C headers and library. Supply the correct compiler and linker flags for the installation; the tested system provides `libonnxruntime` through `pkg-config`.
* Rust and Cargo, with the crate sources needed by `tokenizer-native/Cargo.lock` available. Set `CARGO_NET_OFFLINE=true` to prohibit network access when using a populated cache. This repository does not vendor those sources.
* Existing genuine TEA 3.13 `tcl.m4` and `install-sh`, provided together in an explicit `TEA_CONFIG_DIR`. They are not bundled or downloaded by this project. `autogen.sh` copies the auxiliary installer only into the isolated build directory and fails clearly when the supplied files are missing; `configure` checks the TEA version.

## Platform-specific dependency guidance

The dependency categories above apply to every platform; package names and availability vary by release. The only configured build characterized here ran on Linux x86-64 with the versions in `CHARACTERIZATION.md`. The following are planning guidance, not installation commands or compatibility claims:

* **Fedora/RHEL (DNF):** obtain the distribution's C/C++ compiler, GNU Make, Autoconf, pkg-config, Tcl 8.6 development files and Rust/Cargo. Package names and versions differ between Fedora and RHEL releases; ONNX Runtime development headers and shared library and TEA 3.13 may require separately provisioned sources. No package availability is asserted for a particular release.
* **Debian/Ubuntu (APT): not yet validated.** Equivalent build-essential, Autoconf, pkg-config, Tcl development, Rust/Cargo, TEA 3.13 and ONNX Runtime development/runtime components are required. Availability and version of each package must be checked for the chosen release; the current rules are not certified on these distributions.
* **macOS: not yet validated.** Xcode Command Line Tools or another C/C++ toolchain, compatible Autoconf and GNU Make, Tcl 8.6 development files, Rust/Cargo, TEA 3.13 and an appropriate ONNX Runtime C distribution would be needed. The present `.so` and `$ORIGIN` Linux linking rules and package index are not validated as macOS build or loading rules; these prerequisites alone do not establish macOS support.
* **ARM64 Jetson and DGX Spark: not yet validated.** Each requires an ARM64-compatible Tcl, C/C++ and Rust toolchain, crate sources, TEA 3.13 and ONNX Runtime C headers and libraries matching its OS, architecture and ABI. CPU execution, toolchain availability and the present build rules must be checked on each environment. GPU execution and CUDA compatibility have not been established and are not part of this procedure.

No platform-specific package manager, GPU setup or system modification is performed by the project build.

Some Tcl installations record a compiler wrapper in `tclConfig.sh`. That compiler must work during TEA platform detection even if a different `CC` is selected for the project. If the wrapper's cache is unavailable, configure it appropriately for the environment; do not treat a failed compiler probe as evidence of another platform.

## Isolated configuration and build

Choose an existing source tree as `project_dir`, a new temporary build directory as `build_dir`, a temporary absolute `prefix` for a direct test installation, and the directory containing `tclConfig.sh` as `tcl_config_dir`. Set `TEA_CONFIG_DIR` to the existing TEA directory described above. Keep build and installation directories outside the source tree. Supply `CC`, `CXX`, `CARGO_HOME` or `CARGO_NET_OFFLINE` as needed for the local toolchain; no package manager or system installation is invoked by these commands.

```bash
cd "$build_dir"
TEA_CONFIG_DIR="$TEA_CONFIG_DIR" "$project_dir/autogen.sh"
CPPFLAGS="$(pkg-config --cflags libonnxruntime)" \
LDFLAGS="$(pkg-config --libs-only-L libonnxruntime)" \
  ./configure --srcdir="$project_dir" --prefix="$prefix" --with-tcl="$tcl_config_dir"
make
```

`autogen.sh` generates `configure` and `tea-aux/install-sh` in the current build directory, not the repository. It uses the supplied TEA macros and refuses to overwrite a different auxiliary installer. If TEA or the required crate sources are absent, supply them through an independently authorized process; the build does not silently retrieve them. The configured `unix/Makefile` builds separate C, Tcl bridge and Rust libraries. The current rules use Linux `.so` names and `$ORIGIN`; portability to other systems is not established.

### Source snapshot and Cargo cache

A complete build snapshot must include `configure.ac`, `autogen.sh`, the root and `unix/Makefile.in` templates, `pkgIndex.tcl.in`, `generic/tclembedding.c`, `generic/tokenizer_bridge.c`, `tokenizer-native/Cargo.toml`, `Cargo.lock`, `hf_tokenizer.h`, and `tokenizer-native/src/lib.rs`. Include the applicable `tests/` files and their dependencies for verification. Genuine TEA `tcl.m4` and `install-sh`, crate sources, Tcl and ONNX Runtime are separate prerequisites, not part of the repository snapshot. A source archive based solely on `HEAD` is incomplete while required files remain untracked. Review all candidate files for privacy and completeness before creating a distributable archive; ignored files must not be included automatically.

For the 004-B2 experiment, an isolated temporary snapshot copied the present tracked and non-ignored untracked regular files from the working tree, skipped deleted paths and rejected symlinks; a SHA-256 manifest recorded their contents. No previously built objects, Rust target directory or shared libraries were copied. The snapshot, the build directory and a new `CARGO_TARGET_DIR` were separate. An existing Cargo cache supplied crate source files, not compiled outputs. `CARGO_NET_OFFLINE=true` and the makefile's `cargo build --release --locked` enforced the locked offline build; an empty cache failed to resolve `tokenizers`. A lockfile fixes the dependency graph but does not contain the crate sources. This proves a functional build with the named prepared cache and installed tools, not an independent operating-system installation, standalone source archive or bit-identical binaries.

Development builds can retain symbols and paths for debugging; keep their artifacts private and access-controlled. For proposed distribution builds, review ELF metadata, strings, debug sections and dependency paths for local or sensitive information. Compiler source-path remapping (for example GCC/Clang `-ffile-prefix-map` and Rust `--remap-path-prefix`) may reduce embedded build paths, subject to verification with the actual toolchain and dependencies. Separate or strip debug information only under an explicit packaging policy, retain appropriately protected debugging artifacts where needed, and recheck the result; remapping or stripping is not a substitute for a full artifact review. No such distribution policy has yet been validated for this project.

## Safe installation and staging

The installation policy is `$(DESTDIR)$(libdir)/tclembedding1.0`; the default `libdir` is derived from the configured `prefix`. An explicit `--libdir` changes that policy. `TCL_PACKAGE_PATH` is not used as a shell path. Use an absolute disposable `prefix` and a disposable `DESTDIR` during validation. Before installing, inspect both the resolved directory and the commands:

```bash
make -s -C unix DESTDIR="$staging_dir" print-install-dir
make -n install DESTDIR="$staging_dir"
# Proceed only after checking the resolved directory is inside the authorized staging area.
make install DESTDIR="$staging_dir"
```

For a direct installation under an authorized temporary prefix, repeat the inspection with `DESTDIR=` before running `make install DESTDIR=`. Paths with spaces in both `prefix` and `DESTDIR` were tested. If an install is intended to be confined to a staging directory, do not supply an unsafe `--libdir` or symlinked destination. No global installation is required for these checks.

To load from the staged installation, point Tcl explicitly at the installed package directory, rather than the build tree. For a default `libdir` and absolute `prefix`:

```bash
export TEST_PACKAGE_DIR="$staging_dir$prefix/lib/tclembedding1.0"
"$tclsh" <<'TCL'
lappend auto_path $::env(TEST_PACKAGE_DIR)
foreach p {tclembedding tokenizer tclembedding::tokenizer} {
    puts [list $p [package require -exact $p 1.0.0]]
}
puts [info loaded]
TCL
```

Tcl treats `tclembedding`'s reported `1.0` as equivalent to the index's `1.0.0`; the tokenizer packages report `1.0.0`. The `tcltokenizer` bridge locates its Rust library through `$ORIGIN`. Tcl, ONNX Runtime and the C/C++ runtime libraries remain external dependencies and must be discoverable by the system loader.

## Testing and limitations

From the configured top-level build directory, run the complete suite with the exact external tokenizer and MiniLM ONNX fixtures identified by SHA-256 in `CHARACTERIZATION.md`. First prepare a new disposable directory for the small synthetic ONNX safety fixtures. The generator needs Python 3's standard library only; Python is not a production dependency. It exclusively creates its fixture files and refuses to overwrite them.

```bash
python3 "$project_dir/tests/make_onnx_safety_fixtures.py" "$SAFETY_FIXTURES"
make test TOKENIZER_JSON="$TOKENIZER_JSON" MODEL_ONNX="$MODEL_ONNX" \
  SAFETY_FIXTURES="$SAFETY_FIXTURES"
```

The full `test` target requires all three paths, reports a missing prerequisite as an error, and runs tokenizer parity and lifecycle, Rust panic/restoration and same-instance concurrency checks, tokenizer C ABI, three tokenizer/embedding cases, ONNX lifecycle and synthetic safety tests. Test commands propagate failure; no full-suite test is silently skipped. Some tests hash-check the exact fixtures. Supplying a different readable file is not sufficient. This suite does not run the separate large primary-reference comparison or prove general model compatibility.

To run explicitly selected subsets from the same top-level build directory:

```bash
# No large ONNX model required; both need the identified tokenizer JSON.
make test-tokenizer TOKENIZER_JSON="$TOKENIZER_JSON"
make test-tokenizer-abi TOKENIZER_JSON="$TOKENIZER_JSON"
make test-tokenizer-rust TOKENIZER_JSON="$TOKENIZER_JSON"
# Only the generated synthetic ONNX fixture directory is required.
make test-embedding-safety SAFETY_FIXTURES="$SAFETY_FIXTURES"
# These require the identified external ONNX model; integration also needs tokenizer JSON.
make test-tokenizer-embedding TOKENIZER_JSON="$TOKENIZER_JSON" MODEL_ONNX="$MODEL_ONNX"
make test-embedding-lifecycle MODEL_ONNX="$MODEL_ONNX"
```

Individual targets report failure for missing or unusable inputs; they do not imply that the complete suite passed. Tests execute the newly built libraries, not an installed package. To check an installation separately, set `TCLLIBPATH` to its package directory and invoke the relevant Tcl test script with its fixture arguments. `tests/quick_test.tcl` is a compatibility entry point for the same hash-identified three-case integration check and takes the two explicit file paths; it no longer relies on a fixed model directory or makes an unsupported semantic-success claim.

Crate distribution, ONNX Runtime distribution and non-Linux support remain outside this change. Release artifacts built with debug information can contain local source paths and must be reviewed before publication. No source archive based on `HEAD` alone includes currently untracked working-tree files; source packaging requires a separate review and authorization.

For the exact tested environment and limitations, see `CHARACTERIZATION.md` and `BENCHMARKING.md`.
