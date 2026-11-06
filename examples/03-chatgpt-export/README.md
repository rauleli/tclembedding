# Token-aware conversation fragmentation

This example prepares extractor output for later semantic retrieval. It does not
generate embeddings, use MySQL, or implement a complete RAG application. The
separate [conversation extractor](../../docs/CONVERSATION_EXTRACTION.md)
selects conversation text; this tool consumes its version 1 JSONL output.

## Dependencies and model

Use Tcl 8.6 or later, `rl_json` (tested with 0.15.7), Tcllib's `sha256`
package, and the installed `tokenizer 1.0.0` package from tclembedding. Set
`TCLLIBPATH` or Tcl's `auto_path` to find the installed package. `rl_json` is
an independent third-party library by Ruby Lane, used for JSON parsing and
serialization; see its [upstream repository](https://github.com/RubyLane/rl_json)
for installation and licensing.

Supply the `tokenizer.json` for `intfloat/multilingual-e5-small`, revision
`614241f622f53c4eeff9890bdc4f31cfecc418b3`. Its expected SHA-256 is
`0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39`;
the program verifies it. No model is downloaded. Future embedding processing
for this characterized model uses mean pooling and padding ID 1. Those steps
are outside this example.

## Operation

For each nonempty text part, the program repeatedly tokenizes the complete
candidate prefixed with `passage: `, without `-max-length`. The token count
therefore includes the prefix and the tokenizer's special tokens. The explicit
budget is 1–512 IDs, defaulting to 512; an unsuitable budget produces an
error. This is a per-sequence limit, not an assertion that a batch of any
number of such sequences is valid: the current batch API also limits the
number of sequences and total padded positions.

If the remaining text fits, it is emitted whole. Otherwise the program probes
increasingly spaced whitespace or punctuation boundaries and emits a candidate
whose full token count was measured. If the first natural unit does not fit,
it probes Unicode character boundaries instead. The fallback checks successive
boundaries until it finds a fit, then probes increasingly spaced candidates.
Every emitted fragment advances, is nonempty, and has a measured token count.
Token counts need not increase monotonically as text is extended: the search
never assumes an untested candidate fits or that larger candidates cannot fit.
It does not promise globally optimal fragmentation and may leave a suffix that
cannot fit even when another segmentation exists. An error never means that the
text was silently truncated. A fragment layout may differ from earlier
versions; reconstruction and budget are the contract.

Exact text reconstruction does not imply that a tokenizer represents every
part of that text meaningfully. For example, WordPiece tokenizers can map a
very long unbroken word to a single unknown token. For the characterized BGE
and MPNet tokenizers, the configured WordPiece maximum is 100 characters per
word; a synthetic 101-character word collapsed to `[UNK]`, while the tested
100-character word did not. The E5 tokenizer used by this example is Unigram;
the same synthetic word did not contain unknown IDs. These observations do not
establish a universal rule for other text. The fragmenter counts unknown IDs
without rejecting any fragment. A later ingestion stage can use these
observations to decide whether to index, omit, or quarantine a fragment; no
universal threshold or automatic action is implemented.

Fragments have zero overlap. `char_start` is inclusive and `char_end` is
exclusive, measured in Tcl string indices, not UTF-8 bytes or token offsets.
On Tcl 8.6 a supplementary Unicode character occupies two index units; a
surrogate pair is never split. Combining sequences can span fragments. In
fragment order, concatenating the `text` values for one input part reconstructs
its exact Tcl string, including whitespace and line breaks. This does not
reconstruct the original JSON encoding or its escape sequences.

## Input and output

Input is UTF-8 JSONL produced by extractor version `1`: `version`, `source`,
`conversation_id`, `node_id`, `message_id`, `position`, `role`, `create_time`,
`part`, and nonempty `text`. Roles are `user` and `assistant`; timestamps may
be a string, number, or null. Invalid input causes an error rather than a
completed output. The extractor's selection and privacy limitations still
apply.

Each UTF-8 JSONL output record has `fragment_version` `2`, `input_source_id`
(supplied by the caller), `input_sha256`, `tokenizer_sha256`, `token_budget`,
`extractor_version`, and the original provenance fields except `version`.
It also has zero-based `fragment_index`, `char_start`, `char_end`,
`token_count`, and the exact fragment `text`. Version 2 adds `unk_id`,
`unk_count`, `content_token_count` and `max_nonspace_tcl_units`; consumers of
version 1 must recognize the new version. `unk_count` counts occurrences of
the configured unknown ID in the already computed complete sequence, including
the prefix and special-token processing. A literal special token that maps to
the unknown ID also counts; it is not necessarily an unknown word. E5's
hash-identified tokenizer uses unknown ID 3. The experimental four-model
benchmark uses IDs 3, 100, 3 and 104 for MiniLM, BGE, E5 and MPNet respectively,
with the tokenizer hashes checked before use. An unknown count of zero does not
guarantee semantic coverage. `content_token_count` is null: the public API does
not provide offsets or a per-ID special-token mask, so it cannot reliably
separate content from prefix and special tokens for arbitrary text.
`max_nonspace_tcl_units` is the longest contiguous run of Tcl string units
whose characters are not classified as whitespace by Tcl `string is space`;
punctuation and joiners count as part of the run. This observation helps
distinguish a long continuous input from a short unknown, but is not a quality
judgment. The original message ID is not
assumed globally unique. The input key (`source`, `conversation_id`, `node_id`,
`part`) must be unique within an input file; duplicates are rejected. When
combining outputs, use the input SHA-256 and caller-chosen stable source ID as
well as this key and fragment index, and check for collisions. Repeated content
in different conversations is retained.

Input must remain unchanged throughout processing. The program records its
SHA-256 and checks it again before publishing output. An existing output is
never overwritten. A temporary file in the output directory is renamed only
after all records have been processed and resources closed. On failure, a
private partial file may remain; it is not a completed result and should be
handled as sensitive data. Keep inputs, output and partial files outside the
repository in a protected directory. JSONL text and provenance can contain
personal information.

Example, with paths supplied locally:

```sh
tclsh examples/03-chatgpt-export/fragment.tcl \
  -input /path/to/extracted.jsonl -output /path/to/fragments.jsonl \
  -source-id export-1 -tokenizer /path/to/tokenizer.json -budget 128
```

An explicit source ID is required. Identical input bytes, source ID, tokenizer,
budget and software produce the same JSONL bytes. This is not a commitment to
identical output with different tokenizer versions or configurations.

## Tests

The synthetic test double exercises fragmentation and provenance without an
ONNX model. The optional real-tokenizer test uses synthetic text and checks
actual IDs and limits; it requires the characterized tokenizer artifact and
the installed package.

```sh
tclsh examples/03-chatgpt-export/test.tcl
tclsh examples/03-chatgpt-export/test.tcl --real /path/to/tokenizer.json
```

The tests use temporary files outside the repository. No conversation export
or private corpus is required. Future embedding, persistence and retrieval
must validate their own limits and compatibility separately.

## Bounded performance observation

An isolated Linux x86-64 run with Tcl 8.6.14 and Tokenizers 0.22.1 used one
synthetic case per process and a 12-second process limit. The same six texts
were measured before and after the boundary search change. On the 10,000-unit
structured case, E5 tokenization calls decreased from 10,000 to 78 and the
first fragmentation time from 4.599 s to 0.062 s; the fragment count increased
from 6 to 8. The 42,000-unit case previously exceeded the process limit and
then completed with 386 calls and a 0.512 s first fragmentation. These are
single observations on the measured CPU, not portable performance guarantees.
All 24 model/scenario combinations completed reconstruction, provenance,
budget and deterministic-repeat checks after the change. BGE and MPNet's
continuous-word `[UNK]` observations remain a limitation, not a success in
semantic coverage. No private conversations, embeddings, or ONNX inference were
used in these measurements.

The synthetic benchmark measures calls, the sum and maximum of Tcl string
lengths passed to `tokenizer::tokenize` (including the document prefix),
fragment time, per-fragment token min/mean/max, occupancy as mean token count
divided by the budget, and unknown ID occurrences. These are Tcl string units,
not UTF-8 bytes. Timings include observation overhead; RSS is the whole process.
The metrics are laboratory output and are not written into the documentary
JSONL. The original cutting strategy and its unused budget are unchanged.

In an additional synthetic run with the same environment, E5 and a 16-token
budget, inputs of 5,000, 10,000 and 20,000 Tcl units produced 160, 320 and
641 fragments; the accumulated tokenization inputs were 430,586, 1,662,618
and 6,530,659 Tcl units. These observations show repeated suffix processing
for this workload, not a general complexity guarantee. For one 42,000-unit
continuous string, the characterized BGE and MPNet tokenizers each returned
one unknown ID and two post-processing IDs; MiniLM and E5 instead produced
multiple fragments without unknown IDs in that synthetic case. No decision
to change the search or handle these cases automatically follows from these
measurements.

The synthetic benchmark can be repeated with the exact E5 tokenizer using an
installed tokenizer package and GNU `time` and `timeout`, for example:

```sh
repo=$PWD
tokenizer_json=/path/to/tokenizer.json
tokenizer_sha=0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39
/usr/bin/time -f 'peak_rss_kib=%M' timeout 12s tclsh \
  examples/03-chatgpt-export/benchmark.tcl e5 "$tokenizer_json" \
  "$tokenizer_sha" 512 'passage: ' structured_long "$repo"
```

Run this command from the repository root and configure `TCLLIBPATH` for the
installed package first. Scenarios are `short`, `structured`, `structured_long`,
`very_long`, `unbroken`, `unicode`, `unbroken42`, `many5`, `many10`, and
`many20`; the `many` scenarios use a small explicit budget such as 16 to
produce many fragments. Each process performs a measured run,
integrity checks, and a deterministic repeat. The script creates temporary
synthetic JSONL files under `TMPDIR` or `/tmp`; interrupted runs can leave
those files. Other model settings used in the characterization are laboratory
configurations, not additional accepted public interfaces.

## Resumable embeddings

A separate [E5 embedding pipeline](EMBEDDING_PIPELINE.md) consumes version 2
fragments and writes a verified float32 binary file with resumable checkpoints.
It does not change fragmentation or implement SQL ingestion or search.
