# Example 01: In-memory semantic retrieval

This Tcl example searches a small synthetic support manual using embeddings. Semantic retrieval can supply source material for retrieval-augmented generation (RAG); this example only retrieves documents and does not call a generative language model or generate an answer.

## Requirements

- Tcl 8.6 and the `tclembedding` and `tokenizer` packages. Follow the repository's [installation instructions](../../INSTALL.md); configure `TCLLIBPATH` if the installed package directory is not already on Tcl's package path.
- A local ONNX model and full `tokenizer.json` for [`intfloat/multilingual-e5-small`](https://huggingface.co/intfloat/multilingual-e5-small), revision `614241f622f53c4eeff9890bdc4f31cfecc418b3`. This multilingual model was characterized with the library and can encode the Spanish and English synthetic examples. Supply compatible artifacts yourself; this example does not download models.

The characterized ONNX SHA-256 is `ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665` and tokenizer SHA-256 is `0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39`. These identify the evaluated artifacts, not every available export of the model. See [CHARACTERIZATION.md](../../CHARACTERIZATION.md) for model-validation scope and limits.

## Run retrieval

From the repository root, replace the example paths with your installed package and model locations:

```sh
export TCLLIBPATH="/path/to/installed/package/directory"
tclsh examples/01-in-memory-rag/rag.tcl \
  -model /path/to/model.onnx \
  -tokenizer /path/to/tokenizer.json \
  -query '¿Cómo recupero un documento que no guardé?' \
  -top-k 3
```

`-model`, `-tokenizer` and `-query` are required. `-top-k` defaults to 3 and accepts integers from 1 to 256; when it exceeds the corpus size, all documents are returned. Results show source ID, title, cosine score and document text in descending score order; equal scores use lexicographic source ID order. Scores compare directions of the computed vectors; no relevance threshold or retrieval-quality guarantee is implied.

The example tokenizes full documents with `passage: ` and the question with `query: `, explicitly selects mean pooling, and uses the library's L2-normalized vectors. It calculates cosine with explicit norm and dimension checks. Document embeddings are generated in one `embedding::compute_batch` call with pad ID 1; the query uses `embedding::compute`. It checks the library's 256-sequence, 512-ID and 4,096 padded-position bounds before batch inference, and does not silently truncate text. Pad ID 1 and the model configuration apply to the identified E5 artifact, not arbitrary models. The eight documents are deliberately short: this example has no general chunker.

## Tests and evidence

Run the synthetic unit tests without an ONNX model or external JSON package:

```sh
tclsh examples/01-in-memory-rag/test.tcl
```

They cover cosine validation, ranking and ties, top-k, document inputs, size rejection and resource cleanup with synthetic stubs. Running the retrieval command separately exercises the tokenizer, ONNX batch and single-query inference using the supplied artifacts.

In one local run with the identified model, a synthetic Spanish question about recovering an unsaved document returned `FILE-01` first (cosine 0.907240). An English question about short laptop battery life returned `PWR-01` first (cosine 0.823418). These are observations for two inputs and one environment, not general accuracy guarantees or relevance thresholds.

All documents and vectors live in memory and are rebuilt for each invocation. No database, persistent index, general-purpose chunking, automatic model selection or retrieval-quality evaluation is included. Model compatibility, retrieval quality, throughput and behavior on other environments require independent evaluation. This example does not process ChatGPT exports; that separate text extraction example is documented [here](../../docs/CONVERSATION_EXTRACTION.md).
