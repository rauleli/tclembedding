# Tools Directory - MySQL Integration Examples

> These legacy scripts require review before use with the current UDF. See [MYSQL_UDF.md](../docs/MYSQL_UDF.md) for its vector format, error contract and limited isolated-server validation.

This directory contains example scripts demonstrating the integration of tclembedding with MySQL for semantic search and RAG (Retrieval-Augmented Generation) applications.

## Files Overview

### schema.sql
Database schema for storing documents with embeddings.

**Purpose:** Create the MySQL database structure for semantic search

**What it does:**
- Defines `youtube_rag` table with embedding storage
- Sets up ENUM for content types (transcription, metadata, comment)
- Uses BINARY(1536) for 384-dimensional embeddings
- Includes timestamp tracking

**Key columns:**
```sql
id              - Auto-incrementing document ID
categoria       - Type of content (ENUM)
contenido       - Text content being embedded
embedding       - Binary embedding (384 floats × 4 bytes = 1536 bytes)
created_at      - Timestamp of ingestion
```

**Usage:**
```bash
mysql -u root -p database_name < schema.sql
```

### ingest.tcl
Script for ingesting documents into MySQL with embeddings.

**Purpose:** Load documents from source and generate embeddings for storage

**What it does:**
1. Connects to MySQL
2. Loads tokenizer from model
3. Initializes ONNX embedding model
4. Processes documents through embedding pipeline
5. Stores embeddings as binary data in database

**Key functions:**
- `ingestar` - Main ingestion procedure
  - Accepts document text and category
  - Generates embedding using tclembedding
  - Converts to binary format
  - Inserts into MySQL with proper escaping

**Usage:**
```bash
# Basic usage
tclsh ingest.tcl

# With configuration
export MODEL_PATH="models/e5-small/model.onnx"
tclsh ingest.tcl
```

**Example workflow:**
```tcl
# Script loads documents and executes:
ingestar "transcripcion" "Video content from YouTube..."
ingestar "metadatos" "Video title, duration, author..."
ingestar "comentario" "User comments about video..."
```

### search.tcl
Script for performing semantic search using embeddings and MySQL UDF.

**Purpose:** Find semantically similar documents to a query

**What it does:**
1. Connects to MySQL and initializes model
2. Generates embedding for query
3. Executes SQL with `cosine_similarity()` UDF
4. Returns ranked results by similarity score
5. Displays results with relevance scores

**Key functions:**
- `buscar` - Main search procedure
  - Accepts query string and result limit
  - Generates query embedding
  - Uses MySQL UDF for similarity calculation
  - Returns formatted results

**Usage:**
```bash
tclsh search.tcl
```

**Example output:**
```
🔎 Buscando: '¿Qué comieron en Tokio?'
   #1 [0.8923] (transcripcion): En este video visitamos el mercado de Tsukiji...
   #2 [0.7654] (metadatos): Locación: Tokio...
   #3 [0.6432] (comentario): El sushi se vía delicioso...
```

## Quick Start

### 1. Prerequisites

```bash
# Install required packages
sudo apt-get install mysql-server libmysqlclient-dev mysqltcl

# Or on macOS
brew install mysql mysqltcl
```

### 2. Set Up MySQL

```bash
# Start MySQL
sudo systemctl start mysql

# Connect and create database
mysql -u root -p

mysql> CREATE DATABASE rag;
mysql> CREATE USER 'rag_user'@'localhost' IDENTIFIED BY 'password';
mysql> GRANT ALL ON rag.* TO 'rag_user'@'localhost';
mysql> FLUSH PRIVILEGES;
mysql> EXIT;
```

### 3. Create Database Schema

```bash
mysql -u root -p rag < schema.sql
```

### 4. Install UDF (cosine_similarity)

```bash
cd ../src/
gcc -shared -fPIC -march=native -O3 -msse3 -msse4a \
  -o mysql_cosine_similarity.so rag_optimizations.c \
  $(mysql_config --include) -lm

sudo cp mysql_cosine_similarity.so /usr/lib/mysql/plugin/
```

Register in MySQL:
```sql
mysql -u root -p rag

mysql> CREATE FUNCTION cosine_similarity RETURNS REAL
       SONAME 'mysql_cosine_similarity.so';
```

### 5. Verify Setup

```bash
# Test tclembedding
tclsh -c "package require tclembedding; puts OK"

# Test mysqltcl
tclsh -c "package require mysqltcl; puts OK"
```

### 6. Run Example

```bash
# Ingest sample documents
tclsh ingest.tcl

# Search documents
tclsh search.tcl
```

## Configuration

### Model Paths

Update model paths in scripts to match your setup:

```tcl
# ingest.tcl and search.tcl
set model_onnx  [file join $base_dir "models" "e5-small" "model.onnx"]
set model_vocab [file join $base_dir "models" "e5-small" "tokenizer.json"]
```

### MySQL Connection

```tcl
# Both scripts use:
set db [mysql::connect -u root -db rag]

# Change to your credentials:
set db [mysql::connect \
    -host localhost \
    -user your_user \
    -password your_password \
    -db your_database]
```

## Data Flow

### Ingestion Flow (ingest.tcl)

```
Input Document
    ↓
[E5 Model] Apply "passage: " prefix
    ↓
[Tokenizer] Generate token IDs
    ↓
[ONNX Model] Compute embeddings (384 floats)
    ↓
[Binary Format] Pack as BINARY(1536)
    ↓
[MySQL Escape] Sanitize for SQL
    ↓
[INSERT] Store in database
    ↓
Document Stored ✓
```

### Search Flow (search.tcl)

```
User Query
    ↓
[E5 Model] Apply "query: " prefix
    ↓
[Tokenizer] Generate token IDs
    ↓
[ONNX Model] Compute query embedding
    ↓
[Binary Format] Pack for SQL
    ↓
[SQL Query] SELECT with cosine_similarity()
    ↓
[Ranking] ORDER BY similarity DESC
    ↓
[Results] Display top-k documents
```

## Example Usage

### Basic Ingestion

```bash
tclsh ingest.tcl
```

The script will:
1. Connect to MySQL
2. Load the embedding model
3. Ingest 3 sample documents:
   - Transcription: "En este video visitamos el mercado de Tsukiji..."
   - Metadata: "Locación: Kioto, Templo Kiyomizu-dera..."
   - Comment: "La edición del minuto 4:20 es espectacular..."

### Custom Ingestion

Modify `ingest.tcl` to add more documents:

```tcl
proc execute_ingestion {} {
    global handle db

    # Add your documents
    ingestar "transcripcion" "Your document text here"
    ingestar "metadatos" "Video metadata"
    ingestar "comentario" "User comment"
}

execute_ingestion
mysql::close $db
```

### Basic Search

```bash
tclsh search.tcl
```

The script will execute 3 sample searches:
1. "¿Qué comieron en Tokio?"
2. "¿Qué opinan de la edición?"
3. "Templos antiguos"

### Custom Search

Modify `search.tcl` to run your queries:

```tcl
proc execute_searches {} {
    global handle db

    buscar "Your custom query"
    buscar "Another question"
    buscar "Third query"
}

execute_searches
mysql::close $db
```

## Important Concepts

### E5 Model Prefix

The E5 embedding model requires prefixes:

- **For documents:** `"passage: your document text"`
- **For queries:** `"query: your question"`

This tells the model the context and optimizes embeddings for semantic search.

### Binary Embedding Format

Embeddings are stored as BINARY data:

```tcl
# Convert embedding list to binary
set embedding_list {0.123 0.456 0.789 ...}  # 384 floats
set binary_data [binary format f* $embedding_list]
# Result: 1536 bytes (384 × 4 bytes per float)
```

### Cosine Similarity

The MySQL UDF calculates:

```
         vec1 · vec2
similarity = ──────────────
            |vec1| × |vec2|
```

Returns values from -1.0 to 1.0:
- **1.0** = Identical vectors (100% similar)
- **0.5** = 50% similar
- **0.0** = Orthogonal vectors (unrelated)
- **-1.0** = Opposite vectors

### SQL Escaping

Always escape binary data for SQL:

```tcl
# Correct
set escaped [mysql::escape $db $binary_data]
set sql "... VALUES ('$escaped')"

# Incorrect (vulnerable)
set sql "... VALUES ('$binary_data')"  # ✗ Not escaped
```

## Troubleshooting

### "Unknown function cosine_similarity"

The UDF isn't registered in MySQL:

```bash
# Check if registered
mysql -u root -e "SHOW FUNCTION STATUS WHERE Db = 'rag';"

# Register if needed
mysql -u root rag -e \
  "CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'mysql_cosine_similarity.so';"
```

### "Can't open shared library 'mysql_cosine_similarity.so'"

The UDF file isn't in the correct location:

```bash
# Find MySQL plugin directory
mysql -u root -e "SHOW VARIABLES LIKE 'plugin_dir';"

# Copy file there
sudo cp src/mysql_cosine_similarity.so /usr/lib/mysql/plugin/
sudo chmod 755 /usr/lib/mysql/plugin/mysql_cosine_similarity.so
```

### "Error in search SQL: ... undefined ..."

Model not loaded or embedding generation failed:

```bash
# Test embedding generation
tclsh -c "
package require tclembedding
package require tokenizer
tokenizer::load_vocab models/e5-small/tokenizer.json
set h [embedding::init_raw models/e5-small/model.onnx]
set tokens [tokenizer::tokenize test]
set v [embedding::compute \$h \$tokens]
puts \"Embedding dims: [llength \$v]\"
"
```

### Binary data corruption

Ensure proper conversion:

```tcl
# Verify length matches expectations
set tokens [tokenizer::tokenize "test"]
set embedding_list [embedding::compute $handle $tokens]
set binary [binary format f* $embedding_list]

puts "Embedding count: [llength $embedding_list]"
puts "Binary size: [string length $binary] bytes"
puts "Expected: [expr {384 * 4}] bytes"
```

## Performance Tips

1. **Index frequently searched columns:**
   ```sql
   CREATE INDEX idx_category ON youtube_rag(categoria);
   CREATE INDEX idx_created ON youtube_rag(created_at);
   ```

2. **Use LIMIT in searches:**
   ```tcl
   buscar "query" 5  ;# Get top 5 results
   ```

3. **Filter before similarity calculation:**
   ```sql
   WHERE categoria = 'transcripcion'
   AND cosine_similarity(...) > 0.5
   ```

4. **Monitor database size:**
   ```bash
   mysql -u root -e "SELECT
       table_name,
       ROUND((data_length + index_length) / 1024 / 1024, 2) AS size_mb
   FROM information_schema.tables
   WHERE table_name LIKE 'youtube%';"
   ```

## Advanced Usage

See the following documentation for more advanced examples:

- [MYSQL_INTEGRATION.md](../MYSQL_INTEGRATION.md) - Complete integration guide
- [MYSQL_UDF.md](../MYSQL_UDF.md) - UDF implementation details
- [RAG_EXAMPLE.md](../RAG_EXAMPLE.md) - Full RAG system example

## Architecture

These tools work together to create a semantic search system:

```
┌──────────────────────────────────────────────────────┐
│                Tcl Application                       │
│                                                      │
│  ┌───────────┐  ┌──────────┐  ┌──────────────────┐ │
│  │ ingest.tcl│  │search.tcl│  │ Your app code    │ │
│  └─────┬─────┘  └────┬─────┘  └────┬─────────────┘ │
│        │             │              │               │
│  ┌─────▼─────────────▼──────────────▼─────────────┐ │
│  │  tclembedding (ONNX Runtime)                   │ │
│  │  • Load embedding models                       │ │
│  │  • Generate embeddings from text               │ │
│  │  • Support multiple models (E5, MiniLM, etc)   │ │
│  └─────┬──────────────────────────────────────────┘ │
│        │                                            │
│  ┌─────▼────────────────────────────────────────────┤
│  │  mysqltcl Connector                             │
│  │  • Connect to MySQL                             │
│  │  • Execute queries                              │
│  │  • Retrieve results                             │
│  └─────┬──────────────────────────────────────────┘ │
│        │                                            │
└────────┼────────────────────────────────────────────┘
         │
    ┌────▼──────────────────────────┐
    │  MySQL Database               │
    ├───────────────────────────────┤
    │ • Documents table             │
    │ • Embeddings (BINARY(1536))   │
    │ • cosine_similarity() UDF     │
    │ • Semantic search results     │
    └───────────────────────────────┘
```

## References

- **Source Code:**
  - `ingest.tcl` - Ingestion script
  - `search.tcl` - Search script
  - `schema.sql` - Database schema

- **Related Documentation:**
  - `src/rag_optimizations.c` - UDF implementation
  - [MYSQL_UDF.md](../MYSQL_UDF.md) - UDF compilation guide
  - [MYSQL_INTEGRATION.md](../MYSQL_INTEGRATION.md) - Integration guide
  - [RAG_EXAMPLE.md](../RAG_EXAMPLE.md) - Complete RAG example

---

These tools provide a complete example of semantic search with tclembedding and MySQL.
