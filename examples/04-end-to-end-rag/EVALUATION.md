# Evidence evaluation protocol

This protocol is fixed before the experiments below. All records are invented.
Labels are kept outside the generator messages. The cases do not estimate model
accuracy on real conversations.

- **Retrieval:** the designated relevant source is in the returned candidates.
- **Selection:** the source remains in the selected context after the size limit.
- **Citation validity:** every recognized `[S<number>]` is selected and at least
  one appears. This is the existing structural contract, not a grounding test.
- **Grounding:** a cited source supports the attached claim, assessed against
  predeclared facts in these fixtures; otherwise manual interpretation is needed.
- **Correctness:** the answer agrees with the fixture facts, including role and
  chronology. A numerical score cannot establish correctness.
- **Abstention:** the answer acknowledges insufficient or conflicting evidence
  instead of asserting a definitive fact; human interpretation may be needed.

Assess each property separately. In this limited fixture evaluator, canned
responses use exact predetermined strings; no general truth detection is
claimed. The 04-A validator remains an independent structural control. A correct
uncited abstention is currently rejected by that control. Accepting abstentions
would require an explicit new contract: distinguishing factual assertions and
unsupported claims from genuine abstention is not reliably solved by a list of
phrases. No such policy is activated here.

A future contract may distinguish an evidence-backed answer, an explicit
abstention, and an invalid response. Structured output is a possible subject
for a separately authorized investigation and must itself be tested; a phrase
or regular expression alone cannot establish that a response is a valid
abstention or contains no unsupported factual claims.

For local model diagnosis, use a single synthetic source and fixed question;
compare the original prompt against one predefined variant requesting a short
answer followed by `[S1]`. Keep model, source, question, endpoint, token limit,
and deadline constant; no retries, prompt search, or automated semantic claims.

## Observed controlled run

Ollama 0.15.6, `gemma3:1b`, one source stating that the fictional workshop opens
at 9, the question asking when it opens, `num_predict=256`, and a 120-second
HTTP deadline. A single request was made per variant. The original prompt took
47.0 seconds, ended with `stop`, and asked for the question rather than answering;
it contained no citation and was structurally rejected. The variant adding a
sentence explicitly requesting `[S1]` took 32.2 seconds, ended with `stop`, and
was structurally accepted. However, it stated both that the evidence did not
contain the opening time and that it said 9. This contradiction is not a
correct grounded answer. These two observations do not identify the cause or
establish comparative model quality. No prompt change was applied to 04-A.

The 12 canned cases passed their mechanical retrieval/selection/citation checks.
Three uncited abstentions were rejected by the unchanged structural validator;
a cited but false closing time passed that validator and was labelled incorrect
by the fixture oracle. Grounding and correctness labels are manually determined
for these cases; they do not constitute an independent semantic classifier.

A separate real end-to-end run used the 200-record synthetic E5 database,
SQLite native retrieval, top-k 1, a 1,000-Tcl-unit context limit, the original
04-A prompt, `gemma3:1b`, `num_predict=256`, and a 120-second deadline. The
question was “What is the subject of these documents?” The selected synthetic
fragment mentioned maintenance and recovery. The model answered that the
subject was maintenance and recovery and cited `[S1]`; the structural validator
accepted it. For this single case, the cited fragment supports that answer.
Duration was not separately measured. It does not resolve the contradictory
response observed in the transport experiment or establish general quality.

The native SQLite and disposable MySQL paths were also compared on the same
200-record synthetic corpus. For one E5 query, their five ranked rows and
provenance matched with maximum absolute score difference 0.0. A separate
comparison passed the exact same 1,536-byte stored vector to both engines;
MySQL `HEX` and length checks confirmed the bound bytes, and the top five
sequences, texts and scores matched within `1e-12`. The MySQL instance used a
private socket and had TCP disabled; it was stopped after the checks. Its
startup emitted the previously observed optional `component_reference_cache`
warning. These comparisons are limited to the tested vectors and records.
