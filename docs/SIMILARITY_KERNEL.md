# Shared float32 similarity kernel

`src/similarity.c` and `src/similarity.h` provide two C functions independent
of database and Tcl headers: `similarity_dot_f32le` and
`similarity_cosine_f32le`. Each accepts two byte pointers, their byte lengths,
and an output `double *`; 1 denotes success and 0 denotes invalid input. The
caller retains all ownership; failure leaves the output untouched. Inputs must
be non-null, nonempty, equally sized and a multiple of four. Components must
be finite IEEE 754 binary32 in little-endian order. Byte decoding uses explicit
shifts and `memcpy`, not aligned float pointers or native byte order. Cosine
also rejects zero norms; dot product permits zero vectors. Accumulation and
output are double precision. Results are rejected if non-finite. No function
clamps scores. A `float` with IEEE binary32 characteristics is required at
compile time. Use neither fast-math nor finite-math-only.

`src/rag_optimizations.c` wraps this kernel as the existing MySQL UDF. Invalid
vector data, including SQL NULL, returns SQL NULL for that row; structural
argument errors fail initialization. MySQL output decimals remain 31. The
separate `src/sqlite_similarity.c` implements SQLite
`cosine_similarity_v2(blob, blob)`: NULL, non-BLOB values and invalid vectors
return SQL NULL, and incorrect arity is a SQLite error. MySQL rejects non-string
argument types during initialization, so SQL type-error behavior is not
identical between the engines. Both wrappers use the same cosine calculation.
The extension registers a deterministic, innocuous function for the connection;
SQLite does not expose a per-extension unload through this example. Closing a
connection removes its registration, but does not prove immediate library unload.
Ordering, NULL filtering and deterministic tie-breaking are responsibilities of
the SQL query. The existing examples use descending score followed by sequence.

## Build

The configured build also provides optional `sqlite-similarity.so` and
`mysql-cosine-v2.so` targets in its `unix` directory. Neither is built by the
default binding target. Supply `SQLITE_CPPFLAGS` or `MYSQL_CPPFLAGS` with the
appropriate development headers. For example, from the configured build:

```sh
make -C unix sqlite-similarity.so SQLITE_CPPFLAGS=-I/path/to/sqlite/include
make -C unix mysql-cosine-v2.so MYSQL_CPPFLAGS="$(mysql_config --include)"
```

The corresponding `install-sqlite-similarity` and
`install-mysql-similarity` targets install only on explicit request into
`DESTDIR` plus `SIMILARITY_INSTALL_DIR` (default `libdir/tclembedding-similarity`).
They do not register functions in a server. Inspect the destination before use.
These targets link a scalar object and configured SIMD objects with a stateless
dispatcher. After trying configured AVX2 and AVX paths, on x86-64 it checks
CPUID SSE2 when that object was configured; the ABI requires the OS to
preserve XMM state. It uses scalar if no configured SIMD path is usable. There
is no shared mutable initialization. On other architectures and in cross builds,
the configured selection is scalar. `--with-simd=scalar` disables SIMD objects.
The configure output distinguishes CPU/OS observations, compiler flags,
and objects selected for a subsequent build. It does not establish that those
objects were compiled or executed; detecting a feature does not demonstrate
that its kernel was executed or accelerated a workload.
The AVX and AVX2 cosine implementations are compiled separately when configure
detects suitable CPU/OS support and compiler flags. Dispatch rechecks CPUID AVX,
XSAVE and OSXSAVE before XGETBV, then requires enabled XMM/YMM state; AVX2 also
requires CPUID leaf 7 AVX2. AVX processes four double-precision lanes; AVX2
also checks eight float32 exponent fields with 256-bit integer instructions.
The intended benefit is reduced validation work per vector block, not a
measured speedup. FMA and floating-point contraction are disabled. Both
objects compiled on the Phenom II, but were not executed there; numerical
equivalence and performance on supported CPUs remain unverified. A forced
dispatcher with both objects linked made no advanced calls on that CPU.
AVX-512 remains unimplemented; it would additionally require CPUID AVX-512F
and XGETBV state for opmask and both ZMM register components, plus checks for
the exact instruction subsets used.

To reproduce the non-AVX dispatch check on a suitable x86-64 host, configure
the project normally, then use these commands from the source directory. They
compile advanced objects but the check must not call them:

```sh
make -C "$BUILD_DIR/unix" similarity_scalar.o similarity_sse2.o \
  similarity_avx.o similarity_avx2.o \
  SIMD_AVX_CFLAGS='-mavx -mno-avx2 -mno-fma -ffp-contract=off' \
  SIMD_AVX2_CFLAGS='-mavx2 -mno-fma -ffp-contract=off'
cc -std=c11 -O2 -fPIC -march=x86-64 -include src/similarity_baseline.h \
  -DTCLEMBEDDING_HAVE_SSE2 -DTCLEMBEDDING_HAVE_AVX -DTCLEMBEDDING_HAVE_AVX2 \
  -c src/similarity_dispatch.c -o "$BUILD_DIR/dispatch-all.o"
cc -std=c11 -O2 -pthread tests/similarity_no_avx_test.c "$BUILD_DIR/dispatch-all.o" \
  "$BUILD_DIR/unix/similarity_scalar.o" "$BUILD_DIR/unix/similarity_sse2.o" \
  "$BUILD_DIR/unix/similarity_avx.o" "$BUILD_DIR/unix/similarity_avx2.o" \
  -Wl,--wrap=similarity_avx_cosine -Wl,--wrap=similarity_avx2_cosine \
  -lm -o "$BUILD_DIR/no-avx-test"
"$BUILD_DIR/no-avx-test"
```

For a later compatible target, `tests/similarity_avx_compare.c` compares each
advanced function separately against the scalar reference with absolute
tolerance `1e-12`, invalid inputs and extremes. Build it with the three objects
created above, then select a path explicitly:

```sh
cc -std=c11 -O2 -march=x86-64 tests/similarity_avx_compare.c \
  "$BUILD_DIR/unix/similarity_scalar.o" "$BUILD_DIR/unix/similarity_avx.o" \
  "$BUILD_DIR/unix/similarity_avx2.o" -lm -o "$BUILD_DIR/avx-compare"
"$BUILD_DIR/avx-compare" avx
"$BUILD_DIR/avx-compare" avx2
```

The test checks the selected CPU/OS capability before calling that function.
The executable was compiled but neither path was executed on the non-AVX host.

Configured x86-64 kernel and adapter objects use `-march=x86-64` plus a
preprocessor guard that rejects explicitly enabled instruction sets beyond
the baseline. `configure` checks that guard before its CPU probes. Compilers
may expose additional target extensions not covered by the guard: use a
baseline toolchain and avoid architecture-specific user flags. Autoconf's
earlier compiler checks and external libraries are outside this guard.

The external ONNX Runtime selects its own execution provider and internal
optimizations. Similarity-kernel selection does not control ONNX Runtime's MLAS
dispatch. A future reproducible source build of ONNX Runtime must separately
record its revision, dependencies, target baseline and build options; using an
identified external runtime remains supported.

The manual commands below retain the standalone scalar build and do not use
the configured dispatcher.

For a configured build with SSE2, run the concurrent SSE2-only dispatch check:

```sh
make -C "$BUILD_DIR/unix" test-similarity-dispatch
```

This test requires GNU-compatible linker wrapping, an SSE2 object and a
compatible target. It builds an SSE2-only dispatcher and counts actual calls
into the SSE2 object; it does not test selection of AVX or AVX2.
On the characterized Phenom II, the configured dispatcher, scalar and SSE2
paths passed this concurrent synthetic check; the 768-case comparison against
the standalone scalar reference had maximum absolute difference
`3.8857805861880479e-16` at the existing `1e-12` tolerance. The optional
SQLite extension passed a small synthetic SQL check, and the MySQL adapter
passed the existing SQL suite on an isolated MySQL 8.4.10 server. The isolated
server reported an unavailable `component_reference_cache` component; effects
outside the tested cases are not established. Cross compilation and non-x86
execution remain untested. These results are not a general concurrency proof.

With C11, SQLite development headers and MySQL development headers installed by
the operator, build the independent artifacts in a private directory:

```sh
SQLITE_INCLUDE=/path/to/sqlite/include
cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared -I"$SQLITE_INCLUDE" \
  src/sqlite_similarity.c src/similarity.c -o "$LAB_DIR/similarity.so" -lm
cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared $(mysql_config --include) \
  -Dcosine_similarity=cosine_similarity_v2 \
  -Dcosine_similarity_init=cosine_similarity_v2_init \
  -Dcosine_similarity_deinit=cosine_similarity_v2_deinit \
  src/rag_optimizations.c src/similarity.c -o "$LAB_DIR/mysql_cosine_v2.so" -lm
```

`SQLITE_INCLUDE` must contain both `sqlite3.h` and `sqlite3ext.h`; set it to
the installed header directory or to an explicitly provisioned private copy.
The SQLite extension uses the official `sqlite3ext.h` extension API; it does
not link against a separately selected SQLite library. Enable extension loading
only for the load step, then disable it again:

```tcl
package require sqlite3
sqlite3 db :memory:
db enable_load_extension 1
set extension /path/to/similarity.so
db eval {SELECT load_extension($extension,'sqlite3_similarity_init')}
db enable_load_extension 0
set a [binary format r* {1 0}]
set b [binary format r* {0 1}]
puts [db onecolumn {SELECT cosine_similarity_v2($a,$b)}]
db close
```

Use a separately configured isolated MySQL test server and the procedure in
[MYSQL_UDF.md](MYSQL_UDF.md). The existing SQL example is not modified to load
SQLite extensions automatically; its Tcl scalar path remains available. No
schema, input format or deployed server is altered by these source changes.

## Validation and limits

On Linux x86-64, AMD Phenom II X4 965, GCC 15.3.1, MySQL 8.4.10 and the Tcl
SQLite 3.45.2 package, scalar and explicitly enabled SSE2 standalone builds ran.
Those historical standalone builds have no dispatcher; SSE4.1, AVX and AVX2
are not assumed. The later configured dispatcher is described above.
The 768-vector-length standalone reference test retained its existing absolute
`1e-12` threshold. Independently compiled scalar and SSE2 libraries differed by
at most `3.8857805861880479e-16` absolute and `1.1126198955597224e-13`
relative for non-negligible scores in that synthetic sample. This is not a
universal bound. The SSE2 test exercises the SSE2 cosine path; the dot product
is scalar. The system compiled AVX2/FMA flags only and did not execute them.

The original standalone scalar/SSE2 comparison can be repeated on an SSE2-capable x86 host:

```sh
tclsh tests/mysql_cosine_test.tcl
cc -std=c11 -O2 -fPIC -shared -fno-tree-vectorize -DCOSINE_FORCE_SCALAR \
  src/similarity.c -o "$LAB_DIR/scalar.so" -lm
cc -std=c11 -O2 -fPIC -shared -msse2 -DCOSINE_ENABLE_SSE2 \
  src/similarity.c -o "$LAB_DIR/sse2.so" -lm
cc -std=c11 -O2 -Wall -Wextra -Werror tests/similarity_compare_test.c \
  -o "$LAB_DIR/compare" -ldl -lm
"$LAB_DIR/compare" "$LAB_DIR/scalar.so" "$LAB_DIR/sse2.so"
```

The compare program also ran under Valgrind with `--error-exitcode=99` and
reported no errors. This bounded process does not establish general leak freedom.

An isolated MySQL server loaded both the corrected pre-extraction source and
its shared-kernel successor. The existing MySQL SQL suite passed. Ten synthetic
valid cases, including 384/768 dimensions and float32 extremes, matched the
SQLite function and a Tcl double-precision reference within the pre-existing
absolute `1e-12` threshold; observed maximum difference was zero. The old and
new corrected MySQL paths matched exactly in this sample. Invalid lengths,
empty vectors, zero norms, NaN, infinity and NULL were checked; SQL top-k order
matched for a four-vector synthetic example with a tie. No universal numerical identity
or large-scale performance claim follows.

A separate Example 03 integration loaded the extension explicitly and compared
200 synthetic E5 embeddings with the existing Tcl retrieval path. All scores
matched within `1e-12`; maximum absolute difference was
`1.1102230246251565e-16`. The top five IDs and full returned provenance matched.
The native extension remains optional and the Tcl reference is unchanged. Run
the test with a launcher that can find the installed Tcl packages:

```sh
tclsh tests/sqlite_similarity_integration.tcl "$LAB_DIR/similarity.so" \
  /path/to/synthetic-fragments.jsonl \
  /path/to/model.onnx /path/to/tokenizer.json
```

It creates a new temporary SQLite database and does not require MySQL. The
input fixture must have at least five records; no private export is required.

For a repeat of the cross-engine check, build a second library from the
pre-extraction source (`git show be962f3036c7360f90bc6bff9779f5d5e323419b:src/rag_optimizations.c`)
with the three exported function names changed to `cosine_similarity_old`,
`cosine_similarity_old_init` and `cosine_similarity_old_deinit`. Register that
and the newly built `cosine_similarity_v2` only on an isolated server, then run:

```sh
tclsh tests/mysql_udf_integration.tcl "$LAB_DIR/mysql.sock" "$LAB_DIR"
tclsh tests/similarity_sql_test.tcl "$LAB_DIR/similarity.so" \
  "$LAB_DIR/mysql.sock" "$LAB_DIR"
```

The separate historical artifact from the earlier installation is not the
corrected pre-extraction source. It was probed in standalone child processes
without registration or installation. For `[-2,3]` and `[4,-5]` it returned
`-0.99624061584472656`, versus `-0.9962405881956831` for the corrected MySQL
UDF; it reported `decimals=0`. In these probes, zero vectors returned zero,
NaN returned NaN, unequal and truncated lengths set the error flag, and a NULL
argument set the NULL flag. These historical observations are not the accepted
v2 contract and do not establish behavior for all inputs. The historical
binary was not copied into the repository.

The local SQLite development headers were not installed. For this experiment,
only the headers from the official SQLite 3.45.2 amalgamation archive
`https://www.sqlite.org/2024/sqlite-amalgamation-3450200.zip` were extracted to a
temporary directory. The locally observed archive SHA-256 was
`65230414820d43a6d1445d1d98cfe57e8eb9f7ac0d6a96ad6932e0647cce51db`;
no independent published digest for that historical archive was verified.
