# Verification and measurement procedures

## Native dependency comparison

For byte-offset characterization, use the four tokenizer JSON files and their
hashes identified in `CHARACTERIZATION.md`. The following standalone Tcl test
does not require an ONNX model. The Rust byte/character comparison uses
`TOKENIZER_JSON` for MiniLM and, when supplied, `TOKENIZER_EXTRA_JSONS` as a
platform path list containing BGE, E5 and MPNet, in that order.

```bash
TCLLIBPATH="$build_dir/unix" tclsh tests/tokenizer_details_test.tcl "$MINILM_TOKENIZER" "$BGE_TOKENIZER" "$E5_TOKENIZER" "$MPNET_TOKENIZER"
TOKENIZER_JSON="$MINILM_TOKENIZER" TOKENIZER_EXTRA_JSONS="$BGE_TOKENIZER:$E5_TOKENIZER:$MPNET_TOKENIZER" cargo test --release --locked --manifest-path tokenizer-native/Cargo.toml
TCLLIBPATH="$build_dir/unix" tclsh tests/tokenizer_offsets_probe.tcl "$E5_TOKENIZER" 'passage: ' 128 normal 3
TCLLIBPATH="$build_dir/unix" tclsh tests/tokenizer_offsets_probe.tcl "$BGE_TOKENIZER" '' 128 unknown 100
```

The last two commands compare the full existing fragmentation of a synthetic
ASCII input with the proposal and validation of only its first boundary. They
do not benchmark equivalent complete algorithms or establish correctness of
offset-based fragmentation for Unicode or other inputs.

The dependency update was measured against external, hash-identified model and tokenizer artifacts and previously captured synthetic vectors; see `CHARACTERIZATION.md` for the versions and scope. The small Tcl helpers below are laboratory checks, not production dependencies. `dependency_vector_compare.tcl` needs `rl_json` and a reference JSON containing `cases`, `ids` and `binding_vector`; check the model and reference provenance and hashes independently before running it. It compares every component and reports the maximum absolute error and minimum cosine across the stored vectors. `dependency_batch_compare.tcl` compares two synthetic sequences separately and in a padded batch. `dependency_token_ids.tcl` emits 25 ID/recovery records for byte-for-byte comparison; use the same tokenizer and prefix on both builds.

```bash
TCLLIBPATH="$build_a/unix" tclsh tests/dependency_token_ids.tcl "$TOKENIZER_JSON" "$DOCUMENT_PREFIX" > "$lab_dir/ids-a.txt"
TCLLIBPATH="$build_b/unix" tclsh tests/dependency_token_ids.tcl "$TOKENIZER_JSON" "$DOCUMENT_PREFIX" > "$lab_dir/ids-b.txt"
cmp "$lab_dir/ids-a.txt" "$lab_dir/ids-b.txt"
TCLLIBPATH="$build_b/unix" tclsh tests/dependency_vector_compare.tcl "$MODEL_ONNX" "$REFERENCE_JSON" "$POOLING"
TCLLIBPATH="$build_b/unix" tclsh tests/dependency_batch_compare.tcl "$TOKENIZER_JSON" "$MODEL_ONNX" "$PAD_ID" "$POOLING" "$DOCUMENT_PREFIX"
```

The C API version and the library actually selected by the loader must be recorded independently. In particular, a comparison against an ONNX client sharing the runtime is not an independent PyTorch comparison, and a cross-runtime numerical result is not a universal tolerance.

Functional tests compare results; timing and memory observations characterize a specific environment. Previous results are not performance targets and must not be extrapolated to other machines.

## Reproducible functional tests

Prepare the isolated configured build described in `INSTALL.md`. Provide `TOKENIZER_JSON` and `MODEL_ONNX` matching the hashes checked by the tests; these artifacts are external to the repository:

```bash
make -C "$build_dir/unix" TOKENIZER_JSON="$TOKENIZER_JSON" test-tokenizer
make -C "$build_dir/unix" TOKENIZER_JSON="$TOKENIZER_JSON" test-tokenizer-abi
make -C "$build_dir/unix" TOKENIZER_JSON="$TOKENIZER_JSON" MODEL_ONNX="$MODEL_ONNX" test-tokenizer-embedding
make -C "$build_dir/unix" MODEL_ONNX="$MODEL_ONNX" test-embedding-lifecycle
```

The first test validates 58 sequences, including five explicitly truncated cases, and Tcl resource handling. The second checks C ABI errors and ownership. The third tests three text-to-ONNX inputs; the fourth checks ONNX lifecycle and compares three complete vectors with a stored baseline. They need no Python at runtime. New references or models require independently identified artifacts and criteria.

For native safety tests, use a new empty temporary directory for `SAFETY_FIXTURES`; the generator refuses to overwrite existing fixture files. Python's standard library is used only to generate the synthetic test models:

```bash
python3 "$project_dir/tests/make_onnx_safety_fixtures.py" "$SAFETY_FIXTURES"
make -C "$build_dir/unix" SAFETY_FIXTURES="$SAFETY_FIXTURES" test-embedding-safety
```

## Numerical characterization against ONNX

The following laboratory-only comparison requires Python with `tokenizers==0.22.1`, a C11 compiler, and ONNX Runtime C headers and library. It does not require NumPy, Python ONNX Runtime, or Python in production. Set `project_dir`, `build_dir`, `TOKENIZER_JSON`, `MODEL_ONNX`, `TCLSH_PROG` and `LAB_PYTHON` to the repository, isolated build and identified local fixtures and interpreters. Check the tokenizer and ONNX SHA-256 hashes in `CHARACTERIZATION.md` before execution.

```bash
cc -std=c11 -O2 -Wall -Wextra -Werror $(pkg-config --cflags libonnxruntime) \
  "$project_dir/tests/onnx_reference.c" $(pkg-config --libs libonnxruntime) -lm \
  -o "$build_dir/onnx_reference"
TCLLIBPATH="$build_dir/unix" "$LAB_PYTHON" "$project_dir/tests/onnx_compare.py" \
  "$TOKENIZER_JSON" "$MODEL_ONNX" "$TCLSH_PROG" "$build_dir/onnx_reference"
```

The synthetic corpus includes multiple languages, Unicode, empty text and boundaries of 127, 128 and 129 tokens, with explicit 128-token truncation and separate no-truncation cases. Each Tcl ID sequence is checked against Python Tokenizers; inspected Tcl code constructs an all-one mask and all-zero types, which the independent C client reproduces. The C client checks the ONNX output shape and computes a double-precision mean and L2 normalization. This compares separate callers of the same runtime, not PyTorch against ONNX. It prints mean norms, maximum component differences and normalized cosine similarity. It does not expose the binding's intermediate tensor or prove parity for other inputs.

To compare complete serialized Tcl IDs and vectors across two builds, set `ONNX_COMPARISON_VECTOR_FILE` to a different external file for each run, then compare the files with `cmp` and record their hashes. Identical serialization is a same-environment observation, not a cross-platform guarantee.

The following Sentence Transformers/PyTorch reference procedure was executed in a compatible VM and its results were subsequently compared as described below. Use a modern Linux x86-64 VM with 8 GB RAM, Python 3.11, network access for preparation, and sufficient free disk for the virtual environment, cache, 471 MB weights and output. Keep `LAB_DIR`, model artifacts and output outside the repository. The direct versions below are pinned; record the complete resolved environment because transitive dependencies may differ in another VM.

```bash
set -euo pipefail
export LAB_DIR=/path/to/isolated-lab
export MODEL_DIR="$LAB_DIR/model"
export PROJECT_DIR=/path/to/tclembedding
mkdir -p "$LAB_DIR"
python3.11 -m venv "$LAB_DIR/venv"
"$LAB_DIR/venv/bin/python" -m pip install 'torch==2.8.0' --index-url https://download.pytorch.org/whl/cpu
"$LAB_DIR/venv/bin/python" -m pip install 'sentence-transformers==5.1.2' 'transformers==4.57.1' 'tokenizers==0.22.1' 'huggingface-hub==0.35.3' 'safetensors==0.6.2' 'numpy==2.2.6'
"$LAB_DIR/venv/bin/python" -m pip check
"$LAB_DIR/venv/bin/python" -m pip freeze --all > "$LAB_DIR/environment.freeze"
```

Download only the following model artifacts from the exact revision. The Hub client may create cache and download metadata; no ONNX, alternate weight format, or unrelated model files are requested. This requests the safetensors weights, not a pickle weight file.

```bash
export HF_HUB_CACHE="$LAB_DIR/hf-cache"
"$LAB_DIR/venv/bin/python" - <<'PYDL'
import os
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
    revision="e8f8c211226b894fcb81acc59f3b34ba3efd5f42",
    local_dir=os.environ["MODEL_DIR"],
    allow_patterns=["config.json", "config_sentence_transformers.json", "modules.json",
                    "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
                    "sentence_bert_config.json", "1_Pooling/config.json", "model.safetensors"],
)
PYDL
```

The listed fast-tokenizer file set and package combination are a proposal until the offline load succeeds. If a required file is missing, stop and identify it; do not silently fetch a different revision. The [official Hub weight metadata](https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2/blob/main/model.safetensors) identifies the safetensors SHA-256 as `eaa086f0ffee582aeb45b36e34cdd1fe2d6de2bef61f8a559a1bbc9bd955917b`; the scripts verify it and the known configuration/tokenizer hashes. Preserve `environment.freeze` and the model-file hashes in the export. Do not infer the provenance of the ONNX file from these weights alone.

Run the 21 synthetic inputs (the same 18 003-A conditions plus the three Slice 002 regression texts) in two clearly labeled modes: the model's verified default maximum of 128 and an aligned mode. For 003-A cases without a limit, the aligned mode explicitly uses 512, which leaves their at-most-129-token inputs untruncated; it does not claim unlimited model support. The long 602-token case is explicitly limited to 128. The exporter records expected 003-A IDs and actual Sentence Transformers IDs, masks and type IDs; differences are recorded, not hidden. It exports float32 token embeddings, pooled and `encode` embeddings without L2, and separately normalized embeddings. Python's JSON float representation round-trips each converted float32 value; shape and dtype are included.

```bash
export OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 TOKENIZERS_PARALLELISM=false
export OUTPUT_JSON="$LAB_DIR/st-reference.json"
test ! -e "$OUTPUT_JSON"
test ! -e "$OUTPUT_JSON.partial"
"$LAB_DIR/venv/bin/python" "$PROJECT_DIR/tests/st_reference.py" "$MODEL_DIR" > "$OUTPUT_JSON.partial"
"$LAB_DIR/venv/bin/python" "$PROJECT_DIR/tests/validate_st_reference.py" "$OUTPUT_JSON.partial" "$MODEL_DIR"
mv "$OUTPUT_JSON.partial" "$OUTPUT_JSON"
sha256sum "$OUTPUT_JSON" "$LAB_DIR/environment.freeze" "$PROJECT_DIR/tests/st_reference.py" "$PROJECT_DIR/tests/validate_st_reference.py" > "$LAB_DIR/sha256sums.txt"
```

The validator checks JSON completeness, 42 distinct case/mode records, file hashes, expected configurations, CPU thread counts, tensor dtype/shape and finite values. It reports ID differences but does not treat a real tokenization difference as corruption. Verify and preserve the output and manifest hashes when transferring files. The procedure was executed in the recorded VM; if an import or validation fails in another environment, retain the failure and resolve it before drawing conclusions. Compare outputs only after matching input IDs and masks. Derive numerical tolerances from measured cross-backend differences.

The procedure was subsequently run in a CPU VM, and its transferred export was compared as recorded in `CHARACTERIZATION.md`. To reproduce the comparison using that exact verified JSON as `PRIMARY_JSON` and the isolated Tcl build and ONNX model above:

```bash
cc -std=c11 -O2 -Wall -Wextra -Werror $(pkg-config --cflags libonnxruntime) \
  "$project_dir/tests/onnx_hidden_reference.c" $(pkg-config --libs libonnxruntime) -lm \
  -o "$build_dir/onnx_hidden_reference"
TCLLIBPATH="$build_dir/unix" python3 "$project_dir/tests/compare_primary.py" \
  "$PRIMARY_JSON" "$MODEL_ONNX" "$TCLSH_PROG" "$build_dir/onnx_hidden_reference" > "$build_dir/primary-results.tsv"
```

The script verifies the exact reference and ONNX hashes, rejects masks or type IDs that the binding cannot reproduce, and compares full hidden tensors, pooled values and normalized vectors. `tests/primary_comparison_results.tsv` retains the recorded per-case results. The JSON and model are external artifacts; the PyTorch model files are needed to regenerate the reference and are not included. Results can vary across hardware or runtime versions. The original JSON was validated in its source environment; local transfer checks do not independently revalidate unavailable PyTorch weights.

To repeat the explicit Tcl truncation check against the transferred 129-token reference, with the same exact JSON, tokenizer and ONNX artifacts and Python Tokenizers 0.22.1:

```bash
TCLLIBPATH="$build_dir/unix" "$LAB_PYTHON" "$project_dir/tests/compare_boundary_primary.py" \
  "$PRIMARY_JSON" "$TOKENIZER_JSON" "$MODEL_ONNX" "$TCLSH_PROG"
```

This check reconstructs the synthetic text, verifies its reference hash, calls the Tcl tokenizer with `-max-length 128`, requires identical IDs including final special ID 2, and reports maximum component error, cosine and norms against the normalized PyTorch reference. The measured values and batch-size-one coverage are in `CHARACTERIZATION.md`.

Proposed regression criteria, pending separate approval, are: require exact reference IDs, expected tensor dimensions, finite outputs and matching input masks; on the previously measured build and environment, serialize the 18-case Tcl output with `ONNX_COMPARISON_VECTOR_FILE` as above and compare its SHA-256 with `a65c2d08c270e05eae1ef27a2f0ef304d82d8292c12cca57293f436a41985e35`, investigating any difference. As an initial *diagnostic* on that environment, compare aligned normalized outputs component by component against the identified PyTorch reference using `1e-5` absolute error; the recorded maximum was `1.96218683e-7`. This candidate is not an approved general compatibility tolerance. For other CPUs, ONNX Runtime versions, reference versions or models, record component errors, norms and cosine separately and characterize the distribution before choosing or approving any numerical threshold. A high cosine alone is insufficient.

## Cloning and memory

With locked dependencies already cached, build and run the included diagnostic:

```bash
cargo build --offline --locked --release --example clone_probe --manifest-path "$project_dir/tokenizer-native/Cargo.toml"
/usr/bin/time -f 'peak_rss_kib=%M' "$CARGO_TARGET_DIR/release/examples/clone_probe" "$TOKENIZER_JSON" direct
/usr/bin/time -f 'peak_rss_kib=%M' "$CARGO_TARGET_DIR/release/examples/clone_probe" "$TOKENIZER_JSON" clone
```

The program loads one tokenizer, warms it up, then measures ten iterations of `hola` with and without cloning. It verifies IDs and shows minimum, median and maximum; `/usr/bin/time` reports whole-process peak RSS. Run modes in separate processes. The comparison includes cache and clone destruction effects and does not isolate copying alone. Prior measurements in `CHARACTERIZATION.md` are not guarantees for another environment.

For memory checks, compare a baseline with the same Tcl and interpreter count against load, use, free and teardown scenarios. Retain tool options and summaries, distinguish definite and possible losses and reachable memory, and inspect traces before assigning causes. A bounded successful-model Valgrind run is documented in `CHARACTERIZATION.md`; it does not establish leak freedom for other inputs or conditions.

For the recorded MiniLM single-inference scenario, with `MODEL_ONNX`, `TCLSH_PROG` and `build_dir` set as above:

```bash
TCLLIBPATH="$build_dir/unix" MODEL_ONNX="$MODEL_ONNX" valgrind --vgdb=no \
  --leak-check=full --show-leak-kinds=definite,indirect,possible \
  --errors-for-leak-kinds=definite,indirect --error-exitcode=42 "$TCLSH_PROG" <<'TCL'
if {[catch {
    package require tclembedding
    set h [embedding::init_raw $::env(MODEL_ONNX)]
    if {[llength [embedding::compute $h {0 739 143 2}]] != 384} {error "wrong dimension"}
    embedding::free $h
} message]} {puts stderr $message; exit 1}
TCL
```

The corresponding baseline loads the package in the same Tcl environment without initializing a session. `--errors-for-leak-kinds` excludes possible losses from the error exit status; inspect them separately.

The repeated-inference preparation used the same options and model, replacing the single call with the following loop before freeing the same handle:

```tcl
for {set i 0} {$i < 20} {incr i} {
    if {[llength [embedding::compute $h {0 739 143 2}]] != 384} {error "wrong dimension"}
}
```

The resulting measurements and their limits are recorded in `CHARACTERIZATION.md`.

## Evidence to retain

Record the tested tree or commit, compiler and flags, Tcl, Rust, Tokenizers and ONNX Runtime, architecture, OS and CPU, model and tokenizer hashes, synthetic inputs, padding and truncation settings, individual results and measurement methods. Describe cache, warmup and concurrency conditions. Keep private data and extensive logs out of public deliverables.

## Slice 004-A build audit

The former direct-template Linux procedure was exercised with a fresh Cargo target directory, a prepopulated source cache and `CARGO_NET_OFFLINE=true`. Set both `CC` and `CXX` to usable compilers if wrapper caches are unavailable. An empty Cargo cache cannot supply the locked crate sources offline. The dedicated tests in the first section passed for the artifacts and environment recorded in `CHARACTERIZATION.md`; at that time the root template had no `test` target and the Unix template's legacy generic `test` required a different fixed-path model. Slice 004-B3 replaces that entry point; see `INSTALL.md`.

At the time of the audit, the normal `configure` route was not functional as supplied. `autogen.sh` was run only in an isolated copy of the configuration templates: `install-sh` was missing and, with a temporary placeholder used for diagnosis, the unexpanded TEA macro caused a syntax error. Do not interpret the placeholder as an installation fix. The subsequent 004-B1 configured path and genuine auxiliary installer are described in `INSTALL.md`.

The 004-A installation observation used an explicit single directory as `TCL_PACKAGE_PATH`; it did not verify `configure --prefix`. The then-current Tcl list-form path produced unsafe split destinations in a dry run. The later 004-B1 policy no longer derives installation destinations from `TCL_PACKAGE_PATH`; use the configured, isolated procedure in `INSTALL.md`. Neither test demonstrates isolation from system Tcl or ONNX Runtime libraries.


## Reproducing the 004-B2 source snapshot experiment

Review the working tree first, including non-ignored untracked files, and verify that no private material, symlinks or compiled artifacts are among the files to copy. The following standard-library Python helper was used only for laboratory snapshot preparation; Python is not a production dependency. Set `PROJECT_DIR` to the current source tree and `SNAPSHOT_DIR` to a new temporary directory outside that tree. The helper refuses an existing destination, skips tracked paths deleted from the working tree, rejects symlinks, and writes a SHA-256 manifest outside the copied source directory. Ignored files are not automatically included; review whether any are needed rather than copying them blindly. This method is a local working-tree experiment, not an approved release packaging procedure.

```bash
python3 - <<'PY'
import hashlib, os, pathlib, shutil, subprocess
src = pathlib.Path(os.environ['PROJECT_DIR']).resolve()
root = pathlib.Path(os.environ['SNAPSHOT_DIR'])
root.mkdir(exist_ok=False)
dst = root / 'source'
dst.mkdir()
names = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=src)
entries = []
for raw in names.split(b'\0'):
    if not raw:
        continue
    relative = pathlib.Path(os.fsdecode(raw))
    source = src / relative
    if source.is_symlink():
        raise RuntimeError('symlink: ' + str(relative))
    if not source.exists():
        continue
    if not source.is_file():
        raise RuntimeError('not a regular file: ' + str(relative))
    target = dst / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    entries.append(hashlib.sha256(source.read_bytes()).hexdigest() + '  ' + str(relative))
(root / 'sources.sha256').write_text('\n'.join(entries) + '\n')
PY
(cd "$SNAPSHOT_DIR/source" && sha256sum -c ../sources.sha256)
```

Create a separate empty build directory and a fresh `CARGO_TARGET_DIR`, then use the configured out-of-tree commands in `INSTALL.md` with `project_dir="$SNAPSHOT_DIR/source"`, `CARGO_NET_OFFLINE=true` and a prepared `CARGO_HOME`. Keep the TEA directory, crate cache and external Tcl/ONNX installation identified separately. Inspect the install directory and dry run before installation; run the dedicated tests from the generated Unix makefile and repeat applicable Tcl tests with only the installed directory in `TCLLIBPATH`. Record versions, fixture hashes, package loader paths and results. The tested 004-B2 environment and limitations are in `CHARACTERIZATION.md`.


## Slice 006-A truncation measurements

The observations in `CHARACTERIZATION.md` used separate foreground runs for each path, one load and one warmup per process, followed by ten timed calls on the same tokenizer. `TOKENIZERS_PARALLELISM=false` was set. Tcl timings used `clock microseconds`; process peak RSS used `/usr/bin/time` and includes loading, warmup and all calls. Short input was `hola`; long input was `[string repeat {hola } 80]`. Record input and output ID counts, median, minimum, maximum, load time, peak RSS, tokenizer SHA-256, toolchain versions and machine conditions. Do not interpret peak RSS as proof of leak freedom. The CPU frequency was not controlled and the ten-call samples are exploratory.

The existing `clone_probe` command above reproduces the historical direct-versus-clone comparison. For the Tcl path, a controlled short-input sample can be obtained from an isolated build with the identified tokenizer fixture:

```bash
TCLLIBPATH="$build_dir/unix" TOKENIZER_JSON="$TOKENIZER_JSON" \
TOKENIZERS_PARALLELISM=false /usr/bin/time -f 'peak_rss_kib=%M' "$TCLSH_PROG" <<'TCL'
package require tokenizer 1.0.0
set t [clock microseconds]
tokenizer::load_vocab $::env(TOKENIZER_JSON)
puts [list load_ms [expr {([clock microseconds]-$t)/1000.0}]]
set text hola
set options {-max-length 128}
set expected [tokenizer::tokenize $text {*}$options]
set samples {}
for {set i 0} {$i < 10} {incr i} {
    set t [clock microseconds]
    set ids [tokenizer::tokenize $text {*}$options]
    lappend samples [expr {([clock microseconds]-$t)/1000.0}]
    if {$ids ne $expected} {error "inconsistent IDs"}
}
set samples [lsort -real $samples]
puts [list min_ms [lindex $samples 0] median_ms [expr {([lindex $samples 4]+[lindex $samples 5])/2.0}] max_ms [lindex $samples 9]]
tokenizer::free
TCL
```

Repeat in separate runs with `options {}` and with the long synthetic text above. The 006-A research prototype and its measurement scripts are laboratory artifacts outside the repository; the experiment is not a production implementation. The Rust experiment separately timed load, clone plus destruction, configuration plus reset, and encoding. A later proposal should require exact 58-case IDs, 129-to-128 boundary and terminator preservation, default and alternating limits, error and lifecycle equivalence, restoration under injected errors and unwinding, independent interpreters and appropriate concurrency checks. Measure multiple fresh runs on the same environment before agreeing performance and peak-memory criteria; investigate regressions on the default path. Any thresholds or wider model support remain subject to separate review.


## Slice 006-B verification and performance protocol

The full `make test` now includes `test-tokenizer-rust`; it requires the hash-identified tokenizer fixture. Alternatively run the Rust tests explicitly with `TOKENIZER_JSON` set:

```bash
TOKENIZER_JSON="$TOKENIZER_JSON" CARGO_NET_OFFLINE=true \
  cargo test --release --locked --offline --manifest-path "$project_dir/tokenizer-native/Cargo.toml"
```

For the measurements in `CHARACTERIZATION.md`, the following Tcl probe was run for both the previous and new libraries, default and `-max-length 128`, and short and long synthetic text. Set the paths to the two isolated builds, fixture and Tcl interpreter before running:

```bash
for build in "$before_build" "$after_build"; do
  for mode in direct-short limit-short direct-long limit-long; do
    for run in 1 2 3 4 5; do
      TCLLIBPATH="$build/unix" TOKENIZERS_PARALLELISM=false \
        /usr/bin/time -f 'peak_rss_kib=%M' "$TCLSH_PROG" \
        "$project_dir/tests/tokenizer_perf.tcl" "$TOKENIZER_JSON" "$mode"
    done
  done
done
``` Each of the eight conditions used five independent processes and ten timed calls per process after a warmup. Report the median and range of process medians and the largest process peak RSS; the threshold comparison is specific to the measured environment. Keep CPU load and frequency conditions visible; the observed frequency was not fixed. The default path must be examined independently. Preserve the exact fixture hash and binary versions when repeating.

The numerical regression used the 18-case serialized Tcl output and the previously transferred 42-record PyTorch reference, not a new PyTorch execution. The former retained SHA-256 `a65c2d08c270e05eae1ef27a2f0ef304d82d8292c12cca57293f436a41985e35`; the comparison table was byte-identical to the previously recorded table. Repeat the existing procedures above with the same external fixtures and retain their provenance and environment. This does not establish equivalence for arbitrary models, concurrency or padding.

## Slice 007-B exploratory four-model measurements

The four-model measurements used one process per model on Linux x86-64, ONNX Runtime C 1.20.1 with one inference thread, one warmup and five timed calls per short synthetic text. MiniLM used explicit 128-token truncation, BGE used CLS and the other models used mean; L2 remained enabled. Session-load times were 1822.629, 547.872, 1759.996 and 1668.512 ms for MiniLM, BGE, E5 and MPNet respectively. Short-case median inference times were 26.120, 40.530, 40.558 and 154.255 ms; process peak RSS was 1235968, 263180, 1214548 and 817644 KiB respectively. These are single-process observations, include differing tokenizer and model memory, and do not establish general performance or memory safety. CPU frequency and operating-system caches were uncontrolled.


## Slice 008 — exploratory batch measurements

In one process per condition on an AMD Phenom II X4 965, Linux x86-64, with ONNX Runtime C 1.20.1 and one inference thread, each measurement used one warmup and the median of three timed calls, two sequences per batch. CPU frequency and OS caches were not controlled. Equal-length cases repeated the same synthetic sequence; unequal cases used shorter and longer sequences. E5 used explicit query and passage prefixes. The values include inference and Tcl result construction, not model load; RSS is the process peak including the loaded model. They are observations, not general performance guarantees. These timings preceded the subsequent actual-output-shape guard described in `CHARACTERIZATION.md`; the guard was not separately benchmarked.

| Model | Lengths | Individual total ms | Batch total ms | Individual seq/s | Batch seq/s | Individual/batch peak RSS KiB |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| MiniLM | 11, 11 | 92.614 | 73.199 | 21.60 | 27.32 | 888448 / 888256 |
| MiniLM | 11, 2 | 66.919 | 73.298 | 29.89 | 27.29 | 888444 / 888320 |
| BGE | 13, 13 | 102.493 | 83.513 | 19.51 | 23.95 | 253968 / 254260 |
| BGE | 13, 2 | 70.023 | 83.488 | 28.56 | 23.96 | 254064 / 253972 |
| E5 | 11, 11 | 91.327 | 72.775 | 21.90 | 27.48 | 885232 / 885276 |
| E5 | 11, 9 | 86.462 | 73.131 | 23.13 | 27.35 | 885236 / 885528 |
| MPNet | 13, 13 | 385.287 | 313.055 | 5.19 | 6.39 | 806912 / 807036 |
| MPNet | 13, 2 | 267.220 | 312.076 | 7.48 | 6.41 | 806920 / 807052 |

Per-sequence latency is half the total in these two-sequence tests. Unequal batches process `2 * max(length)` padded positions: 22 versus 13 actual for MiniLM, 26 versus 15 for BGE and MPNet, and 22 versus 20 for E5. Padding caused slower batch totals for the strongly unequal cases; E5's near-equal batch was faster in this observation.

To reproduce with identified local fixtures and explicit synthetic token IDs, build the extension and run `tests/embedding_batch_bench.tcl` in a fresh process. Its arguments are `model.onnx pad_id mean|cls single|batch`; provide one line on stdin with sequences separated by semicolons and IDs separated by spaces. Set `TCLLIBPATH` to the isolated build directory. Use `/usr/bin/time -f '%M'` around each separate process for peak RSS. Compute throughput as `sequence_count * 1000 / median_total_ms`. The separate `tests/onnx_batch_reference.c` accepts the same input line with arguments `model.onnx pad_id dimension mean|cls input_count`; it calls ONNX Runtime separately and calculates masking and pooling independently of the binding. Neither client proves PyTorch parity by itself.

To build the separate C reference on the tested Unix setup:

```bash
cc -std=c11 -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -Werror \
  $(pkg-config --cflags libonnxruntime) tests/onnx_batch_reference.c \
  $(pkg-config --libs libonnxruntime) -lm -o "$build_dir/onnx_batch_reference"
```

The four-model numerical and performance experiments used batches of at most two sequences; three-row padding and stride are covered separately by the synthetic batch fixture.

The standalone `make test-embedding-batch` target uses generated synthetic fixtures and does not require an external model. The existing full `make test` still requires the identified tokenizer and MiniLM ONNX fixtures for its pre-existing integration and lifecycle regressions; they are not downloaded by the test harness.
