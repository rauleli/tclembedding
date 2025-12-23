# Changelog

All notable changes to the tclembedding project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2024-12-21

### Added
- Initial release of tclembedding extension
- Support for text embedding generation using ONNX Runtime
- Multilingual transformer model support (MiniLM, E5)
- Mean pooling and L2 normalization of embeddings
- Complete TEA (Tcl Extension Architecture) compliance
- Comprehensive documentation and examples
- Automatic package discovery and loading
- Support for multiple concurrent model instances
- Efficient C implementation with minimal overhead

### Features
- `embedding::init_raw` - Initialize ONNX model
- `embedding::compute` - Compute embeddings from token IDs
- `embedding::free` - Clean up resources
- `tokenizer::load_vocab` - Load tokenizer vocabulary
- `tokenizer::tokenize` - Convert text to token IDs
- SentencePiece tokenization support
- Variable-length input handling (up to 128 tokens)

### Documentation
- README.md with comprehensive usage guide
- INSTALL.md with detailed installation instructions
- examples.tcl demonstrating common use cases
- API reference with full command documentation

### Build System
- autoconf/automake configuration
- Cross-platform Unix/Linux build support
- Automatic dependency detection
- TEA-compliant installation structure

## [Unreleased]

### Added
- **SIMD Hardware Acceleration**: Support for SIMD hardware acceleration (SSE/AVX) in cosine similarity calculation
- Automatic CPU dispatching via preprocessor macros to select the best available implementation

### Changed
- MySQL UDF (`cosine_similarity`) now uses compiler capability detection to maximize performance based on the target CPU
- Updated build command with `-march=native -O3 -msse3 -msse4a` flags for architecture-specific optimization
- Standardized output filename to `mysql_cosine_similarity.so`
- UDF now **requires** linking the math library (`-lm`) due to `sqrtf()` usage in vector magnitude calculation

### Technical Notes
- **SSE3/SSE4a Path**: Parallel processing of 4 floats per iteration (optimal for AMD Phenom II and similar CPUs)
- **AVX Path**: Parallel processing of 8 floats per iteration (for modern Intel/AMD CPUs)
- **Fallback**: Scalar implementation for architectures without SIMD
- Optimized for E5-small model's 384-dimension architecture, enabling efficient vector processing
- 384-dim model is processed in 96 SSE iterations (384/4) or 48 AVX iterations (384/8)
- **Important**: The `-lm` flag is essential for the `sqrtf()` function used in magnitude calculation

### Build Command
```bash
gcc -shared -fPIC -march=native -O3 -msse3 -msse4a \
  -o mysql_cosine_similarity.so rag_optimizations.c \
  $(mysql_config --include) -lm
```

### Planned Features
- Windows (MSVC) build support
- macOS universal binary support
- Batch processing API
- Support for more tokenizer formats
- GPU acceleration options
- Extended model support

---

## Release Notes

### Version 1.0.0
**Stable Release**

This is the first stable release of tclembedding, providing production-ready text embedding functionality within Tcl applications.

**Key Milestones:**
- Zero compiler warnings
- Complete memory management verification
- Comprehensive test coverage
- Full TEA compliance
- Exhaustive ONNX Runtime error checking

**Known Limitations:**
- CPU inference only (GPU support planned)
- Single-threaded operation
- Maximum sequence length: 128 tokens
- Requires system-installed ONNX Runtime

**Testing:**
- Tested on Linux (Ubuntu, Fedora)
- Verified with popular models from HuggingFace
- Confirmed compatibility with Tcl 8.6, 8.7, 9.0
- Validated with multiple language inputs

### Compatibility

| Component | Version |
|-----------|---------|
| Tcl/Tk | 8.6+ |
| ONNX Runtime | 1.12+ |
| GCC | 7.0+ |
| Clang | 5.0+ |

### Contributors

- Original implementation and design
- ONNX Runtime integration
- TEA standard compliance
- Comprehensive documentation

---

For detailed changelog entries, see git commit history.
