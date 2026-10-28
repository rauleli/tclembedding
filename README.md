# tclembedding - Tcl Text Embedding Extension

A high-performance Tcl extension for generating text embeddings using ONNX Runtime and sentence transformer models.

## Overview

`tclembedding` provides Tcl bindings for text embedding generation using pre-trained multilingual transformer models. It leverages ONNX Runtime for efficient inference and supports models like:

- `e5-small` (384 dimensions) - requires `query:` or `passage:` prefix
- `paraphrase-multilingual-MiniLM-L12-v2` (384 dimensions) - no prefix required

## Requirements

- **Tcl 8.6 or higher**
- **ONNX Runtime** (development package)
  - Linux: `libonnxruntime-dev`
  - macOS: `onnx-runtime` (via Homebrew)
- **Standard C compiler** (GCC, Clang, etc.)

## Installation

### From Source (Standard TEA Installation)

1. **Configure the build**:
   ```bash
   ./configure
   ```

   Available options:
   - `--prefix=/usr/local` - Installation prefix (default: `/usr/local`)
   - `--with-tcl=/path/to/tcl/config` - Tcl configuration directory

2. **Build the extension**:
   ```bash
   make
   ```

3. **Install**:
   ```bash
   make install
   ```

   This installs to the Tcl package path: `$prefix/lib/tclembedding1.0/`

### Building Configure Script

If `configure` is not present:

```bash
autoconf
./configure
make
make install
```

## Quick Start

### Basic Usage

```tcl
# Load the extensions
package require tclembedding
package require tokenizer

# Load the tokenizer vocabulary
tokenizer::load_vocab "path/to/tokenizer.json"

# Initialize the ONNX model
set handle [embedding::init_raw "path/to/model.onnx"]

# Tokenize text and compute embedding
set tokens [tokenizer::tokenize "your text here"]
set vector [embedding::compute $handle $tokens]

# Clean up
embedding::free $handle
```

### Complete Example

```tcl
#!/usr/bin/env tclsh

package require tclembedding
package require tokenizer

# Model paths
set model_path "models/e5-small/model.onnx"
set tokenizer_path "models/e5-small/tokenizer.json"

# 1. Load tokenizer vocabulary
tokenizer::load_vocab $tokenizer_path

# 2. Initialize ONNX model
set handle [embedding::init_raw $model_path]

# 3. Tokenize and compute embedding
set text "passage: Hello, world!"
set tokens [tokenizer::tokenize $text]
set embedding [embedding::compute $handle $tokens]

# Display results
puts "Text: $text"
puts "Token IDs: $tokens"
puts "Dimensions: [llength $embedding]"
puts "First 5 values: [lrange $embedding 0 4]"

# Cleanup
embedding::free $handle
```

## API Reference

### Package: tclembedding

#### embedding::init_raw *model_path*

Initializes the ONNX embedding model.

**Arguments:**
- `model_path` - Path to ONNX model file

**Returns:** A handle string (e.g., `embedding0x12345678`)

**Errors:** Returns error if model cannot be loaded

#### embedding::compute *handle* *token_id_list*

Computes the embedding vector from a list of token IDs.

**Arguments:**
- `handle` - Handle returned by `embedding::init_raw`
- `token_id_list` - Tcl list of integer token IDs (from `tokenizer::tokenize`)

**Returns:** A list of floating-point numbers representing the embedding (384 dimensions for e5-small)

**Features:**
- Mean pooling across tokens
- L2 normalization

#### embedding::free *handle*

Releases resources associated with the model.

**Arguments:**
- `handle` - Handle returned by `embedding::init_raw`

---

### Package: tokenizer

#### tokenizer::load_vocab *json_path*

Loads the vocabulary from a HuggingFace tokenizer.json file.

**Arguments:**
- `json_path` - Path to tokenizer.json file

**Notes:**
- Supports SentencePiece array format and flat dictionary format
- Automatically detects special tokens (`<s>`, `</s>`, `<unk>`)

#### tokenizer::tokenize *text*

Tokenizes input text into a list of token IDs.

**Arguments:**
- `text` - Input text string

**Returns:** A Tcl list of integer token IDs

**Features:**
- SentencePiece-style tokenization with `▁` (U+2581) prefix for word boundaries
- Greedy longest-match algorithm
- Automatically adds BOS (`<s>`) and EOS (`</s>`) tokens

## Model Files

Models can be obtained from HuggingFace. Each model requires:
- `model.onnx` - ONNX format neural network
- `tokenizer.json` - SentencePiece/BPE tokenizer configuration

### Downloading Models

Models are available from HuggingFace in ONNX format:

- **e5-small**: https://huggingface.co/intfloat/e5-small (use ONNX version)
- **paraphrase-multilingual-MiniLM-L12-v2**: https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2

You can download models using `git lfs` or the HuggingFace CLI:
```bash
# Using git
git lfs install
git clone https://huggingface.co/intfloat/e5-small models/e5-small

# Or using huggingface-cli
pip install huggingface_hub
huggingface-cli download intfloat/e5-small --local-dir models/e5-small
```

### Model Prefixes

Some models require specific text prefixes for optimal performance:

| Model | Prefix Required | Usage |
|-------|-----------------|-------|
| `e5-small` | Yes | Use `query:` for search queries, `passage:` for documents |
| `paraphrase-multilingual-MiniLM-L12-v2` | No | Direct text input |

Example with e5-small:
```tcl
# For a search query
set tokens [tokenizer::tokenize "query: What is machine learning?"]

# For a document/passage to be searched
set tokens [tokenizer::tokenize "passage: Machine learning is a subset of AI..."]
```

### Directory Structure

```
models/
├── e5-small/
│   ├── model.onnx
│   └── tokenizer.json
└── paraphrase-multilingual-MiniLM-L12-v2/
    ├── model.onnx
    └── tokenizer.json
```

## Performance

- **CPU inference** with ONNX Runtime
- **Intra-op parallelism** with configurable thread count
- **Sequential execution mode** for memory efficiency
- **Mean pooling** for variable-length inputs

Typical performance:
- Model loading: <500ms
- Single inference: 10-50ms (CPU dependent)

## Architecture Details

### Tokenization

- SentencePiece/Unigram style tokenization
- Automatic special token handling (`<s>`, `</s>`, `<pad>`, `<unk>`)
- Greedy longest-match subword splitting
- Maximum sequence length: 128 tokens

### Output Processing

1. Extract last hidden state from ONNX model
2. Apply mean pooling across token dimension
3. Calculate L2 norm and normalize vector
4. Return as Tcl list of floats

### Memory Management

- Tcl-managed memory for extension state
- Standard malloc/free for tokenizer vocabulary
- ONNX Runtime handles tensor memory
- Automatic cleanup via `embedding::free`

## Testing

Run the test suite:

```bash
make test
```

Or individually:
```bash
tclsh tests/quick_test.tcl
```

## Troubleshooting

### "libonnxruntime not found"

Install ONNX Runtime:
- **Ubuntu/Debian**: `sudo apt-get install libonnxruntime-dev`
- **Fedora**: `sudo dnf install onnxruntime-devel`
- **macOS**: `brew install onnx-runtime`

### "Model file not found"

Ensure model paths are absolute or relative to the current working directory.

### "Tokenizer.json parsing failed"

Verify the tokenizer.json format matches HuggingFace structure.

## Building from Git

```bash
git clone <repository-url>
cd tclembedding
autoconf
./configure --prefix=/usr/local
make
make install
```

## License

See LICENSE file for details.

## Development

### Build Configuration

The extension uses standard autoconf/automake for cross-platform compatibility:

```bash
# Generate configure script
autoconf

# Configure build
./configure

# Build
make

# Clean
make clean
```

### Directory Structure

- `generic/` - Platform-independent C source code (tclembedding.c)
- `lib/` - Tcl library modules (tokenizer.tcl)
- `tests/` - Test suite
- `tools/` - Utility scripts for ingestion and search
- `docs/` - Advanced documentation (MySQL integration, RAG examples, security)
- `models/` - ONNX models and tokenizer files (not included in distribution)

## Documentation

- [examples.tcl](docs/examples.tcl) - Usage examples
- [GETTING_STARTED.md](docs/GETTING_STARTED.md) - Detailed setup guide
- [TEA_SETUP.md](docs/TEA_SETUP.md) - TEA build system details
- [MYSQL_INTEGRATION.md](docs/MYSQL_INTEGRATION.md) - MySQL vector storage
- [RAG_EXAMPLE.md](docs/RAG_EXAMPLE.md) - RAG implementation example
- [SECURITY.md](docs/SECURITY.md) - Security considerations

## Contributing

Report issues and improvements to the repository.

## See Also

- [Tcl/Tk Documentation](https://www.tcl.tk)
- [ONNX Runtime](https://onnxruntime.ai/)
- [Sentence Transformers](https://www.sbert.net/)
- [TEA (Tcl Extension Architecture)](https://www.tcl.tk/doc/tea/tea.html)

---

## ☕ Support my work

If this project has been helpful to you or saved you some development time, consider buying me a coffee! Your support helps me keep exploring new optimizations and sharing quality code.

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ffdd00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/rauleli)
