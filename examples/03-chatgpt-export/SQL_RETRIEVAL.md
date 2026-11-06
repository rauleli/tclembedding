# Synthetic semantic retrieval with SQLite or MySQL

These independent Tcl examples import existing fragment JSONL v2 and complete
L2E1 files. They do not generate document embeddings, implement an LLM, or
require both database engines. Use synthetic data for tests, and keep databases,
JSONL, vectors, logs and credentials outside the source tree. Retrieval prints
fragment text and provenance: treat its output as sensitive.

Both paths verify the entire L2E1 header, model identity, record checksums,
source hash and per-line identity before ingestion. They store the exact 1,536
float32 little-endian bytes, without decoding or re-embedding. Corpus identity
is the SHA-256 of the complete fragment JSONL. A second import verifies the
entire existing corpus and exact vector bytes; a changed L2E1 for the same input
is rejected, even when numerically close. A changed JSONL is a separate corpus.
Each import uses one transaction: process termination or failure rolls it back;
retry the same command after resolving the error. The code does not provide
incremental commits, concurrent import guarantees, migrations or authentication
against malicious modification. SHA-256 identifies accidental changes; it is
not a signature. Keep source files immutable during import.

The E5 query uses the verified model/tokenizer hashes and revision from
[EMBEDDING_PIPELINE.md](EMBEDDING_PIPELINE.md), `query: `, mean pooling and L2.
The query vector is rounded to float32 for both engines. Results are Tcl lists:
score, zero-based input sequence, text, source ID, original-source hash, source,
conversation ID, node ID, message ID, role, original position, timestamp as a
JSON scalar, part, fragment index, start, end, and model ID. Equal scores are
ordered by sequence. Search is a full linear scan; no performance or retrieval
quality guarantee is implied. The implementations retain query results in
memory and have only been exercised on a small synthetic corpus; they are not
validated for the full exported corpus or concurrent writers.

## Integrity by operation

- Import validates the supplied JSONL and L2E1 file hashes, model and tokenizer
  identity, record count and sequence, each record checksum, per-line identity,
  float32 vector length and numeric validity. It stores the exact vector bytes.
- Corpus opening checks the schema version and expected column signatures;
  MySQL additionally checks that the two data tables use InnoDB. This is not an
  exhaustive audit of all database constraints. A query
  checks model metadata, the stored count and the minimum and maximum sequence;
  it does not reopen the original JSONL or L2E1 file or rehash the whole corpus.
- Ranking necessarily reads vectors for the linear search. SQLite checks each
  vector's length and numerical validity while scoring; MySQL uses its UDF and
  rejects NULL scores among the selected rows. Only returned top-k rows have
  their stored text or provenance-line and vector checksums verified. SQLite does not independently
  authenticate its normalized provenance columns during query. Corruption in an
  unreturned row may affect ranking without being detected. A concurrent writer
  could change rows between operations; concurrent queries and writes are not
  characterized.
- To check every stored row against both original files, re-run `ingest` with the
  identical JSONL and L2E1 files. This verifies identity, every vector and all
  saved provenance without changing a matching corpus. It is an explicit full
  verification, not an automatic extra checksum scan on each query.

## SQLite

Requires Tcl 8.6, `sqlite3`, `rl_json`, Tcllib `sha256`, and installed
`tclembedding`/`tokenizer` for queries. Schema `user_version=1` has a `corpora`
row with model/configuration and input identity; `messages` normalizes source
and message-part provenance using a compound identity, not a globally unique
message ID; `fragments` stores ranges, text, hashes and vector bytes. Foreign
keys and unique corpus/sequence and message/fragment keys are enforced.
Queries calculate cosine in Tcl and validate checksums for returned rows.

```sh
# Use a private temporary directory and an appropriate Tcl launcher.
tclsh examples/03-chatgpt-export/sqlite_retrieval.tcl init /path/to/store.sqlite3
tclsh examples/03-chatgpt-export/sqlite_retrieval.tcl ingest /path/to/store.sqlite3 /path/to/fragments.jsonl /path/to/embeddings.l2e
tclsh examples/03-chatgpt-export/sqlite_retrieval.tcl query /path/to/store.sqlite3 FRAGMENT_JSONL_SHA256 /path/to/model.onnx /path/to/tokenizer.json 'synthetic question' 3

tclsh examples/03-chatgpt-export/sqlite_retrieval_test.tcl /path/to/synthetic-fragments.jsonl /path/to/synthetic-embeddings.l2e /path/to/new-test-directory
```

`init` refuses an existing file and requests mode 0600. It can leave an empty
or partial file after an initialization failure; a later `init` refuses to
overwrite it, and opening an incomplete or incompatible schema fails. Inspect
the file and select a new path; no automatic repair or deletion is attempted.
SQLite files and sidecars must remain private. All variable SQL values use the
Tcl SQLite binding's prepared parameters.

## MySQL

Requires `tdbc::mysql`, MySQL-compatible client libraries, a user-provided
schema, and a separately installed `cosine_similarity_v2` UDF compatible with
[MYSQL_UDF.md](../../docs/MYSQL_UDF.md). The example checks identical and
zero-vector UDF behavior before querying. Schema version 1 consists of
`l2_schema`, `l2_corpora` and `l2_fragments`; each fragment retains its exact
JSONL provenance line as a BLOB once, plus its exact vector and checksums.
Foreign keys and a corpus/sequence primary key apply. MySQL evaluates cosine
using the UDF and results are sorted by score and sequence. Text is decoded as
UTF-8 after retrieval. SQL values use TDBC prepared statements, with binary
parameters explicitly marked `varbinary`. MySQL DDL is not transactional:
initialize only a new disposable schema; a failed initialization may leave
partial tables. Initialization refuses to proceed if any L2 table already
exists. Opening an incomplete or incompatible schema fails; inspect it and
choose a new empty schema. No automatic repair or deletion is attempted.

```sh
# The socket and schema must be explicitly supplied. Set the optional password
# in the environment only when needed; do not put it into command arguments.
tclsh examples/03-chatgpt-export/mysql_retrieval.tcl init /path/to/mysql.sock synthetic_db test_user
tclsh examples/03-chatgpt-export/mysql_retrieval.tcl ingest /path/to/mysql.sock synthetic_db test_user /path/to/fragments.jsonl /path/to/embeddings.l2e
tclsh examples/03-chatgpt-export/mysql_retrieval.tcl query /path/to/mysql.sock synthetic_db test_user FRAGMENT_JSONL_SHA256 /path/to/model.onnx /path/to/tokenizer.json 'synthetic question' 3
```

For isolated testing, use a fresh server with its own data, socket and plugin
directories and TCP disabled, following the isolated procedure in
[MYSQL_UDF.md](../../docs/MYSQL_UDF.md). Create a fresh synthetic database, then
run the following; the runner requires a laboratory under `/tmp`, verifies that
the data and plugin directories are siblings of the socket and that networking
is disabled:

```sh
tclsh examples/03-chatgpt-export/mysql_retrieval_test.tcl /path/to/isolated/mysql.sock fresh_synthetic_db test_user /path/to/synthetic-fragments.jsonl /path/to/synthetic-embeddings.l2e
```

MySQL 8.4.10 and `tdbc::mysql` 1.1.7 were used for isolated prepared statement,
BLOB, transaction and UDF tests. The driver's `configure` inspection produced
`Unknown system variable 'TX_ISOLATION'` with this server; this example does not
call that method, and its exercised operations succeeded. Other versions and
platforms remain unverified.
The isolated server also logged a failure to load
`component_reference_cache` from its deliberately separate plugin directory.
It nevertheless started and passed the operations described above; the effect
of that missing component outside these tests has not been assessed.

`mysqltcl` 3.052 was also inspected locally. Its exported commands include query,
execution and escaping operations, but the installed package exposes no
prepared-statement or parameter-binding command. This observation concerns that
installed version and does not establish the capabilities of other MySQL Tcl
bindings or versions. It was not used for this adapter: no claim is made here
that escaping SQL text is equivalent to bound parameters.
