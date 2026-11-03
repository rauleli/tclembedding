"""Offline PyTorch reference export for the fixed synthetic corpus.

Usage: python st_reference.py LOCAL_MODEL_DIR > reference.json
Run only with the complete pinned model revision on a compatible CPU.
The JSON stores binary32-derived values as round-trippable JSON numbers.
"""
import hashlib
import importlib.metadata as metadata
import json
import os
from pathlib import Path
import platform
import sys

import torch
import torch.nn.functional as F
from sentence_transformers import SentenceTransformer
from tokenizers import Tokenizer

REVISION = "e8f8c211226b894fcb81acc59f3b34ba3efd5f42"
REQUIRED = ("config.json", "config_sentence_transformers.json", "modules.json",
            "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
            "sentence_bert_config.json", "1_Pooling/config.json", "model.safetensors")
KNOWN_HASHES = {
    "config.json": "6300193cb75e01cf80c96decef7187dfb33094d97cc1490b7ead6ff134476e4e",
    "modules.json": "8f4b264b80206c830bebbdcae377e137925650a433b689343a63bdc9b3145460",
    "tokenizer.json": "2c3387be76557bd40970cec13153b3bbf80407865484b209e655e5e4729076b8",
    "tokenizer_config.json": "5036ea374ffedd706e3bef33e2e0d6953cb868ef8a490e76e32ba0faa37a6b9b",
    "special_tokens_map.json": "378eb3bf733eb16e65792d7e3fda5b8a4631387ca04d2015199c4d4f22ae554d",
    "1_Pooling/config.json": "4be450dde3b0273bb9787637cfbd28fe04a7ba6ab9d36ac48e92b11e350ffc23",
    "model.safetensors": "eaa086f0ffee582aeb45b36e34cdd1fe2d6de2bef61f8a559a1bbc9bd955917b",
}

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

def corpus(tok):
    cases = [
        ("hola", "hola", 128), ("video", "video", 128), ("youtube", "youtube", 128),
        ("es", "Un gato duerme bajo la luz del sol.", 128),
        ("en", "A small bird flies across the quiet garden.", 128),
        ("fr", "Le chat regarde les étoiles dans le ciel.", 128),
        ("ar", "مرحبا بالعالم", 128), ("zh", "你好世界", 128),
        ("unicode", "camión cafe\u0301 😀  punctuation!", 128),
        ("spaces", "  hola   mundo  ", 128), ("empty", "", 128),
    ]
    tok.no_truncation()
    tok.no_padding()
    for target in (127, 128, 129):
        text = next("hola " * n + suffix for n in range(1, 200) for suffix in ("", "a", "x")
                    if len(tok.encode("hola " * n + suffix).ids) == target)
        cases.extend(((f"boundary-{target}-limit128", text, 128),
                      (f"boundary-{target}-no-limit", text, 0)))
    cases.append(("long-limit128", "hola " * 300, 128))
    cases.extend((("regression-hola", "hola", 0),
                  ("regression-gato", "un gato duerme", 0),
                  ("regression-estrellas", "las estrellas brillan", 0)))
    if len(cases) != 21 or len({x[0] for x in cases}) != 21:
        raise RuntimeError("incorrect corpus")
    return cases

def tensor_data(tensor):
    tensor = tensor.detach().cpu()
    return {"dtype": str(tensor.dtype), "shape": list(tensor.shape), "values": tensor.tolist()}

if len(sys.argv) != 2:
    raise SystemExit(__doc__)
root = Path(sys.argv[1])
files = {}
for name in REQUIRED:
    path = root / name
    if not path.is_file():
        raise SystemExit(f"missing required file: {name}")
    files[name] = {"bytes": path.stat().st_size, "sha256": sha256(path)}
    if name in KNOWN_HASHES and files[name]["sha256"] != KNOWN_HASHES[name]:
        raise SystemExit(f"unexpected model artifact hash: {name}")
config = json.loads((root / "sentence_bert_config.json").read_text(encoding="utf-8"))
if config.get("max_seq_length") != 128 or config.get("do_lower_case") is not False:
    raise SystemExit("unexpected Sentence Transformers configuration")
torch.set_num_threads(1)
torch.set_num_interop_threads(1)
model = SentenceTransformer(str(root), device="cpu", local_files_only=True, trust_remote_code=False)
model.eval()
default_max = model.max_seq_length
if default_max != 128:
    raise SystemExit(f"unexpected model default max_seq_length: {default_max}")
tok = Tokenizer.from_file(str(root / "tokenizer.json"))
cases = corpus(tok)
result = {
    "schema": 1, "revision": REVISION, "default_max_seq_length": default_max,
    "versions": {name: metadata.version(name) for name in
                 ("torch", "sentence-transformers", "transformers", "tokenizers", "huggingface-hub", "safetensors")},
    "python": platform.python_version(), "machine": platform.machine(), "platform": platform.platform(),
    "parameter_dtype": str(next(model.parameters()).dtype),
    "torch_threads": torch.get_num_threads(), "torch_interop_threads": torch.get_num_interop_threads(),
    "thread_environment": {k: os.environ.get(k) for k in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS")},
    "script_sha256": sha256(Path(__file__)), "files": files, "runs": [],
}
for label, text, original_limit in cases:
    tok.no_truncation()
    raw_ids = tok.encode(text, add_special_tokens=True).ids
    if original_limit:
        tok.enable_truncation(max_length=original_limit)
    expected_ids = tok.encode(text, add_special_tokens=True).ids
    regression_ids = {"regression-hola": [0, 739, 143, 2],
                      "regression-gato": [0, 51, 125583, 115, 56, 282, 2],
                      "regression-estrellas": [0, 576, 114566, 7, 39192, 1414, 2]}
    if label in regression_ids and expected_ids != regression_ids[label]:
        raise SystemExit(f"regression token IDs do not match fixture: {label}")
    for mode in ("official_default", "aligned_003a"):
        # No-limit 003-A cases have <=129 tokens. A 512 limit leaves them intact;
        # this is an explicit model limit, not an assertion of unlimited inputs.
        effective_limit = default_max if mode == "official_default" else (original_limit or 512)
        model.max_seq_length = effective_limit
        features = model.tokenize([text])
        with torch.inference_mode():
            output = model(features)
            encoded = model.encode([text], convert_to_tensor=True,
                                   normalize_embeddings=False, show_progress_bar=False)
            normalized = F.normalize(encoded, p=2, dim=1)
        ids = features["input_ids"].detach().cpu().tolist()[0]
        masks = features["attention_mask"].detach().cpu().tolist()[0]
        types_tensor = features.get("token_type_ids")
        result["runs"].append({
            "case": label, "mode": mode, "original_003a_limit": original_limit,
            "effective_max_seq_length": effective_limit,
            "text_utf8_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "raw_token_count": len(raw_ids), "expected_003a_ids": expected_ids,
            "ids_match_003a": ids == expected_ids,
            "input_ids": ids, "attention_mask": masks,
            "token_type_ids": types_tensor.detach().cpu().tolist()[0] if types_tensor is not None else None,
            "effective_token_count": len(ids),
            "last_hidden_state": tensor_data(output["token_embeddings"]),
            "pooled": tensor_data(output["sentence_embedding"]),
            "encode_without_normalization": tensor_data(encoded),
            "normalized": tensor_data(normalized),
        })
json.dump(result, sys.stdout, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
sys.stdout.write("\n")
