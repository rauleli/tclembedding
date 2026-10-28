#!/usr/bin/env tclsh

#==============================================================================
# ingest.tcl - Data Ingestion with Semantic Embeddings
#==============================================================================
#
# Purpose: Load documents from various sources and store them with embeddings
#          in a MySQL database for semantic search.
#
# This script demonstrates:
# - Loading ONNX embedding models with tclembedding
# - Generating embeddings for text documents
# - Converting embeddings to binary format for MySQL storage
# - Proper SQL escaping for binary and text data
# - Batch ingestion workflow
#
# Dependencies:
# - tclembedding    - Text embedding generation
# - mysqltcl        - MySQL connectivity
# - ONNX models     - E5 or similar embedding models
#
# Usage:
#   tclsh ingest.tcl
#
#==============================================================================

package require Tcl 8.6
package require tclembedding
package require tokenizer
package require mysqltcl

# ============================================================================
# CONFIGURATION AND SETUP
# ============================================================================

# Detect base directory relative to script location
set script_dir [file dirname [file normalize [info script]]]
set base_dir   [file join $script_dir ".."]

# Path to embedding model files
set model_onnx  [file join $base_dir "models" "e5-small" "model.onnx"]
set model_vocab [file join $base_dir "models" "e5-small" "tokenizer.json"]

# MySQL Connection Configuration
set db_host     "localhost"
set db_user     "root"
set db_password ""
set db_database "rag"

# Ingestion parameters
set embedding_dim 384          ;# Number of dimensions in embeddings
set batch_size 100             ;# Documents to process before checkpoint
set verbose 1                  ;# Print progress messages

# ============================================================================
# VALIDATION AND INITIALIZATION
# ============================================================================

# Verify model files exist
if {![file exists $model_onnx]} {
    puts "❌ ERROR: Model file not found: $model_onnx"
    puts "   Please ensure E5 model is in: $base_dir/models/e5-small/"
    exit 1
}

if {![file exists $model_vocab]} {
    puts "❌ ERROR: Tokenizer file not found: $model_vocab"
    puts "   Please ensure tokenizer.json is in: $base_dir/models/e5-small/"
    exit 1
}

puts "✓ Model files verified"

# ============================================================================
# MYSQL CONNECTION
# ============================================================================

if {$verbose} {
    puts "🔌 Connecting to MySQL at $db_host..."
}

if {[catch {
    set db [mysql::connect \
        -host $db_host \
        -user $db_user \
        -password $db_password \
        -db $db_database \
    ]
} err]} {
    puts "❌ MySQL Connection Failed: $err"
    puts ""
    puts "Troubleshooting:"
    puts "1. Ensure MySQL is running: sudo systemctl start mysql"
    puts "2. Verify credentials: user=$db_user, password='$db_password'"
    puts "3. Check database exists: mysql -u root -e 'SHOW DATABASES;'"
    puts "4. Create database if needed: mysql -u root -e 'CREATE DATABASE rag;'"
    exit 1
}

puts "✓ Connected to MySQL database: $db_database"

# ============================================================================
# EMBEDDING MODEL INITIALIZATION
# ============================================================================

if {$verbose} {
    puts "🧠 Initializing embedding model (E5)..."
}

if {[catch {
    tokenizer::load_vocab $model_vocab
    set handle [embedding::init_raw $model_onnx]
} err]} {
    puts "❌ Failed to initialize embedding model: $err"
    mysql::close $db
    exit 1
}

puts "✓ Embedding model loaded successfully (dim=$embedding_dim)"

# ============================================================================
# INGESTION PROCEDURE
# ============================================================================

#
# ingest_document - Insert document with embedding into database
#
# Arguments:
#   db         - MySQL database handle
#   categoria  - Document category (transcripcion, metadatos, comentario)
#   texto      - Document content (text to be embedded)
#
# Returns:
#   1 on success, 0 on failure
#
# Process:
#   1. Prepend "passage: " prefix (required for E5 model)
#   2. Generate embedding from text
#   3. Convert embedding list to binary format
#   4. Escape SQL special characters
#   5. Insert into database
#
proc ingest_document {db categoria texto} {
    global handle embedding_dim

    # ─────────────────────────────────────────────────────────────────
    # STEP 1: Prepare text with E5 prefix
    # ─────────────────────────────────────────────────────────────────
    #
    # E5 models use different prefixes for different tasks:
    # - "passage: " for documents being indexed
    # - "query: " for search queries
    #
    # This affects how embeddings are optimized for semantic search.
    #
    set texto_preparado "passage: $texto"

    # ─────────────────────────────────────────────────────────────────
    # STEP 2: Generate embedding vector
    # ─────────────────────────────────────────────────────────────────
    #
    # tokenizer::tokenize + embedding::compute returns a Tcl list of floats
    # Example: {0.123456 -0.234567 0.345678 ... } (384 elements)
    #
    if {[catch {
        set tokens [tokenizer::tokenize $texto_preparado]
        set embedding_list [embedding::compute $handle $tokens]
    } err]} {
        puts "❌ Embedding generation failed: $err"
        return 0
    }

    # Verify embedding dimensions
    if {[llength $embedding_list] != $embedding_dim} {
        puts "⚠️  Warning: Expected $embedding_dim dims, got [llength $embedding_list]"
    }

    # ─────────────────────────────────────────────────────────────────
    # STEP 3: Convert to binary format
    # ─────────────────────────────────────────────────────────────────
    #
    # Tcl embedding is a list of floats. MySQL stores as BINARY.
    # The 'f*' format converts list to native-endian floats (4 bytes each).
    #
    # Example:
    #   Input:  {1.0 0.0 -1.0}
    #   Output: Binary data (12 bytes)
    #   Size:   [llength $embedding_list] * 4 bytes
    #
    set binary_blob [binary format f* $embedding_list]

    if {[string length $binary_blob] != [expr {$embedding_dim * 4}]} {
        puts "⚠️  Binary size mismatch: expected [expr {$embedding_dim * 4}], got [string length $binary_blob]"
    }

    # ─────────────────────────────────────────────────────────────────
    # STEP 4: Escape data for SQL safety
    # ─────────────────────────────────────────────────────────────────
    #
    # mysql::escape handles:
    # - Quote escaping in text (remove ambiguity)
    # - Null byte handling in binary data
    # - Character encoding issues
    #
    # IMPORTANT: Always escape before inserting into SQL strings!
    #
    set esc_texto [mysql::escape $db $texto]
    set esc_blob  [mysql::escape $db $binary_blob]

    # ─────────────────────────────────────────────────────────────────
    # STEP 5: Execute INSERT query
    # ─────────────────────────────────────────────────────────────────
    #
    # Store document with embedding in database
    #
    set sql "INSERT INTO youtube_rag (categoria, contenido, embedding) \
             VALUES ('$categoria', '$esc_texto', '$esc_blob')"

    if {[catch {mysql::query $db $sql} err]} {
        puts "❌ Database INSERT failed: $err"
        return 0
    }

    return 1
}

# ============================================================================
# BATCH INGESTION EXECUTION
# ============================================================================

puts "\n=========================================="
puts "INGESTION PHASE"
puts "=========================================="

# Sample documents to ingest
set documents {
    {
        categoria "transcripcion"
        texto "En este video visitamos el mercado de Tsukiji en Tokio para probar el sushi más fresco de la ciudad. El mercado es una institución icónica con más de 80 años de historia."
    }
    {
        categoria "metadatos"
        texto "Locación: Kioto, Templo Kiyomizu-dera. Clima: Lluvioso. Fecha: 2024-12-21. Duración: 12 minutos. Idioma: Español."
    }
    {
        categoria "comentario"
        texto "La edición del minuto 4:20 es espectacular, me transmitió mucha paz. El color grading está excelente."
    }
}

set ingested_count 0
set failed_count 0

foreach doc $documents {
    dict with doc {
        if {$verbose} {
            puts "\nProcessing: [string range $texto 0 60]..."
        }

        if {[ingest_document $db $categoria $texto]} {
            incr ingested_count
            puts "✅ Ingested ($categoria): [string range $texto 0 50]..."
        } else {
            incr failed_count
            puts "❌ Failed to ingest ($categoria)"
        }
    }
}

# ============================================================================
# COMPLETION AND STATISTICS
# ============================================================================

puts "\n=========================================="
puts "INGESTION SUMMARY"
puts "=========================================="
puts "✓ Successfully ingested: $ingested_count documents"
if {$failed_count > 0} {
    puts "✗ Failed: $failed_count documents"
}
puts ""

# Verify ingestion by counting documents
if {[catch {
    set total [lindex [mysql::query $db "SELECT COUNT(*) FROM youtube_rag"] 0]
    puts "📊 Total documents in database: $total"
} err]} {
    puts "⚠️  Could not verify ingestion: $err"
}

# ============================================================================
# CLEANUP AND SHUTDOWN
# ============================================================================

puts "\n🔌 Closing connections..."

# Close database connection
if {[catch {mysql::close $db}]} {
    puts "⚠️  Warning: Problem closing MySQL connection"
}

# Clean up embedding model resources
# Note: embedding::free is optional but recommended for cleanup
catch {embedding::free $handle}

puts "✓ Ingestion complete\n"

# ============================================================================
# END OF SCRIPT
# ============================================================================
