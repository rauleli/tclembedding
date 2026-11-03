"""Compare explicit Tcl truncation with the transferred 129-token reference.

Usage: compare_boundary_primary.py REFERENCE_JSON TOKENIZER_JSON MODEL_ONNX TCLSH
Set TCLLIBPATH to the isolated extension build. The input is synthetic.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys

from tokenizers import Tokenizer, __version__ as tokenizer_version

if len(sys.argv) != 5:
    raise SystemExit(__doc__)
reference, tokenizer_path, model, tclsh = sys.argv[1:]

def file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

for path, expected in (
    (reference, "59c40fa2ec199a8f824bc89808dc881af62e9b6edf6e9e7263be15a0eab70ce7"),
    (tokenizer_path, "2c3387be76557bd40970cec13153b3bbf80407865484b209e655e5e4729076b8"),
    (model, "10f7a088420252b26caf819236ca2c9d2987afd0fc06fec7553b542a5655a05a"),
):
    if file_hash(path) != expected:
        raise SystemExit(f"unexpected artifact hash: {Path(path).name}")
if tokenizer_version != "0.22.1":
    raise SystemExit("expected tokenizers 0.22.1")
with open(reference, encoding="utf-8") as source:
    data = json.load(source)
rows = [r for r in data["runs"] if r["case"] == "boundary-129-no-limit" and r["mode"] == "official_default"]
if len(rows) != 1:
    raise SystemExit("expected one official-default reference record")
row = rows[0]
tok = Tokenizer.from_file(tokenizer_path)
tok.no_truncation()
tok.no_padding()
text = next("hola " * n + suffix for n in range(1, 200) for suffix in ("", "a", "x")
            if len(tok.encode("hola " * n + suffix).ids) == 129)
if hashlib.sha256(text.encode("utf-8")).hexdigest() != row["text_utf8_sha256"]:
    raise SystemExit("synthetic text does not match reference")
if row["attention_mask"] != [1] * 128 or row["token_type_ids"] != [0] * 128:
    raise SystemExit("reference masks do not match the Tcl binding")
script = str(Path(__file__).with_name("onnx_compare.tcl"))
env = os.environ.copy()
env["TOKENIZERS_PARALLELISM"] = "false"
completed = subprocess.run([tclsh, script, tokenizer_path, model],
                           input="128\t" + text.encode("utf-8").hex() + "\n",
                           text=True, capture_output=True, check=True, env=env, timeout=120)
ids_text, values_text = completed.stdout.strip().split("\t")
ids = [int(value) for value in ids_text.split(",")]
values = [float(value) for value in values_text.split(",")]
expected = row["normalized"]["values"][0]
if ids != row["input_ids"] or len(ids) != 128 or ids[-1] != 2:
    raise SystemExit("Tcl IDs or the final special token do not match")
if len(values) != 384 or len(expected) != 384:
    raise SystemExit("unexpected embedding dimension")
error = max(abs(a-b) for a, b in zip(values, expected))
norm = lambda vector: math.sqrt(sum(x*x for x in vector))
cosine = sum(a*b for a, b in zip(values, expected)) / (norm(values)*norm(expected))
print("ids_equal=true count=128 final_special_id=2")
print(f"max_abs={error:.17g} cosine={cosine:.17g}")
print(f"tcl_norm={norm(values):.17g} pytorch_norm={norm(expected):.17g}")
