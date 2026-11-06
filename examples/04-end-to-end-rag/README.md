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
pooling. MySQL uses the L-3 UDF. SQLite currently uses the existing Tcl scalar
reference; using its native extension without duplicating the accepted retrieval
logic remains future work. The normal Example 03 CLI and query results are
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
integrity, and query limitations. Future 04-B work may evaluate native SQLite
retrieval, more nuanced citation assessment, and other generation adapters;
none is implemented here.
