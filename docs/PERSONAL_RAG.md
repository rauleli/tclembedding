# Personal RAG — reference example

## Purpose

A reusable example of retrieval-augmented search over a user's own exported AI conversations and selected documents. The example demonstrates how to generate embeddings with `tclembedding`, store and retrieve them, and return relevant source passages with verifiable context.

The example is intended to run on a user's machine with their own data. The repository contains demonstration code and a small synthetic test corpus, not user conversations or generated personal databases.

## Database backends

| Backend | Typical environment | Integration |
| --- | --- | --- |
| MySQL | Shared datasets, multiple users or application processes | Existing MySQL integration, `mysqltcl`, and C `cosine_similarity()` UDF |
| SQLite | Embedded or single-host applications with minimal service overhead | Additional storage and similarity implementation to be provided |

Embedding inference is independent of SQL storage. A common retrieval interface can expose equivalent operations while allowing backend-specific connection, transaction, indexing, and backup behavior.

The existing MySQL examples are found in `tools/ingest.tcl`, `tools/search.tcl`, `tools/schema.sql`, and `docs/MYSQL_INTEGRATION.md`. They do not currently provide a complete conversation-import example. SQLite retrieval support is not currently supplied by these tools.

## Functional coverage

The reference application illustrates:

- Importing a locally supplied conversation export and text documents.
- Preserving available source IDs, message roles, timestamps, conversation titles, ordering, and parent/branch links.
- Segmenting long content into searchable passages while retaining links to the original messages or documents.
- Generating embeddings with a specified model and tokenizer, with their versions recorded.
- Storing passages, metadata, and binary vector values in a selected SQL backend.
- Searching by semantic similarity, with optional exact-text and metadata filters.
- Expanding retrieved passages to neighboring messages and presenting source references.
- Reporting missing evidence rather than inventing a conversation origin, decision, or chronology.

Source material is authoritative. Embeddings, indexes, and summaries are derived artifacts that can be regenerated. Metadata not present in the source must remain explicitly unknown.

The example is useful without a language model that generates answers; optional answer synthesis is separate from the retrieval and evidence functions.

## Example layout

An illustrative directory within the repository:

```text
examples/personal_rag/
├── README.md
├── config.example.tcl
├── import.tcl
├── search.tcl
├── benchmark.tcl
├── fixtures/
│   ├── sample_conversations.json
│   └── expected_results.json
└── sql/
    ├── mysql.sql
    └── sqlite.sql
```

Names and layout describe an example, not files that already exist.

## SQL comparison / benchmark

A repeatable optional benchmark compares the MySQL and SQLite backends using **identical input data**:

- Same documents, passages, metadata, identifiers, and precomputed embedding bytes.
- Same query vectors, filtering rules, result limits, and expected source matches.
- Separate measurements for data import, exact-text lookup, filtered/unfiltered vector similarity, and retrieval of neighboring context.
- Latency distributions (including p50/p95), CPU time, memory consumption, database size, read concurrency, and write contention.
- Recorded versions, schema, corpus size, machine specifications, cache conditions, and query plans.

ONNX embedding generation and optional LLM response time are measured separately from SQL retrieval. Backend results are checked for semantic equivalence, not identical physical representations.

The existing MySQL cosine-similarity UDF evaluates candidate rows; it is **not** an approximate-nearest-neighbor (ANN) index. A simple SQLite scalar function would likewise not provide an ANN index automatically. Corpus size, candidate filtering, and query plans matter to the comparison.

## Synthetic validation corpus

A small distributable fixture can cover:

- Recovering an earlier interpretation instead of supplying only generic background information.
- Identifying a conversation's actual opening topic despite later digressions.
- Distinguishing user statements from assistant suggestions and later revisions.
- Following chronological and branch relationships when recorded.
- Correctly reporting absent evidence or unavailable metadata.

Evaluation of retrieved source passages is distinct from evaluation of any generated answer.

## Relationship to tclembedding

This example demonstrates existing embedding functionality and a possible additional SQL storage adapter; it does not change the ONNX binding's purpose or imply support for unverified models.

The repository's existing correctness requirements for tokenization, ONNX signatures, pooling, numerical parity, and lifecycle behavior apply independently of the database backend.
