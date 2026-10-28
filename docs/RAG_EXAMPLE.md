# RAG (Retrieval-Augmented Generation) Example

Complete working example of using tclembedding with MySQL for semantic search and knowledge retrieval.

## What is RAG?

**Retrieval-Augmented Generation** is a technique that:

1. **Retrieves** relevant documents from a knowledge base using semantic search
2. **Augments** an LLM prompt with the retrieved context
3. **Generates** answers based on the augmented prompt

### RAG Workflow

```
User Query
    ↓
[1] Generate Query Embedding (tclembedding)
    ↓
[2] Search Database for Similar Documents (MySQL UDF)
    ↓
[3] Retrieve Top-K Most Similar Documents
    ↓
[4] Augment Prompt with Retrieved Context
    ↓
[5] Send to LLM for Answer Generation
    ↓
Answer with Context
```

## Architecture

```
┌────────────────────────────────────────────────────┐
│                   Tcl RAG Application              │
├────────────────────────────────────────────────────┤
│                                                    │
│  ┌──────────────────────────────────────────────┐ │
│  │  Knowledge Base Loading & Ingestion          │ │
│  │  • Load documents from files/APIs            │ │
│  │  • Generate embeddings (tclembedding)        │ │
│  │  • Store with metadata (MySQL)               │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  ┌──────────────────────────────────────────────┐ │
│  │  Query Processing & Retrieval                │ │
│  │  • User query → embedding (tclembedding)    │ │
│  │  • Semantic search (MySQL cosine UDF)        │ │
│  │  • Retrieve top results                      │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  ┌──────────────────────────────────────────────┐ │
│  │  Context Augmentation & Response             │ │
│  │  • Format retrieved documents                │ │
│  │  • Create augmented prompt                   │ │
│  │  • Send to LLM (API or local)                │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
└────────────────────────────────────────────────────┘
```

## Project Structure

```
rag_example/
├── config.tcl              # Configuration
├── rag.tcl                 # Main RAG application
├── database.tcl            # Database operations
├── retriever.tcl           # Retrieval operations
├── knowledge_base/         # Sample documents
│   ├── document1.txt
│   ├── document2.txt
│   └── ...
└── models/                 # Embedding models
    └── e5-small/
        ├── model.onnx
        └── tokenizer.json
```

## Implementation

### Step 1: Configuration

File: `config.tcl`

```tcl
#!/usr/bin/env tclsh

# MySQL Configuration
set config(mysql_host) "localhost"
set config(mysql_user) "root"
set config(mysql_password) "password"
set config(mysql_database) "rag_db"

# Model Configuration
set config(model_path) "models/e5-small/model.onnx"
set config(tokenizer_path) "models/e5-small/tokenizer.json"

# RAG Configuration
set config(retrieval_limit) 5
set config(similarity_threshold) 0.6
set config(chunk_size) 500  ;# Characters per chunk
set config(chunk_overlap) 50

# API Configuration (if using external LLM)
set config(llm_api) "http://localhost:8000"
set config(llm_model) "mistral"
set config(llm_temperature) 0.7
```

### Step 2: Database Operations

File: `database.tcl`

```tcl
#!/usr/bin/env tclsh

package require mysqltcl

# ============ DATABASE INITIALIZATION ============

proc init_database {host user password database} {
    # Create database if not exists
    set root_db [mysql::connect -host $host -user $user -password $password]

    mysql::query $root_db "CREATE DATABASE IF NOT EXISTS $database"
    mysql::close $root_db

    # Connect to database
    set db [mysql::connect -host $host -user $user -password $password -db $database]

    # Create tables
    mysql::query $db {
        CREATE TABLE IF NOT EXISTS documents (
            id INT AUTO_INCREMENT PRIMARY KEY,
            title VARCHAR(255),
            source VARCHAR(255),
            content LONGTEXT,
            embedding BINARY(1536),
            chunk_index INT DEFAULT 0,
            chunk_total INT DEFAULT 1,
            metadata JSON,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

            INDEX idx_source (source),
            INDEX idx_chunk (chunk_index)
        ) ENGINE=InnoDB
    }

    mysql::query $db {
        CREATE TABLE IF NOT EXISTS retrieval_logs (
            id INT AUTO_INCREMENT PRIMARY KEY,
            query TEXT,
            results_count INT,
            avg_score FLOAT,
            response_time_ms INT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

            INDEX idx_created (created_at)
        ) ENGINE=InnoDB
    }

    puts "✓ Database initialized"
    return $db
}

# ============ DOCUMENT STORAGE ============

proc store_document {db title source content embedding {metadata ""}} {
    set esc_title [mysql::escape $db $title]
    set esc_source [mysql::escape $db $source]
    set esc_content [mysql::escape $db $content]
    set esc_embedding [mysql::escape $db $embedding]
    set esc_metadata [mysql::escape $db $metadata]

    set sql "INSERT INTO documents
             (title, source, content, embedding, metadata)
             VALUES ('$esc_title', '$esc_source', '$esc_content',
                     '$esc_embedding', '$esc_metadata')"

    mysql::query $db $sql
}

# ============ DOCUMENT RETRIEVAL ============

proc retrieve_similar {db query_embedding limit {threshold 0.0}} {
    set esc_query [mysql::escape $db $query_embedding]

    set sql "SELECT id, title, source, content,
                    cosine_similarity(embedding, '$esc_query') AS score
             FROM documents
             WHERE cosine_similarity(embedding, '$esc_query') > $threshold
             ORDER BY score DESC
             LIMIT $limit"

    set results [list]
    mysql::sel $db $sql
    mysql::map $db {id title source content score} {
        lappend results [dict create \
            id $id \
            title $title \
            source $source \
            content $content \
            score $score \
        ]
    }

    return $results
}

# ============ LOG RETRIEVAL ============

proc log_retrieval {db query results_count avg_score response_time_ms} {
    set esc_query [mysql::escape $db $query]

    set sql "INSERT INTO retrieval_logs
             (query, results_count, avg_score, response_time_ms)
             VALUES ('$esc_query', $results_count, $avg_score, $response_time_ms)"

    mysql::query $db $sql
}
```

### Step 3: Retriever Component

File: `retriever.tcl`

```tcl
#!/usr/bin/env tclsh

package require tclembedding
package require tokenizer

# ============ EMBEDDING MANAGEMENT ============

proc init_embedding_model {model_path tokenizer_path} {
    global embedding_handle

    if {[catch {
        tokenizer::load_vocab $tokenizer_path
        set embedding_handle [embedding::init_raw $model_path]
        puts "✓ Embedding model initialized"
        return 1
    } err]} {
        puts "ERROR: Failed to initialize model: $err"
        return 0
    }
}

proc generate_query_embedding {query} {
    global embedding_handle

    # E5 models expect "query: " prefix for search queries
    set prefixed_query "query: $query"

    if {[catch {
        set tokens [tokenizer::tokenize $prefixed_query]
        set embedding_list [embedding::compute $embedding_handle $tokens]
        set binary_data [binary format f* $embedding_list]
        return $binary_data
    } err]} {
        puts "ERROR generating embedding: $err"
        return ""
    }
}

proc generate_passage_embedding {passage} {
    global embedding_handle

    # E5 models expect "passage: " prefix for documents
    set prefixed_passage "passage: $passage"

    if {[catch {
        set tokens [tokenizer::tokenize $prefixed_passage]
        set embedding_list [embedding::compute $embedding_handle $tokens]
        set binary_data [binary format f* $embedding_list]
        return $binary_data
    } err]} {
        puts "ERROR generating embedding: $err"
        return ""
    }
}

# ============ DOCUMENT CHUNKING ============

proc chunk_document {text chunk_size overlap} {
    set chunks [list]
    set text_length [string length $text]

    set start 0
    while {$start < $text_length} {
        set end [expr {$start + $chunk_size}]
        if {$end > $text_length} {
            set end $text_length
        }

        set chunk [string range $text $start $end]
        lappend chunks $chunk

        # Move start position
        set start [expr {$end - $overlap}]
        if {$start <= 0} {
            break
        }
    }

    return $chunks
}

# ============ INGESTION ============

proc ingest_document {db title source content chunk_size overlap} {
    # Chunk the document
    set chunks [chunk_document $content $chunk_size $overlap]
    set chunk_total [llength $chunks]

    puts "Ingesting '$title' ([llength $chunks] chunks)..."

    set chunk_index 0
    foreach chunk $chunks {
        # Generate embedding
        set embedding [generate_passage_embedding $chunk]
        if {$embedding eq ""} {
            puts "  ✗ Failed to generate embedding for chunk $chunk_index"
            continue
        }

        # Store in database
        store_document $db "$title (chunk $chunk_index)" $source $chunk $embedding

        puts "  ✓ Stored chunk $chunk_index/$chunk_total"
        incr chunk_index
    }
}

# ============ RETRIEVAL ============

proc retrieve_context {db query limit threshold} {
    set start_time [clock clicks -milliseconds]

    # Generate query embedding
    set query_embedding [generate_query_embedding $query]
    if {$query_embedding eq ""} {
        puts "ERROR: Failed to generate query embedding"
        return [list]
    }

    # Retrieve similar documents
    set results [retrieve_similar $db $query_embedding $limit $threshold]

    # Calculate metrics
    set response_time [expr {[clock clicks -milliseconds] - $start_time}]
    set avg_score 0.0
    if {[llength $results] > 0} {
        set sum 0.0
        foreach result $results {
            set sum [expr {$sum + [dict get $result score]}]
        }
        set avg_score [expr {$sum / [llength $results]}]
    }

    # Log retrieval
    log_retrieval $db $query [llength $results] $avg_score $response_time

    puts "✓ Retrieved [llength $results] documents in ${response_time}ms"

    return $results
}

# ============ CONTEXT FORMATTING ============

proc format_context {results} {
    set context ""

    foreach result $results {
        dict with result {
            append context "**$title** (similarity: [format "%.2f" $score])\n"
            append context "[string range $content 0 200]...\n\n"
        }
    }

    return $context
}
```

### Step 4: Main RAG Application

File: `rag.tcl`

```tcl
#!/usr/bin/env tclsh

source config.tcl
source database.tcl
source retriever.tcl

package require tclembedding
package require mysqltcl

# ============ INITIALIZATION ============

proc initialize_rag {} {
    global config db embedding_handle

    puts "🚀 Initializing RAG System..."

    # Initialize database
    set db [init_database \
        $config(mysql_host) \
        $config(mysql_user) \
        $config(mysql_password) \
        $config(mysql_database) \
    ]

    # Initialize embedding model
    init_embedding_model $config(model_path) $config(tokenizer_path)

    puts "✓ RAG System Ready"
}

# ============ BUILD KNOWLEDGE BASE ============

proc build_knowledge_base {documents_dir} {
    global db config

    puts "\n📚 Building Knowledge Base..."

    # Scan directory for text files
    set files [glob -nocomplain -directory $documents_dir "*.txt"]

    if {[llength $files] == 0} {
        puts "WARNING: No text files found in $documents_dir"
        return
    }

    set count 0
    foreach file $files {
        if {[catch {
            set fp [open $file r]
            set content [read $fp]
            close $fp

            set title [file rootname [file tail $file]]
            ingest_document $db $title $file $content \
                $config(chunk_size) $config(chunk_overlap)

            incr count
        } err]} {
            puts "ERROR processing $file: $err"
        }
    }

    puts "✓ Ingested $count documents"
}

# ============ QUERY AND RETRIEVE ============

proc query_rag {query} {
    global db config

    puts "\n❓ Query: $query"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Retrieve relevant context
    set results [retrieve_context $db $query \
        $config(retrieval_limit) \
        $config(similarity_threshold) \
    ]

    # Format context
    set context [format_context $results]

    puts "\n📄 Retrieved Context:"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts $context

    # In a real system, this would be augmented with a prompt
    # and sent to an LLM for answer generation
    set augmented_prompt "Context:\n$context\n\nQuestion: $query\n\nAnswer:"

    puts "📝 Augmented Prompt (first 200 chars):"
    puts "[string range $augmented_prompt 0 200]...\n"

    return [dict create \
        query $query \
        context $context \
        results $results \
    ]
}

# ============ CLEANUP ============

proc cleanup_rag {} {
    global db embedding_handle

    puts "\n🔌 Closing connections..."

    if {[info exists db]} {
        mysql::close $db
    }

    if {[info exists embedding_handle]} {
        embedding::free $embedding_handle
    }

    puts "✓ Cleanup complete"
}

# ============ MAIN ============

if {[info exists argv0] && $argv0 eq [info script]} {
    # Initialize
    if {[catch {initialize_rag} err]} {
        puts "FATAL: $err"
        exit 1
    }

    # Build knowledge base from sample documents
    set kb_dir [file join [file dirname [info script]] "knowledge_base"]
    if {[file exists $kb_dir]} {
        build_knowledge_base $kb_dir
    }

    # Run sample queries
    set queries {
        "What is the main topic?"
        "How does the system work?"
        "What are the key concepts?"
    }

    foreach query $queries {
        query_rag $query
        after 500  ;# Small delay between queries
    }

    # Cleanup
    cleanup_rag

    puts "✓ RAG Example Complete\n"
}
```

## Sample Knowledge Base

Create sample documents in `knowledge_base/`:

### document1.txt
```
Tcl (Tool Command Language) is a high-level scripting language that provides
excellent cross-platform compatibility. It was created by John Ousterhout in
1988 and has since become widely used for automation, testing, and system
administration tasks.

Key features of Tcl include:
- Simple and readable syntax
- Dynamic typing
- Powerful string manipulation
- Extensive C extension capabilities
- Cross-platform support (Unix, Linux, Windows, macOS)

Tcl is particularly useful for rapid development and system integration.
```

### document2.txt
```
Text embeddings are numerical representations of words or documents that
capture their semantic meaning. They are generated using neural networks
and are widely used in natural language processing tasks.

Embeddings allow us to:
- Measure semantic similarity between texts
- Perform semantic search
- Train machine learning models
- Build recommendation systems

Modern embedding models like E5, BERT, and Sentence-Transformers provide
state-of-the-art performance for various tasks.
```

## Running the Example

### 1. Prepare Environment

```bash
# Install dependencies
sudo apt-get install mysql-server libmysqlclient-dev mysqltcl

# Or macOS
brew install mysql mysqltcl
```

### 2. Set Up MySQL

```bash
# Start MySQL
sudo systemctl start mysql

# Create user and database
mysql -u root -p
> CREATE USER 'rag_user'@'localhost' IDENTIFIED BY 'rag_password';
> CREATE DATABASE rag_db;
> GRANT ALL ON rag_db.* TO 'rag_user'@'localhost';
> FLUSH PRIVILEGES;
```

### 3. Install UDF

Follow instructions in [MYSQL_UDF.md](MYSQL_UDF.md) to register `cosine_similarity` UDF.

### 4. Create Sample Documents

```bash
mkdir -p knowledge_base
echo "Document content..." > knowledge_base/doc1.txt
echo "More content..." > knowledge_base/doc2.txt
```

### 5. Run RAG Application

```bash
tclsh rag.tcl
```

### Expected Output

```
🚀 Initializing RAG System...
✓ Database initialized
✓ Embedding model initialized
✓ RAG System Ready

📚 Building Knowledge Base...
Ingesting 'document1' (2 chunks)...
  ✓ Stored chunk 0/2
  ✓ Stored chunk 1/2
✓ Ingested 2 documents

❓ Query: What is the main topic?
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Retrieved 3 documents in 45ms

📄 Retrieved Context:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
**document1 (chunk 0)** (similarity: 0.89)
Tcl (Tool Command Language) is a high-level scripting language...

**document2 (chunk 0)** (similarity: 0.76)
Text embeddings are numerical representations...
```

## Advanced Features

### Multi-Query Expansion

```tcl
proc expand_query {original_query} {
    # Generate multiple interpretations of the query
    set variations [list $original_query]

    # Simple expansion: add related terms
    lappend variations "$original_query features"
    lappend variations "how $original_query"
    lappend variations "$original_query implementation"

    return $variations
}

# Use expanded queries for better retrieval
set expanded_queries [expand_query "semantic search"]
foreach query $expanded_queries {
    set results [retrieve_context $db $query 3 0.5]
    # Process results...
}
```

### Re-ranking Results

```tcl
proc rerank_results {results query} {
    # Simple re-ranking: prefer longer documents
    set ranked [lsort -command [lambda {a b} {
        set len_a [string length [dict get $a content]]
        set len_b [string length [dict get $b content]]
        return [expr {$len_b - $len_a}]
    }] $results]

    return $ranked
}
```

### Relevance Feedback

```tcl
proc log_relevance_feedback {query result_id is_relevant} {
    global db

    set sql "INSERT INTO feedback (query, result_id, is_relevant)
             VALUES ('$query', $result_id, $is_relevant)"

    mysql::query $db $sql
}
```

## Performance Metrics

```tcl
proc print_statistics {db} {
    # Average retrieval time
    set avg_time [lindex [mysql::query $db \
        "SELECT AVG(response_time_ms) FROM retrieval_logs"] 0]

    # Total queries
    set total_queries [lindex [mysql::query $db \
        "SELECT COUNT(*) FROM retrieval_logs"] 0]

    # Average results per query
    set avg_results [lindex [mysql::query $db \
        "SELECT AVG(results_count) FROM retrieval_logs"] 0]

    puts "📊 RAG Statistics"
    puts "  Total Queries: $total_queries"
    puts "  Avg Response Time: ${avg_time}ms"
    puts "  Avg Results: $avg_results"
}
```

## Integration with LLMs

To augment queries with an external LLM:

```tcl
proc augment_with_llm {query context llm_api llm_model} {
    set prompt "Context:\n$context\n\nQuestion: $query\n\nProvide a comprehensive answer based on the context."

    # Call LLM API (example with HTTP)
    set response [exec curl -s -X POST "$llm_api/generate" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"$llm_model\", \"prompt\": \"$prompt\"}" \
    ]

    return $response
}

# Usage
set results [retrieve_context $db $query 5 0.6]
set context [format_context $results]
set answer [augment_with_llm $query $context \
    "http://localhost:8000" "mistral"
]

puts "Answer: $answer"
```

## References

- **Tcl Embeddings:** [README.md](README.md)
- **MySQL Integration:** [MYSQL_INTEGRATION.md](MYSQL_INTEGRATION.md)
- **UDF Reference:** [MYSQL_UDF.md](MYSQL_UDF.md)
- **Tools:** `tools/` directory

---

This example demonstrates a complete RAG system with semantic search capabilities using tclembedding and MySQL.
