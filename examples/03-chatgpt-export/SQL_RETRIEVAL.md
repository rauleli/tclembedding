# Direct semantic ingestion and retrieval with SQLite or MySQL

These independent Tcl examples consume fragment JSONL version 2, generate E5
embeddings and commit them directly to the selected SQL database. Neither
backend requires the other. The corpus identity is the SHA-256 of the complete
fragment file. Input, database, sidecars and logs may contain private data and
must remain outside the source tree.

## Contract

The characterized model is `intfloat/multilingual-e5-small`, revision
`614241f622f53c4eeff9890bdc4f31cfecc418b3`; its ONNX and tokenizer hashes are
checked against `embedding_common.tcl`. Document text is tokenized with
`passage: `, budget 128 including special tokens, without truncation. E5 uses
mean pooling, pad ID 1, 384 components and L2 normalization. Vectors are stored
as 1,536 bytes of IEEE float32 little-endian. Batch sizes from 1 through 32
respect the 4,096 padded-position limit. The characterized Linux backend and
ONNX Runtime hashes are checked; differently built libraries require separate
qualification. Query embeddings use `query: `.

Schema version 2 stores the corpus and model identity, a configuration identity,
expected count, committed progress, fragments, vector checksums and provenance.
Each batch and its checkpoint commit atomically. An interrupted run can repeat
the same command with unchanged input, model, libraries and batch size; it
verifies already committed records before continuing. A conflicting input or
configuration is rejected. Incomplete corpora are not queryable. Checksums
protect against accidental corruption, not deliberate tampering. SQLite uses
WAL with `synchronous=FULL`; its WAL and shared-memory files are sensitive too.
MySQL uses transactional InnoDB tables. Concurrent writers and power-loss
behavior beyond the database's guarantees have not been characterized.

Retrieval returns the existing 17-field Tcl list with score, sequence, text,
source identifiers and message provenance. Results are ordered by score
and then sequence. SQLite can use Tcl cosine or the explicit L-3 native
extension; MySQL uses its separately installed `cosine_similarity_v2` UDF.
Both searches are linear. The returned rows are validated; a query is not a
full audit of every stored record. Re-running ingestion explicitly checks all
stored records before accepting a completed corpus.

## SQLite

```sh
tclsh examples/03-chatgpt-export/sqlite_retrieval.tcl init /path/to/store.sqlite3
tclsh examples/03-chatgpt-export/sqlite_retrieval.tcl ingest /path/to/store.sqlite3 /path/to/fragments.jsonl /path/to/model.onnx /path/to/tokenizer.json 8
tclsh examples/03-chatgpt-export/sqlite_retrieval.tcl query /path/to/store.sqlite3 FRAGMENT_SHA256 /path/to/model.onnx /path/to/tokenizer.json 'synthetic question' 3
```

Initialization refuses an existing file. A failed initialization may leave a
partial file; inspect it and choose a new path. Values use SQLite bound
parameters. No automatic schema migration or concurrent-writer guarantee is
provided.

## MySQL

Requires `tdbc::mysql`, a separately supplied schema and the L-3 UDF. Use a
server with appropriate access controls; tests must use a disposable instance
with its own socket, data and plugin directories and TCP disabled. MySQL DDL is
not transactional; a partially initialized schema is rejected rather than
repaired automatically. The existing driver observation about `TX_ISOLATION`
and the isolated-server `component_reference_cache` warning remain documented
in the historical MySQL characterization.

```sh
tclsh examples/03-chatgpt-export/mysql_retrieval.tcl init /path/to/mysql.sock synthetic_db test_user
tclsh examples/03-chatgpt-export/mysql_retrieval.tcl ingest /path/to/mysql.sock synthetic_db test_user /path/to/fragments.jsonl /path/to/model.onnx /path/to/tokenizer.json 8
tclsh examples/03-chatgpt-export/mysql_retrieval.tcl query /path/to/mysql.sock synthetic_db test_user FRAGMENT_SHA256 /path/to/model.onnx /path/to/tokenizer.json 'synthetic question' 3
```

SQL values use TDBC bound parameters, with BLOBs bound as binary. Do not expose
credentials in command arguments or logs.

## Synthetic tests

Generate a synthetic fixture with `sql_fixture.tcl tokenizer.json output.jsonl
12`. Run `sqlite_retrieval_test.tcl fragments model tokenizer new-directory
sqlite-extension` or, against an isolated fresh MySQL schema only,
`mysql_retrieval_test.tcl socket database user fragments model tokenizer`.
These tests exercise transactional failure, a committed-batch interruption,
resumption, repeated ingestion and retrieval. They do not establish production
scale or concurrency guarantees.
