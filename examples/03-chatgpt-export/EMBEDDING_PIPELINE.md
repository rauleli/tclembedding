> Historical record: the experimental format and commands described below have been retired from current examples. For the supported ingestion path, see [SQL_RETRIEVAL.md](SQL_RETRIEVAL.md). The historical implementation can be inspected in an earlier Git revision.

# Resumable E5 embedding file

This example consumes the existing version 2 fragment JSONL. It does not query a
conversation export, implement a database, or provide retrieval. Use only data
that may be processed locally and protect every fragment, partial file and final
file as sensitive. No model, vectors or generated JSONL belong in the repository.

## Requirements and limits

Use Tcl 8.6, `rl_json` 0.15.7, Tcllib `sha256`, and the characterized
`tclembedding` tokenizer and embedding packages. The implementation currently
requires the E5 revision `614241f622f53c4eeff9890bdc4f31cfecc418b3`, tokenizer
SHA-256 `0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39`
and ONNX SHA-256 `ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665`.
The `passage: ` prefix, mean pooling, pad ID 1, dimension 384 and L2
normalization are fixed. Tokenization is never truncated. Each fragment's
recorded count, unknown-ID count and budget must match the full real
tokenization. The final diagnostic reports the number of input fragments with
unknown IDs; it does not reject them or assign a quality judgment. The requested
batch size is 1–256; each sequence has at most 512 IDs and each padded batch
has at most 4,096 positions. Output remains in input order.

This initial implementation intentionally requires the characterized Linux
x86-64 Rust backend and ONNX Runtime 1.31.1 binary hashes recorded in the
program. It checks the actual mapped files in `/proc/self/maps`; a separately
built, functionally equivalent library is not automatically accepted. This is
an explicit reproducibility restriction, not universal model or platform
support. Keep input and model files immutable throughout a run; the input,
model and tokenizer hashes are checked before and after processing. No hashes
provide authentication against an adversary who can rewrite both data and
checksums.

## Portable version 1 format

The byte format is independent of native integer or float byte order. Offsets
below start at zero; the range endpoint is exclusive. The header is:

| File offset | Length | Content |
| --- | ---: | --- |
| 0 | 5 | ASCII `L2E1` followed by LF |
| 5 | 8 | Lowercase ASCII hexadecimal metadata byte length |
| 13 | 1 | LF |
| 14 | N | UTF-8 JSON metadata bytes |
| 14 + N | 64 | Lowercase ASCII hexadecimal SHA-256 of those N bytes |
| 78 + N | 1 | LF |

Exactly `records` consecutive 1,672-byte records follow at offset `79 + N`.
Each record has this layout, with offsets relative to its first byte:

| Record range | Length | Content |
| --- | ---: | --- |
| [0, 8) | 8 | Nonnegative signed 64-bit sequence number, little-endian; starts at zero |
| [8, 72) | 64 | Lowercase ASCII hexadecimal SHA-256 of the UTF-8 JSONL line, excluding LF |
| [72, 1608) | 1,536 | 384 IEEE 754 float32 values, little-endian, in vector order |
| [1608, 1672) | 64 | Lowercase ASCII hexadecimal SHA-256 of the preceding bytes [0, 1608) |

The two hashes use 64 ASCII bytes each, not 32 binary digest bytes. Thus the
record length is `8 + 64 + 1536 + 64 = 1672`; there are no additional fields.
Vectors must be finite and have L2 norm within `1e-5` of one after serialization.

The metadata identifies the input file hash, record count, fragment contract,
model identity and revision, artifact hashes, dimension, pooling, normalization,
prefix, token budget, batch size, padding ID, Tcl and library versions, and
loaded native library hashes. No filesystem path is embedded. The pair of input
file hash and zero-based sequence number identifies a position; the per-line
hash checks the exact fragment record, including all its provenance. A future
consumer needs the same source JSONL to recover the full metadata or text.
Duplicate provenance keys are rejected. SHA-256 protects against accidental
corruption, not deliberate tampering.

A final file is complete only if its exact length matches its header record
count and every record passes sequence, checksum, finite-value and norm checks.
The verification command can additionally check the input file and every line's
identity.

## Run and resume

With an appropriate Tcl launcher and local paths selected:

```sh
tclsh examples/03-chatgpt-export/embed_pipeline.tcl \
  -input /path/to/fragments.jsonl -output /path/to/embeddings.l2e \
  -model /path/to/model.onnx -tokenizer /path/to/tokenizer.json \
  -budget 128 -batch-size 8

tclsh examples/03-chatgpt-export/embed_pipeline.tcl \
  -verify /path/to/embeddings.l2e -input /path/to/fragments.jsonl
```

Output must be outside the source tree and must not already exist. The program
creates `embeddings.l2e.partial` exclusively or resumes that checkpoint; do not
run multiple writers for the same output. A newly created checkpoint belongs to
the executing user and requests mode `0600` (subject to the process umask); the
final rename preserves its ownership and permissions. The program does not
check ownership or change permissions of an existing checkpoint. It validates
the exact header and each complete record, rejecting incompatible inputs,
configuration or corrupt full
records. An incomplete trailing record is truncated to the previous record
boundary; an incomplete header or a full record with a wrong checksum is an
error, not automatically repaired. If interruption occurs within a batch, the
same batch is recomputed and its already saved records must match exactly before
new records are appended. A changed input hash, model, tokenizer, runtime,
backend or batch configuration cannot be resumed. A completed checkpoint is
validated, input and artifacts are rechecked, and only then is it renamed to
the requested final name. The source file is never modified.

`flush` makes Tcl write its buffers but is not an `fsync` guarantee: power-loss
durability and concurrent writers are not characterized. Resume only after the
previous writer has stopped. Identical final bytes are required in the tested
same environment, inputs, binary dependencies and batching configuration; the
format makes no bit-identity promise across CPUs, runtimes, or batch policies.
The checkpoint does not enforce CPU identity: do not move it between machines
or change the execution environment while resuming.
The verification command establishes file integrity, not semantic correctness.
Checkpoint validation currently retains complete preceding records in memory;
its memory use grows with the number of records already written. This initial
implementation has not established a production-scale memory bound.

## Synthetic tests and measurement

```sh
tclsh examples/03-chatgpt-export/embed_pipeline_test.tcl \
  /path/to/model.onnx /path/to/tokenizer.json /path/to/new-test-directory

tclsh examples/03-chatgpt-export/embed_pipeline_fixture.tcl \
  /path/to/tokenizer.json /path/to/new-synthetic.jsonl 200

tclsh examples/03-chatgpt-export/l2e1_reference_test.tcl \
  /path/to/synthetic-embeddings.l2e /path/to/synthetic-fragments.jsonl
```

The test exercises complete and interrupted child-process runs, including a
simulated partial record write, exact same-environment output comparison,
checksum errors, changed input/model/configuration, duplicate records and
refusal to overwrite. Synthetic files and results remain outside Git. A child
exit after writing part of a record simulates a torn application write; it does
not simulate every kernel, hardware or power failure. Per-run diagnostic timing
reports tokenization, inference, checkpoint scanning and batch sizes; it is not
an ONNX benchmark across different environments.
The independent reference test does not source the writer. It reads a complete
synthetic file and its JSONL, checks byte boundaries, both checksums, sequence
numbers, fragment identity, float32 decoding and vector norms, then checks that
truncation, corruption and extra trailing data are rejected. Its in-memory
reader is a format reference for future consumers, not a streaming SQL adapter.

One initial CPU-only observation used 200 deterministic synthetic fragments,
the E5 artifacts identified above, an AMD Phenom II X4 965, ONNX Runtime 1.31.1
with one inference thread, and one process per run. With batch size 8 (25 full
batches), wall time was 52.42 s, including 33.704 s in inference and 25.666 ms
in tokenization;
maximum process RSS was 1,157,880 KiB. With batch size 1, wall time was 43.28 s,
including 24.425 s in inference and 39.829 ms in tokenization; maximum RSS was
1,157,972 KiB. Both files contained 335,509 bytes. The maximum component
difference between the 200 float32 vectors was `7.07805157e-8`; this is an
observation, not a universal tolerance. These single runs do not establish a
general throughput advantage for either policy. Wall time includes setup and
hashing; the internal total excludes the initial model and tokenizer hashes.

In a separate interruption of the same 200-fragment batch-size-8 input, the
process exited after 32 complete records. Resume scanned that checkpoint in
26.697 ms, processed the remaining 168 records in 21 batches, and completed
in 47.25 s wall time, including dependency and artifact checks. The resulting
file matched the uninterrupted batch-size-8 file byte for byte. The measured
scan is only one component of resume cost; startup, loading, hashing and the
remaining inference still take time.
