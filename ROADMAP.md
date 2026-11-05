# Roadmap

This map identifies dependencies and possible work; it does not authorize new slices or commit to a final order.

## Progressive consumer examples

These examples consume the public library; they are separate from the native binding slices and do not themselves authorize changes to the binding.

1. **In-memory semantic retrieval:** a small synthetic corpus, embeddings and ranked retrieval. Formally accepted within the documented model, inputs and tested environment.
2. **Persistent semantic retrieval:** extend retrieval with SQLite storage. Formally accepted within the documented model, inputs and tested environment.
3. **ChatGPT conversation export:** prepare conversation text and provenance using `rl_json`. The existing extraction tool is separate from retrieval and does not implement a complete RAG pipeline.
4. **End-to-end RAG:** combine these capabilities with generation, initially using Ollama. The first three examples do not depend on a generative LLM.

An earlier isolated local HTTP chat experiment exercised response parsing, error handling and a simulated transport. It did not validate generation against a real LLM and is not part of Example 01. Future integration requires its own design and verification.

## Slice 001 — native tokenization

**Formally accepted with recognized outstanding issues.** The Rust/C/Tcl backend and tests are described in `BASELINE.md` and `CHARACTERIZATION.md`. Acceptance does not constitute a commit, publication or authorization to start another slice.

## Slice 002 — ONNX lifecycle characterization and correction

**Formally accepted, including characterization 002-A and correction 002-B, with recognized outstanding issues.** The binding now releases handle-owned resources on explicit free, Tcl command deletion or interpreter teardown, and cleans partial initialization. See `DECISIONS.md` and `CHARACTERIZATION.md` for contract, test evidence and limits. Acceptance does not authorize publication or automatically start Slice 003.

## Slice 003 — numerical embedding correctness

**Formally accepted**, including 003-A, native safety work 003-B1 and the 003-B2 primary-reference comparison, within the model, revision, environments, configurations and cases actually evaluated. The accepted L2 and truncation contract is recorded in `DECISIONS.md`; evidence and remaining limits are in `CHARACTERIZATION.md`. Acceptance does not authorize a subsequent slice or publication.

## Slice 004 — build, installation and test infrastructure

**Formally accepted**, including 004-A and 004-B1 through 004-B3, for the evaluated Linux x86-64 environment and the identified, previously available external dependencies. The evidence covers TEA configuration, prefix and `DESTDIR` installation, a working-tree source snapshot build and the root test entry point; see `CHARACTERIZATION.md` and `INSTALL.md`. Acceptance does not establish bit reproducibility, a complete build from the then-current `HEAD`, self-contained distribution or compatibility with other platforms. At the time, it did not authorize publication or subsequent work.

## Slice 005 — source integrity, Git baseline and development publication

**Formally accepted**, including the source audit, local Git baseline and development publication. Commit `338dacbd3a68a19374e7ab2775ddf87055b15d4b` was rebuilt and tested from a Git archive with identified external dependencies; merge `b610fec` reconciled the histories without changing that baseline tree. Development publication is recorded; see `CHARACTERIZATION.md`. Acceptance is not a stable release and does not establish self-contained distribution, binary reproducibility, general model compatibility, concurrency or portability. It does not authorize subsequent work.

## Slice 006 — tokenizer truncation performance

**Formally accepted**, including characterization 006-A and correction 006-B, within the evaluated Linux x86-64 environment, tokenizer and cases. Per-instance synchronization and temporary native truncation replace per-call cloning; the accepted Tcl/C contracts and characterized outputs remain unchanged. See `CHARACTERIZATION.md` and `BENCHMARKING.md` for measurements, tests and limits. Acceptance does not establish universal performance, absence of leaks, safe concurrent handle destruction or compatibility with other models or platforms. It does not authorize subsequent work.

## Further work to evaluate

For stable distribution and future publication, TEA, crate sources and ONNX Runtime acquisition and distribution need decisions; binary paths and debugging-symbol policy need review; and packaging, publication requirements and other distributions, macOS and ARM64 need separate characterization. These remain open. Existing concurrency, model compatibility and memory questions also remain open. See `INSTALL.md` and `CHARACTERIZATION.md`.

| Topic | Evidence or decision needed |
| --- | --- |
| ONNX lifecycle coverage | A bounded successful-model Valgrind run was completed in 003-B1, fulfilling the requested successful-session instrumentation within its tested scope. Characterize individual initialization failures and concurrent interpreters. |
| Truncation cloning | Slice 006 is formally accepted within the tested scope; broader model and concurrency characterization remains open. See `tokenizer-native/src/lib.rs` and `CHARACTERIZATION.md`. |
| Embedding parity | The identified MiniLM PyTorch reference was compared under the conditions in `CHARACTERIZATION.md`. Extend evidence to other inputs, masks, model revisions and runtimes, and decide any compatibility criteria separately; the current observations do not establish general parity. |
| Embedding contract | The current L2 and default truncation behavior are accepted in D-005; padding, other normalization options and future contracts require separate evidence and decisions. |
| TEA build and installation | TEA 3.13 must be supplied externally; configured installation has been tested on one Linux environment. Resolve distribution and evaluate additional platforms; see `INSTALL.md`. |
| Memory and concurrency | A bounded 20-inference Valgrind run was completed; extend scenarios across interpreters and threads and investigate possibly lost memory without premature attribution. |
| Native validation coverage | Exercise null or non-tensor outputs, inconsistent element counts, unobserved size overflows and individual failure paths where reproducible; evaluate vocabulary validation without assuming model limits. |
| Additional models | Select each model only after identifying tokenizer, signature, limit, pooling and parity evidence. The current backend does not guarantee universal support. |

Autonomous retrieval, its consumers and any later integration need their own contracts and authorizations. No additional storage engine or application is decided here.

### Slice 007 — four-model encoder characterization

007-A characterized four identified ONNX models. 007-B implements validated two-/three-input encoder signatures, dynamic hidden dimensions and explicit mean/CLS pooling; the implementation is **formally accepted** within the identified models, revisions, configurations, cases and environments. Independent PyTorch/Sentence Transformers vectors were subsequently compared directly with the binding for the identified BGE, E5 and MPNet cases; see `CHARACTERIZATION.md` for scope and limits. General padding, batching, concurrency, portability and compatibility with untested models remain outside the demonstrated scope.


### Slice 008 — batch inference and attention masking

The additive batch API and its bounded right-padding and pooling behavior are formally accepted within the identified models, revisions, inputs and environments. Evidence and resource limits are in `CHARACTERIZATION.md` and `README.md`. General arbitrary masks, other input signatures, fixed batch sizes above one, dynamic hidden-size metadata, broader memory failure injection, concurrency and portability remain outside the tested scope.
