# Technical history

This record summarizes the supported history of tokenization and the build infrastructure. Experimental observations are detailed in `CHARACTERIZATION.md`; authorized decisions are recorded in `DECISIONS.md`.

## Background

The tree introduced in the initial commit `b333cd3f44d2a0d7d5bfe888c634d7f812ad3794` included a Tcl tokenizer that greedily searched for the longest piece, with a maximum window of 25 characters. The inherited documentation mentioned several models. The available history does not establish when each component was created or show that previously documented versions correspond to verifiable commits. Sources: historical `CHANGELOG.md` and the initial commit.

## Tokenization characterization

With the reference tokenizer identified in `CHARACTERIZATION.md`, the previous implementation matched 5 of 11 synthetic inputs. For `hola`, `camión` and Arabic text, greedy and Unigram selection chose different pieces; other cases showed normalization and spacing differences.

A later SentencePiece C++ evaluation matched 57 of 58 cases after applying the investigated vocabulary and special-token mapping. Normalization of `＜mask＞` revealed a difference involving the added vocabulary in the JSON. A Rust Tokenizers prototype with a C interface matched 58 of 58. These are limited observations; the prototypes and console logs of those tests are not part of this repository. Sources: previous laboratory observations in `CHANGELOG.md` and `CHARACTERIZATION.md`.

## Slice 001

The greedy implementation was replaced by Rust Tokenizers through a C ABI, without a silent fallback or a requirement to preserve the vocabulary-only format. The current tree includes the integration and tests for 58 cases, lifecycle and a limited text-to-ONNX path. The Tcl interface retains existing names where applicable and adds explicit release. Sources: `DECISIONS.md`, `tokenizer-native/`, `generic/tokenizer_bridge.c` and `tests/`.

A subsequent review corrected output initialization for null arguments and removed deep cloning on the untruncated path. Cloning with `-max-length` remained at that stage; Slice 006 subsequently removed it. Slice 001 was formally accepted with the documented outstanding issues; acceptance did not authorize a commit, publication or the automatic start of subsequent work. Technical evidence: tokenizer robustness in `CHANGELOG.md`.

## Slice 004

An audit characterized the build and installation limitations. Subsequent work connected externally supplied TEA 3.13 files, established prefix and `DESTDIR` installation, rebuilt C and Rust from a 64-file working-tree snapshot with prepared external dependencies, and provided a root test entry point. Slice 004 was formally accepted for the evaluated Linux x86-64 environment and identified dependencies. Binary reproducibility, a complete build from the then-current `HEAD`, self-contained distribution and other platforms are not established. Sources and outstanding work: `CHARACTERIZATION.md`, `BENCHMARKING.md`, `INSTALL.md` and `ROADMAP.md`.

## Slice 005

A source audit preceded the selective incorporation of the accepted implementation, tests and documentation into development baseline commit `338dacbd3a68a19374e7ab2775ddf87055b15d4b`. The commit was rebuilt and tested from a Git archive using identified external dependencies. Merge `b610fec` reconciled the histories without changing the baseline tree, and development publication was recorded. Slice 005 was formally accepted within these documented limits; it is not a stable release. Sources: `CHARACTERIZATION.md`, `CHANGELOG.md` and `ROADMAP.md`.

## Slice 006

Characterization identified deep Unigram cloning as the dominant cost of each explicit truncation call. The backend subsequently adopted per-instance synchronization and temporary native truncation with restoration and explicit failure for unusable state. Slice 006 was formally accepted within the tested Linux x86-64 environment and cases; the evidence, numerical comparisons and performance limits are in `CHARACTERIZATION.md` and `BENCHMARKING.md`. This does not establish safe concurrent handle destruction, universal performance or other-model compatibility.
