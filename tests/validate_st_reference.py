"""Validate completeness and model-file integrity of an offline reference export.

Usage: python validate_st_reference.py REFERENCE_JSON LOCAL_MODEL_DIR
This checks structure and recorded hashes, not model numerical correctness.
"""
import hashlib
import json
import math
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit(__doc__)
with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
root = Path(sys.argv[2])
required = {"config.json", "config_sentence_transformers.json", "modules.json", "tokenizer.json",
            "tokenizer_config.json", "special_tokens_map.json", "sentence_bert_config.json",
            "1_Pooling/config.json", "model.safetensors"}
known = {
    "config.json": "6300193cb75e01cf80c96decef7187dfb33094d97cc1490b7ead6ff134476e4e",
    "modules.json": "8f4b264b80206c830bebbdcae377e137925650a433b689343a63bdc9b3145460",
    "tokenizer.json": "2c3387be76557bd40970cec13153b3bbf80407865484b209e655e5e4729076b8",
    "tokenizer_config.json": "5036ea374ffedd706e3bef33e2e0d6953cb868ef8a490e76e32ba0faa37a6b9b",
    "special_tokens_map.json": "378eb3bf733eb16e65792d7e3fda5b8a4631387ca04d2015199c4d4f22ae554d",
    "1_Pooling/config.json": "4be450dde3b0273bb9787637cfbd28fe04a7ba6ab9d36ac48e92b11e350ffc23",
    "model.safetensors": "eaa086f0ffee582aeb45b36e34cdd1fe2d6de2bef61f8a559a1bbc9bd955917b",
}
if data.get("schema") != 1 or data.get("revision") != "e8f8c211226b894fcb81acc59f3b34ba3efd5f42":
    raise SystemExit("unexpected schema or revision")
if set(data.get("files", {})) != required or data.get("default_max_seq_length") != 128:
    raise SystemExit("incomplete artifact manifest or unexpected maximum")
for name in sorted(required):
    digest = hashlib.sha256()
    file = root / name
    if not file.is_file() or file.stat().st_size != data["files"][name]["bytes"]:
        raise SystemExit(f"file missing or size differs: {name}")
    with file.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != data["files"][name]["sha256"]:
        raise SystemExit(f"hash mismatch: {name}")
    if name in known and digest.hexdigest() != known[name]:
        raise SystemExit(f"unexpected pinned artifact hash: {name}")
config = json.loads((root / "sentence_bert_config.json").read_text(encoding="utf-8"))
if config.get("max_seq_length") != 128 or config.get("do_lower_case") is not False:
    raise SystemExit("unexpected Sentence Transformers configuration")
labels = {"hola", "video", "youtube", "es", "en", "fr", "ar", "zh", "unicode", "spaces", "empty",
          "boundary-127-limit128", "boundary-127-no-limit", "boundary-128-limit128", "boundary-128-no-limit",
          "boundary-129-limit128", "boundary-129-no-limit", "long-limit128",
          "regression-hola", "regression-gato", "regression-estrellas"}
runs = data.get("runs", [])
expected = {(label, mode) for label in labels for mode in ("official_default", "aligned_003a")}
if len(runs) != len(expected) or {(r.get("case"), r.get("mode")) for r in runs} != expected:
    raise SystemExit("missing or duplicate case/mode")
if data.get("torch_threads") != 1 or data.get("torch_interop_threads") != 1:
    raise SystemExit("unexpected torch thread count")
if set(data.get("versions", {})) != {"torch", "sentence-transformers", "transformers", "tokenizers", "huggingface-hub", "safetensors"} or not data.get("script_sha256"):
    raise SystemExit("missing version or script identity")
exporter = Path(__file__).with_name("st_reference.py")
if hashlib.sha256(exporter.read_bytes()).hexdigest() != data["script_sha256"]:
    raise SystemExit("exporter script hash mismatch")
if data.get("parameter_dtype") != "torch.float32":
    raise SystemExit("unexpected parameter precision")
def check_tensor(record, key, shape):
    tensor = record.get(key, {})
    if tensor.get("dtype") != "torch.float32" or tensor.get("shape") != shape:
        raise SystemExit(f"bad dtype/shape: {record['case']} {key}")
    def check_values(values, dims):
        if dims:
            if not isinstance(values, list) or len(values) != dims[0]:
                raise SystemExit(f"incomplete tensor: {record['case']} {key}")
            for item in values:
                check_values(item, dims[1:])
            return
        if not isinstance(values, (int, float)) or not math.isfinite(values):
            raise SystemExit(f"non-finite value: {record['case']} {key}")
    check_values(tensor.get("values"), shape)
for row in runs:
    ids, mask, types = row.get("input_ids"), row.get("attention_mask"), row.get("token_type_ids")
    n = row.get("effective_token_count")
    expected_limit = 128 if row["mode"] == "official_default" else (row["original_003a_limit"] or 512)
    if row.get("effective_max_seq_length") != expected_limit:
        raise SystemExit(f"unexpected maximum: {row['case']}")
    if not isinstance(ids, list) or not isinstance(n, int) or n != len(ids) or not 0 < n <= row["effective_max_seq_length"]:
        raise SystemExit(f"invalid input length: {row['case']}")
    if len(mask) != n or any(not isinstance(x, int) for x in ids + mask):
        raise SystemExit(f"invalid input tensors: {row['case']}")
    if types is not None and (len(types) != n or any(not isinstance(x, int) for x in types)):
        raise SystemExit(f"invalid token type IDs: {row['case']}")
    for key, shape in (("last_hidden_state", [1, n, 384]), ("pooled", [1, 384]),
                       ("encode_without_normalization", [1, 384]), ("normalized", [1, 384])):
        check_tensor(row, key, shape)
    if row.get("ids_match_003a") != (ids == row.get("expected_003a_ids")):
        raise SystemExit(f"inconsistent ID comparison: {row['case']}")
    regression = {"regression-hola": [0, 739, 143, 2],
                  "regression-gato": [0, 51, 125583, 115, 56, 282, 2],
                  "regression-estrellas": [0, 576, 114566, 7, 39192, 1414, 2]}
    if row["case"] in regression and row.get("expected_003a_ids") != regression[row["case"]]:
        raise SystemExit(f"unexpected regression IDs: {row['case']}")
print(f"OK: {len(runs)} case/mode records; model-file hashes and tensor dimensions verified")
print("ID differences (reported, not treated as corruption):", sum(not row["ids_match_003a"] for row in runs))
