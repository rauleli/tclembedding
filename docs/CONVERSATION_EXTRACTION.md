# ChatGPT conversation text extraction example

`tools/conversation_extract.tcl` is a local, text-only example for preparing a ChatGPT conversation export. Its JSONL output can later be consumed by a RAG pipeline for chunking, embedding and retrieval while preserving message provenance. Those later steps are not implemented here: this is not a complete RAG application.

## Dependencies and attribution

The example requires Tcl 8.6 and [`rl_json`](https://github.com/RubyLane/rl_json), an independently developed third-party project by Ruby Lane. It uses `rl_json` to parse, manipulate and serialize JSON in Tcl; the dependency is not part of the `tclembedding` implementation. Version 0.15.7 was tested locally. The script requests `rl_json` 0.15.7 through Tcl's package mechanism; compatibility with other versions has not been established by these tests. See the [upstream repository](https://github.com/RubyLane/rl_json) for installation instructions and licensing information.

## Input and execution

Provide exactly two UTF-8 JSON files named `conversations-000.json` and `conversations-001.json`, in that order, and a new output filename. Use paths appropriate to the local environment:

```sh
umask 077
mkdir -m 700 /path/to/private-output
tclsh tools/conversation_extract.tcl \
  /path/to/private-export/conversations-000.json \
  /path/to/private-export/conversations-001.json \
  /path/to/private-output/active-text.jsonl
```

The output is created exclusively with requested mode `0600`; an existing file is never overwritten. Protect the directory, backups, terminal output and all derived files. The user must choose an output outside the public repository. JSONL contains original private text and identifiers: do not publish or upload it. The tool reads each source as a whole JSON document, one file at a time; streaming was not established. It never opens references or attachments. A failed run can leave an incomplete output file; do not consume it. The tool reports a generic failure so private content and paths are not exposed through diagnostics. Inspect and remove incomplete output manually under the local retention policy.

Run the synthetic tests from the repository root:

```sh
tclsh tests/conversation_extract_test.tcl
```

The tests create synthetic files under a new temporary directory. No actual export or model is required.

## Selection and provenance

Input roots must be arrays of conversation objects. For each conversation the extractor follows `parent` from `current_node` to a null-parent root, checks node existence, ID consistency and cycles, then walks that path in root-to-leaf order. Nodes outside that path are not indexed. Missing or malformed required structural fields cause failure; no partial output is reported as successful. Files and conversations retain their input order. A null message is a structural node.

Messages must have a matching node/message ID, role `user` or `assistant`, content type `text`, and an array of parts. Every nonempty string part is a separate output record; whitespace-only parts, non-string parts, other roles and all other content types, including `multimodal_text`, `thoughts` and `reasoning_recap`, are excluded. Parts containing known attachment URI schemes (`file-service://`, `sandbox:/`, `attachment://`, `sediment://`, case-insensitive) are excluded in their entirety. This conservative rule can omit ordinary text in the same part. It is not a complete classifier for every possible attachment reference or sensitive content; unknown reference formats and personal information require further review. Nested objects and referenced files are never processed.

Each output line is a UTF-8 JSON object with:

- `version`: extractor format version, currently the string `1`.
- `source`: input basename.
- `conversation_id`, `node_id`, `message_id`: original identifiers.
- `position`: zero-based node position in the active path, including structural nodes.
- `role`: original accepted role.
- `create_time`: original JSON number or string, or `null` when null or missing.
- `part`: zero-based original index in the message's parts array.
- `text`: the original selected string.

The tuple `(source, conversation_id, node_id, part)` identifies an occurrence within inputs with unique conversation identifiers. Message IDs alone are not global identifiers. No deduplication is performed; repeated content in different conversations remains separate. Duplicate conversation IDs within a source would require a further source-record ordinal and are not automatically rejected; validate such inputs before relying on that tuple. Dates are preserved rather than used for ordering. The representation is a local intermediate format, not a chunk, vector or public database schema.

Aggregate counters are printed only after successful extraction. `messages` counts active non-null message objects; exclusion counts apply in role, content type, parts and string order. `no_text` counts eligible text messages with no emitted parts. `chars` uses Tcl string length; `utf8_bytes` counts bytes of selected text only, excluding JSONL framing. Two successful runs with the same input bytes, Tcl/rl_json behavior and script version should produce identical JSONL bytes; this was checked locally, not claimed for every Tcl implementation.

Memory usage depends on the size and structure of each complete input document. Measure resource requirements locally before processing a large export; the tool does not provide streaming or resource guarantees.
