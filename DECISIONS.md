# Technical decisions

This record separates authorized decisions from open contracts. Experimental evidence is in `CHARACTERIZATION.md`; code observations do not imply general support.

## D-011 — Curated source distribution

The distribution artifact is a source-only archive made from an explicit
inventory at a named commit. Tcl, TEA, Cargo crates, ONNX Runtime and models are
external. No precompiled binary or third-party runtime is included. The Git
repository retains the historical documentation, while the archive contains a
short installation guide and the files needed for the selected build and tests.
Publication is a separate decision.

## D-010 — Explicit ONNX Runtime provider selection

CPU remains the default. CUDA is opt-in through the public ONNX Runtime API;
provider registration or session initialization errors are returned to Tcl.
Optional session profiling is finalized on handle destruction. Different nodes
may use different providers, and current integrated CUDA hardware validation
remains pending.

## D-009 — Direct SQL persistence for example ingestion

The SQL examples generate document embeddings and persist them directly in the
selected database. SQLite and MySQL are independent alternatives. Schema version
2 stores committed progress, corpus and configuration identity, vectors and
provenance; incomplete corpora are not queryable. The former intermediate
format was experimental and is not part of the supported interface. Historical
results remain documented. Existing schema version 1 databases require a new
ingestion; automatic migration is not provided.

## D-008 — Structured generation reference and optional thinking

**Status: proposed for review; qualification remains conditional on the
identified tests.** Ollama 0.40.15 is the current reference for structured
generation qualification. Ollama 0.15.6 observations are historical evidence,
not a current qualification target. The reference version alone does not
establish support for every model or semantic correctness.

An explicit `off` mode may send the top-level `think: false` field. The default
leaves the field absent, preserving existing requests. The mode is opt-in: it
does not infer capabilities, change models, retry, alter sampling or relax the
local validator. Its compatibility with other models and versions is unverified.
The two Qwen3 observations under this mode form a new protocol revision, not
a replacement for prior default-thinking observations. See `CHARACTERIZATION.md`.

## D-001 — Initial tokenization backend

**Status: authorized, implemented and accepted in Slice 001.** Rust Tokenizers 0.22.1 provides the initial backend through a C ABI; Tcl remains the user interface and C provides the bridge. Python was an experimental reference and is not a production dependency. Building the backend requires Rust and Cargo. Sources: `tokenizer-native/Cargo.toml`, `tokenizer-native/Cargo.lock`, `tokenizer-native/hf_tokenizer.h`, `generic/tokenizer_bridge.c`.

The previous greedy search differed from Unigram, while the Rust/C ABI path matched 58 experimental cases. This adds a native build and distribution dependency without claiming universal support or excluding future backends. See `CHARACTERIZATION.md`.

## D-002 — Configuration and legacy compatibility

**Status: authorized, implemented and accepted in Slice 001.** This backend loads the complete `tokenizer.json`, including tokenization and postprocessing rules. It does not apply model-specific ID offsets or silently fall back to the previous algorithm. Compatibility with the previous API or vocabulary-only files is not required.

The current interface retains `tokenizer::load_vocab` and `tokenizer::tokenize` and adds `tokenizer::free`. Truncation is optional; no universal limit is imposed. The retained names do not imply support for vocabulary-only files. Sources: `README.md`, `generic/tokenizer_bridge.c`, `tokenizer-native/src/lib.rs`.

The accepted Slice 006 implementation serializes encoding per tokenizer instance. If an encoding panics, it attempts to restore the previous truncation configuration and marks that instance unusable; later calls return a controlled error. A poisoned mutex also returns an error without using the state. The instance can be released, and a successful `tokenizer::load_vocab` creates a replacement; a failed load retains the existing state. This does not authorize freeing an active handle concurrently or establish recovery from process aborts or invalid pointers. Sources: `tokenizer-native/src/lib.rs`, `generic/tokenizer_bridge.c`, `CHARACTERIZATION.md`.

## D-003 — ONNX handle ownership

**Status: authorized, implemented and formally accepted as part of Slice 002, with the outstanding issues recorded in `ROADMAP.md`.** Each successful `embedding::init_raw` creates a new interpreter-owned command and independent binding state; it does not reinitialize an existing handle. `embedding::free` deletes that command; its delete callback releases the session, options, environment reference and state. Deleting the command with `rename` or destroying the interpreter invokes the same callback. A renamed command remains the same handle. Unknown, foreign or freed handles return errors, as does repeated free. Partial initialization uses the same native cleanup.

This corrects a no-op `free` and unowned lifecycle without changing inference, pooling, normalization or the tokenizer. The change does not decide support for other models, output shapes or concurrency. Sources: `generic/tclembedding.c`, `tests/embedding_lifecycle_test.tcl`.

## D-004 — Native input and output safety

**Status: authorized, implemented and formally accepted in Slice 003-B1, with the outstanding issues recorded in `ROADMAP.md`.** `embedding::compute` rejects empty ID lists, non-integers, negative values and values outside signed 64-bit range. At the time it validated allocation arithmetic and required a float32 output tensor with shape `[1, token_count, 384]` and the expected element count before reading it. Zero or non-finite mean norms and non-finite means return errors. The existing operation order, normalization threshold and output for valid finite nonzero inputs remain unchanged. That change did not impose a vocabulary-size limit or expand supported models; see D-006 for the later dimension change. Slice 003 was subsequently accepted within the scope of the documented evidence. Sources: `generic/tclembedding.c`, `tests/embedding_safety_test.tcl`.

## D-005 — Embedding normalization and truncation contract

**Status: authorized and accepted with Slice 003.** `embedding::compute` continues to return L2-normalized embeddings. No public option to disable L2 will be added at present. The Tcl tokenizer does not truncate by default; to align with the 128-token Sentence Transformers configuration for `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` at revision `e8f8c211226b894fcb81acc59f3b34ba3efd5f42`, the consumer must explicitly request `-max-length 128`.

The model's default `SentenceTransformer.encode()` output is not L2-normalized; it must be normalized separately before a like-for-like comparison with the current Tcl output. The configured limit comes from the model's `sentence_bert_config.json`, not a universal tokenizer limit. Different truncation or normalization choices can change vectors. This acceptance applies only to the model, revision, configurations, cases and environments actually evaluated; it does not establish universal compatibility or approve an optional unnormalized output. Sources: `CHARACTERIZATION.md`, `README.md`, `generic/tclembedding.c`.

## D-006 — Explicit pooling and validated encoder signatures

**Status: implemented and formally accepted within the tested scope of Slice 007.** `embedding::compute handle token_ids ?-pooling mean|cls?` preserves mean pooling by default. The caller explicitly selects first-token pooling when required; no model-name heuristics, automatic prefixes or automatic truncation are introduced. L2 normalization remains unchanged. Session initialization validates the required rank-2 int64 `input_ids` and `attention_mask`, permits `token_type_ids` only when declared, and rejects additional or incompatible inputs. The actual float32 output must have shape `[1, token_count, hidden_dimension]`, with safe allocation and element-count checks. A dynamic dimension does not establish compatibility with arbitrary graphs. See `CHARACTERIZATION.md` for model-specific evidence and the limits of the PyTorch comparisons.

## D-007 — Explicit batch inputs and attention masks

**Status: implemented and formally accepted within the tested scope of Slice 008.** `embedding::compute_batch handle token_id_lists -pad-id integer ?-pooling mean|cls?` is additive. The caller must choose the padding ID; the binding does not infer it from the tokenizer or ONNX. Right-padding creates a length-based attention mask and mean pooling excludes masked positions. CLS and L2 apply per sequence. The existing single-sequence command is unchanged. Batch and output bounds are revisable binding policies detailed in `README.md`; graphs with unknown declared hidden dimensions are rejected by the batch API before inference. The single-sequence API validates the effective output dimension and does not have that static-metadata restriction. The tested model-specific padding IDs and their limitations are recorded in `CHARACTERIZATION.md`. This does not claim support for arbitrary models, padding policies or general concurrency.

## Open decisions

| Question | Status |
| --- | --- |
| Supported model families and revisions; numerical references and tolerances | Pending evidence and decision. |
| Additional ONNX signatures, pooling variants and normalization options beyond D-006 | Pending; L2 and truncation remain as described in D-005. |
| General compatibility, cross-platform distribution and model-specific limits | Pending. |
| Broader tokenizer concurrency and concurrent handle destruction | Pending evidence; Slice 006 removed per-call truncation cloning within its accepted scope. |
| Alternative backends or formats for future models | Pending; future models are not assumed to use `tokenizer.json`. |

Retrieval and consumer integration require separate contracts and authorization.
