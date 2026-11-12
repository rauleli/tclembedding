# Example: in-memory semantic retrieval

This example searches a small synthetic corpus. It does not generate answers
or require a database. Install the Tcl packages as described in
[INSTALL.md](../../INSTALL.md), and provide compatible local model and
model-tokenizer files. The example does not download them.

The characterized model is `intfloat/multilingual-e5-small`, revision
`614241f622f53c4eeff9890bdc4f31cfecc418b3`. The previously evaluated ONNX
SHA-256 is `ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665`
and tokenizer SHA-256 is
`0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39`.
Other model exports and signatures need their own verification.

```sh
tclsh examples/01-in-memory-rag/rag.tcl \
  -model /path/to/model.onnx -tokenizer /path/to/tokenizer.json \
  -query 'How do I recover an unsaved document?' -top-k 3
```

The tests use synthetic stubs and do not require the model:

```sh
tclsh examples/01-in-memory-rag/test.tcl
```

Relevance and retrieval quality are not guaranteed by the example.
