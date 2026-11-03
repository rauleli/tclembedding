# Compatibility entry point for the existing, hash-identified integration test.
# Usage: tclsh quick_test.tcl TOKENIZER_JSON MODEL_ONNX
# Errors, including missing fixtures and failed checks, propagate to the caller.
source [file join [file dirname [info script]] tokenizer_embedding_test.tcl]
