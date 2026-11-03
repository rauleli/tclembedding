# Technical decisions

This record separates authorized decisions from open contracts. Experimental evidence is in `CHARACTERIZATION.md`; code observations do not imply general support.

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

**Status: authorized, implemented and formally accepted in Slice 003-B1, with the outstanding issues recorded in `ROADMAP.md`.** `embedding::compute` rejects empty ID lists, non-integers, negative values and values outside signed 64-bit range. It validates allocation arithmetic and requires a float32 output tensor with shape `[1, token_count, 384]` and the expected element count before reading it. Zero or non-finite mean norms and non-finite means return errors. The existing operation order, normalization threshold and output for valid finite nonzero inputs remain unchanged. The check does not impose a vocabulary-size limit or expand supported models. Slice 003 was subsequently accepted within the scope of the documented evidence. Sources: `generic/tclembedding.c`, `tests/embedding_safety_test.tcl`.

## D-005 — Embedding normalization and truncation contract

**Status: authorized and accepted with Slice 003.** `embedding::compute` continues to return L2-normalized embeddings. No public option to disable L2 will be added at present. The Tcl tokenizer does not truncate by default; to align with the 128-token Sentence Transformers configuration for `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` at revision `e8f8c211226b894fcb81acc59f3b34ba3efd5f42`, the consumer must explicitly request `-max-length 128`.

The model's default `SentenceTransformer.encode()` output is not L2-normalized; it must be normalized separately before a like-for-like comparison with the current Tcl output. The configured limit comes from the model's `sentence_bert_config.json`, not a universal tokenizer limit. Different truncation or normalization choices can change vectors. This acceptance applies only to the model, revision, configurations, cases and environments actually evaluated; it does not establish universal compatibility or approve an optional unnormalized output. Sources: `CHARACTERIZATION.md`, `README.md`, `generic/tclembedding.c`.

## Open decisions

| Question | Status |
| --- | --- |
| Supported model families and revisions; numerical references and tolerances | Pending evidence and decision. |
| Additional ONNX inference contracts, pooling variants, dimensions and normalization options | Pending; the current L2 and truncation behavior is accepted as described in D-005. |
| General compatibility, cross-platform distribution and model-specific limits | Pending. |
| Broader tokenizer concurrency and concurrent handle destruction | Pending evidence; Slice 006 removed per-call truncation cloning within its accepted scope. |
| Alternative backends or formats for future models | Pending; future models are not assumed to use `tokenizer.json`. |

Retrieval and consumer integration require separate contracts and authorization.
