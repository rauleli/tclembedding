"""Create small synthetic ONNX fixtures without third-party Python packages.

Usage: python make_onnx_safety_fixtures.py EMPTY_DIRECTORY
Files are opened exclusively and existing files are never overwritten.
"""
from pathlib import Path
import struct
import sys

def varint(n):
    result = bytearray()
    while n > 127:
        result.append((n & 127) | 128)
        n >>= 7
    result.append(n)
    return bytes(result)

def integer(field, value):
    return varint(field << 3) + varint(value)

def data(field, value):
    return varint((field << 3) | 2) + varint(len(value)) + value

def string(field, value):
    return data(field, value.encode("utf-8"))

def value_info(name, elem, dims):
    shape = b"".join(data(1, integer(1, d) if isinstance(d, int) else string(2, d)) for d in dims)
    tensor_type = integer(1, elem) + data(2, shape)
    return string(1, name) + data(2, data(1, tensor_type))

def model(dims, elem, raw, inputs=None):
    tensor = b"".join(integer(1, d) for d in dims) + integer(2, elem) + data(9, raw)
    attribute = string(1, "value") + data(5, tensor) + integer(20, 4)
    node = string(2, "last_hidden_state") + string(4, "Constant") + data(5, attribute)
    graph = data(1, node) + string(2, "synthetic_safety")
    if inputs is None:
        inputs = [(name, 7, [1, "sequence"]) for name in ("input_ids", "attention_mask", "token_type_ids")]
    for name, input_type, input_dims in inputs:
        graph += data(11, value_info(name, input_type, input_dims))
    graph += data(12, value_info("last_hidden_state", elem, dims))
    return integer(1, 8) + string(2, "synthetic") + data(7, graph) + data(8, integer(2, 13))

if len(sys.argv) != 2:
    raise SystemExit(__doc__)
root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
fixtures = {
    "valid.onnx": ([1, 2, 384], 1, 1.0),
    "zero.onnx": ([1, 2, 384], 1, 0.0),
    "nan.onnx": ([1, 2, 384], 1, float("nan")),
    "inf.onnx": ([1, 2, 384], 1, float("inf")),
    "tiny.onnx": ([1, 2, 384], 1, 1e-12),
    "rank.onnx": ([2, 384], 1, 1.0),
    "batch.onnx": ([2, 2, 384], 1, 1.0),
    "sequence.onnx": ([1, 1, 384], 1, 1.0),
    "hidden.onnx": ([1, 2, 3], 1, 1.0),
    "type.onnx": ([1, 2, 384], 7, 1),
}
for name, (dims, element, value) in fixtures.items():
    size = 1
    for dim in dims:
        size *= dim
    raw = struct.pack("<f" if element == 1 else "<q", value) * size
    with (root / name).open("xb") as output:
        output.write(model(dims, element, raw))
    print(name)

# Additional synthetic signatures and a nonuniform two-token output.
def write_extra(name, inputs, dim=768):
    values = ([1.0] + [0.0] * (dim - 1) + [0.0, 1.0] + [0.0] * (dim - 2))
    raw = struct.pack("<" + "f" * len(values), *values)
    with (root / name).open("xb") as output:
        output.write(model([1, 2, dim], 1, raw, inputs))

def inp(name, typ=7, dims=None):
    return (name, typ, [1, "sequence"] if dims is None else dims)

two = [inp("input_ids"), inp("attention_mask")]
write_extra("two-768.onnx", two)
write_extra("three-768.onnx", two + [inp("token_type_ids")])
write_extra("unknown-input.onnx", two + [inp("other")])
write_extra("missing-input.onnx", [inp("input_ids"), inp("token_type_ids")])
write_extra("input-type.onnx", [inp("input_ids", 1), inp("attention_mask")])
write_extra("input-rank.onnx", [inp("input_ids", 7, [1, 2, 3]), inp("attention_mask")])
write_extra("input-batch.onnx", [inp("input_ids", 7, [2, "sequence"]), inp("attention_mask")])
write_extra("fixed-input.onnx", [inp("input_ids", 7, [1, 2]), inp("attention_mask", 7, [1, 2])])
