# Changelog

All notable changes to the tclembedding project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.1.0] - 2024-12-24

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
