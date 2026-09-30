# TODO - RAG & MySQL Optimizations Project

This document details pending improvements, hardware optimizations, and planned new features for the information retrieval (RAG) system.

## Performance Optimizations (Hardware & C)

- [ ] **Runtime CPU Dispatching:** Evolve the C code to detect capabilities (SSE/AVX) at runtime instead of relying solely on compile-time flags.
- [ ] **Vector Pre-normalization:** Modify the Tcl ingestion flow to normalize vectors to magnitude 1.0. This will allow using a simple *Dot Product* in MySQL, skipping square root calculations and divisions.
- [ ] **Quantization Support (INT8):** Research and implement similarity calculation on quantized vectors to reduce memory footprint in MySQL and increase speed on older CPUs.
- [ ] **Latency Benchmarking:** Create a script to measure `cosine_similarity` response time scaling from 10k to 1M records on the Phenom II.

## RAG Engine Improvements

- [ ] **Re-ranking with Cross-Encoders:** Implement a second filtering stage after semantic search in MySQL to improve response accuracy.
- [ ] **Dynamic Context Management:** Optimize the number of chunks sent to the LLM based on the similarity score obtained from the UDF.
- [ ] **Multi-Model Support:** Allow configuration of different embedding models (e.g., BGE or larger E5 versions) by dynamically adjusting the UDF to new dimensions.

## Tools and Maintenance

- [ ] **Build Automation:** Create a robust `Makefile` that detects the system architecture and applies GCC flags (`-march=native`, `-lm`, etc.) automatically.
- [ ] **Diagnostic Scripts:** Develop a Tcl tool that verifies the integrity of embeddings stored in the database.
- [ ] **API Documentation:** Expand the `.md` files with clear examples of how to consume the UDF from languages other than Tcl.

## Scalability

- [ ] **Migration to Vector Indexes:** If the table exceeds one million records, evaluate integration of tools like `pgvector` (in case of migrating to Postgres) or the use of spatial indexes in MySQL for pre-filtering.

---
*Last updated: December 2025 - SSE4A Hardware Optimization completed.*

## Binding correctness and revalidation — 2026-09-30

These items were identified during a fresh review of the current repository state. They should be treated as revalidation work, not as an assumption that the existing implementation is unusable.

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
- [ ] **Add model-signature tests.** Exercise at least one supported MiniLM-family model and one E5-family model, with explicit expected dimensions and tensor signatures.
- [ ] **Add tokenizer parity tests.** Store reference token IDs generated by the authoritative tokenizer and compare the Tcl implementation exactly.
- [ ] **Add embedding parity tests.** Compare vectors or cosine similarity against a trusted reference implementation using the exact same model, tokenizer and input.
- [ ] **Run ASan/UBSan and/or Valgrind where practical.** Retain actual evidence for memory-safety claims.
- [ ] **Create reproducible characterization records.** Record model checksum, tokenizer checksum, ONNX Runtime version, host, compiler, tclembedding commit, exact inputs and measured outputs.

### Documentation reconciliation

- [ ] **Reconcile README claims with the actual implementation.** In particular review statements about automatic cleanup, verified memory management, test coverage, model generality, threading and production readiness.
- [ ] **Review historical dates and release claims.** Some documentation currently contains 2024 dates even though the repository history begins in December 2025; preserve true history and correct generated/stale dates.
- [ ] **Revisit `docs/SECURITY_REVIEW.md`.** Its categorical claims about memory safety, input validation and release readiness should be replaced or qualified using current evidence.
- [ ] **Separate contract from characterization.** Consider adding `DECISIONS.md` / `CHARACTERIZATION.md` or equivalent so model-specific observations are not mistaken for universal API guarantees.

---

*Review additions recorded: 2026-09-30.*

