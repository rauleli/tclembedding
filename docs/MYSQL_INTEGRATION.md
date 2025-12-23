# MySQL Integration with tclembedding

Complete guide to integrating text embeddings with MySQL for semantic search and RAG (Retrieval-Augmented Generation) applications.

## Overview

This integration combines:

1. **tclembedding** - Generate embeddings from text using ONNX models
2. **MySQL UDF** - Calculate similarity directly in the database
3. **mysqltcl** - Connect Tcl scripts to MySQL
4. **Tools** - Scripts for data ingestion and semantic search

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Tcl Application                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  • ingest.tcl   ─→ Load documents, generate embeddings    │
│  • search.tcl   ─→ Query, calculate similarity, retrieve  │
│                                                             │
├──────────────────────┬──────────────────────┐───────────────┤
│ tclembedding         │ mysqltcl             │ Other libs    │
│ (ONNX Runtime)       │ (MySQL connector)    │               │
├──────────────────────┴──────────────────────┴───────────────┤
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              MySQL Server                            │  │
│  ├──────────────────────────────────────────────────────┤  │
│  │ • Documents table with BINARY embedding columns     │  │
│  │ • cosine_similarity() UDF for similarity search     │  │
│  │ • Indexed queries for fast retrieval                │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Required Software

1. **tclembedding**
   - Installed and working
   - Models available (e5-small, MiniLM, etc.)
   - See: [INSTALL.md](INSTALL.md)

2. **MySQL Server**
   - Version 5.7 or later
   - Running and accessible
   - Admin access for UDF registration

3. **mysqltcl**
   - Tcl MySQL connector library
   - Installation: See below

4. **ONNX Models**
   - e5-small or other embedding models
   - In `models/` directory

### Installation Steps

#### 1. Install mysqltcl

**Ubuntu/Debian:**
```bash
# Package manager
sudo apt-get install mysqltcl

# Or compile from source
git clone https://github.com/rene-aguirre/mysqltcl.git
cd mysqltcl
make
make install
```

**macOS:**
```bash
brew install mysqltcl
# Or via MacPorts
sudo port install mysqltcl
```

**Manual Compilation:**
```bash
# Download mysqltcl source
wget https://github.com/rene-aguirre/mysqltcl/archive/master.zip
unzip master.zip
cd mysqltcl-master

# Compile
./configure --with-tcl=/path/to/tcl
make
sudo make install

# Verify
tclsh -c "package require mysqltcl; puts OK"
```

#### 2. Install MySQL Development Files

**Ubuntu/Debian:**
```bash
sudo apt-get install libmysqlclient-dev mysql-server
```

**Fedora/RHEL:**
```bash
sudo dnf install mysql-devel mysql-server
```

**macOS:**
```bash
brew install mysql
```

#### 3. Install and Register cosine_similarity UDF

Follow instructions in [MYSQL_UDF.md](MYSQL_UDF.md):

```bash
cd src/
gcc -shared -fPIC -o cosine_similarity.so rag_optimizations.c \
  $(mysql_config --cflags --libs) -lm

sudo cp cosine_similarity.so /usr/lib/mysql/plugin/
```

Register in MySQL:
```sql
CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'cosine_similarity.so';
```

## Database Schema

### Basic Embeddings Table

For storing documents with embeddings:

```sql
CREATE TABLE documents (
    id INT AUTO_INCREMENT PRIMARY KEY,
    title VARCHAR(255),
    content LONGTEXT,
    embedding BINARY(1536),  -- 384-dim embeddings * 4 bytes
    category VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    INDEX idx_category (category),
    INDEX idx_created (created_at),
    FULLTEXT INDEX ft_content (content)
) ENGINE=InnoDB;
```

### YouTube/Video Content Example

For video transcriptions and metadata:

```sql
CREATE TABLE youtube_content (
    id INT AUTO_INCREMENT PRIMARY KEY,
    video_id VARCHAR(20),
    video_title VARCHAR(255),
    content_type ENUM('transcription', 'metadata', 'comment'),
    content TEXT,
    embedding BINARY(1536),  -- 384-dim
    timestamp_seconds INT,    -- For videos
    language VARCHAR(10),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    INDEX idx_video (video_id),
    INDEX idx_type (content_type),
    INDEX idx_language (language)
) ENGINE=InnoDB;
```

### Chunks Table (for Long Documents)

For splitting long documents into chunks:

```sql
CREATE TABLE document_chunks (
    id INT AUTO_INCREMENT PRIMARY KEY,
    document_id INT,
    chunk_number INT,
    chunk_text TEXT,
    embedding BINARY(1536),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE,
    INDEX idx_doc (document_id),
    INDEX idx_chunk (chunk_number)
) ENGINE=InnoDB;
```

## Tcl Integration

### Connection Management

```tcl
package require mysqltcl

# Connect to MySQL
set db [mysql::connect \
    -host localhost \
    -user your_user \
    -password your_password \
    -db your_database \
]

# Test connection
if {[catch {mysql::query $db "SELECT 1"} result]} {
    puts "Connection failed: $result"
    exit 1
}

# ... do work ...

# Clean close
mysql::close $db
```

### Safe Connection with Error Handling

```tcl
proc connect_to_database {host user password database} {
    if {[catch {
        set db [mysql::connect \
            -host $host \
            -user $user \
            -password $password \
            -db $database \
        ]

        # Verify connection
        mysql::query $db "SELECT 1"

        return $db
    } err]} {
        puts "ERROR: Failed to connect to MySQL"
        puts "Details: $err"
        return ""
    }
}

# Usage
set db [connect_to_database "localhost" "root" "password" "mydb"]
if {$db eq ""} { exit 1 }
```

### Embedding Generation with Proper Encoding

```tcl
package require tclembedding
package require tokenizer

# Initialize model
proc init_embedding_model {model_path tokenizer_path} {
    global embedding_handle

    if {[catch {
        tokenizer::load_vocab $tokenizer_path
        set embedding_handle [embedding::init_raw $model_path]
        puts "✓ Embedding model loaded"
    } err]} {
        puts "ERROR loading model: $err"
        return 0
    }
    return 1
}

# Generate embedding (with E5 prefix for semantic search)
proc generate_embedding {text embedding_type} {
    global embedding_handle

    # E5 models expect specific prefixes
    # passage: for documents being indexed
    # query: for search queries
    set prefixed_text "$embedding_type: $text"

    if {[catch {
        set tokens [tokenizer::tokenize $prefixed_text]
        set embedding_list [embedding::compute $embedding_handle $tokens]

        # Convert to binary (4 bytes per float)
        set binary_data [binary format f* $embedding_list]

        return $binary_data
    } err]} {
        puts "ERROR generating embedding: $err"
        return ""
    }
}

# Cleanup
proc cleanup_embedding {} {
    global embedding_handle
    if {[info exists embedding_handle]} {
        embedding::free $embedding_handle
    }
}
```

## Data Ingestion

### Ingestion Workflow

```tcl
package require tclembedding
package require mysqltcl

proc ingest_document {db document_text category} {
    global embedding_handle

    # 1. Generate embedding
    set embedding_binary [generate_embedding $document_text "passage"]
    if {$embedding_binary eq ""} {
        return 0
    }

    # 2. Escape for SQL
    set escaped_text [mysql::escape $db $document_text]
    set escaped_embedding [mysql::escape $db $embedding_binary]

    # 3. Insert into database
    set sql "INSERT INTO documents (content, category, embedding)
             VALUES ('$escaped_text', '$category', '$escaped_embedding')"

    if {[catch {mysql::query $db $sql} result]} {
        puts "ERROR inserting document: $result"
        return 0
    }

    puts "✓ Ingested: [string range $document_text 0 50]..."
    return 1
}

# Example usage
set db [mysql::connect -user root -db mydb]
init_embedding_model "models/e5-small/model.onnx" "models/e5-small/tokenizer.json"

ingest_document $db "This is my document content" "article"
ingest_document $db "Another text to index" "blog"

mysql::close $db
cleanup_embedding
```

### Batch Ingestion with Progress

```tcl
proc ingest_batch {db documents {batch_size 100}} {
    global embedding_handle

    set total [llength $documents]
    set count 0

    foreach doc_data $documents {
        dict with doc_data {
            set binary [generate_embedding $content "passage"]
            if {$binary ne ""} {
                set esc_content [mysql::escape $db $content]
                set esc_binary [mysql::escape $db $binary]

                set sql "INSERT INTO documents (title, content, category, embedding)
                         VALUES ('$title', '$esc_content', '$category', '$esc_binary')"

                if {[catch {mysql::query $db $sql}]} {
                    puts "WARNING: Failed to ingest '$title'"
                } else {
                    incr count
                    if {$count % $batch_size == 0} {
                        puts "Ingested $count/$total documents..."
                    }
                }
            }
        }
    }

    puts "✓ Ingestion complete: $count/$total documents"
}

# Usage
set documents {
    {title "Doc 1" content "..." category "news"}
    {title "Doc 2" content "..." category "blog"}
    {title "Doc 3" content "..." category "research"}
}

ingest_batch $db $documents 10
```

## Semantic Search

### Basic Search Query

```tcl
proc semantic_search {db query {limit 5}} {
    global embedding_handle

    # 1. Generate query embedding
    set query_binary [generate_embedding $query "query"]
    if {$query_binary eq ""} {
        return [list]
    }

    # 2. Escape for SQL
    set esc_query [mysql::escape $db $query_binary]

    # 3. Execute similarity search
    set sql "SELECT id, title, content, category,
                    cosine_similarity(embedding, '$esc_query') AS score
             FROM documents
             ORDER BY score DESC
             LIMIT $limit"

    # 4. Fetch and format results
    set results [list]
    if {[catch {
        mysql::sel $db $sql
        mysql::map $db {id title content category score} {
            lappend results [dict create \
                id $id \
                title $title \
                content [string range $content 0 100] \
                category $category \
                score [format "%.4f" $score]
            ]
        }
    } err]} {
        puts "ERROR in search: $err"
        return [list]
    }

    return $results
}

# Usage
set results [semantic_search $db "my search query" 10]
foreach result $results {
    dict with result {
        puts "[$score] $title ($category)"
        puts "  $content..."
    }
}
```

### Search with Filtering

```tcl
proc filtered_semantic_search {db query category {min_score 0.7} {limit 5}} {
    global embedding_handle

    set query_binary [generate_embedding $query "query"]
    if {$query_binary eq ""} { return [list] }

    set esc_query [mysql::escape $db $query_binary]

    # Include WHERE clause for filtering
    set sql "SELECT id, title, category,
                    cosine_similarity(embedding, '$esc_query') AS score
             FROM documents
             WHERE category = '$category'
               AND cosine_similarity(embedding, '$esc_query') > $min_score
             ORDER BY score DESC
             LIMIT $limit"

    set results [list]
    mysql::sel $db $sql
    mysql::map $db {id title category score} {
        lappend results [dict create \
            id $id title $title category $category score $score]
    }

    return $results
}
```

### Batch Search

```tcl
proc batch_search {db queries} {
    set all_results [dict create]

    foreach query $queries {
        set results [semantic_search $db $query 5]
        dict set all_results $query $results
        puts "Searched: $query"
    }

    return $all_results
}

# Usage
set queries {
    "How to learn Tcl?"
    "MySQL best practices"
    "Semantic search examples"
}

set results [batch_search $db $queries]
dict for {query hits} $results {
    puts "Query: $query"
    puts "  Found [llength $hits] results"
}
```

## Performance Optimization

### Index Strategy

```sql
-- Create indexes for common queries
CREATE INDEX idx_category_created ON documents(category, created_at);
CREATE INDEX idx_type ON youtube_content(content_type);

-- For temporal queries
CREATE INDEX idx_created_year ON documents(YEAR(created_at));
```

### Query Optimization

```tcl
# Fast: Filter first, then similarity
proc optimized_search {db query category {limit 5}} {
    # Filter by category first (uses index)
    # Then calculate similarity only for filtered results
    set query_binary [generate_embedding $query "query"]
    set esc_query [mysql::escape $db $query_binary]

    set sql "SELECT id, title,
                    cosine_similarity(embedding, '$esc_query') AS score
             FROM documents
             WHERE category = '$category'  -- Filter first!
             ORDER BY score DESC
             LIMIT $limit"

    # ... execute query ...
}
```

### Connection Pooling

For multiple simultaneous operations:

```tcl
proc get_db_connection {} {
    global db_pool

    # Simple pool: maintain connection(s)
    if {![info exists db_pool]} {
        set db_pool [mysql::connect -user root -db mydb]
    }

    return $db_pool
}

proc close_db_pool {} {
    global db_pool
    if {[info exists db_pool]} {
        mysql::close $db_pool
        unset db_pool
    }
}
```

## Complete Example Applications

### Example 1: Document Search Engine

See `tools/search.tcl` for a complete semantic search implementation.

### Example 2: Data Ingestion

See `tools/ingest.tcl` for document ingestion with embeddings.

### Example 3: RAG Application

See `RAG_EXAMPLE.md` for a Retrieval-Augmented Generation application.

## Monitoring and Maintenance

### Check Database Statistics

```sql
-- Number of documents
SELECT COUNT(*) FROM documents;

-- Size of embeddings table
SELECT
    table_name,
    ROUND(((data_length + index_length) / 1024 / 1024), 2) AS size_mb
FROM information_schema.tables
WHERE table_name = 'documents';

-- Embedding statistics
SELECT
    category,
    COUNT(*) as count,
    MIN(created_at) as oldest,
    MAX(created_at) as newest
FROM documents
GROUP BY category;
```

### Rebuild Embeddings

If you change models or need to regenerate:

```tcl
proc rebuild_embeddings {db {batch_size 100}} {
    global embedding_handle

    # 1. Fetch all documents
    set total [lindex [mysql::query $db "SELECT COUNT(*) FROM documents"] 0]
    set count 0

    # 2. Update embeddings
    mysql::sel $db "SELECT id, content FROM documents"
    mysql::map $db {id content} {
        set binary [generate_embedding $content "passage"]
        if {$binary ne ""} {
            set esc_binary [mysql::escape $db $binary]
            mysql::query $db "UPDATE documents SET embedding = '$esc_binary' WHERE id = $id"

            incr count
            if {$count % $batch_size == 0} {
                puts "Updated $count/$total embeddings..."
            }
        }
    }

    puts "✓ Rebuild complete: $count embeddings updated"
}
```

### Monitor Query Performance

```sql
-- Enable query log
SET GLOBAL general_log = 'ON';
SET GLOBAL log_output = 'TABLE';

-- View slow queries
SELECT * FROM mysql.general_log WHERE argument LIKE '%cosine_similarity%'\G

-- Disable when done
SET GLOBAL general_log = 'OFF';
```

## Troubleshooting

### "Unknown function cosine_similarity"

```sql
-- Verify UDF is registered
SHOW FUNCTION STATUS WHERE Db = 'your_database';

-- Re-register if needed
CREATE FUNCTION IF NOT EXISTS cosine_similarity RETURNS REAL
SONAME 'cosine_similarity.so';
```

### "Package mysqltcl not found"

```bash
# Install mysqltcl
sudo apt-get install mysqltcl

# Or verify installation
tclsh -c "package require mysqltcl; puts OK"

# If not found, compile manually
git clone https://github.com/rene-aguirre/mysqltcl.git
cd mysqltcl
make && sudo make install
```

### "Binary data corruption"

Ensure proper conversion:

```tcl
# Correct: Use binary format for float list
set embedding {0.1 0.2 0.3 ...}
set binary [binary format f* $embedding]
# Length should be: [llength $embedding] * 4

# Verify before insert
puts "Embedding count: [llength $embedding]"
puts "Binary size: [string length $binary] bytes"
# Should match: 384 * 4 = 1536
```

### Slow Similarity Searches

```sql
-- Check query plan
EXPLAIN SELECT * FROM documents
ORDER BY cosine_similarity(embedding, @query_binary) DESC
LIMIT 10;

-- Add WHERE clause to filter first
SELECT * FROM documents
WHERE category = 'news'  -- Filter reduces rows to check
ORDER BY cosine_similarity(embedding, @query_binary) DESC
LIMIT 10;
```

## Best Practices

1. **Always use binary format** for embeddings in MySQL
2. **Escape data properly** using `mysql::escape`
3. **Filter before similarity** calculation for better performance
4. **Cache models** in memory to avoid reloading
5. **Use transactions** for batch operations
6. **Monitor query performance** with `EXPLAIN`
7. **Clean up connections** properly to avoid leaks
8. **Use appropriate data types** (BINARY vs BLOB)

## References

- **Tcl embeddings:** [tclembedding Guide](README.md)
- **MySQL UDF:** [MYSQL_UDF.md](MYSQL_UDF.md)
- **Tools:** `tools/` directory
- **Examples:** [RAG_EXAMPLE.md](RAG_EXAMPLE.md)

---

For complete working examples, see the `tools/` directory.
