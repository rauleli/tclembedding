> Historical record: this benchmark used an experimental input format and an earlier implementation. Its measurements are preserved as observed; the historical commands require Git revision `2ba8ffc6bd429c547431e5acfccbf72c4449bd4a`. Current ingestion is described in [SQL_RETRIEVAL.md](../examples/03-chatgpt-export/SQL_RETRIEVAL.md).

# Synthetic MySQL and SQLite benchmark

## Protocol fixed before measurement

The initial experiment uses the same existing 200-record synthetic JSONL v2 and
L2E1 inputs for both engines. It does not claim statistical independence of the
records or measure retrieval relevance. Larger valid inputs may be supplied as
external files; this protocol does not manufacture additional vectors.

Build both L-3 adapters from the same kernel source with `-O2`, without SSE2
opt-in, fast-math, AVX flags, or machine-specific tuning. Use a private SQLite
file and a disposable MySQL server with isolated data, socket and plugins and
TCP disabled. No existing database is reused. Verify both input files and every
imported vector before timing queries.

Measure adapter initialization, initial ingest and identical reimport once per
engine. Initialization times cover schema creation, not MySQL server startup;
record startup separately. Import times include the accepted adapter's complete
integrity verification, Tcl work, SQL and transaction. Report them as totals;
do not invent a decomposition of validation from database time.

Generate two fixed synthetic E5 query vectors once, including `query: `, and
record tokenization and ONNX inference separately from SQL. Use identical
float32 little-endian bytes for both engines. Record a first query on each new
connection, then one untimed warmup for each query/engine combination. Record
30 timed executions per query and engine, with a deterministic alternating
engine order. Each timed SQL operation includes native cosine, ordering,
fetching top five rows and materializing database results in Tcl. Decode MySQL
JSON and perform integrity checks outside that timer. The engines' different
physical schema and result representations remain part of the SQL measurement.
For each warmed execution, separately time result decoding and selected-row
checksum validation; their sum with the SQL interval is a functional retrieval
measurement. The sum omits small orchestration gaps and the cross-engine check.
The first-connection result is not called cold-cache. No cache clearing is used.
Only query 1 is the first ranking operation on the reopened connection; query 2
is its first use on that same, already used connection.

Before accepting timings, compare every imported vector byte, corpus count,
query bytes, and for each query the top-five sequence, scores, text and
provenance. Compare scores using the existing absolute `1e-12` criterion; report
relative error only for scores whose absolute value exceeds `1e-12`. Validate
tie ordering with a separate deterministic synthetic SQL control. A top-k or
provenance mismatch invalidates the affected timing comparison.

Save each raw observation as CSV and summarize minimum, mean, median, p95 and
maximum in milliseconds. Percentiles use nearest-rank: sorted sample at rank
`ceil(p*n)` (one-based); p50 is the median, averaging the middle pair for an
even sample. Tcl `clock clicks -microseconds` supplies elapsed timestamps; its
monotonic behavior is platform-dependent, and negative intervals are rejected.
RSS and SQLite file sizes are point-in-time measurements. Where available,
`VmHWM` additionally records the process-lifetime high-water RSS; it is not a
query-specific peak. MySQL table sizes are engine estimates and its data directory includes server
baseline and preallocated files. SQLite uses its default rollback journal, not
an intentionally enabled WAL. Never sum RSS of different processes as if it were
one measurement. All tests run sequentially without deliberate competing work.

The initial pilot exposed a protocol implementation error: its connections had
already performed verification reads before the first ranking measurement, and
it did not time result validation. That pilot is excluded. The final procedure
reopens both connections before the first ranking query and records validation
separately. Subsequent bounded rehearsal runs verified the added metadata,
runtime identity and Tcl control. A subsequent run was invalidated when the
direct result of MySQL `SELECT :vector` did not round-trip a 1,536-byte value
through this driver. A separate controlled probe established that the server
received all original bytes (`HEX` and `OCTET_LENGTH`) and that explicitly
casting the result as binary also round-tripped. The final verification uses
the server-side hex and length, avoiding reliance on the driver's direct
parameter-result conversion. The probe does not imply that all TDBC/MySQL
versions behave alike. Rehearsals and the invalidated run are not pooled into
the reported samples. No thresholds or corpus parameters were changed.

## Requirements and execution

Use Tcl 8.6 with `sqlite3`, `rl_json`, Tcllib `sha256`, `tdbc::mysql`, and the
installed tokenizer and ONNX packages. The experiment requires MySQL Server and
matching development headers, SQLite extension headers `sqlite3.h` and
`sqlite3ext.h`, GCC, and the characterized E5 ONNX/tokenizer artifacts. The
SQLite extension and MySQL UDF are built only in the temporary laboratory.
The benchmark consumes externally supplied valid JSONL v2 and L2E1 files. For
reproducing the 200-record fixture, `embed_pipeline_fixture.tcl` and
`embed_pipeline.tcl` can generate it; that preparation is outside these timing
intervals. The benchmark accepts other positive record counts, but no larger
corpus was measured or validated in this experiment.

The comparison itself requires both engines. Independent tests do not: the
SQLite-only `tests/sqlite_similarity_integration.tcl` and MySQL-only
`tests/mysql_udf_integration.tcl` procedures are documented in
[SIMILARITY_KERNEL.md](SIMILARITY_KERNEL.md) and
[MYSQL_UDF.md](MYSQL_UDF.md), respectively. The accepted ingestion tests can
also be run separately as described in
[SQL_RETRIEVAL.md](../examples/03-chatgpt-export/SQL_RETRIEVAL.md).

Set these variables to existing local files; no models or dependencies are
fetched by the benchmark. `SQLITE_INCLUDE` is a directory containing the two
SQLite headers. Use the project's installed Tcl launcher in place of `tclsh` if
it sets the necessary package and runtime paths.

If the synthetic files do not already exist, choose new private paths and run
the following once before the benchmark. The vector generator enforces the
characterized E5 artifact and runtime hashes:

```sh
tclsh examples/03-chatgpt-export/embed_pipeline_fixture.tcl "$TOKENIZER" "$FRAGMENTS" 200
tclsh examples/03-chatgpt-export/embed_pipeline.tcl \
  -input "$FRAGMENTS" -output "$VECTORS" -model "$MODEL" \
  -tokenizer "$TOKENIZER" -budget 128 -batch-size 8
```

Define `FRAGMENTS`, `VECTORS`, `MODEL` and `TOKENIZER` before running those
commands. Both generators refuse to overwrite their outputs.

```sh
FRAGMENTS=/path/to/synthetic-fragments.jsonl
VECTORS=/path/to/synthetic-embeddings.l2e
MODEL=/path/to/model.onnx
TOKENIZER=/path/to/tokenizer.json
SQLITE_INCLUDE=/path/to/sqlite/headers
LAB_DIR=$(mktemp -d /tmp/tclembedding-l4-XXXXXX)
chmod 700 "$LAB_DIR"
mkdir -m 700 "$LAB_DIR/data" "$LAB_DIR/tmp" "$LAB_DIR/plugins" "$LAB_DIR/results"
cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared -I"$SQLITE_INCLUDE" \
  src/sqlite_similarity.c src/similarity.c -o "$LAB_DIR/similarity.so" -lm
cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared $(mysql_config --include) \
  -Dcosine_similarity=cosine_similarity_v2 \
  -Dcosine_similarity_init=cosine_similarity_v2_init \
  -Dcosine_similarity_deinit=cosine_similarity_v2_deinit \
  src/rag_optimizations.c src/similarity.c -o "$LAB_DIR/plugins/mysql_cosine_v2.so" -lm
mysqld --no-defaults --initialize-insecure --basedir=/usr \
  --datadir="$LAB_DIR/data" --tmpdir="$LAB_DIR/tmp" \
  --plugin-dir="$LAB_DIR/plugins" --log-error="$LAB_DIR/init.log"
mysqld --no-defaults --basedir=/usr --datadir="$LAB_DIR/data" \
  --tmpdir="$LAB_DIR/tmp" --plugin-dir="$LAB_DIR/plugins" \
  --socket="$LAB_DIR/mysql.sock" --pid-file="$LAB_DIR/mysql.pid" \
  --skip-networking --mysqlx=0 --log-error="$LAB_DIR/server.log" &
# Wait until the private socket responds; do not use another server's socket.
mysqladmin --no-defaults --protocol=socket --socket="$LAB_DIR/mysql.sock" -uroot ping
mysql --no-defaults --protocol=socket --socket="$LAB_DIR/mysql.sock" -uroot \
  -e "CREATE FUNCTION cosine_similarity_v2 RETURNS REAL SONAME 'mysql_cosine_v2.so'"
tclsh examples/03-chatgpt-export/sql_benchmark.tcl \
  "$FRAGMENTS" "$VECTORS" "$MODEL" "$TOKENIZER" "$LAB_DIR/similarity.so" \
  "$LAB_DIR/mysql.sock" "$LAB_DIR/results/run"
mysqladmin --no-defaults --protocol=socket --socket="$LAB_DIR/mysql.sock" -uroot shutdown
```

Wait for startup before `ping`, and stop this server through its own socket
also after a failed run. The benchmark requires a user-owned laboratory under
`/tmp` whose directory name begins `tclembedding-l4-`, validates the server's
socket, data and plugin directories and requires TCP disabled. It creates a new
synthetic database in that instance. Never direct it at a shared server. It
refuses an existing output directory. It checks the characterized ONNX Runtime
and tokenizer backend library hashes; another build may need separate
characterization. The benchmark records the extension and UDF hashes and probes
the UDF contract, but those checks alone do not prove that both binaries were
built from the same kernel source. Rebuild both with the commands above and
retain build provenance when making that claim. No deletion or global
installation is performed.

The output directory contains `samples.csv`, a stable five-column CSV
(`kind,engine,query,iteration,elapsed_us`), `summary.md`, and a private SQLite
file. `warm` is SQL plus result materialization; `validate` is selected-row
checking and provenance decoding; `functional` is their sum. `first_use`
records the first ranking on a reopened connection for query 1 and the first
use of query 2 on the same connection. Other rows record verification,
initialization, imports and query-vector preparation. Copy only the CSV and
summary when sharing synthetic results; do not copy the database or laboratory
as a whole. A missing summary or any equivalence error means timings from that
run are not accepted.

Server setup timing and MySQL data-directory allocation are separate manual
measurements, not entries in the CSV: the observed run used `/usr/bin/time` for
initialization, realtime timestamps around readiness polling for startup, and
`du -sk` immediately after initialization and again after the benchmark. These
readings are environment-specific; collect them separately when reproducing
the storage comparison. The generated summary records process RSS and table
estimates, but does not itself time or start the server.

## Observed results

A bounded run on 2026-11-06 UTC used Fedora 43 x86-64, AMD Phenom II X4 965,
GCC 15.3.1, Tcl 8.6.14, SQLite 3.45.2, MySQL 8.4.10, `tdbc::mysql` 1.1.7,
Tokenizers 0.23.2 and CPU ONNX Runtime 1.31.1. The source HEAD was
`c75556dee04e87b79cf57a52e4e336287bb0b55d`; the working tree contained the
uncommitted benchmark and README changes. The C builds used `-O2`, without
fast-math, machine-specific tuning or explicit SSE2 optimization. The processor
advertised SSE2 but not AVX/AVX2.

The synthetic JSONL SHA-256 was
`70ade3bb43add618812b62b83582d8279d702ac2d2e4e08c0b5c839ec3a92f57`; L2E1 was
`e2a5893f8924223358c211ebc7bee9debbd70b1ba4d7fa38d0792673c3463938`. The
model and tokenizer hashes, native library hashes, query-vector hashes, source
script hash, CPU and version details are recorded in the generated summary.
No private corpus was used.

| Operation | SQLite | MySQL |
| --- | ---: | ---: |
| Schema initialization | 1.245 ms | 62.172 ms |
| Initial import including validation | 443.701 ms (450.8 records/s) | 593.431 ms (337.0 records/s) |
| Idempotent reimport including validation | 427.160 ms | 555.574 ms |

MySQL schema initialization above excludes creating the empty database and
excludes server initialization and startup. Those separate operations took
3.05 s to initialize the data directory and approximately 1.050 s until the
server responded, respectively. Readiness used a realtime clock and 100 ms
polling, so it is approximate. The benchmark's separate initial input-file
verification took 196.389 ms; the timed adapter imports perform their own
verification and cannot be decomposed into independent engine-only costs.

| Warm SQL + materialization | SQLite p50 / p95 | MySQL p50 / p95 |
| --- | ---: | ---: |
| Query 1 | 1.190 / 1.239 ms | 2.157 / 5.683 ms |
| Query 2 | 1.250 / 1.310 ms | 2.131 / 2.179 ms |

| SQL + selected-row validation | SQLite p50 / p95 | MySQL p50 / p95 |
| --- | ---: | ---: |
| Query 1 | 1.573 / 1.639 ms | 2.734 / 6.225 ms |
| Query 2 | 1.658 / 1.694 ms | 2.706 / 2.760 ms |

Each row uses 30 samples from one run. The first ranking after reopening the
connections took 1.969 ms for SQLite and 3.139 ms for MySQL for query 1;
query 2's first use took 1.272 and 2.187 ms respectively, after query 1 had
already used the connections. These are not cold-cache measurements. Query
vector tokenization took 0.180/0.162 ms and ONNX inference 37.824/36.989 ms;
model/tokenizer loading took 2.734 s, all outside SQL timings. `functional`
is the sum of two timed phases, not a complete application latency.

All 200 stored vector byte sequences matched the input in each database. Both
query vectors were shared by the engines. The top five IDs, text and provenance
matched for both queries; their maximum absolute and relative score differences
were zero in this sample. The independent Tcl control also matched the top-five
scores in this run. A separate tie control returned the same sequence order.
The bytes of each query were also checked inside MySQL with `HEX` and
`OCTET_LENGTH`, and round-tripped through SQLite. Only top-k scores are
compared, not all 200 scores, and this says nothing about semantic relevance.

The SQLite database was 884,736 bytes in `delete` journal mode; no journal,
WAL or SHM file was present at the measurement point. MySQL estimated 1,622,016
bytes of table data and zero separately reported index bytes; InnoDB can account
for clustered indexes within data. The private MySQL data directory occupied
215,376 KiB after the run versus 191,296 KiB after initialization. These
figures include different overheads and preallocation and are not directly
comparable to the SQLite file or attributable solely to the corpus. The source
JSONL was 154,014 bytes and L2E1 was 335,509 bytes.

At the measurement point, Tcl RSS was 398,800 KiB with process high-water RSS
1,163,220 KiB; this includes ONNX loading, not just retrieval. The MySQL server
RSS and high-water RSS were both 486,468 KiB and include the server baseline.
They are separate process measurements. The complete Tcl process took 14.93 s
wall time, including setup and hashing. No memory sum is claimed.

The isolated server reported a failure to load `component_reference_cache`
from its intentionally separate plugin directory, yet started and completed
these tests; effects outside this scope are unknown. The previously observed
`tdbc::mysql` `TX_ISOLATION` configuration-inspection incompatibility remains;
the benchmark does not call that method.

SQLite had lower measured medians in this single small local experiment. That
is not a general database ranking: these physical schemas, IPC, SQL result
representations, driver work, cache state and server baseline differ. SQLite is
a simpler embedded option for small local deployments; MySQL may be useful when
its server deployment model is required. Larger corpora, concurrent users,
other hardware and repeated independent runs remain uncharacterized. The 30
measurements in each combination share a process, connections and cache state;
they are not 30 independent server deployments. No conclusion about semantic
quality or universal performance is warranted.

For the recorded run, the raw CSV SHA-256 was
`777548321e0b5bc3291a2ea90be5f50b7fcf3923af0bda231e4b94ea1404042a`, and
the exact benchmark-script SHA-256 was
`5acc91edecdcd50f096db881064c74a7c9346bf861dce8480abbe54afd319a0e`.
