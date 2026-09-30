# TODO — tclembedding revalidation and hardening

This file records follow-up work identified during a fresh repository review on **2026-09-30**.

The current implementation already performs useful ONNX inference, but correctness and lifecycle assumptions must be revalidated before performance work, broader model claims or new RAG features are promoted into active development.

## Working method

Treat this file as a sequence of questions to resolve, not as an approved feature backlog.

- Work in **small, independently reviewable slices**.
- **Characterize current behavior first**, then decide the intended contract, then modify code.
- Correctness and parity come before optimization.
- Do not claim generic model support until the exact tokenizer, ONNX signature, pooling and normalization behavior have been demonstrated.
- A capability should not become public merely because ONNX Runtime, MySQL or another dependency can support it. Identify the Tcl/Iik' consumer and operational need first.
- Separate **contract** from **characterization**: decisions belong in `DECISIONS.md`; measured/model-specific evidence belongs in `CHARACTERIZATION.md`.
- Preserve exact evidence for claims: model/tokenizer checksums, ONNX Runtime version, host, compiler, tclembedding commit, inputs and measured outputs.
- Do not mix lifecycle repair, model-contract changes, tokenizer work and performance optimization in one slice unless the dependency is unavoidable.

## Recommended order of work

```text
baseline reproducible
        ↓
lifecycle / free / init-failure cleanup
        ↓
handle identity and validation
        ↓
ONNX model signature
        ↓
tokenizer parity
        ↓
pooling + normalization parity
        ↓
embedding parity
        ↓
performance characterization
        ↓
only then: broader RAG/features
```

## Binding correctness and revalidation — 2026-09-30

### Lifecycle, ownership and handle safety

- [ ] **Implement real `embedding::free` cleanup.** The current command returns `TCL_OK` without releasing `OrtSession`, `OrtSessionOptions`, `OrtEnv` or the allocated `EmbeddingState`.
- [ ] **Unify explicit and implicit cleanup.** Give embedding handle commands a delete callback so `embedding::free`, `rename $handle {}`, command deletion and interpreter destruction converge on one cleanup path.
- [ ] **Audit init failure cleanup.** `CHECK_STATUS_INIT` can return after partially creating ONNX Runtime resources. Convert initialization to a cleanup-aware path that releases everything already acquired before returning an error.
- [ ] **Harden handle validation.** Do not cast arbitrary command `objClientData` to `EmbeddingState` merely because `Tcl_GetCommandInfo` succeeds. Verify that the command is a tclembedding handle and that its client data/command identity are consistent.
- [ ] **Replace pointer-derived handle identity if retained as public state.** Current names use `embedding%p`; review this using the handle-identity lessons already characterized in tclwhisper.
- [ ] **Test stale, renamed, deleted, foreign-command and double-free cases.** All should fail deterministically without leaking or dereferencing unrelated data.

### Model contract and ONNX signature

- [ ] **Remove the hardcoded assumption that embedding dimension is always 384, or explicitly scope the API to that contract.** Today `state->embedding_dim = 384` conflicts with broader multi-model claims.
- [ ] **Inspect and validate model input/output signatures at initialization.** Confirm expected inputs (`input_ids`, `attention_mask`, optional `token_type_ids`), tensor element types, sequence shape and output tensor layout before inference.
- [ ] **Define supported model families from evidence.** Do not claim generic SentenceTransformer/ONNX compatibility until the exact model signatures and pooling requirements have been characterized.
- [ ] **Validate maximum sequence length against the model.** The documentation mentions 128 tokens, but the binding should either discover/enforce the real model limit or clearly state the fixed contract.

### Tokenizer correctness

- [ ] **Characterize the Tcl tokenizer against each model's reference tokenizer.** Compare token IDs exactly over a representative corpus, including multilingual text, punctuation, whitespace, accents, unknown characters and long subwords.
- [ ] **Do not assume greedy longest-match is equivalent to SentencePiece/BPE/Unigram.** Keep the current tokenizer only where equivalence is demonstrated; otherwise integrate or bind the model's actual tokenizer behavior.
- [ ] **Verify special-token handling per model.** BOS/EOS/UNK IDs, prefixes such as `query:` / `passage:`, and whitespace normalization must come from model/tokenizer metadata rather than generic assumptions where possible.
- [ ] **Test empty input and boundary cases.** Include empty strings, whitespace-only text, very long text and exact sequence-limit behavior.

### Numerical and inference correctness

- [ ] **Verify pooling semantics per model.** Mean pooling across all token positions may be wrong for models requiring attention-mask-weighted pooling or another sentence representation.
- [ ] **Verify L2 normalization requirements per model.** Confirm whether normalization belongs in the binding contract or should be optional/model-specific.
- [ ] **Check all Tcl numeric conversions.** `Tcl_GetLongFromObj` results currently need explicit error handling before values are used as token IDs.
- [ ] **Validate output tensor size before indexing.** Ensure the returned tensor actually contains `token_count * embedding_dim` values in the expected layout before reading it.
- [ ] **Review allocation and integer-size arithmetic.** Replace magic byte multipliers such as `token_count*8` with `sizeof(int64_t)`-based calculations and guard against overflow.

### Tests and evidence

- [ ] **Add lifecycle tests.** Cover repeated init/free, implicit command deletion, interpreter teardown, multiple simultaneous handles and failed initialization.
- [ ] **Add model-signature tests.** Exercise each model family only after it has a defined contract, with explicit expected dimensions and tensor signatures.
- [ ] **Add tokenizer parity tests.** Store reference token IDs generated by the authoritative tokenizer and compare the Tcl implementation exactly.
- [ ] **Add embedding parity tests.** Compare vectors or cosine similarity against a trusted reference implementation using the exact same model, tokenizer and input.
- [ ] **Run ASan/UBSan and/or Valgrind where practical.** Retain actual evidence for memory-safety claims.
- [ ] **Create reproducible characterization records.** Record model checksum, tokenizer checksum, ONNX Runtime version, host, compiler, tclembedding commit, exact inputs and measured outputs.

### Documentation reconciliation

- [ ] **Reconcile README claims with the actual implementation.** In particular review statements about automatic cleanup, verified memory management, test coverage, model generality, threading and production readiness.
- [ ] **Review historical dates and release claims.** Some documentation currently contains 2024 dates even though the repository history begins in December 2025; preserve true history and correct generated/stale dates.
- [ ] **Revisit `docs/SECURITY_REVIEW.md`.** Its categorical claims about memory safety, input validation and release readiness should be replaced or qualified using current evidence.
- [ ] **Establish `DECISIONS.md` and `CHARACTERIZATION.md` before behavioral changes that require new contract decisions or measurements.** Keep API contract, unresolved questions and model-specific evidence separate.

## Deferred ideas — not approved work

The items below are preserved from the earlier roadmap for historical continuity. They are **not an approved implementation plan**.

Promote one of these ideas into active work only when all of the following exist:

1. a concrete consumer or operational problem;
2. evidence that the current implementation is insufficient;
3. a bounded slice with explicit acceptance criteria;
4. a characterization plan that can verify the result.

### Performance and hardware ideas

- [ ] **Runtime CPU dispatching.** Evaluate runtime capability detection (SSE/AVX) only if measurements show compile-time targeting is materially limiting supported deployments.
- [ ] **Vector pre-normalization / dot-product optimization.** Reconsider only after the embedding contract establishes where L2 normalization belongs and stored-vector parity has been verified.
- [ ] **Quantization support (INT8).** Research only if memory or similarity-query throughput becomes a measured bottleneck.
- [ ] **Latency/scaling benchmarking.** Characterize `cosine_similarity` from small datasets through large datasets only with a reproducible corpus and database configuration; do not assume the Phenom II remains the only relevant target.

### RAG ideas

- [ ] **Re-ranking with cross-encoders.** Consider only if retrieval-quality evidence demonstrates that first-stage semantic search is insufficient for an identified workload.
- [ ] **Dynamic context management.** Consider only after retrieval scores are characterized well enough to define a defensible selection policy.
- [ ] **Broader model support.** Do not begin by "making dimensions dynamic." Add a new model family only after its tokenizer, ONNX signature, pooling, normalization and reference embeddings are characterized.

### Tooling and deployment ideas

- [ ] **Build automation.** Improve architecture detection and compiler flags only after the supported build matrix is defined; do not make `-march=native` an unconditional portability assumption.
- [ ] **Diagnostic scripts.** Add integrity tooling when its checks can be tied to a defined embedding/storage contract.
- [ ] **External API examples.** Expand documentation for non-Tcl consumers only if those consumers become part of the supported project scope.
- [ ] **Alternative vector indexes/backends.** Evaluate pgvector, MySQL pre-filtering or other indexing only when measured dataset size/query latency justifies the migration cost.

---

*Review additions recorded: 2026-09-30. Earlier roadmap ideas are retained above as deferred, unapproved work.*
