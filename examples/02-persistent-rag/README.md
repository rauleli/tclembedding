# Example 02: Persistent semantic retrieval with SQLite

This Tcl example stores and reuses embeddings for the synthetic support corpus from [Example 01](../01-in-memory-rag/README.md). It reopens a SQLite database on each invocation: ingestion embeds documents and commits them transactionally, while a later query embeds only the query and scans the stored vectors. SQLite is a persistent store here, not a specialized vector index. This is semantic retrieval, not a complete retrieval-augmented generation application.

## Dependencies

- Tcl 8.6 or later, with the [`sqlite3` Tcl binding](https://www.sqlite.org/tclsqlite.html). On Fedora, the binding is distributed in `sqlite-tcl`; use the distribution's installation procedure. The local test used Tcl 8.6.14 and SQLite Tcl/SQLite 3.45.2.
- Tcllib's `sha256` package (tested with 1.0.4) verifies artifact identity. It is used only for hashing; no Tcllib JSON package is used.
- The `tclembedding` and `tokenizer` packages, installed as described in [INSTALL.md](../../INSTALL.md). Set `TCLLIBPATH` to the installed package directory if needed.
- The characterized ONNX and full `tokenizer.json` for `intfloat/multilingual-e5-small` revision `614241f622f53c4eeff9890bdc4f31cfecc418b3`. The script verifies ONNX SHA-256 `ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665` and tokenizer SHA-256 `0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39` before each operation. Other artifacts are rejected, even if they have the same filename. No models are downloaded.

## Create, ingest, and query

Choose a database location outside the source tree. The example refuses a database path under the source tree; ignore rules for common SQLite filenames in this example directory provide an additional precaution. Keep all databases, sidecar files and derived vectors private. Use an appropriate private directory and restrictive permissions.

From the repository root, replace the following paths with local ones:

```sh
umask 077
export TCLLIBPATH="/path/to/installed/package/directory"
export E5_MODEL="/path/to/model.onnx"
export E5_TOKENIZER="/path/to/tokenizer.json"
export RETRIEVAL_DB="/path/to/private/retrieval.sqlite3"

tclsh examples/02-persistent-rag/persistent.tcl init \
  -db "$RETRIEVAL_DB" -model "$E5_MODEL" -tokenizer "$E5_TOKENIZER"
tclsh examples/02-persistent-rag/persistent.tcl ingest \
  -db "$RETRIEVAL_DB" -model "$E5_MODEL" -tokenizer "$E5_TOKENIZER"
tclsh examples/02-persistent-rag/persistent.tcl query \
  -db "$RETRIEVAL_DB" -model "$E5_MODEL" -tokenizer "$E5_TOKENIZER" \
  -query '¿Cómo recupero un documento que no guardé?' -top-k 3
```

These are separate processes: `init` creates a new file exclusively, `ingest` reopens it and persists document vectors, and `query` reopens it again and computes only the query vector. An existing database is never overwritten by `init`. A failed initialization may leave an empty or incomplete file; inspect it before removing it manually. Hashing the large ONNX file on every invocation can take noticeable time. Protect the artifacts from modification between hash verification and loading.

Document tokenization uses `passage: `; query tokenization uses `query: `. The identified E5 model uses mean pooling, L2-normalized embeddings and batch padding ID 1. Document token sequences are checked against the 512-token limit; batches are checked against 256 sequences and 4,096 padded positions. Inputs are not silently truncated. The corpus is deliberately short; there is no general chunking. For each existing document ID, ingestion replaces its title, content and embedding transactionally; documents not in the supplied corpus are retained. An error during insertion rolls back the transaction.

Each query loads stored vectors, validates them and computes cosine in Tcl. Results are sorted by descending score with document ID as a deterministic tie-breaker. `-top-k` defaults to 3 and accepts integers from 1 to 256. This linear scan is intended for a small teaching corpus; it is not an approximate-nearest-neighbor index and has not been benchmarked for large collections.

## Schema and vector format

Schema version 1 uses SQLite `user_version` and one `metadata` row recording the schema version, model ID and revision, model and tokenizer SHA-256 values, dimension 384 and vector format `float32-le`. Each `documents` row stores a stable ID, title, text, dimension and embedding BLOB. SQL uses bound parameters; it does not interpolate user document text into SQL commands.

Each component is serialized as IEEE 754 float32 in little-endian byte order using Tcl `binary format r*`, and reconstructed using `binary scan r*`. The code rejects incompatible metadata, dimensions, BLOB lengths, non-finite values and values outside the finite float32 range. Converting a double to float32 may round or underflow; exact preservation of arbitrary Tcl doubles is not promised. The synthetic test checks a `1e-7` absolute tolerance for its small representative values, not a universal error bound.

## Tests and limitations

Run the synthetic tests with Tcl and the SQLite binding; no model is required:

```sh
tclsh examples/02-persistent-rag/test.tcl
```

They exercise persistence across connections, float byte order and rounding, invalid vectors, metadata rejection, quoted text, updates, transaction rollback, ranking and a simulated query path that does not call document batch inference. They create disposable test databases under a new temporary directory. Run the three commands above to exercise real ONNX inference and persistence; tests do not download models or connect to a database service.

The example does not supply model files, an LLM, an index, encryption, concurrent-writer guarantees, migration or compatibility with arbitrary schemas, models or platforms. Restrict local database access and consider the privacy of operating-system backups and SQLite sidecars. The model hash and embedding format prevent accidental mixing of the characterized artifacts, but do not establish retrieval quality or protect against deliberate database tampering.
