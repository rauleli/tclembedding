# tclembedding - Tcl Text Embedding Extension

A high-performance Tcl extension for generating text embeddings using ONNX Runtime and sentence transformer models.

## Overview

`tclembedding` provides Tcl bindings for tokenization and ONNX inference. The tokenizer loads a complete Hugging Face `tokenizer.json`; model compatibility depends on the tokenizer and ONNX signature and must be verified for each model.

### Why Tcl?

It all started with Eggdrop bots in the '90s. Things got a little out of hand.

Thirty years later, I'm still using it to connect databases, automate industrial systems, build ERPs, run distributed workers, and integrate AI models.

Some of that code has been running unchanged for seven years.

At this point, switching languages would be the experimental choice.

## Requirements

- **Tcl 8.6** and its development files; other versions are not characterized.
- **ONNX Runtime C** headers and library from a compatible installation.
- **Standard C compiler** (GCC, Clang, etc.)
- **Rust and Cargo**, to build the native tokenizer with the committed `Cargo.lock`

## Installation

### Source distributions

The [Releases page](https://github.com/rauleli/tclembedding/releases) is the
intended location for reviewed source archives when publication is authorized.
An explicitly prepared source archive is distinct from GitHub's automatically
generated source snapshots: the prepared archive contains a curated inventory,
installation instructions and a SHA-256 manifest. No archive is implied to be
available until it is actually published. Tcl, TEA, Cargo dependencies and ONNX
Runtime remain external; the source archive does not contain binaries or models.
See [INSTALL.md](INSTALL.md) for how to build and verify a local archive.

### Linux build

See [INSTALL.md](INSTALL.md) for the configured, isolated Linux build and installation procedure, including the required external TEA 3.13 files and Tcl and ONNX settings. Other platforms and dependency distribution remain unverified.

## Quick Start

### Basic Usage

```tcl
# Load the extensions
package require tclembedding
package require tokenizer

# Load a complete tokenizer configuration
tokenizer::load_vocab "path/to/tokenizer.json"

# Initialize the ONNX model
set handle [embedding::init_raw "path/to/model.onnx"]

# Tokenize text and compute embedding
set tokens [tokenizer::tokenize "your text here"]
set vector [embedding::compute $handle $tokens]

# Release the independent model and tokenizer resources.
embedding::free $handle
tokenizer::free
```

### Complete Example

```tcl
#!/usr/bin/env tclsh

package require tclembedding
package require tokenizer

# Model paths
set model_path "path/to/model.onnx"
set tokenizer_path "path/to/tokenizer.json"

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

# Release the model and tokenizer
embedding::free $handle
tokenizer::free
```

## API Reference

### Package: tclembedding

#### embedding::init_raw *model_path* ?-provider cpu|cuda? ?-device index? ?-profile prefix?

Initializes the ONNX embedding model. CPU is the default. CUDA must be selected
explicitly and requires a compatible ONNX Runtime CUDA provider, driver and
dependencies. An unavailable CUDA provider or failed registration returns an
error; it is not silently replaced by a CPU-only session. ONNX Runtime may still
assign individual graph nodes to CPU in a CUDA session.

**Arguments:**
- `model_path` - Path to ONNX model file
- `-provider` - `cpu` or `cuda`; defaults to `cpu`.
- `-device` - Nonnegative decimal CUDA device index, default `0`; requires CUDA.
- `-profile` - Writable filename prefix for an optional ONNX Runtime profile.

Profiling starts with session creation and is finalized when the handle is freed,
deleted or its interpreter is destroyed. ONNX Runtime determines the final
filename by appending a timestamp and `.json`. Explicit `embedding::free`
reports finalization errors and releases the handle; deletion callbacks cannot
return an error to the caller. Keep profile files private. Without `-profile`,
the binding does not request profiling. CPU-only ONNX Runtime installations do
not require CUDA libraries. Provider registration does not prove that every node
ran on GPU. See `INSTALL.md` for requirements and the current validation scope.

**Returns:** An opaque handle string scoped to the current interpreter.

**Errors:** Returns error if model cannot be loaded

#### embedding::compute *handle* *token_id_list* ?-pooling mean|cls?

Computes the embedding vector from a list of token IDs.
The list must be nonempty and contain nonnegative signed 64-bit integers.
Incompatible ONNX output tensors and zero or non-finite embedding norms return errors.

**Arguments:**
- `handle` - Handle returned by `embedding::init_raw`
- `token_id_list` - Tcl list of integer token IDs (from `tokenizer::tokenize`)

**Returns:** A list of floating-point numbers representing an L2-normalized embedding. The length is the validated hidden dimension of the ONNX output (384 or 768 in the evaluated models).

**Features:**
- `-pooling mean` averages token positions and is the default. `-pooling cls` uses the first token.
- L2 normalization; no automatic pooling selection, truncation or input prefixes.
- Input signatures with the required rank-2 int64 `input_ids` and `attention_mask`, and optional `token_type_ids`, are validated at initialization. Additional inputs are rejected.

#### embedding::compute_batch *handle* *token_id_lists* -pad-id *integer* ?-pooling mean|cls?

Computes one L2-normalized embedding per nonempty sequence, preserving input order. The caller must supply a nonnegative signed 64-bit padding ID; the binding does not infer it from the tokenizer or the ONNX model. Sequences are padded on the right to the longest sequence; the attention mask is one for supplied positions and zero for padding. Mean pooling excludes padding; CLS pooling selects the first token of each sequence. The default pooling is mean. `token_type_ids` are zeros only when the model declares that input. No tokenizer batching, truncation or model-specific prefix is applied.

For bounded execution, this API accepts at most 256 sequences, 512 IDs per sequence and 4,096 padded input positions. It requires a positive, statically declared ONNX output hidden dimension no greater than 8,192 and at most 16,777,216 output elements. These are revisable binding resource policies, not model vocabulary or context limits; ONNX Runtime may allocate additional internal memory. Unsupported metadata, fixed batch or sequence mismatches, invalid IDs, empty sequences, non-finite output and invalid norms return Tcl errors. The model must support the requested batch, and callers must supply IDs appropriate to its vocabulary.

```tcl
set vectors [embedding::compute_batch $handle [list $ids1 $ids2] -pad-id $pad_id]
set cls_vectors [embedding::compute_batch $handle [list $ids1 $ids2] -pad-id $pad_id -pooling cls]
```

The evaluated padding IDs were MiniLM 1, BGE 0, E5 1 and MPNet 1. For the identified MiniLM revision, the tokenizer uses ID 1 for `<pad>` while the model configuration declares `pad_token_id` 0; ID 1 was used in the reported tests. It is not established that a different ID is always immaterial or that 0 is incorrect. An inconsistent ID can cause errors or change semantics, so selecting it is the caller's responsibility.

Batch support is characterized for the four identified model revisions in `CHARACTERIZATION.md`, not arbitrary ONNX graphs. Fixed batch sizes other than one are currently rejected when creating a handle. `embedding::compute` retains its existing behavior and validates the effective output dimension at runtime; it does not impose the batch path's static-hidden-dimension restriction.

#### embedding::free *handle*

Releases the model resources and deletes the handle command. Repeated free, a freed handle or a foreign command produces an error. Renaming the handle preserves its identity; deleting it with `rename $handle {}` or destroying its interpreter also releases the resources.

**Arguments:**
- `handle` - Handle returned by `embedding::init_raw`

---

### Package: tokenizer

#### tokenizer::load_vocab *json_path*

Loads a complete Hugging Face `tokenizer.json`. A successful load replaces the previous tokenizer in the interpreter; a failed load leaves it intact. Vocabulary-only JSON files are not supported.

**Arguments:**
- `json_path` - Path to tokenizer.json file

#### tokenizer::tokenize *text* ?-max-length *count*?

Tokenizes input text into a list of token IDs.

**Arguments:**
- `text` - Input text string
- `-max-length count` - Optional positive maximum number of output IDs, including special tokens. A limit smaller than the required special tokens is an error. By default truncation and padding are disabled.

**Returns:** A Tcl list of integer token IDs

The configuration supplies normalization, tokenization, added tokens and postprocessing. Errors are returned if loading or encoding fails.

#### tokenizer::encode_details *text* ?-max-length *count*?

Returns one positional list per token: `{id byte_start byte_end special_mask attention_mask type_id}`. IDs and truncation follow `tokenizer::tokenize`. Offsets are zero-based byte positions into the standard UTF-8 encoding of the supplied Tcl text; the end is exclusive. They are not Tcl string indices or grapheme offsets. Normalization, added tokens and the model's postprocessor can yield overlapping, noncontiguous or empty ranges, and offsets need not cover the input. Do not assume a byte offset is a Tcl character boundary.

The masks and type IDs are returned directly by Hugging Face Tokenizers. A postprocessor-inserted special commonly has an empty range and mask 1, but a literal special token in the input can have a nonempty range and mask 0 even when its ID is special. A zero mask does not prove that an ID is ordinary. Padding is disabled by this binding; attention values are provided by the tokenizer and should not be inferred from IDs. No grapheme segmentation or universal alignment guarantee is implied.

This additive command remains in package version `1.0.0` so existing exact package requirements continue to load. A future release may introduce coordinated versioning; callers that need this capability should also check for the command.

#### tokenizer::free

Releases the loaded tokenizer. It also runs automatically when the interpreter is deleted. Calling it without a loaded tokenizer returns an error.

### Evaluated model configuration

The characterized model is `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`, revision `e8f8c211226b894fcb81acc59f3b34ba3efd5f42`, with 384-dimensional outputs. For this revision, Sentence Transformers configures a maximum of 128 tokens and returns embeddings without L2 normalization by default. The Tcl tokenizer does not truncate by default; to match the evaluated model's truncation setting explicitly:

```tcl
set tokens [tokenizer::tokenize $text -max-length 128]
```

`embedding::compute` always applies L2 normalization; there is currently no public option to disable it. Thus its output should be compared with a separately normalized Sentence Transformers embedding, using equivalent IDs and attention masks. Different truncation or normalization settings can change vectors even when the numeric calculation is correct. The comparison covered batch size one without actual padding; general concurrent use and universal model compatibility are not established; right-padding in the batch API has separate, limited evidence. Other ONNX configurations have separate, limited evidence in `CHARACTERIZATION.md`. Slice 003 acceptance is limited to the evaluated model, revision, environments, configurations and cases; see `CHARACTERIZATION.md` for measured errors and limits.

## Model Files

Models can be obtained from HuggingFace. The evaluated backend requires:
- `model.onnx` - ONNX format neural network
- `tokenizer.json` - complete Hugging Face tokenizer configuration

### Downloading Models

Model files are available from HuggingFace. The following links do not establish compatibility for models other than the revision characterized above:

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
- **Intra-op parallelism** configured to one thread in the current binding
- **Sequential execution mode** for memory efficiency
- **Mean or first-token pooling** selected explicitly by the caller

Exploratory measurements and their limitations are recorded in `BENCHMARKING.md`; they are not general performance guarantees.

## Architecture Details

### Tokenization

- Rust Tokenizers reads the complete tokenizer configuration.
- No universal maximum length is imposed; callers may explicitly request truncation.

### Output Processing

1. Extract last hidden state from ONNX model
2. Apply mean pooling across the token dimension by default, or first-token pooling when explicitly selected
3. Calculate L2 norm and normalize vector
4. Return as Tcl list of floats

### Memory Management

- Tcl-managed memory for extension state
- Tokenizer state is released explicitly or during interpreter destruction
- ONNX Runtime handles tensor memory
- ONNX sessions are released with `embedding::free`, handle deletion or interpreter destruction

## Testing

From the configured build directory, `make test` runs the full suite when the identified tokenizer JSON, ONNX model and synthetic safety fixtures are supplied. It reports missing fixtures and failed checks as errors. Tokenizer-only and safety-only targets are also available. See [INSTALL.md](INSTALL.md) for fixture preparation, commands and limits; tests do not download models.

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

Use the isolated build procedure in [INSTALL.md](INSTALL.md). The existing configure/install workflow remains unverified.

## License

See LICENSE file for details.

## Development

### Build Configuration

The existing autoconf templates require separately supplied TEA macros. Cross-platform configure and installation have not been verified. Use the isolated Linux procedure in `INSTALL.md` for the tested build.

### Directory Structure

- `generic/` - Platform-independent C source code (tclembedding.c)
- `tokenizer-native/` - Rust tokenizer and C ABI
- `tests/` - Test suite
- `tools/` - Utility scripts for ingestion and search
- `docs/` - Advanced documentation (MySQL integration, RAG examples, security)
- `models/` - ONNX models and tokenizer files (not included in distribution)

## Documentation

- [BASELINE.md](BASELINE.md) - Current technical baseline
- [HISTORY.md](HISTORY.md) - Technical history and evidence boundaries
- [DECISIONS.md](DECISIONS.md) - Authorized decisions and open questions
- [CHARACTERIZATION.md](CHARACTERIZATION.md) - Experimental observations
- [BENCHMARKING.md](BENCHMARKING.md) - Reproducible checks and measurements
- [ROADMAP.md](ROADMAP.md) - Pending work and dependencies
- [examples.tcl](docs/examples.tcl) - Usage examples
- [GETTING_STARTED.md](docs/GETTING_STARTED.md) - Detailed setup guide
- [TEA_SETUP.md](docs/TEA_SETUP.md) - TEA build system details
- [MYSQL_INTEGRATION.md](docs/MYSQL_INTEGRATION.md) - MySQL vector storage
- [RAG_EXAMPLE.md](docs/RAG_EXAMPLE.md) - RAG implementation example
- [In-memory semantic retrieval](examples/01-in-memory-rag/README.md) - Synthetic corpus and embeddings without a database or generative model
- [Persistent semantic retrieval](examples/02-persistent-rag/README.md) - Store and reuse synthetic embeddings with SQLite
- [Conversation retrieval with SQL](examples/03-chatgpt-export/SQL_RETRIEVAL.md) - Generate embeddings directly into SQLite or MySQL with resumable batches
- [CONVERSATION_EXTRACTION.md](docs/CONVERSATION_EXTRACTION.md) - Local ChatGPT conversation export preparation for a future RAG pipeline
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
