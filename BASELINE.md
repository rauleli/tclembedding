# Technical baseline

Slices 001–008 were formally accepted with documented outstanding issues. Slice 008 acceptance is limited to the identified models, revisions, inputs and environments; it does not establish general padding, batching, memory safety, concurrency, portability or performance guarantees. Slice 007 acceptance is limited to the four identified model revisions, configurations, cases and environments in `CHARACTERIZATION.md`; it does not establish general model compatibility, padding, batching, concurrency or portability. Slice 003 acceptance is limited to the model, revision, environments, configurations and cases actually evaluated. Slice 004 acceptance is limited to the evaluated Linux x86-64 build, installation and test environment with identified external dependencies. Slice 005 established and published a development Git baseline; it does not establish binary reproducibility, self-contained distribution, general model compatibility, concurrency or other-platform compatibility. Slice 006 replaced per-call truncation cloning with per-instance synchronization and temporary native configuration, accepted only within the tested scope; no general concurrency or performance guarantee follows. Acceptance does not authorize subsequent work. The behavior below is based on the present code and tests and does not imply general model compatibility.

## Components

| Component | Responsibility and source |
| --- | --- |
| Tokenization | `generic/tokenizer_bridge.c` connects Tcl with `tokenizer-native/`, using Rust Tokenizers 0.22.1 and a complete `tokenizer.json` for normalization, model, added tokens and postprocessing. |
| Inference | `generic/tclembedding.c` uses ONNX Runtime with validated two- or three-input signatures and `last_hidden_state`; it derives the hidden dimension, offers mean or first-token pooling and normalizes. |
| Example storage | `src/rag_optimizations.c`, `src/rag_optimizations_avx2.c` and `tools/` contain MySQL UDFs and examples separate from tokenization and inference. They were not exercised in Slice 001. |
| Build | `tokenizer-native/Cargo.toml` pins `tokenizers = 0.22.1`; `Cargo.lock` locks dependencies. `unix/Makefile.in` builds separate libraries. The tested Linux procedure is in `INSTALL.md`. |

## Interfaces and limits

`package require tokenizer 1.0.0` registers `tokenizer::load_vocab path`, `tokenizer::tokenize text ?-max-length count?` and `tokenizer::free`. Each interpreter maintains one loaded tokenizer; failed loads preserve the previous one. Truncation and padding are disabled absent an explicit limit. A complete `tokenizer.json` is required and there is no greedy fallback. Sources: `pkgIndex.tcl.in`, `generic/tokenizer_bridge.c`, `tokenizer-native/src/lib.rs`.

The ONNX binding exposes `embedding::init_raw model_path`, `embedding::compute handle token_ids ?-pooling mean|cls?`, and `embedding::free handle`. Each call to `init_raw` creates a new handle; it does not reinitialize an existing one. Each handle owns a session and is released by `free`, deletion of its Tcl command, or interpreter destruction. Foreign and freed handles are rejected. Compute validates nonempty nonnegative signed 64-bit IDs and the returned float32 tensor shape `[1, token_count, hidden_dimension]`. The default is mean pooling; CLS must be selected explicitly. The additive `embedding::compute_batch` supplies right-padding and length-derived attention masks with a caller-supplied padding ID; its bounds and current evidence are documented in `README.md` and `CHARACTERIZATION.md`. Slice 008 is formally accepted within its tested scope; broader model compatibility remains open. Source: `generic/tclembedding.c`.

Evidence and limits are in `CHARACTERIZATION.md`; authorized and open decisions in `DECISIONS.md`; measurement procedures in `BENCHMARKING.md`; outstanding work in `ROADMAP.md`. Tests identify external artifact hashes; the repository does not distribute those artifacts.
