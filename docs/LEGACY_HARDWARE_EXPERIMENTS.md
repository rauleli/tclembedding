# Legacy-hardware evidence for local RAG

This document preserves the continuity of experimental results, including
failures, alongside the code and the conditions under which results were
observed. It is a technical record, not a claim of general accuracy or speed.
The historical experiments are identified by their existing public documentation
or by preserved synthetic outputs; new observations are identified separately.
No private conversations or attachments are part of this record.

## Environment and constraints

The evaluated host runs Fedora Linux 43, kernel 7.2.11-100.fc43.x86_64, on an
AMD Phenom II X4 965: four logical CPUs and one thread per core. The visible
flags include SSE, SSE2, SSE3 (`pni`) and SSE4a, but not AVX, AVX2 or SSE4.1.
SSE4a is not SSE4.1. It has about 31 GiB RAM and 93 GiB swap; approximately
20 GiB RAM was available and swap unused before the new experiments. The model
store filesystem reported approximately 898 GiB free. These are snapshots,
not minimum requirements. Ollama 0.15.6, Tcl 8.6.14, rl_json 0.15.7 and Tcl
SQLite 3.45.2 were used. The selected local embedding installation is
Tokenizers Rust 0.23.2 and ONNX Runtime 1.31.1 as characterized in `INSTALL.md`.
The ONNX inference path was CPU; Ollama reported 100% CPU for the observed
loaded models. GPU availability in other configurations was not evaluated.

The generation models and their quantization, as reported locally, are
`llama3.2:3b` (3.2B, Q4_K_M), `qwen3:1.7b` (2.0B, Q4_K_M), and
`phi4-mini:3.8b` (3.8B, Q4_K_M). The latter two were made available using their
exact authorized tags; Ollama reported SHA-256 verification. Their published
Ollama catalog entries report approximately 1.4 GB and 2.5 GB respectively:
[qwen3:1.7b](https://ollama.com/library/qwen3:1.7b) and
[phi4-mini:3.8b](https://ollama.com/library/phi4-mini:3.8b). Phi's catalog
states a minimum Ollama version of 0.5.13. Qwen3 advertises a thinking mode;
this experiment does not disable it or equate internal reasoning with a final
answer.

## Continuity of prior results

- Example 04-A tested the local HTTP transport with `gemma3:1b`; a synthetic
  source produced a valid `[S1]` citation in approximately 9.5 s. Other real
  end-to-end runs lacked citations and were rejected. Their termination details
  were not fully retained. See [Example 04 README](../examples/04-end-to-end-rag/README.md).
- Example 04-B separated retrieval, selection, citation validity, grounding,
  correctness and abstention. With `gemma3:1b`, an original prompt produced no
  citation (47.0 s), while an explicit citation instruction produced a formally
  cited but contradictory response (32.2 s). A separate real E5-to-SQLite-to-
  Ollama synthetic case succeeded, but did not prove general grounding. See
  [the evaluation protocol](../examples/04-end-to-end-rag/EVALUATION.md).
- Example 04-C initially received HTTP 500 for the full structured schema. The
  journal reported an excessive grammar-repetition limit; adding only
  `maxLength: 4096` to a working three-field schema reproduced the failure.
  The generation schema subsequently omitted that keyword while the local Tcl
  validator retained the 4096-unit limit. Three subsequent `gemma3:1b` cases
  returned JSON with empty citations and were rejected; one invented a closing
  time and another ignored contradictory evidence. Their observed times were
  42.578, 40.061 and 21.813 s. See [the structured contract](../examples/04-end-to-end-rag/STRUCTURED.md).
- Preserved synthetic outputs from a subsequent local comparison recorded
  `llama3.2:3b`, `gemma3:4b` and `qwen2.5:1.5b` as structurally and factually
  correct for one explicit fact at temperature zero (141.692, 159.820 and
  70.846 s respectively). `llama3.2:3b` also abstained correctly for missing
  and contradictory evidence (75.480 and 98.112 s). These are individual
  observations, not a statistical benchmark. The previously published 04-C
  `gemma3:1b` runs used default sampling, so they are not a controlled baseline
  for that comparison.

## New experiment protocol

Source revision: `004310117a13368f3da9124cb632d2531539e50b`. The 200-record
synthetic JSONL v2 corpus SHA-256 is
`70ade3bb43add618812b62b83582d8279d702ac2d2e4e08c0b5c839ec3a92f57`; the
corresponding L2E1 SHA-256 is
`e2a5893f8924223358c211ebc7bee9debbd70b1ba4d7fa38d0792673c3463938`.
The E5 ONNX SHA-256 is
`ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665`, and its
tokenizer SHA-256 is
`0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39`.
See [SQL benchmark methodology](SQL_BENCHMARK.md) for their prior provenance.

The end-to-end case was fixed before execution: ask “What is the subject of
these documents?”, use top-k 1 and a 1000-Tcl-unit context limit, and check that
the returned evidence actually supports the generated answer and its selected
citation. The anticipated synthetic subject is maintenance and recovery. The
query is embedded with E5, retrieved by SQLite and the L-3 native extension,
and supplied to `llama3.2:3b` through structured-v1. The three fixed model-only
cases from 04-C ask about an explicit opening time, an absent closing time, and
conflicting opening times. Both additional models receive the same cases,
prompt, schema, selected sources, temperature 0 and `num_predict=192`. Each
request has a 600-second HTTP deadline and there are no automatic retries.
The model's default thinking configuration is not changed.

The transport and local structural validator are unchanged. A structurally
valid declaration is not a semantic judgment. All semantic assessments below
are case-specific reviews against the synthetic sources. RSS is sampled every
five seconds from the Ollama server and runners; sampled maxima are not proven
process peaks. The runner figure can include more than one resident runner.
One observation per case cannot support percentiles or general performance
claims. Loading, cache state and other local workloads were not controlled.

## New end-to-end observation

The query retrieved sequence 132 with score `0.7938556113748525`. Its exact
synthetic text was “Synthetic document 132. Una frase breve sobre mantenimiento
y recuperación. ” Source and provenance were the synthetic input identifier,
conversation `c`, node `n132`, message `m132`, user role, position 132, null
original timestamp, part 0, fragment 0 and Tcl-character range `[0,76)`.
The query used the corpus SHA above and model `intfloat/multilingual-e5-small`.
Retrieval and embedding took 10.429 s as observed by this driver; this includes
startup and artifact validation rather than isolated inference alone.

`llama3.2:3b` (digest
`a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72`)
returned HTTP 200, `done_reason=stop` and a locally accepted `answered` result:
“The subject of these documents appears to be maintenance and recovery.” with
`S1`. This matches the selected synthetic source. External elapsed time was
161.917 s; the server reported total 161.914 s, load 20.209 s, prompt evaluation
109.590 s for 140 tokens and generation 30.776 s for 31 tokens. Server times
are converted from the nanosecond values retained in the observation file.

The author additionally authorized one repeat after the experiment's
other resident runners were unloaded; no model was deleted and the service was
not restarted. This repetition was an eighth generation
request in addition to the seven originally planned. The same fragment and identical structured content were observed
and accepted. Retrieval took 10.584 s and the generation request 144.442 s;
server-reported total was 144.439 s, load 3.630 s, prompt evaluation 108.838 s
for 140 tokens and generation 30.654 s for 31 tokens. Before the first request,
the sampled aggregate runner RSS was 3,050,352 KiB and during it the sampled
maximum was 5,701,616 KiB. Before the repeated request no runner was observed;
the sampled maximum was 2,628,036 KiB. These are snapshots and aggregated sampled
maxima, not proof of a causal performance difference or an absolute peak.

## New model-only observations

All six requests returned HTTP 200, `done_reason=stop`, and structured results
accepted by the local validator. The last column is a fixture-specific semantic
assessment; acceptance is not a general grounding guarantee.

| Model | Case | External time | Sampled runner RSS max | Output and fixture assessment |
|---|---|---:|---:|---|
| qwen3:1.7b | Explicit fact | 227.764 s | 6,736,456 KiB | `answered`, “9”, S1; matches source |
| qwen3:1.7b | Missing fact | 147.126 s | 4,581,500 KiB | `abstained`, “Unable to determine”, S1; appropriate but terse |
| qwen3:1.7b | Contradiction | 155.357 s | 1,993,720 KiB | `abstained`, “Unable to determine”, S1 and S2; appropriate but does not explain the conflict |
| phi4-mini:3.8b | Explicit fact | 146.961 s | 5,133,340 KiB | `abstained`, “Insufficient or contradictory information provided”, S1; inappropriate because the fact is present |
| phi4-mini:3.8b | Missing fact | 68.452 s | 5,286,664 KiB | `abstained`, no citations; correctly notes the closing time is absent |
| phi4-mini:3.8b | Contradiction | 89.462 s | 5,369,384 KiB | `abstained`, S1 and S2; appropriate but does not describe the differing times |

These RSS values sum resident Ollama runner processes at each sample; several
models were resident at some points. Server and runner before, sampled maximum,
and after values are retained independently in the observation file. The
sampled maximum excludes a separate final sample and is not an absolute peak.
No claim is made that memory was exclusively attributable to the queried model.

The exact locally observed model digests were
`8f68893c685c3ddff2aa3fffce2aa60a30bb2da65ca488b61fff134a4d1730e7` for
`qwen3:1.7b` and
`78fad5d182a7c33065e153a5f8ba210754207ba9d91973f57dffa7f487363753` for
`phi4-mini:3.8b`. Qwen responses included a separate thinking field in this
Ollama configuration; thinking was not switched off. The public observations
record only its presence, not its content.

## Mistral 7B synthetic structured responses

The locally installed `mistral:7b-instruct` model was identified by digest
`f974a74358d62a017b37c6f424fcdf2744ca02926c4f952513ddf474b2fa5091`,
4,113,301,824 bytes, 7.2B parameters and Q4_0 quantization. Ollama 0.15.6
reported CPU execution. The host had approximately 23 GiB available RAM and
zero swap in use before the run; no Ollama runner was resident. No model was
downloaded. The same 04-C prompt, three fixtures and validator were used with
temperature 0, `num_predict=192` and a 900-second HTTP deadline per request.
There were no retries.

| Case | HTTP / termination | Local result | Fixture assessment | External time |
|---|---|---|---|---:|
| Explicit | 200 / stop | `answered`, S1 | Correct: the source says 9 | 337.897 s |
| Absent | 200 / stop | `abstained`, S1 | Appropriate; identifies the missing closing time | 181.224 s |
| Contradiction | 200 / stop | `abstained`, S1 and S2 | Appropriate; identifies unresolved conflicting sources | 218.974 s |

The server reported, respectively, load times of 33.197, 0.048 and 0.039 s;
prompt evaluation of 242.992, 54.814 and 92.434 s; and generation of 61.442,
125.805 and 125.885 s. These are conversions from the retained nanosecond
measurements, not independently measured stages. Across the sampled runs,
aggregate runner RSS reached 4,680,136 KiB; sampled host available memory
remained at least 20,187,168 KiB and sampled swap use was zero. Samples were
taken every five seconds and do not establish absolute maxima or minima. The
model was warm for later cases; cache and loading differences prevent simple
latency attribution.

The earlier `llama3.2:3b` cases were favorable on the same three fixtures;
`gemma3:4b` and `qwen2.5:1.5b` were assessed only on the explicit fixture.
`qwen3:1.7b` also answered the explicit case and abstained on both others;
`phi4-mini:3.8b` unnecessarily abstained on the explicit case. These observations
are individual trials, not a ranking, and do not isolate size, model design,
quantization, hardware instruction sets or cache state as causes.

## DeepSeek R1 7B synthetic structured responses

The additional locally installed `deepseek-r1:7b` has digest
`0a8c266910232fd3291e71e5ba1e058cc5af9d411192cf88b6d30e92b6e73163`,
7.6B parameters and Q4_K_M quantization. It was not downloaded. The same
three fixtures, prompt, validator, temperature 0, `num_predict=192` and
900-second deadline were used once each. Its default reasoning configuration
was not changed. Mistral was initially still resident; the aggregated RSS
figures therefore cannot be attributed to DeepSeek alone.

| Case | HTTP / termination | Local result | Fixture assessment | External time |
|---|---|---|---|---:|
| Explicit | 200 / stop | `answered`, S1 | Correct: the source says 9 | 310.393 s |
| Absent | 200 / stop | `answered`, S1 | Incorrect: invented a 5 PM closing time | 126.571 s |
| Contradiction | 200 / stop | `answered`, S1 | Incorrect: chose 9 without resolving the conflict | 154.847 s |

The latter two demonstrate why selected source identifiers and valid JSON do
not establish semantic grounding. The maximum aggregate runner RSS sampled in
the first case was 9,744,556 KiB while another runner was resident. The minimum
sampled available memory was 15,046,924 KiB and the maximum sampled swap use
was 256 KiB. Five-second sampling does not establish absolute peaks.

## GPT-OSS 20B: one synthetic structured response

The locally installed `gpt-oss:20b` had digest
`f2b8351c629c005bd3f0a0e3046f905afcbffede19b648e4bd7c884cdfd63af6`,
13,780,173,839 bytes, 20.9B parameters and MXFP4 quantization. It was not
downloaded. One explicit-fact fixture used the same structured-v1 prompt,
temperature 0 and `num_predict=192`, with a 1200-second HTTP deadline. Its
default reasoning configuration was not changed. Ollama reported CPU execution.

The response was HTTP 200, `done=true`, `done_reason=stop`, locally valid:
`{"status":"answered","answer":"The workshop opens at 9.","citations":["S1"]}`.
This fact and citation match the synthetic source. The observed request time
was 506.653 s. The server reported total 506.650 s, load 101.904 s, prompt
evaluation 3.178 s for 289 tokens and generation 34.820 s for 23 tokens;
these reported components do not sum to the total, and the remainder has not
been attributed. One case cannot establish general semantic quality.

The sampled runner RSS maximum was 13,949,532 KiB; the independent final sample
was 13,949,536 KiB. The minimum sampled available memory was 14,281,388 KiB.
Swap use was 4,481,844 KiB before and reached 4,481,936 KiB in the samples.
In 98 separate one-second system samples, swap input was zero and swap output
was nonzero once, at 68 KiB/s; these host-wide samples are not attributable
solely to one process and do not establish absolute peaks. The model's separate
thinking field was present and is not included in the public observation.

## Observation format and reproduction

[Sanitized synthetic observations](legacy_hardware_observations.jsonl) contain
one JSON object per request. `origin` distinguishes new observations, the
requested integration repetition, and prior retained synthetic outputs plus
the earlier report. Each contains the synthetic request and final response,
model identity and available Ollama metrics. New records additionally contain
HTTP status, local structural result, source evidence, elapsed milliseconds,
and RSS snapshots in KiB. Ollama duration fields retain their original
nanosecond units; token counts retain their original units. The separate thinking
content is intentionally omitted; `thinking_present` records whether it was
returned. No system logs, local paths, credentials or private corpus are
included. `diagnostic=accepted` concerns structure only; the judgments above
are separate human evaluations of these fixed fixtures.
The SHA-256 of the original 13-record prefix is
`22334339b9d8bf892329f362d49be4b96e9c574f6b6c4ff5d96dd695f3b7d332`.
After adding the seven observations above, the complete 20-record file SHA-256 is
`89eafb1156d8f53517897d7e2c51491e2254a9a2cd17756726b69fd03d6afb17`.
Run `tclsh examples/04-end-to-end-rag/legacy_observations_test.tcl` to check the
JSONL, common request settings and local structural outcomes without generation.

To reproduce the later synthetic 7B comparisons with local artifacts, run
`tclsh examples/04-end-to-end-rag/mistral_experiment.tcl /path/outside/repository/results.jsonl`
for Mistral, or append `deepseek-r1:7b` for the three DeepSeek cases. Append
`gpt-oss:20b` to run only the explicit-fact GPT-OSS case. The output file must
not exist. These commands do not download models. The script checks each
locally observed digest; a different artifact is an error and requires a new
characterization rather than a silent substitution.

Prepare a verified synthetic 200-record database using Example 03's fixture and
embedding procedures in [the pipeline](../examples/03-chatgpt-export/EMBEDDING_PIPELINE.md)
and [SQL retrieval instructions](../examples/03-chatgpt-export/SQL_RETRIEVAL.md).
Supply a locally built L-3 SQLite extension and the exact E5 artifacts. With
Ollama and the three named models already available, run:

```sh
tclsh examples/04-end-to-end-rag/legacy_experiment.tcl \
  /path/to/synthetic.sqlite3 /path/to/similarity.so /path/to/e5.onnx \
  /path/to/tokenizer.json /path/outside/repository/observations.jsonl
```

Configure the Tcl package search path and ONNX Runtime as in `INSTALL.md`.
The output file must not exist. To run only the end-to-end case, append
`integration-only`; a new output file is still required. The script contacts
only the local Ollama service, does not pull models, and uses the existing
structured-v1 prompt and validator. The external file contains raw synthetic
server responses, potentially including the model's thinking field; review and
sanitize before any publication. Exact vector-file hashes may differ when the
runtime, dependencies or generated inputs differ; check identity before making
numerical comparisons.

## Future cross-generation characterization

Repeat applicable synthetic library experiments across SSE2-only CPUs, CPUs
with AVX, AVX2 and AVX-512, NVIDIA GPUs using CUDA, and ARM-based Jetson Orin.
These are future test targets, not claims of current platform support. Preserve
successful and unsuccessful observations, including resource-constrained
configurations and the minimum resources observed in each tested environment.
The Phenom II results are the historical reference, not a universal performance
target or a stated minimum supported hardware specification.

For each environment, record the Git revision, actual CPU instruction flags,
CPU and GPU configuration, operating system, runtime and dependency versions,
execution provider, model artifacts and digests, quantization, numerical
results, memory consumption, latency, throughput and observed failures. Report
thread counts, CPU allocation, model residency, cache state, RAM and swap when
relevant. Identify CPU-only and GPU-accelerated runs separately.

Use the same inputs, models and configuration when feasible. Record differences
in software, model quantization, execution providers and runtime settings before
comparing results. A timing difference alone cannot establish its cause without
an experiment isolating the relevant variable. Library hardware characterization
is independent of application-specific RAG behavior and does not require a
particular generative runtime. No concurrency, large-corpus scalability,
portability or universal hardware compatibility is established by this record.
