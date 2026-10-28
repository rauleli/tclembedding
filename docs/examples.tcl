#!/usr/bin/env tclsh
# examples.tcl - Usage examples for tclembedding extension

# Example 1: Basic embedding generation
proc example_basic {} {
    package require tclembedding
    package require tokenizer

    # Initialize model (MiniLM - no prefix required)
    set model_path "models/paraphrase-multilingual-MiniLM-L12-v2/model.onnx"
    set tokenizer_path "models/paraphrase-multilingual-MiniLM-L12-v2/tokenizer.json"

    tokenizer::load_vocab $tokenizer_path
    set handle [embedding::init_raw $model_path]

    # Get embedding
    set text "Hello, world!"
    set tokens [tokenizer::tokenize $text]
    set vector [embedding::compute $handle $tokens]

    puts "Text: $text"
    puts "Embedding dimensions: [llength $vector]"
    puts "First 5 values: [lrange $vector 0 4]"

    # Cleanup
    embedding::free $handle
}

# Example 2: Compare semantic similarity
proc example_similarity {} {
    package require tclembedding
    package require tokenizer

    set model_path "models/paraphrase-multilingual-MiniLM-L12-v2/model.onnx"
    set tokenizer_path "models/paraphrase-multilingual-MiniLM-L12-v2/tokenizer.json"

    tokenizer::load_vocab $tokenizer_path
    set handle [embedding::init_raw $model_path]

    # Encode two similar texts
    set text1 "The cat sat on the mat"
    set text2 "A feline rested on the carpet"

    set tokens1 [tokenizer::tokenize $text1]
    set tokens2 [tokenizer::tokenize $text2]

    set vec1 [embedding::compute $handle $tokens1]
    set vec2 [embedding::compute $handle $tokens2]

    # Calculate cosine similarity (dot product for normalized vectors)
    set similarity [dot_product $vec1 $vec2]

    puts "Text 1: $text1"
    puts "Text 2: $text2"
    puts "Similarity: [format %.4f $similarity]"

    embedding::free $handle
}

# Helper: Calculate dot product (equals cosine similarity for L2-normalized vectors)
proc dot_product {vec1 vec2} {
    set dot 0.0
    foreach v1 $vec1 v2 $vec2 {
        set dot [expr {$dot + $v1 * $v2}]
    }
    return $dot
}

# Example 3: Multilingual support
proc example_multilingual {} {
    package require tclembedding
    package require tokenizer

    set model_path "models/paraphrase-multilingual-MiniLM-L12-v2/model.onnx"
    set tokenizer_path "models/paraphrase-multilingual-MiniLM-L12-v2/tokenizer.json"

    tokenizer::load_vocab $tokenizer_path
    set handle [embedding::init_raw $model_path]

    # Test different languages
    set texts {
        "Hello, world!"
        "Hola, mundo!"
        "Bonjour, monde!"
        "Hallo, Welt!"
    }

    puts "Multilingual Embeddings:"
    puts "========================"

    foreach text $texts {
        set tokens [tokenizer::tokenize $text]
        set vec [embedding::compute $handle $tokens]
        set norm [vector_norm $vec]
        puts "Text: $text -> Norm: [format %.4f $norm]"
    }

    embedding::free $handle
}

# Helper: Calculate vector norm
proc vector_norm {vec} {
    set sum 0.0
    foreach v $vec {
        set sum [expr {$sum + $v * $v}]
    }
    return [expr {sqrt($sum)}]
}

# Example 4: Batch processing
proc example_batch {} {
    package require tclembedding
    package require tokenizer

    set model_path "models/paraphrase-multilingual-MiniLM-L12-v2/model.onnx"
    set tokenizer_path "models/paraphrase-multilingual-MiniLM-L12-v2/tokenizer.json"

    tokenizer::load_vocab $tokenizer_path
    set handle [embedding::init_raw $model_path]

    # List of texts to embed
    set documents {
        "The quick brown fox jumps over the lazy dog"
        "A fast auburn canine leaps past a sluggish hound"
        "The sky is blue"
        "Cats are wonderful pets"
    }

    puts "Batch Processing:"
    puts "================="

    set embeddings [list]
    foreach doc $documents {
        set tokens [tokenizer::tokenize $doc]
        set vec [embedding::compute $handle $tokens]
        lappend embeddings $vec
        puts "Embedded: [string range $doc 0 40]..."
    }

    # Calculate similarity matrix (dot product = cosine for normalized vectors)
    puts "\nSimilarity Matrix:"
    for {set i 0} {$i < [llength $embeddings]} {incr i} {
        for {set j 0} {$j < [llength $embeddings]} {incr j} {
            set sim [dot_product [lindex $embeddings $i] [lindex $embeddings $j]]
            puts -nonewline "[format %.2f $sim] "
        }
        puts ""
    }

    embedding::free $handle
}

# Main execution
if {[info exists argv0] && $argv0 eq [info script]} {
    puts "tclembedding Examples"
    puts "===================="
    puts ""

    if {[llength $argv] == 0} {
        puts "Available examples:"
        puts "  1. example_basic       - Basic embedding generation"
        puts "  2. example_similarity  - Compare semantic similarity"
        puts "  3. example_multilingual - Test multilingual support"
        puts "  4. example_batch       - Batch processing"
        puts ""
        puts "Usage: tclsh examples.tcl <example>"
        exit 1
    }

    set example [lindex $argv 0]

    if {[catch {$example} err]} {
        puts "Error running example: $err"
        puts $::errorInfo
        exit 1
    }
}
