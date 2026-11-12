# Tcl API

Both packages require compatible external artifacts supplied by the application.
The tokenizer accepts a complete Hugging Face `tokenizer.json`, not a vocabulary
alone. The embedding binding accepts supported ONNX encoder signatures; it does
not select a model, tokenize input, choose model-specific prefixes or infer a
model's padding ID.

- `tokenizer::load_vocab json_path` loads a tokenizer. A successful load replaces
  the current tokenizer; a failed load leaves it intact.
- `tokenizer::tokenize text ?-max-length count?` returns token IDs. Truncation
  and padding are disabled by default. An explicit maximum includes special IDs.
- `tokenizer::encode_details text ?-max-length count?` returns a list of
  `{id byte_start byte_end special_mask attention_mask type_id}` lists. Offsets
  are zero-based UTF-8 bytes with an exclusive end, not Tcl indices. Ranges may
  overlap, be empty or fail to cover the input. Masks reflect the tokenizer's
  postprocessing; a literal special token can have a special mask of zero.
- `tokenizer::free` releases the tokenizer.

- `embedding::init_raw model_path ?-provider cpu|cuda? ?-device index? ?-profile prefix?`
  creates an interpreter-owned handle. CPU is the default. CUDA is explicit,
  requires a compatible external runtime and can still assign nodes to CPU;
  `-device` is a nonnegative decimal index and requires CUDA. Profiling is
  optional; ONNX Runtime chooses the final timestamped JSON filename. Explicit
  `embedding::free` reports finalization errors; handle or interpreter deletion
  cannot return such errors. Profile files can contain sensitive data.
- `embedding::compute handle token_id_list ?-pooling mean|cls?` returns one
  L2-normalized vector. The list must contain nonnegative signed 64-bit IDs.
  Mean pooling is the default.
- `embedding::compute_batch handle token_id_lists -pad-id integer ?-pooling mean|cls?`
  returns vectors in input order and uses right padding. At most 256 sequences,
  512 IDs per sequence and 4,096 padded positions are accepted; other tensor
  shape and output-size checks also apply. The caller chooses the padding ID.
- `embedding::free handle` releases the session and removes the handle. Deleting
  the handle command or its interpreter also releases it. Invalid handles and
  errors during initialization or inference are Tcl errors.

The project README and characterization documents in the development repository
provide model-specific limits and evidence; they are not universal compatibility
claims. See `examples/01-in-memory-rag` for a complete synthetic example.
