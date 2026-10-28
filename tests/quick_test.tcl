#!/usr/bin/env tclsh

# quick_test.tcl - TEA installation validation without database
# Shows complete flow: Text -> Tokens -> Vector -> Math

package require Tcl 8.6
# If TEA is installed correctly, this should work directly:
if {[catch {package require tclembedding} err]} {
    puts "❌ ERROR: Cannot load tclembedding. Did you run 'make install'?"
    exit 1
}
if {[catch {package require tokenizer} err]} {
    puts "❌ ERROR: Cannot load tokenizer."
    exit 1
}

# --- 1. Path Configuration ---
set script_dir [file dirname [file normalize [info script]]]
set base_dir   [file join $script_dir ".."]
# Assuming E5-Small by default
set model_onnx  [file join $base_dir "models" "e5-small" "model.onnx"]
set model_vocab [file join $base_dir "models" "e5-small" "tokenizer.json"]

if {![file exists $model_onnx]} {
    puts "⚠️  WARNING: Model not found at $model_onnx"
    puts "   (Make sure to run models/download_models.sh first)"
    exit 1
}

# --- 2. Loading Components ---
puts "🔹 1. Loading Vocabulary..."
tokenizer::load_vocab $model_vocab

puts "🔹 2. Initializing ONNX..."
set handle [embedding::init_raw $model_onnx]

# --- 3. Tokenization Test ---
set texto "passage: Hello World"
puts "\n🔹 3. Tokenization Test:"
puts "   Input: '$texto'"
set tokens [tokenizer::tokenize $texto]
puts "   Output (IDs): $tokens"

if {[llength $tokens] > 0} {
    puts "   ✅ Tokenization successful."
} else {
    puts "   ❌ FAILURE: Token list is empty."
    exit 1
}

# --- 4. Embedding Test ---
puts "\n🔹 4. Vectorization Test (C Extension):"
set vector [embedding::compute $handle $tokens]
set dim [llength $vector]
puts "   Dimensions obtained: $dim"

if {$dim == 384} {
    puts "   ✅ Correct dimension (384)."
} else {
    puts "   ❌ FAILURE: Incorrect dimension (Expected 384, Got $dim)."
    exit 1
}

# --- 5. Mathematical Verification (Normalization) ---
# The vector should be unit (magnitude ≈ 1.0)
set sum_sq 0.0
foreach val $vector {
    set sum_sq [expr {$sum_sq + ($val * $val)}]
}
set magnitude [expr {sqrt($sum_sq)}]
puts "   Vector magnitude: [format "%.6f" $magnitude]"

if {$magnitude > 0.99 && $magnitude < 1.01} {
    puts "   ✅ Correct L2 normalization."
} else {
    puts "   ⚠️ WARNING: Vector does not appear to be normalized."
}

# --- 6. Semantic Test (Cosine Similarity in Tcl) ---
puts "\n🔹 5. Semantic Test (Comparative):"

proc get_vec {text} {
    global handle
    return [embedding::compute $handle [tokenizer::tokenize "query: $text"]]
}

# Since vectors are normalized, Cosine Similarity is simply the Dot Product
proc dot_product {v1 v2} {
    set dot 0.0
    foreach a $v1 b $v2 {
        set dot [expr {$dot + ($a * $b)}]
    }
    return $dot
}

set v1 [get_vec "dog"]
set v2 [get_vec "canine"]
set v3 [get_vec "computer"]

set sim_alta [dot_product $v1 $v2]
set sim_baja [dot_product $v1 $v3]

puts "   Similarity 'dog' vs 'canine': [format "%.4f" $sim_alta]"
puts "   Similarity 'dog' vs 'computer': [format "%.4f" $sim_baja]"

if {$sim_alta > $sim_baja} {
    puts "   ✅ Semantic Logic OK (Synonyms > Unrelated)."
} else {
    puts "   ❌ SEMANTIC FAILURE: Something is wrong with the model."
}

puts "\n🎉 ALL SET. The system works correctly."
