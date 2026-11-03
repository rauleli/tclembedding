# Technical baseline

Slices 001, 002, 003 and 004 were formally accepted with documented outstanding issues; acceptance did not imply a commit, publication or authorization to begin another slice. Slice 003 acceptance is limited to the model, revision, environments, configurations and cases actually evaluated. Slice 004 acceptance is limited to the evaluated Linux x86-64 build, installation and test environment with identified external dependencies; it does not establish a complete build from current `HEAD` alone, self-contained distribution, binary reproducibility or other-platform compatibility. The behavior below is based on the present code and tests and does not imply general model compatibility.

## Components

| Component | Responsibility and source |
| --- | --- |
| Tokenization | `generic/tokenizer_bridge.c` connects Tcl with `tokenizer-native/`, using Rust Tokenizers 0.22.1 and a complete `tokenizer.json` for normalization, model, added tokens and postprocessing. |
| Inference | `generic/tclembedding.c` uses ONNX Runtime with three inputs and `last_hidden_state`; it currently fixes 384 dimensions, averages positions and normalizes. |
| Example storage | `src/rag_optimizations.c`, `src/rag_optimizations_avx2.c` and `tools/` contain MySQL UDFs and examples separate from tokenization and inference. They were not exercised in Slice 001. |
| Build | `tokenizer-native/Cargo.toml` pins `tokenizers = 0.22.1`; `Cargo.lock` locks dependencies. `unix/Makefile.in` builds separate libraries. The tested Linux procedure is in `INSTALL.md`. |

## Interfaces and limits

`package require tokenizer 1.0.0` registers `tokenizer::load_vocab path`, `tokenizer::tokenize text ?-max-length count?` and `tokenizer::free`. Each interpreter maintains one loaded tokenizer; failed loads preserve the previous one. Truncation and padding are disabled absent an explicit limit. A complete `tokenizer.json` is required and there is no greedy fallback. Sources: `pkgIndex.tcl.in`, `generic/tokenizer_bridge.c`, `tokenizer-native/src/lib.rs`.

The ONNX binding exposes `embedding::init_raw model_path`, `embedding::compute handle token_ids`, and `embedding::free handle`. Each call to `init_raw` creates a new handle; it does not reinitialize an existing one. Each handle owns a session and is released by `free`, deletion of its Tcl command, or interpreter destruction. Foreign and freed handles are rejected. Compute validates nonempty nonnegative signed 64-bit IDs and the returned float32 tensor shape `[1, token_count, 384]`; broader model-signature and compatibility validation remain open. Source: `generic/tclembedding.c`.

Evidence and limits are in `CHARACTERIZATION.md`; authorized and open decisions in `DECISIONS.md`; measurement procedures in `BENCHMARKING.md`; outstanding work in `ROADMAP.md`. Tests identify external artifact hashes; the repository does not distribute those artifacts.
