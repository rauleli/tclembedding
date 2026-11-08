# Changelog

All notable changes to the tclembedding project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Legacy-hardware RAG characterization

- Preserve synthetic structured-response observations, historical limitations,
  and a bounded CPU-only E5/SQLite/Ollama experiment in
  `docs/LEGACY_HARDWARE_EXPERIMENTS.md`.

### Slice 008 — batch inference (formally accepted)

- Add `embedding::compute_batch` with explicit padding ID, right-padding, attention masks, per-sequence mean or CLS pooling and L2. Preserve the existing single-sequence API.
- Bound batch dimensions and validate input IDs, ONNX metadata, output tensors and numeric results. Add reproducible synthetic tests and a separate ONNX C comparison client. A focused review found that ONNX Runtime could return a hidden dimension inconsistent with declared metadata; the batch path now rejects the mismatch and enforces actual output bounds before pooling. Synthetic tests cover that case and three padded rows.
- Compare four identified ONNX models with individual inference and matching independent ONNX and previously captured PyTorch references; see `CHARACTERIZATION.md` for tested cases and limitations. Slice 008 is formally accepted only for the characterized models, revisions, inputs and environments; general batching, padding, memory safety, concurrency, portability and performance remain unestablished.

### Slice 007 — four-model ONNX compatibility (formally accepted)

- Validate the required two-input encoder signature and the optional third token-type input before publishing a handle; reject unsupported inputs and incompatible metadata with controlled errors.
- Derive the hidden dimension from the validated float32 runtime output, with checked allocation and indexing. Add explicit `-pooling mean|cls` while retaining mean as the default and preserving L2.
- Extend synthetic safety fixtures for two and three inputs, 768 dimensions, CLS versus mean, invalid input signatures and handle recovery. The existing 58 tokenizer cases, eight Rust tests, C ABI, lifecycle, MiniLM integration and safety tests passed.
- The 18 serialized MiniLM vectors and 42-row PyTorch comparison were unchanged in the measured environment. BGE CLS, E5 mean and MPNet mean were compared against separate ONNX clients; subsequent direct binding-versus-PyTorch comparisons cover the identified cases for those models; see the cross-validation evidence below. See `CHARACTERIZATION.md` and `BENCHMARKING.md` for limits.

### Slice 007 — direct PyTorch vector comparison

- Compared the complete normalized PyTorch vectors directly with the Tcl binding for six BGE, seven E5 and five MPNet cases after checking model and tokenizer hashes, text identity, input IDs, masks, type IDs, truncation, dimensions and pooling. Maximum absolute differences were `2.908163e-7`, `1.260232e-7` and `3.657771e-7`; see `CHARACTERIZATION.md` for minimum cosines and limits.
- The additional reference was generated in the identified CPU environment using the existing models and dependencies. No inference behavior was changed by this comparison. These measurements do not establish universal numerical tolerances, padding or concurrency support. Slice 007 is formally accepted within the evaluated models, revisions, configurations, cases and environments.

### Slice 006 — post-acceptance corrective maintenance

* Validate the original Tcl `-max-length` integer's sign and range before wide conversion, preventing out-of-range negative values from wrapping into accepted positive limits. The existing model-specific limit 1 behavior and valid token IDs are retained.
* Added regression coverage for integer boundaries and for freeing an owned Rust tokenizer invalidated by an injected panic, followed by loading and using a new instance. Focused checks and the complete test suite passed with the identified fixtures; no change to the formal Slice 006 acceptance is implied.

### Slice 006 — tokenizer truncation performance

* Formally accepted 006-A and 006-B within the evaluated Linux x86-64 environment, model and cases. The accepted Tcl/C contracts, token IDs and characterized ONNX outputs remain unchanged; see `CHARACTERIZATION.md` for the seven Rust tests, 58 cases, numerical regression and five-process measurements. Acceptance does not establish universal performance, absence of leaks, safe concurrent handle destruction or compatibility with other models or platforms.

### Slice 006-B — per-instance tokenizer truncation

* Replaced per-call tokenizer cloning with per-instance synchronized native truncation and restoration. The default and limited paths share the instance lock; a panic invalidates the instance and a poisoned lock fails explicitly. C ABI functions and accepted truncation behavior remain unchanged. This work preceded the formal Slice 006 acceptance recorded above.
* Added reproducible Rust tests for restoration, panic containment, poisoned locks and concurrent same-instance encodes; the full test target runs them with the identified tokenizer fixture. The 58 tokenizer cases, boundary, ABI, ONNX and numerical comparisons passed in the environment described in `CHARACTERIZATION.md`. Five-process measurements per route met the specified local latency and peak-RSS targets; this is not a performance guarantee on other systems.

### Slice 005 — source integrity, Git baseline and development publication

* Formally accepted the source audit, selective Git baseline and development publication. The source inventory and verified private working-tree backup preceded commit `338dacbd3a68a19374e7ab2775ddf87055b15d4b`. That commit was rebuilt from a Git archive, installed in an isolated prefix and passed package loading and `make test` with identified fixtures. The ingestion example's password diagnostics were corrected as part of the baseline.
* Merge `b610fec` reconciled local and remote histories without changing the baseline tree; the development branch was published. This is not a stable release or evidence of binary reproducibility, self-contained dependency distribution, general model support, concurrency or other-platform compatibility. See `CHARACTERIZATION.md` and `ROADMAP.md` for evidence and open work.

### Development baseline preparation

* The ingestion example no longer prints the configured password in connection troubleshooting, and redacts it from caught error diagnostics. A synthetic failing-connection check verified that the password is not echoed; no database connection was made.
* Expanded ignore rules for generated build files, caches, local environments and model weights while keeping the Rust lockfile, source and synthetic test fixtures available for version control.

### Slice 004 — build, installation and test infrastructure

* Formally accepted 004-A and 004-B1 through 004-B3 within the evaluated Linux x86-64 environment and identified, previously available dependencies. The evidence and commands remain in `CHARACTERIZATION.md`, `BENCHMARKING.md` and `INSTALL.md`.
* Acceptance covers the tested TEA configuration, isolated prefix and `DESTDIR` installation, 64-file working-tree source snapshot build, installed package loading, and full and subset test entry points. It does not establish bit-identical builds, a complete build from the then-current `HEAD`, self-contained distribution or other-platform compatibility. At that stage source version control, dependency distribution, binary and debug-symbol review, packaging and publication requirements remained open; the subsequent source baseline and development publication are recorded above.

### Slice 004-B3 — test entry point

* Added configured root `make test` and explicit subset targets. The complete suite requires tokenizer, model and synthetic safety fixture paths and propagates failures. The former fixed-path quick test now delegates to the existing hash-checked integration test instead of reporting unsupported semantic success.
* In an isolated Linux build, the full suite passed its 58 tokenizer cases, C ABI, three integrated cases, ONNX lifecycle and synthetic safety checks. Missing fixtures, a forced child failure and a Tcl fixture-hash assertion returned nonzero through the root target; tokenizer and safety subsets also ran without the large ONNX fixture. The integration entry point passed with packages from an isolated installation. See `INSTALL.md` and `CHARACTERIZATION.md`; These results preceded the later formal Slice 004 acceptance recorded above.

### Slice 004-B2 — source build characterization

* Rebuilt the working-tree C and locked Rust sources from an isolated, hash-verified 64-file snapshot, including untracked source files, using a fresh Cargo target and an existing offline crate cache. An empty offline Cargo cache could not resolve Tokenizers. TEA, Tcl and ONNX Runtime remained external dependencies.
* Installed to an isolated staging prefix after a dry run. Package loading from the installed directory, the 58 tokenizer cases, C ABI checks, three tokenizer/ONNX cases and ONNX lifecycle checks passed in the environment described in `CHARACTERIZATION.md`. Debug metadata exposed temporary build paths; release review remains necessary. See `INSTALL.md` for platform-specific prerequisites and unvalidated platforms. This observation preceded the later formal Slice 004 acceptance recorded above.

### Slice 004-B1 — TEA configuration and installation

* The out-of-tree configuration uses supplied TEA 3.13 macros and a genuine auxiliary installer, verifies the TEA version, and fails explicitly if the required files or Unix platform are unavailable. No TEA files are bundled or downloaded.
* Installation now uses `$(DESTDIR)$(libdir)/tclembedding1.0`, with the default `libdir` derived from `prefix`; a Tcl package-path list is not used as a shell destination. The configured install was inspected in dry runs and exercised with direct, staged and space-containing temporary paths. Installed packages loaded from their explicit installed directory, and tokenizer and ONNX smoke checks passed. See `INSTALL.md` and `CHARACTERIZATION.md` for commands and conditions.
* External crate and ONNX Runtime distribution, other platforms, test entry-point restructuring and release artifact review were pending at this stage; see 004-B3 for the subsequent test entry point. This work preceded the later formal Slice 004 acceptance recorded above.

### Slice 003 — numerical embedding correctness

* Formally accepted 003-A, 003-B1 and the 003-B2 primary-reference characterization, limited to the evaluated model, revision, environments, configurations and cases. Acceptance does not imply universal model compatibility, publication or authorization for subsequent work.
* The current public contract retains L2-normalized `embedding::compute` output and no default tokenizer truncation; no public L2-disable option is added at present. For the evaluated MiniLM revision, consumers explicitly use `-max-length 128` to align with its Sentence Transformers length setting. The default Sentence Transformers `encode()` result is unnormalized; see `DECISIONS.md`.
* The 42 PyTorch reference records include official-default and aligned configurations. With equivalent inputs, IDs matched and the maximum observed normalized embedding error was `1.96218683e-7`. The explicit 129-token truncation check retained `</s>`, matched all 128 reference IDs and observed maximum error `9.1238726837583606e-8`. These are experimental results, not universal tolerances. Pooling and hidden-state comparisons use a separate ONNX client; the binding's internal intermediates are not exposed. Batch-one `encode()` without L2 matched PyTorch pooling numerically for all 42 records. See `CHARACTERIZATION.md` for evidence and limits.

### Slice 003-B1 — native input and output safety

* `embedding::compute` now rejects empty lists, non-integers, negative values and integers outside signed 64-bit range, checks allocation and indexing arithmetic, and validates tensor type, rank, shape and element count before reading. It returns errors for zero or non-finite means and norms. Valid finite nonzero inputs retain the existing pooling and normalization order and threshold; no model vocabulary limit or new model support was introduced.
* Added generated synthetic ONNX fixtures and `tests/embedding_safety_test.tcl` covering invalid IDs, recovery, wrong tensor types and dimensions, zero, NaN, infinity and a small nonzero norm. The 18-case ONNX binding comparison remained identical to its pre-change output; the existing three-vector and lifecycle tests passed. This is not PyTorch or Sentence Transformers parity.
* Slice 003-B1 was formally accepted with the outstanding issues documented in `ROADMAP.md`. At that point this acceptance did not authorize 003-B2 or establish acceptance of Slice 003; the later Slice 003 acceptance is recorded above. Memory instrumentation and remaining limits are described in `CHARACTERIZATION.md`.

### Slice 002 — ONNX resource lifecycle

* Slice 002, including characterization 002-A and correction 002-B, was formally accepted with the outstanding issues recorded in `ROADMAP.md`. Acceptance does not authorize publication or automatically start Slice 003.
* `embedding::free` now deletes a validated, interpreter-owned handle and releases its session, options, environment reference and binding state. Handle renaming preserves identity; command deletion and interpreter destruction use the same cleanup. Repeated free, foreign commands and use after free return errors. Partially initialized resources are cleaned on failure.
* Each `embedding::init_raw` call creates a new handle; it does not reinitialize an existing handle.
* Added `tests/embedding_lifecycle_test.tcl` and `make test-embedding-lifecycle MODEL_ONNX="$MODEL_ONNX"` for bounded lifecycle tests. Three existing integrated tokenizer/ONNX cases passed. For the identified model and environment in `CHARACTERIZATION.md`, all three complete pre- and post-change vectors matched byte for byte; the persistent test compares each component with absolute tolerance `1e-5`. This does not establish general embedding parity.
* A bounded failed-load Valgrind comparison and sampled RSS, thread and file descriptor observations are documented in `CHARACTERIZATION.md`. Successful-session instrumentation, then required before publication, was subsequently performed in Slice 003-B1. Forced failures at each initialization step, full concurrency characterization and the cause of possibly lost memory remain open.

### Slice 001

* Slice 001 was formally accepted with the outstanding issues recorded in `ROADMAP.md`. Acceptance did not imply a commit, publication or authorization to start another slice.

### Tokenization

* Replaced the Tcl greedy vocabulary lookup with a native Rust Tokenizers backend and a Tcl/C bridge. A complete `tokenizer.json` is required; vocabulary-only JSON is no longer supported. Normalization, model, added tokens and postprocessing are read from the file. Padding and truncation are disabled by default; callers can request a maximum length.
* `tokenizer::load_vocab` loads or replaces interpreter-local state, `tokenizer::tokenize` returns IDs, and `tokenizer::free` releases it. The state is also released when the interpreter is deleted. A failed load leaves a previously loaded tokenizer intact.
* Added a locked Cargo build and 58 synthetic cases. The tokenizer is independent of the ONNX library and Python is not a runtime dependency.

### Documentation

* Added a technical baseline, history, decision record, characterization, reproducibility procedures and roadmap. Historical laboratory observations are identified separately from integration tests and unresolved work.

### Verified integration

* On Linux x86-64 with glibc 2.42, GCC 15.3.1, Tcl 8.6.14, Rust 1.99.1, Tokenizers 0.22.1 and ONNX Runtime C 1.20.1, the Tcl/C path matched all 58 reference ID sequences, including fullwidth special tokens, embedded NUL, Unicode, empty input and explicitly configured truncation. The same 58 results matched the separate experimental C ABI. The fixtures use the exact model/tokenizer hashes recorded in the test scripts; other model compatibility is not implied.
* Loading failures, use before load, repeated free, use after free, reload, option errors and interpreter destruction were exercised. A Valgrind 3.27.1 run reported no invalid accesses or definitely lost bytes with the configured definite-loss check; it also reported 2,015,744 possibly lost bytes in the Tcl process with a child interpreter. A separate load/free process and a Tcl package baseline each reported 1,447,936 possibly lost bytes. These results do not prove the absence of leaks.
* Three synthetic texts passed through the integrated tokenizer and ONNX binding, producing distinct 384-component vectors with L2 norms approximately 1. At that point the ONNX binding and pooling had not been modified and `embedding::free` was a no-op; see Slice 002-B above for the subsequent lifecycle correction. Output-shape checks, full numerical parity, portability and additional models remain unverified.
* The initial native wrapper cloned the tokenizer for every encoding. The default untruncated path then used the loaded tokenizer directly; explicit `-max-length` still cloned it at that stage. Slice 006-B subsequently removed that clone.

### Tokenizer robustness

* C ABI error paths now reset valid output pointers and counts even when another argument is null. The C ABI test covers null arguments, oversized lengths, malformed UTF-8, an embedded NUL, emoji, a combining accent, empty input and matching deallocation. An intentionally triggered Rust panic was caught and returned as an error in a unit test; abort-on-panic and allocation failure cannot be recovered by that mechanism.
* The 58-case Tcl fixture passed again, including five explicit truncation cases. Additional checks covered malformed JSON, retained state after failed loads, repeated load/free, use after free, and independent parent/child interpreter state in both teardown orders.
* In one bounded comparison on the same Linux x86-64 environment and identified MiniLM tokenizer, 20 Tcl calls to `hola` took 7,850,108 µs before removing the default-path clone and 368 µs afterward. Process RSS after those calls was 537,904 KiB before and 297,168 KiB afterward. These are individual diagnostic runs, not portable performance guarantees; the later lifecycle test temporarily held two loaded interpreters.
* Inspection of Tokenizers 0.22.1 shows Unigram cloning copies the vocabulary, token map and trie and initializes a fresh cache. In a separate 10-iteration Rust diagnostic after warmup, median clone-and-encode time was 391.314 ms versus 0.007177 ms for direct encode; peak RSS was 534,184 versus 302,244 KiB in separate processes. At that stage the explicit truncation path still had this clone cost; Slice 006-B subsequently removed it.
* Valgrind 3.27.1 reported zero invalid-access errors and zero definitely or indirectly lost bytes under a definite-loss check. The package/interpreter baseline reported 2,065,408 possibly lost bytes in 118 blocks; a separate repeated load/encode/free and interpreter teardown run reported 1,797,632 bytes in 103 blocks. Inspected possible-loss records in both runs contained Tcl allocator frames. These results do not establish absence of leaks or attribute the possible losses to Rust.
* A separate Valgrind run of the C ABI checks, without Tcl, reported zero errors and no definite, indirect or possible losses; 88 bytes remained reachable. This is limited to the exercised paths.

### Previous laboratory observations

* The previous Tcl tokenizer differed from Tokenizers 0.22.1 for 6 of 11 synthetic inputs with the same multilingual MiniLM tokenizer. A SentencePiece C++ adapter matched 57 of 58 cases; a Rust Tokenizers C ABI prototype matched 58 of 58. These observations preceded the integration tests above.
* With the same model on ONNX Runtime C 1.20.1, three mean-pooled vectors were distinct; pairwise cosine similarities were approximately 0.104921, 0.293307 and 0.107481. The Tcl binding's normalized outputs matched independently calculated normalized means within `5.56e-17` for those inputs. This was a limited laboratory observation, not a general numerical compatibility claim.

### Reproduction

After the isolated Linux build in `INSTALL.md`, supply the test fixtures and run from that build directory:

```bash
make -C "$build_dir/unix" TOKENIZER_JSON="$TOKENIZER_JSON" test-tokenizer
make -C "$build_dir/unix" TOKENIZER_JSON="$TOKENIZER_JSON" test-tokenizer-abi
make -C "$build_dir/unix" TOKENIZER_JSON="$TOKENIZER_JSON" MODEL_ONNX="$MODEL_ONNX" test-tokenizer-embedding
make -C "$build_dir/unix" MODEL_ONNX="$MODEL_ONNX" test-embedding-lifecycle
```

With the locked Cargo dependencies available, the panic unit test and the bounded clone diagnostic can be reproduced separately:

```bash
cargo test --offline --locked --release --lib --manifest-path "$project_dir/tokenizer-native/Cargo.toml"
cargo build --offline --locked --release --example clone_probe --manifest-path "$project_dir/tokenizer-native/Cargo.toml"
/usr/bin/time -f 'peak_rss_kib=%M' "$CARGO_TARGET_DIR/release/examples/clone_probe" "$TOKENIZER_JSON" direct
/usr/bin/time -f 'peak_rss_kib=%M' "$CARGO_TARGET_DIR/release/examples/clone_probe" "$TOKENIZER_JSON" clone
```

Set `CARGO_TARGET_DIR` to the isolated build directory when running the last three commands.

The fixture hashes are checked by the tests. The tests above were also run against an isolated Unix makefile build with an existing offline Cargo cache. The current Unix link rule uses Linux `.so` and `$ORIGIN`; other platforms and the full configure/install workflow have not been verified.

---

## [1.1.0] - 2024-12-24

The following historical entries were inherited with the initial import. Their dates and release claims have not been independently verified against earlier commits.

### Added

* **FMA (Fused Multiply-Add) Support**: AVX-capable builds can leverage FMA instructions for improved performance and numerical precision.
* **Efficient Horizontal Reductions**: Added `hsum_sse` and `hsum_avx` helpers for optimal SIMD vector summation.
* **Identity Optimization**: Fast path returning `1.0` when comparing a vector with itself.

### Changed

* Cosine similarity denominator optimized to use a **single `sqrtf()` call** (`sqrt(ma2 * mb2)`) to reduce latency.
* SIMD implementations are now selected **at compile time** via compiler flags, favoring predictability and simplicity.
* Improved numerical stability using `FLT_MIN` thresholds instead of exact zero comparisons.
* Unified cosine similarity calculation into a **single-pass algorithm** (dot product and magnitudes computed together).
* Enhanced build flags for performance-oriented builds:

  ```bash
  -O3 -march=native -ffast-math -fno-math-errno -flto
  ```
* Improved code organization with clearer functional separation and documentation.

### Fixed

* Strict validation of input BLOB sizes to ensure alignment with `float32`.
* Dimension mismatch handling: vectors of different sizes now result in an explicit error instead of silent truncation.
* Potential division-by-zero scenarios with near-zero magnitude vectors.

### Technical Notes

* **SIMD Selection**: Instruction sets (SSE / AVX / FMA) are chosen at compile time.
* **Recompilation Required**: To leverage newer CPU features, the UDF must be recompiled on the target system.
* **SSE Path**: Processes 4 floats per iteration (suitable for AMD Phenom II and similar CPUs).
* **AVX Path**: Processes 8 floats per iteration when enabled.
* **Scalar Fallback**: Guaranteed portability on systems without SIMD support.
* 384-dimension vectors: 96 SSE iterations or 48 AVX iterations.
* 1024-dimension vectors: 256 SSE iterations or 128 AVX iterations.

### Build Command

```bash
gcc -O3 -march=native -ffast-math -fno-math-errno -flto \
    -shared -fPIC \
    -o udf_cosine_similarity.so rag_optimizations.c \
    -I/usr/include/mysql -lm
```

---

## [1.0.1] - 2024-12-21

### Added

* Initial SIMD hardware acceleration for cosine similarity (SSE / AVX where available).
* Architecture-aware compilation via compiler feature detection.

### Changed

* MySQL UDF (`cosine_similarity`) optimized for architecture-specific builds.
* Standardized output filename to `mysql_cosine_similarity.so`.
* Updated build flags to emphasize performance-oriented compilation.
* Explicit dependency on the math library (`-lm`) due to `sqrtf()` usage.

### Technical Notes

* **SSE Path**: Parallel processing of 4 floats per iteration (optimized for AMD Phenom II).
* **AVX Path**: Parallel processing of 8 floats per iteration on capable CPUs.
* **Fallback**: Scalar implementation for maximum portability.
* Optimized primarily for 384-dimension embedding models.
* The `-lm` flag is required for correct linkage.

---

## [1.0.0] - 2024-12-21

### Added

* Initial release of the tclembedding extension.
* Support for text embedding generation using ONNX Runtime.
* Multilingual transformer model support (MiniLM, E5).
* Mean pooling and L2 normalization of embeddings.
* Complete TEA (Tcl Extension Architecture) compliance.
* Comprehensive documentation and usage examples.
* Automatic package discovery and loading.
* Support for multiple concurrent model instances.
* Efficient C implementation with minimal overhead.

### Features

* `embedding::init_raw` – Initialize ONNX model.
* `embedding::compute` – Compute embeddings from token IDs.
* `embedding::free` – Release model resources.
* `tokenizer::load_vocab` – Load tokenizer vocabulary.
* `tokenizer::tokenize` – Convert text to token IDs.
* SentencePiece tokenization support.
* Variable-length input handling (up to 128 tokens).

### Documentation

* README.md with comprehensive usage guide.
* INSTALL.md with detailed installation instructions.
* `examples.tcl` demonstrating common use cases.
* API reference with full command documentation.

### Build System

* autoconf / automake configuration.
* Cross-platform Unix/Linux build support.
* Automatic dependency detection.
* TEA-compliant installation layout.

---

## Release Notes

### Version 1.0.0 – Stable Release

First production-ready release of tclembedding, providing efficient and reliable text embedding functionality for Tcl applications.

**Key Milestones**

* Zero compiler warnings.
* Verified memory management.
* Comprehensive test coverage.
* Full TEA compliance.
* Robust ONNX Runtime error handling.

**Known Limitations**

* CPU inference only (GPU support planned).
* Single-threaded execution.
* Maximum sequence length: 128 tokens.
* Requires system-installed ONNX Runtime.

### Compatibility

| Component    | Version |
| ------------ | ------- |
| Tcl/Tk       | 8.6+    |
| ONNX Runtime | 1.12+   |
| GCC          | 7.0+    |
| Clang        | 5.0+    |

---

For detailed history, see the git commit log.
