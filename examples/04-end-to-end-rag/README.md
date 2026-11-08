# Example 04: Evidence-grounded local RAG

This Tcl example retrieves previously ingested E5 fragments, sends a question
and the selected evidence to a local Ollama server, and displays its answer with
source records. It is an example, not an assurance of factual correctness,
confidentiality against a compromised server, or immunity to prompt injection.
It does not ingest documents, compute document embeddings, or maintain chat
history. Example 03 supplies those separate preparation stages.

## Requirements

- Tcl 8.6, Tcl `http`, and [rl_json](https://github.com/RubyLane/rl_json)
  by Ruby Lane; the Example 03 dependencies, installed `tokenizer` and
  `tclembedding` packages, and the characterized E5 ONNX and tokenizer files.
- A completed Example 03 corpus, identified by its SHA-256. For SQLite use
  `sqlite3` for Tcl and the existing database file. For MySQL use `tdbc::mysql`,
  a database containing the Example 03 schema and the separately installed
  `cosine_similarity_v2` UDF. The two backends are independent alternatives.
- A local Ollama server with the explicitly named model already installed.
  No model is downloaded and no service is started by this example.

The E5 artifact hashes and model revision are checked by the existing retrieval
adapters. They tokenize `query: ` without silent truncation and apply mean
pooling. MySQL uses the L-3 UDF. SQLite defaults to the existing Tcl scalar
reference and can explicitly use the L-3 native extension. The normal Example 03 CLI and query results are
unchanged. New `query_results` procedures return their existing 17-field rows.

## Run

Run with the Tcl package search path and ONNX Runtime configured as for Example
03. Use a synthetic corpus or data you are authorized to send to the server.
Arguments are positional; quote the question and other values as required by
your shell:

```sh
tclsh examples/04-end-to-end-rag/rag.tcl sqlite /path/to/corpus.sqlite3 CORPUS_SHA256 /path/to/e5.onnx /path/to/tokenizer.json 'What is the procedure?' 3 12000 11434 MODEL_NAME 256 120000
```

For MySQL the second argument is a Tcl list of socket, database, and user, for
example `'/path/to/mysql.sock test_database test_user'`. The existing adapter
reads an optional password from `TCLEMBEDDING_MYSQL_PASSWORD`. Credentials do
not belong in the source or arguments. The remaining arguments have the same
meaning. `top-k` is 1–256. The context limit is the sum of Tcl string lengths
of selected fragment text; it does not count the question or JSON framing and
is **not** a generator-token budget. Complete fragments that do not fit are
skipped, never truncated. If none fits, no generation occurs. `response-tokens`
sets Ollama's `num_predict` (1–32768); actual behavior depends on the model.
The last argument is the total HTTP request deadline in milliseconds; an
additional loopback connection probe has a 5000 ms deadline. The actual request
has its own total deadline, including its connection. The probe cannot guarantee
a later connection's timing.

Only `127.0.0.1` is contacted. The server's `/api/tags` must list the exact
configured model name and must not identify it as remote; cloud-tagged models
are rejected. This check depends on an honest server and its metadata, and is
not a network isolation or privacy guarantee. Configure Ollama itself and its
network policy appropriately. Requests and retrieved text are not logged by
this script, but the local server may retain or log them.

The response must be nonempty, complete, have assistant role, and contain at
least one citation in the form `[S1]`. Each such citation is checked against
selected evidence IDs. A response with unknown IDs is rejected. The citation
validator does not add citations to a generated answer. The citation
check does not establish whether a cited source supports a claim, and does not
validate other citation formats. The source records retain score, sequence,
text, original source and hashes, conversation, node, message, role, position,
original timestamp representation, part, fragment index, character range, and
embedding-model identity. The corpus identity is printed separately. The
retrieval adapter verifies selected records under its documented integrity
contract; it does not authenticate a deliberately modified database.

The system message tells the generator to treat evidence as untrusted data;
evidence and question are JSON-encoded in a separate user message. This is a
structural precaution, not a guarantee that the model will ignore hostile text.
Retrieved records are ranked by the accepted adapters; no relevance threshold
is applied. High similarity and valid citations do not establish correctness.

The transport follows Ollama's [chat API](https://docs.ollama.com/api/chat):
`POST /api/chat`, `stream: false`, and explicit model and messages. The
[model catalogue](https://docs.ollama.com/api/tags) supplies the local model
check. HTTP failures, deadline expiry, invalid JSON and incomplete or invalid
responses are errors. A missing model is an error, not a download request.

## Tests

```sh
tclsh examples/04-end-to-end-rag/test.tcl
```

Tests use synthetic records and a simulated loopback HTTP server. They do not
establish real-model quality. A real Ollama test requires a locally installed model and
is optional. In one local test with Ollama 0.15.6 and `gemma3:1b`, the
synthetic question “When does the fictional service desk close?” and synthetic
evidence “The fictional service desk closes at 5 PM.” produced the answer
“The fictional service desk closes at 5 PM. [S1]” in a response taking about
9.5 seconds (`num_predict=128`). Another response omitted citations and was
rejected. A separate full SQLite-to-Ollama attempt also omitted citations and
was rejected; it is not a successful end-to-end generation test. The original
rejected responses did not retain enough diagnostic metadata to determine
whether an output limit contributed to the missing citations. These observations
do not establish semantic answer quality or model-quality guarantees.

A later full SQLite-to-Ollama test used one synthetic fragment, the question
“What topics do these documents mention?”, `gemma3:1b`, `num_predict=256`, and
a 120-second HTTP deadline. It completed the HTTP exchange but the answer had
no recognizable source citation and was rejected. The output-limit check did
not report a length termination; this does not establish why the model omitted
the citation.

See `SQL_RETRIEVAL.md` in Example 03 for ingestion, backend
integrity, and query limitations. Future work may evaluate more nuanced
citation assessment and other generation adapters;
none is implemented here.

## Evaluation and optional native SQLite

The 04-B protocol, defined before the experiments, is in [EVALUATION.md](EVALUATION.md).
It separates retrieval, context selection, citation validity, grounding, answer
correctness and abstention. Run `tclsh examples/04-end-to-end-rag/evaluation_test.tcl`
to check 12 fixed synthetic cases. Retrieval in those cases is simulated; their
semantic labels are predeclared fixture assessments, not an automatic verifier.
The cases cover direct and combined facts, similar documents, chronology, roles,
contradiction, missing evidence, top-k and context omissions, hostile text,
unsupported citations and unknown citations. A structurally valid citation can
accompany an incorrect answer. An uncited correct abstention still fails the
unchanged 04-A structural validator. No generalized abstention policy is enabled.

To explicitly choose the L-3 SQLite extension, use `sqlite-native` as the backend
and provide its target as a Tcl list containing the database and extension paths:

```sh
tclsh examples/04-end-to-end-rag/rag.tcl sqlite-native '/path/to/corpus.sqlite3 /path/to/similarity.so' CORPUS_SHA256 /path/to/e5.onnx /path/to/tokenizer.json 'What is the procedure?' 3 12000 11434 MODEL_NAME 256 120000
```

Use Tcl list quoting when either path contains spaces. Build the extension with
the instructions in `docs/SIMILARITY_KERNEL.md`. The caller chooses a trusted
local shared library; loading arbitrary native code is unsafe. Extension loading
is enabled only for the load operation and then disabled, including on failure.
A load failure is an error, not a fallback to Tcl. The default `sqlite` route is
unchanged and does not require the extension; MySQL is unaffected. Both SQLite
paths validate metadata and completeness and check hashes of selected rows, but
neither query is an authentication or full storage audit.

Run the 200-record comparison and full E5 query using a previously prepared
synthetic Example 03 database, without changing it:

```sh
tclsh examples/04-end-to-end-rag/native_test.tcl /path/to/similarity.so /path/to/synthetic.sqlite3 /path/to/e5.onnx /path/to/tokenizer.json
tclsh examples/04-end-to-end-rag/integration_test.tcl /path/to/synthetic.sqlite3 /path/to/similarity.so /path/to/e5.onnx /path/to/tokenizer.json
```

The second test generates a real E5 query embedding and retrieves native SQLite
results, then uses a simulated generator. It is not a real Ollama generation.
The supplied database must be the characterized 200-record synthetic corpus.
The native test creates a private temporary database copy for destructive checks.
The L-3 extension was compared with the Tcl route on 200 records: top ten and
all provenance fields matched; the maximum score difference was
`1.1102230246251565e-16` for the tested vector. Equal-score sequence ordering,
invalid and incomplete data, selected-row integrity, and load errors were
checked. This is functional evidence, not a performance benchmark or a full
storage audit.

`ollama_evaluate.tcl` runs two predefined synthetic transport experiments
against locally available `gemma3:1b`: the original 04-A prompt, and the same
prompt with one added sentence requiring `[S1]`. Both use the same question,
evidence, model, output limit and deadline. This does not change the production
prompt or add retries. Outputs must be assessed separately for factual support;
mechanical citation acceptance alone is insufficient.

In one later real end-to-end run, an E5 query over the 200-record synthetic
database used native SQLite and the original prompt; `gemma3:1b` correctly
identified the selected fragment's maintenance-and-recovery subject and cited
`[S1]`. The validator accepted that one response. The controlled prompt results,
including a structurally valid but contradictory answer, are recorded in
[EVALUATION.md](EVALUATION.md); neither observation guarantees model quality.
A separate isolated MySQL run on the same 200-record corpus returned the same
five results and provenance as native SQLite for one E5 query, with maximum
absolute score difference `0.0`; this is not a benchmark or an exhaustive
comparison.

## Optional structured output

A separate, opt-in `structured.tcl` entry point distinguishes model-declared
answers and abstentions from locally rejected output. Its exact schema, tests,
local-server compatibility observations and limitations are in
[STRUCTURED.md](STRUCTURED.md). The existing text CLI and its behavior remain
unchanged. Structural validity and valid evidence IDs do not verify semantic
truth or the correctness of an abstention.

For the synthetic legacy-hardware experiments and preserved results, see
[LEGACY_HARDWARE_EXPERIMENTS.md](../../docs/LEGACY_HARDWARE_EXPERIMENTS.md).
