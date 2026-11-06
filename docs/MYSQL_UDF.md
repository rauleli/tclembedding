# MySQL cosine similarity UDF

`src/rag_optimizations.c` provides `cosine_similarity` for two binary vectors and uses the independent kernel in `src/similarity.c`. It is independent of the ONNX and tokenizer bindings. Standalone numeric tests alone do not establish server integration; isolated MySQL results are described below.

For the shared kernel API, SQLite extension and cross-engine characterization,
see [SIMILARITY_KERNEL.md](SIMILARITY_KERNEL.md).

## Input and output contract

Each non-NULL argument must be a BLOB containing a positive number of IEEE 754 binary32 values in little-endian byte order. Both BLOBs must have equal byte length, divisible by four. All components must be finite, and each vector must have nonzero magnitude. The UDF accumulates products and squared magnitudes in double precision, then returns cosine similarity as a SQL REAL. Rounding may produce values very slightly outside the mathematical interval [-1, 1].

A SQL NULL argument, malformed lengths, unequal dimensions, empty vectors, zero magnitudes, NaN, infinity and non-finite results return SQL NULL by setting the per-row `is_null` flag, without setting MySQL's persistent `error` flag. Invalid argument count or types cause an initialization error. A NULL score alone cannot distinguish a NULL argument from invalid vector data; validate embeddings during ingestion. In the isolated MySQL 8.4.10 test, a valid–invalid–valid sequence returned `1, NULL, 1`, and a top-k query excluding NULL retained both valid rows. Identical argument pointers are still fully validated. The binary format is the same as Example 02's `binary format r*`; `binary format f*` is native-endian and must not be assumed portable. Arbitrary bytes cannot prove their intended endianness or model identity: callers must track format, dimension and model separately.

The initialization sets `UDF_INIT.decimals` to 31, MySQL's value for an unspecified number of decimal places ([loadable function documentation](https://dev.mysql.com/doc/extending-mysql/8.4/en/adding-loadable-function.html)). This avoids forcing a fixed zero-decimal output on the tested server; it does not guarantee a fixed number of digits across clients or MySQL versions. For synthetic vectors `[-2, 3]` and `[4, -5]`, MySQL 8.4.10 returned `-0.9962405881956831` directly, without CAST. The earlier implementation displayed `-1` and could propagate an invalid-row error to later rows in the same statement; both behaviors were corrected and retested within the scope below.

Examples of little-endian float32 bytes:

```sql
-- [1, 0] with itself: 1
SELECT cosine_similarity(X'0000803F00000000', X'0000803F00000000');
-- [1, 0] and [0, 1]: 0
SELECT cosine_similarity(X'0000803F00000000', X'000000000000803F');
-- A NULL argument returns NULL.
SELECT cosine_similarity(NULL, X'0000803F');
```

## Compilation and deployment

Use a C11 compiler and development headers matching the target MySQL or MariaDB server. MySQL 8.4.10 headers were used to compile the corrected UDF with GCC 15.3.1 and `-Wall -Wextra -Werror`. For an environment that supplies `mysql_config`, an example Linux build is:

```sh
cc -std=c11 -O3 -fPIC -shared $(mysql_config --include) \
  src/rag_optimizations.c src/similarity.c -o mysql_cosine_similarity.so -lm
```

Do not use `-ffast-math` or `-ffinite-math-only`: the source rejects these options because they undermine NaN and infinity validation. Do not assume a library built for one server version is ABI-compatible with another. MySQL 8 uses a `bool` UDF initialization result and unsigned-byte status pointers; MariaDB and older MySQL headers use `my_bool` and char status pointers. The source selects types from the headers. MySQL 8.4.10 header types, direct library calls and isolated server invocation passed; MariaDB headers and server invocation remain unverified.

After an administrator independently verifies the target server's plugin directory, library compatibility and permissions, install the shared library there and register it manually:

```sql
CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'mysql_cosine_similarity.so';
```

Do not register experimental functions on a server used by other applications. Use a separately authorized isolated test instance and its own plugin directory. No automatic installation, service configuration or registration is provided here.

## CPU paths

The default implementation is scalar C. An optional SSE2 implementation is enabled only when explicitly compiling with `-DCOSINE_ENABLE_SSE2` and the compiler targets x86/x86-64 with `__SSE2__`; e.g., on a compatible target add `-msse2 -DCOSINE_ENABLE_SSE2`. There is no runtime CPU dispatch: the operator must ensure the deployment CPU supports every instruction emitted by the compiler. The default scalar source remains available on non-x86 targets with compatible C float representation; non-x86 execution has not been tested. Compiling with hardware-specific flags can generate additional instructions outside the explicitly selected code path, so build for the intended deployment baseline rather than requiring `-march=native`.

The SSE2 path uses double-precision vector arithmetic and decodes little-endian bytes without assuming pointer alignment. SSE3 and SSE4.1 are not needed for this implementation. AMD SSE4a is not SSE4.1. No explicit AVX2 or FMA implementation or runtime dispatch is included; compiling with those flags does not establish that an AVX2/FMA-specific implementation was tested or is safe on older CPUs.

## Reproducible standalone tests and observed measurements

On Linux x86-64 with GCC and Tcl 8.6:

```sh
tclsh tests/mysql_cosine_test.tcl
```

The Tcl runner compiles a scalar binary and, when the host advertises SSE2, an SSE2 binary in a new temporary directory. It tests 768 synthetic vector lengths, including 384 and 768, against an independent long-double scalar calculation with absolute tolerance `1e-12`; it also checks equal, orthogonal and opposite vectors, malformed lengths, unaligned bytes, zero vectors, NaN, infinity, float32 extremes and little-endian decoding. A separate C test uses **synthetic UDF structure definitions** to exercise the wrapper flags. Those test types do not establish ABI compatibility. On an SSE2 host the runner also checks whether GCC can compile with AVX2/FMA flags; that binary is never executed. The test runner expects Linux `/proc/cpuinfo`; other platforms need a separate test procedure.

After compiling the separately named library shown below, the following direct test uses real MySQL development headers and loads that library; it does not connect to MySQL:

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror $(mysql_config --include) \
  tests/mysql_udf_real_headers_test.c -o "$LAB_DIR/real-header-test" -ldl -lm
"$LAB_DIR/real-header-test" "$LAB_DIR/plugins/mysql_cosine_v2.so"
```

On an AMD Phenom II X4 965 with GCC 15.3.1, the CPU advertised SSE2, SSE3 and SSE4a, not SSE4.1, AVX or AVX2. Both scalar and SSE2 standalone tests passed. Five independent processes per implementation each measured 10,000 calls on a 768-component synthetic pair after the correctness loop. Scalar elapsed times were 25.748–26.051 ms (median 25.788 ms); SSE2 times were 36.392–48.303 ms (median 37.363 ms). The scalar build disabled tree vectorization for this comparison. These short, unpinned, single-machine measurements exclude SQL, are not throughput guarantees and do not predict scaling to large tables; SSE2 was slower in this observation. The SSE2 path therefore remains opt-in.

MySQL Server 8.4.10, matching development headers and `mysql_config` were available for the real-header build. A separate process loaded the corrected shared library and exercised its exported functions using the actual MySQL header structures and function-pointer types. Subsequently, an isolated MySQL 8.4.10 server with TCP disabled loaded a separately named library and registered `cosine_similarity_v2` in its own data directory. The server reported that `component_reference_cache.so` was absent from the isolated plugin directory, but became ready and executed the checks; effects outside these checks were not investigated. Direct SQL results without CAST matched independent Tcl numeric calculations at absolute tolerance `1e-12` for identical, orthogonal, opposite and signed vectors, positive and near-zero values, 384 and 768 dimensions and float32 extremes. Tests also covered SQL NULL, malformed and unequal lengths, empty and zero vectors, NaN and infinities, non-string initialization errors, per-row recovery and top-k with NULL excluded. No running production server or system plugin directory was modified. MariaDB, other platforms and server query performance remain unverified.

A bounded standalone scalar run under Valgrind exited successfully with no errors or definite/indirect losses reported under the selected options. This did not exercise a database server or establish general leak freedom. An AddressSanitizer build could not link because the local ASan runtime was unavailable.

### Historical artifact

An independently installed historical shared object was observed with size 15,840 bytes, modification date 2025-12-22 and SHA-256 `e8757e41b33b397099e327933dfbc461617627af114cb7604538e2f87fb48890`. Its exported names include `cosine_similarity`, `cosine_similarity_init` and `cosine_similarity_deinit`. A basic identical-vector SQL result of 1 was reported for that installation; it was not repeated in this characterization. The observed file's timestamp and reported use do not establish which source revision produced its bytes. The author subsequently removed the historical function registration and installed shared object; a read-only check confirmed their absence. The corrected implementation is a separate build and was not installed as a replacement.

### Isolated server procedure

The following is a procedure to execute only on a system where private Unix sockets and a user-owned MySQL data directory are permitted. It creates a fresh insecure root account **only inside the isolated data directory**, disables TCP and the X protocol, and uses a separate plugin directory. It must not point at an existing server's data, socket or plugin directory. The isolated server remains a separate process that must be shut down through its own socket.

```sh
LAB_DIR=$(mktemp -d)
mkdir -m 700 "$LAB_DIR/data" "$LAB_DIR/tmp" "$LAB_DIR/plugins"
cc -std=c11 -O3 -Wall -Wextra -Werror -fPIC -shared $(mysql_config --include) \
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
```

Once the isolated server is ready, use its socket explicitly:

```sh
mysql --no-defaults --protocol=socket --socket="$LAB_DIR/mysql.sock" -uroot \
  -e "CREATE FUNCTION cosine_similarity_v2 RETURNS REAL SONAME 'mysql_cosine_v2.so'; SELECT cosine_similarity_v2(X'0000803F', X'0000803F');"
tclsh tests/mysql_udf_integration.tcl "$LAB_DIR/mysql.sock" "$LAB_DIR"
mysqladmin --no-defaults --protocol=socket --socket="$LAB_DIR/mysql.sock" -uroot shutdown
```

The Tcl test requires `mysqltcl`, checks the supplied socket, data and plugin directories and requires TCP to be disabled. It tests the registered `cosine_similarity_v2` function; never point it at a production socket. The procedure needs an environment that permits private Unix sockets.

## Legacy examples

The historical MySQL examples have not been redesigned for this contract. In particular, `tools/search.tcl` probes availability with a zero vector, which now returns NULL, and older examples use native-endian `binary format f*`. Review and update those consumers before using them with this UDF. See [MYSQL_INTEGRATION.md](MYSQL_INTEGRATION.md) and [RAG_EXAMPLE.md](RAG_EXAMPLE.md) as illustrative material, not validated integration tests.
