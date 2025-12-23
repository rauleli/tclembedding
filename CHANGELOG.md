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
- **SIMD Hardware Acceleration**: Soporte para aceleración por hardware SIMD (SSE/AVX) en el cálculo de similitud de coseno
- CPU dispatching automático mediante macros de preprocesador para seleccionar la mejor implementación disponible

### Changed
- El UDF de MySQL (`cosine_similarity`) ahora utiliza detección de capacidades del compilador para maximizar el rendimiento según el CPU donde se compile
- Comando de compilación actualizado con flags `-march=native -O3 -msse3 -msse4a` para optimización específica de arquitectura
- Nombre del archivo de salida estandarizado a `mysql_cosine_similarity.so`
- El UDF ahora **requiere** linkear la librería matemática (`-lm`) debido al uso de `sqrtf()` en el cálculo de magnitudes vectoriales

### Technical Notes
- **SSE3/SSE4a Path**: Procesamiento paralelo de 4 floats por iteración (óptimo para AMD Phenom II y CPUs similares)
- **AVX Path**: Procesamiento paralelo de 8 floats por iteración (para CPUs Intel/AMD modernos)
- **Fallback**: Implementación escalar para arquitecturas sin SIMD
- Optimizado para la arquitectura de 384 dimensiones del modelo E5-small, permitiendo procesamiento vectorial eficiente
- El modelo de 384 dims se procesa en 96 iteraciones SSE (384/4) o 48 iteraciones AVX (384/8)
- **Importante**: El flag `-lm` es vital para la función `sqrtf()` usada en el cálculo de magnitudes

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
