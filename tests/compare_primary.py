"""Compare exported PyTorch records against ONNX and the Tcl binding.

Usage: compare_primary.py REFERENCE_JSON MODEL_ONNX TCLSH ONNX_HIDDEN_CLIENT
Set TCLLIBPATH to the isolated extension build. All inputs are synthetic.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import struct
import sys

if len(sys.argv) != 5:
    raise SystemExit(__doc__)
reference, model, tclsh, client = sys.argv[1:]
with open(reference, encoding="utf-8") as source:
    data = json.load(source)
if data.get("revision") != "e8f8c211226b894fcb81acc59f3b34ba3efd5f42" or len(data.get("runs", [])) != 42:
    raise SystemExit("unexpected reference revision or record count")
def file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1024*1024), b""):
            digest.update(block)
    return digest.hexdigest()
if file_hash(reference) != "59c40fa2ec199a8f824bc89808dc881af62e9b6edf6e9e7263be15a0eab70ce7":
    raise SystemExit("unexpected primary-reference hash")
if file_hash(model) != "10f7a088420252b26caf819236ca2c9d2987afd0fc06fec7553b542a5655a05a":
    raise SystemExit("unexpected ONNX model hash")
runs = data["runs"]
if len({(r["case"], r["mode"]) for r in runs}) != 42:
    raise SystemExit("duplicate records")
unique = {}
for row in runs:
    ids = tuple(row["input_ids"])
    if not ids or row["attention_mask"] != [1]*len(ids) or row["token_type_ids"] != [0]*len(ids):
        raise SystemExit(f"unsupported mask or token types: {row['case']} {row['mode']}")
    if ids not in unique:
        unique[ids] = len(unique)
payload = "".join(" ".join(map(str, ids)) + "\n" for ids in unique)
env = os.environ.copy()
tcl = subprocess.run([tclsh, str(Path(__file__).with_name("compare_primary.tcl")), model],
                     input=payload, text=True, capture_output=True, env=env, check=True, timeout=600)
onnx = subprocess.run([client, model], input=payload, text=True, capture_output=True,
                      check=True, timeout=600)
tcl_rows = tcl.stdout.splitlines()
onnx_rows = onnx.stdout.splitlines()
if len(tcl_rows) != len(unique) or len(onnx_rows) != len(unique):
    raise SystemExit("unexpected number of ONNX/Tcl outputs")
def norm(values):
    return math.sqrt(sum(x*x for x in values))
def metric(a, b):
    if len(a) != len(b) or not a or not all(math.isfinite(x) for x in a+b):
        raise ValueError("invalid comparison vectors")
    error = max(abs(x-y) for x, y in zip(a, b))
    na, nb = norm(a), norm(b)
    cosine = sum(x*y for x, y in zip(a, b))/(na*nb) if na and nb else float("nan")
    return error, cosine, na, nb
parsed = []
for ids, index in unique.items():
    values = [float(x) for x in onnx_rows[index].split()]
    vector = [float(x) for x in tcl_rows[index].split(",")]
    if len(values) != 769+len(ids)*384 or len(vector) != 384:
        raise SystemExit("unexpected output dimension")
    # Nine decimal digits round-trip binary32 only after conversion back to float32.
    hidden = [struct.unpack("=f", struct.pack("=f", x))[0] for x in values[769:]]
    parsed.append((values[1:385], values[385:769], hidden, vector))
print("case\tmode\tn\tids_match_003a\thidden_max\thidden_cos\tpool_max\tpool_cos\tpool_torch_norm\tpool_onnx_norm\tpool_rounding_max\tnorm_max\tnorm_cos\tnorm_torch_norm\tnorm_tcl_norm\ttcl_vs_onnx_max\tunnorm_max\tencode_vs_pool_max\ttorch_normalization_max")
for row in runs:
    ids = tuple(row["input_ids"])
    mean, onnx_normalized, hidden, tcl_vector = parsed[unique[ids]]
    torch_hidden = [x for token in row["last_hidden_state"]["values"][0] for x in token]
    torch_mean = row["pooled"]["values"][0]
    torch_encode = row["encode_without_normalization"]["values"][0]
    torch_normalized = row["normalized"]["values"][0]
    if row["last_hidden_state"]["shape"] != [1, len(ids), 384]:
        raise SystemExit("unexpected reference hidden shape")
    torch_double_mean = [sum(torch_hidden[t*384+d] for t in range(len(ids)))/len(ids) for d in range(384)]
    hidden_error, hidden_cos, _, _ = metric(hidden, torch_hidden)
    mean_error, mean_cos, mean_onnx_norm, mean_torch_norm = metric(mean, torch_mean)
    pooling_rounding, _, _, _ = metric(torch_double_mean, torch_mean)
    normalized_error, normalized_cos, norm_tcl, norm_torch = metric(tcl_vector, torch_normalized)
    onnx_tcl_error, _, _, _ = metric(onnx_normalized, tcl_vector)
    raw_error, _, _, _ = metric(tcl_vector, torch_encode)
    encode_error, _, _, _ = metric(torch_encode, torch_mean)
    torch_encode_norm = norm(torch_encode)
    if not torch_encode_norm:
        raise SystemExit("cannot compare a zero-norm reference")
    torch_double_normalized = [x/torch_encode_norm for x in torch_encode]
    torch_normalization_error, _, _, _ = metric(torch_double_normalized, torch_normalized)
    print("\t".join(map(str, (row["case"], row["mode"], len(ids), int(row["ids_match_003a"]),
        f"{hidden_error:.9g}", f"{hidden_cos:.17g}", f"{mean_error:.9g}", f"{mean_cos:.17g}",
        f"{mean_torch_norm:.9g}", f"{mean_onnx_norm:.9g}", f"{pooling_rounding:.9g}",
        f"{normalized_error:.9g}", f"{normalized_cos:.17g}", f"{norm_torch:.12g}", f"{norm_tcl:.12g}",
        f"{onnx_tcl_error:.9g}", f"{raw_error:.9g}", f"{encode_error:.9g}", f"{torch_normalization_error:.9g}"))))
