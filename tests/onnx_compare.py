"""Laboratory comparison; Python is not a production dependency.

Args: TOKENIZER_JSON MODEL_ONNX TCLSH ONNX_REFERENCE. Set TCLLIBPATH to the build.
Requires Python tokenizers 0.22.1. No downloads; no NumPy or Python ONNX Runtime.
"""
import math
import os
from pathlib import Path
import subprocess
import sys
from tokenizers import Tokenizer, __version__ as version

if len(sys.argv) != 5:
    raise SystemExit(__doc__)
tokenizer_path, model, tclsh, reference = sys.argv[1:]
if version != "0.22.1":
    raise SystemExit("expected tokenizers 0.22.1")
tok = Tokenizer.from_file(tokenizer_path)
tok.no_truncation()
tok.no_padding()
cases = [
    ("hola", "hola", 128), ("video", "video", 128), ("youtube", "youtube", 128),
    ("es", "Un gato duerme bajo la luz del sol.", 128),
    ("en", "A small bird flies across the quiet garden.", 128),
    ("fr", "Le chat regarde les étoiles dans le ciel.", 128),
    ("ar", "مرحبا بالعالم", 128), ("zh", "你好世界", 128),
    ("unicode", "camión cafe\u0301 😀  punctuation!", 128),
    ("spaces", "  hola   mundo  ", 128), ("empty", "", 128),
]
# Construct exact boundary lengths from the tokenizer, including special tokens.
for target in (127, 128, 129):
    found = next(("hola " * n + suffix for n in range(1, 200) for suffix in ("", "a", "x")
                  if len(tok.encode("hola " * n + suffix).ids) == target), None)
    if found is None:
        raise SystemExit(f"could not synthesize {target} tokens")
    cases.append((f"boundary-{target}-limit128", found, 128))
    cases.append((f"boundary-{target}-no-limit", found, 0))
cases.append(("long-limit128", "hola " * 300, 128))
payload = "".join(f"{limit}\t{text.encode('utf-8').hex()}\n" for _, text, limit in cases)
script = str(Path(__file__).with_name("onnx_compare.tcl"))
env = os.environ.copy()
env["TOKENIZERS_PARALLELISM"] = "false"
tcl = subprocess.run([tclsh, script, tokenizer_path, model], input=payload,
                     text=True, capture_output=True, env=env, check=True, timeout=600)
if os.environ.get("ONNX_COMPARISON_VECTOR_FILE"):
    Path(os.environ["ONNX_COMPARISON_VECTOR_FILE"]).write_text(tcl.stdout, encoding="utf-8")
rows = tcl.stdout.splitlines()
if len(rows) != len(cases):
    raise SystemExit(f"unexpected Tcl row count: {len(rows)}: {tcl.stderr}")
ids_rows, vectors = [], []
for (label, text, limit), row in zip(cases, rows):
    ids_text, vector_text = row.split("\t")
    ids = [int(x) for x in ids_text.split(",")]
    if limit:
        tok.enable_truncation(max_length=limit)
    else:
        tok.no_truncation()
    enc = tok.encode(text, add_special_tokens=True)
    if ids != enc.ids or enc.attention_mask != [1] * len(ids) or enc.type_ids != [0] * len(ids):
        raise SystemExit(f"input mismatch: {label}")
    ids_rows.append(ids)
    vectors.append([float(x) for x in vector_text.split(",")])
ref = subprocess.run([reference, model], input="".join(" ".join(map(str, ids)) + "\n" for ids in ids_rows),
                     text=True, capture_output=True, check=True, timeout=600)
print("SIGNATURE", ref.stderr.strip().replace("\n", " | "))
ref_rows = ref.stdout.splitlines()
if len(ref_rows) != len(cases):
    raise SystemExit("unexpected reference row count")
print("case raw_tokens used_tokens max_abs cosine raw_norm normalized_norm raw_max_abs")
tok.no_truncation()
for (label, text, _), ids, vector, row in zip(cases, ids_rows, vectors, ref_rows):
    values = [float(x) for x in row.split()]
    if len(values) != 769 or len(vector) != 384:
        raise SystemExit(f"bad dimensions: {label}")
    norm, mean, normalized = values[0], values[1:385], values[385:]
    delta = max(abs(a-b) for a, b in zip(vector, normalized))
    raw_delta = max(abs(a-b) for a, b in zip(vector, mean))
    vn = math.sqrt(sum(a*a for a in vector))
    rn = math.sqrt(sum(a*a for a in normalized))
    cosine = sum(a*b for a, b in zip(vector, normalized)) / (vn*rn)
    raw_count = len(tok.encode(text).ids)
    print(f"{label} {raw_count} {len(ids)} {delta:.9g} {cosine:.12g} {norm:.9g} {vn:.12g} {raw_delta:.9g}")
limited = vectors[next(i for i, x in enumerate(cases) if x[0] == "boundary-129-limit128")]
unlimited = vectors[next(i for i, x in enumerate(cases) if x[0] == "boundary-129-no-limit")]
error = max(abs(a-b) for a, b in zip(limited, unlimited))
cosine = sum(a*b for a, b in zip(limited, unlimited)) / (math.sqrt(sum(a*a for a in limited))*math.sqrt(sum(b*b for b in unlimited)))
print(f"TRUNCATION_EFFECT boundary-129 max_abs={error:.9g} cosine={cosine:.12g}")
