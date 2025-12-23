#!/usr/bin/env tclsh

#==============================================================================
# search.tcl - Semantic Search with MySQL UDF
#==============================================================================
#
# Purpose: Perform semantic search on documents stored with embeddings.
#          Uses MySQL cosine_similarity UDF for fast similarity calculation.
#
# This script demonstrates:
# - Generating query embeddings for semantic search
# - Computing similarity with stored document embeddings
# - Using MySQL UDF for database-level similarity calculations
# - Ranking results by relevance score
# - Displaying semantic search results
#
# Dependencies:
# - tclembedding    - Query embedding generation
# - mysqltcl        - MySQL connectivity
# - MySQL UDF       - cosine_similarity function (from rag_optimizations.c)
#
# Prerequisites:
# - MySQL database with documents ingested (run ingest.tcl first)
# - cosine_similarity UDF registered in MySQL
#
# Usage:
#   tclsh search.tcl
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

# Search parameters
set embedding_dim 384          ;# Number of dimensions in embeddings
set default_limit 3            ;# Default results to return
set min_score_threshold 0.0    ;# Minimum similarity score
set verbose 1                  ;# Print progress messages

# ============================================================================
# INITIALIZATION AND VALIDATION
# ============================================================================

puts "🚀 Initializing Semantic Search..."
puts ""

# Verify model files exist
if {![file exists $model_onnx]} {
    puts "❌ ERROR: Model file not found: $model_onnx"
    exit 1
}

if {![file exists $model_vocab]} {
    puts "❌ ERROR: Tokenizer file not found: $model_vocab"
    exit 1
}

# Connect to MySQL database
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
    puts "1. Ensure MySQL is running"
    puts "2. Verify ingest.tcl has been run to populate database"
    puts "3. Check cosine_similarity UDF is registered"
    exit 1
}

puts "✓ Connected to MySQL"

# Initialize embedding model
if {[catch {
    tokenizer::load_vocab $model_vocab
    set handle [embedding::init_raw $model_onnx]
} err]} {
    puts "❌ Failed to initialize embedding model: $err"
    mysql::close $db
    exit 1
}

puts "✓ Embedding model loaded"
puts ""

# Verify UDF is available
if {[catch {
    mysql::query $db "SELECT cosine_similarity(x'00000000', x'00000000')"
} err]} {
    puts "⚠️  WARNING: cosine_similarity UDF may not be registered"
    puts "   Error: $err"
    puts "   To register: CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'mysql_cosine_similarity.so';"
}

# ============================================================================
# SEMANTIC SEARCH PROCEDURE
# ============================================================================

#
# semantic_search - Find similar documents to a query
#
# Arguments:
#   db        - MySQL database handle
#   query     - Search query string (natural language)
#   limit     - Maximum number of results to return (default: 3)
#
# Returns:
#   List of results, each containing:
#   - id: Document ID
#   - titulo: Document title/preview
#   - categoria: Document category
#   - score: Similarity score (0.0 to 1.0)
#   - contenido: Document content
#
# Process:
#   1. Prepend "query: " prefix (required for E5 model)
#   2. Generate embedding for query using tclembedding
#   3. Convert embedding to binary format
#   4. Execute SQL SELECT with cosine_similarity() UDF
#   5. ORDER BY similarity score DESC
#   6. Return top-K results
#
proc semantic_search {db query {limit 3}} {
    global handle embedding_dim verbose

    # ─────────────────────────────────────────────────────────────────
    # STEP 1: Prepare query with E5 prefix
    # ─────────────────────────────────────────────────────────────────
    #
    # E5 models require "query: " prefix for search queries.
    # This optimizes embeddings for semantic search (as opposed to
    # document embeddings which use "passage: " prefix).
    #
    set query_prepared "query: $query"

    if {$verbose} {
        puts "🔍 Query: $query"
    }

    # ─────────────────────────────────────────────────────────────────
    # STEP 2: Generate query embedding
    # ─────────────────────────────────────────────────────────────────
    #
    # tokenizer::tokenize + embedding::compute returns list of floats
    # representing the semantic meaning of the query
    #
    if {[catch {
        set tokens [tokenizer::tokenize $query_prepared]
        set query_embedding [embedding::compute $handle $tokens]
    } err]} {
        puts "❌ Embedding generation failed: $err"
        return [list]
    }

    if {[llength $query_embedding] != $embedding_dim} {
        puts "⚠️  Warning: Unexpected embedding dimensions"
    }

    # ─────────────────────────────────────────────────────────────────
    # STEP 3: Convert to binary format for MySQL
    # ─────────────────────────────────────────────────────────────────
    #
    # MySQL expects embeddings as binary data.
    # Format 'f*' = native-endian floats (4 bytes each)
    #
    set binary_query [binary format f* $query_embedding]

    # ─────────────────────────────────────────────────────────────────
    # STEP 4: Escape binary data for safe SQL insertion
    # ─────────────────────────────────────────────────────────────────
    #
    # mysql::escape protects against:
    # - Null bytes in binary data
    # - Quote escaping issues
    # - Character encoding problems
    #
    set esc_query [mysql::escape $db $binary_query]

    # ─────────────────────────────────────────────────────────────────
    # STEP 5: Build and execute SQL query
    # ─────────────────────────────────────────────────────────────────
    #
    # SELECT with cosine_similarity() UDF:
    # - cosine_similarity(stored_embedding, query_embedding)
    # - ORDER BY score DESC (most similar first)
    # - LIMIT to top-K results
    #
    # The cosine_similarity() UDF is implemented in C for performance.
    # It calculates: dot(v1,v2) / (magnitude(v1) * magnitude(v2))
    #
    set sql "SELECT contenido, categoria,
                    cosine_similarity(embedding, '$esc_query') AS score
             FROM youtube_rag
             ORDER BY score DESC
             LIMIT $limit"

    # ─────────────────────────────────────────────────────────────────
    # STEP 6: Execute query and collect results
    # ─────────────────────────────────────────────────────────────────
    #
    # mysql::sel executes SELECT
    # mysql::map iterates through results with variable binding
    #
    set results [list]
    set result_count 0

    if {[catch {
        mysql::sel $db $sql

        mysql::map $db {contenido categoria score} {
            incr result_count

            # Format score to 4 decimal places
            set score_fmt [format "%.4f" $score]

            # Display result
            set content_preview [string range $contenido 0 80]
            puts "   #$result_count \[$score_fmt\] ($categoria): $content_preview..."

            # Store result
            lappend results [dict create \
                rank $result_count \
                categoria $categoria \
                score $score \
                contenido $contenido \
            ]
        }

        # Handle no results
        if {$result_count == 0} {
            puts "   (No results found)"
        }

    } err]} {
        puts "❌ Search SQL error: $err"
        puts ""
        puts "Troubleshooting:"
        puts "1. Check if cosine_similarity UDF is registered:"
        puts "   mysql -u root -e \"SHOW FUNCTION STATUS WHERE Db = 'rag';\""
        puts ""
        puts "2. Verify database has documents:"
        puts "   mysql -u root rag -e \"SELECT COUNT(*) FROM youtube_rag;\""
        puts ""
        puts "3. If UDF missing, register it:"
        puts "   mysql -u root rag -e \"CREATE FUNCTION cosine_similarity"
        puts "     RETURNS REAL SONAME 'mysql_cosine_similarity.so';\""
        puts ""
        return [list]
    }

    return $results
}

# ============================================================================
# SEARCH EXECUTION
# ============================================================================

puts "=========================================="
puts "SEMANTIC SEARCH RESULTS"
puts "=========================================="
puts ""

# Sample queries to demonstrate search capabilities
set queries {
    "¿Qué comieron en Tokio?"
    "¿Qué opinan de la edición?"
    "Templos antiguos"
}

# Execute searches
foreach query $queries {
    set results [semantic_search $db $query $default_limit]

    if {[llength $results] > 0} {
        # Calculate average score
        set sum 0.0
        foreach result $results {
            set sum [expr {$sum + [dict get $result score]}]
        }
        set avg_score [expr {$sum / [llength $results]}]

        puts "   └─ Average similarity: [format "%.4f" $avg_score]"
    }

    puts ""
    after 200  ;# Small delay between queries for readability
}

# ============================================================================
# CUSTOM SEARCH EXAMPLE
# ============================================================================

# Uncomment to run custom search
#
# puts "\n--- CUSTOM SEARCH ---"
# puts ""
# set custom_results [semantic_search $db "Your custom query here" 5]

# ============================================================================
# CLEANUP AND SHUTDOWN
# ============================================================================

puts "🔌 Closing connections..."

# Close database connection
if {[catch {mysql::close $db}]} {
    puts "⚠️  Warning: Problem closing MySQL connection"
}

# Clean up embedding model
catch {embedding::free $handle}

puts "✓ Search complete\n"

# ============================================================================
# END OF SCRIPT
# ============================================================================
