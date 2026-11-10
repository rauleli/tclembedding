# Optional structured answers: structured-v1

This is an additional Tcl entry point. Existing `rag.tcl` and its text-mode
validator, retrieval contracts, source selection and SQL backends are unchanged.
`structured.tcl` reuses the same retrieval, context construction, loopback HTTP
transport and local model checks. It never generates if no evidence is selected.
It displays selected source rows and corpus identity from retrieval, not from
model output. The generator's citations identify sources as a whole; they do
not assign an individual claim to a source.

## Contract

The local contract identifier is `structured-v1`; it is not a model-generated
field. The request contains this **generation schema** in the Ollama `format`
field. The local validator is authoritative and additionally imposes rules
that this schema does not fully express:

```json
{"type":"object","properties":{"status":{"type":"string","enum":["answered","abstained"]},"answer":{"type":"string","minLength":1},"citations":{"type":"array","maxItems":32,"uniqueItems":true,"items":{"type":"string","pattern":"^S[1-9][0-9]{0,2}$"}}},"required":["status","answer","citations"],"additionalProperties":false}
```

All three fields are required and non-null; duplicate top-level keys, including
escaped equivalents, are rejected. `answer` must contain non-whitespace text and
is limited locally to 4096 Tcl string units. The transmitted schema deliberately
does not include a maximum answer length; the local limit remains mandatory.
Tcl 8.6 units may differ from Unicode scalar values for supplementary characters.
UTF-8 and escaped Unicode are supported, without a grapheme-count promise.
Citations must be distinct and belong to the actual selected IDs.
`answered` requires at least one citation; `abstained` may have none. Bracketed
references such as `[S1]` inside `answer`, if present, must also occur in the
citation array. Other textual citation formats are not interpreted.

The generation schema is a constrained decoding aid, not an authority. It omits
the maximum answer length, does not require citations for `answered`, cannot
restrict IDs to the actual selected sources, and does not check whitespace-only
text or references embedded in the answer. Local validation applies all of
these requirements independently;
it also checks assistant role, completed response and rejects `done_reason=length`.
A rejected output or failed transport raises an error; neither becomes an
abstention and no citation is supplied by the application. JSON object keys in
the structured model content are checked for duplicates before `rl_json`
normalizes them. This is not a general JSON Schema validator. Response-envelope
parsing uses `rl_json` and its normal duplicate-key behavior.

```json
{"status":"answered","answer":"The workshop opens at 9.","citations":["S1"]}
{"status":"abstained","answer":"The evidence is insufficient.","citations":[]}
```

`answered` and `abstained` are declarations from the model; `invalid` is a
local validation outcome, never a model status. A valid abstention may still
contain false claims. A valid answer with selected citations may still be false
or cite irrelevant sources. No semantic verification is performed during CLI
execution: it displays `semantic_evaluation not_determined`. An optional future
per-claim contract could associate claims with sources, but would require its own
design, validation and authorization. Evidence remains untrusted data in the
user message; this separation is not a guarantee against prompt injection.

## Use

An optional final `think-mode` argument accepts `default` or `off`. The default
omits the `think` field and preserves the existing request. `off` sends a
top-level JSON boolean `think: false`; select it explicitly only for a model
and Ollama version that support the field. This setting does not change the
prompt, generation schema, token limit, sampling options or validator. An error
or an invalid result remains an error, and no fallback or retry is performed.
Changing the mode changes the experimental conditions; record it with the
result rather than combining it with default-thinking observations.

Use the same arguments as `rag.tcl`, selecting the separate entry point. For
example, with a prepared synthetic SQLite database and explicitly trusted L-3
extension:

```sh
tclsh examples/04-end-to-end-rag/structured.tcl sqlite-native '/path/to/corpus.sqlite3 /path/to/similarity.so' CORPUS_SHA256 /path/to/e5.onnx /path/to/tokenizer.json 'What is the procedure?' 3 12000 11434 MODEL_NAME 256 120000
```

SQLite scalar and MySQL targets work as in the existing README. The context
limit remains a count of Tcl string units, not generator tokens. The selected
model must already be locally available; there is no model download or fallback
to unstructured text. The server's reported model metadata is not a network
isolation guarantee. Use only a server and data you trust.

## Tests and observed compatibility

`tclsh examples/04-end-to-end-rag/structured_test.tcl` tests valid and invalid
structures, JSON and Unicode, citations, abstention declarations, hostile
source isolation, truncation and simulated transport failures. Its semantic
fixture labels are independently predetermined, not computed from model output.
The complete synthetic E5 and SQLite-native path can be checked with:

```sh
tclsh examples/04-end-to-end-rag/structured_integration_test.tcl /path/to/synthetic.sqlite3 /path/to/similarity.so /path/to/e5.onnx /path/to/tokenizer.json FRAGMENT_SHA256
```

This uses a simulated generator. `structured_experiment.tcl` contains three
fixed real Ollama cases: explicit answer, missing fact and conflicting evidence;
it uses `gemma3:1b`, `num_predict=192`, the server's default sampling parameters,
and no retry. It sends no real conversations.

A previous, separate minimal-schema experiment against local Ollama 0.15.6 and
`gemma3:1b` returned HTTP 200 and a JSON value independently validated in Tcl.
For the original structured-v1 generation schema, the three fixed cases returned
HTTP 500 without generated output. A bounded diagnostic reproduced the failure
when `maxLength: 4096` alone was added to a working three-field schema; the
server journal reported that grammar repetitions exceeded its allowed limit.
The transmitted schema now omits that keyword; the local limit has not changed.
The original failure remains part of the evidence. The old 04-A and 04-B
results, including negative and contradictory outputs, remain unchanged.

The official [chat API](https://docs.ollama.com/api/chat) and [structured-output
reference](https://docs.ollama.com/capabilities/structured-outputs) describe
`format` with a schema. A single minimal-schema success does not establish
support for every schema feature or semantic correctness. Further compatibility
testing and a future per-claim evidence policy remain separate work.

### Bounded compatibility correction

With Ollama 0.15.6 and `gemma3:1b`, the generation schema above was exercised
once for each of the same three fixed synthetic cases, using `num_predict=192`,
server-default sampling, and a 120-second deadline. Every response was HTTP
200, terminated with `stop`, and contained syntactically valid JSON. No retry
or prompt change was used. The local results were:

| Case | Model output summary | Local validation | Fixture assessment | Time |
|---|---|---|---|---:|
| Explicit fact | `answered`, opens at 9, empty citations | Invalid: no citations | The fact matches the source, but is uncited | 42.578 s |
| Missing closing time | `answered`, closes at 9, empty citations | Invalid: no citations | Unsupported invented closing time | 40.061 s |
| Conflicting opening times | `answered`, opens at 9, empty citations | Invalid: no citations | Does not acknowledge the conflicting source | 21.813 s |

The empty arrays meet the transmitted schema, but not the local `answered`
contract. The successful HTTP responses establish that the previous grammar
failure did not recur in these three requests; they do not establish a valid
structured-v1 answer or semantic correctness. The earlier minimal schema
experiment and the original HTTP 500 results remain historical evidence.
At the time of those tests, no real structured-v1 run had passed the local validator.

The subsequent synthetic legacy-hardware observations, including an accepted
end-to-end run and adverse model results, are documented separately in
[LEGACY_HARDWARE_EXPERIMENTS.md](../../docs/LEGACY_HARDWARE_EXPERIMENTS.md).

### Current qualification reference and tested thinking mode

Ollama 0.40.15 is the proposed current qualification reference, conditional on
review and the tests actually run; the earlier 0.15.6 observations above are
historical. The structured unit test checks that the default request omits
`think`, that explicit `off` sends a JSON boolean false without changing other
request fields, that invalid modes fail, and that `off` reaches the mocked
transport. The existing rejection tests and local validation rules are retained.

Two Qwen3 fixtures reached the output limit under the default setting. Repeating
only those two with `off` at the same 192-token limit produced complete,
structurally accepted outputs; fixture-specific semantic judgments are in
`CHARACTERIZATION.md`. No automatic inference of model support, retry, citation
repair or semantic classification was added. Test the model, digest and server
version before treating the option as supported in another environment.

A subsequent bounded synthetic transport check on the previously characterized
CPU-only system used Ollama 0.40.15 and the installed Qwen3 1.7B model. With
`off`, one explicit-fact request returned a locally accepted `answered` result
with S1 in 91.398 seconds. This observation establishes neither general
accuracy nor support across models.
