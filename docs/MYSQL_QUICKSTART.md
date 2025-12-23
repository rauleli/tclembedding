# MySQL Integration Quick Start

Fast-track guide to set up semantic search with tclembedding and MySQL.

## 5-Minute Setup

### 1. Install Dependencies

```bash
# Ubuntu/Debian
sudo apt-get install mysql-server libmysqlclient-dev mysqltcl

# macOS
brew install mysql mysqltcl

# Start MySQL
sudo systemctl start mysql
```

### 2. Build and Register UDF

```bash
cd src/
gcc -shared -fPIC -march=native -O3 -msse3 -msse4a \
  -o mysql_cosine_similarity.so rag_optimizations.c \
  $(mysql_config --include) -lm

sudo cp mysql_cosine_similarity.so /usr/lib/mysql/plugin/
```

Register in MySQL:
```bash
mysql -u root -p
```

```sql
CREATE DATABASE rag;
CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'mysql_cosine_similarity.so';
```

### 3. Create Database Schema

```bash
mysql -u root -p rag < tools/schema.sql
```

### 4. Run Example Scripts

**Ingest documents:**
```bash
cd tools/
tclsh ingest.tcl
```

**Search semantically:**
```bash
tclsh search.tcl
```

## Architecture Overview

```
Your Tcl App
    ↓
tclembedding (ONNX Runtime)
    ↓ generate embeddings
mysqltcl
    ↓ SQL queries
MySQL Database
    ↓ cosine_similarity() UDF
Results
```

## Key Components

### 1. MySQL UDF: cosine_similarity()

**File:** `src/rag_optimizations.c`

Calculates similarity between embedding vectors:
```sql
SELECT * FROM documents
WHERE cosine_similarity(embedding, @query) > 0.7
ORDER BY cosine_similarity(embedding, @query) DESC
LIMIT 5;
```

**Installation:**
- Compile to `.so` file
- Copy to `/usr/lib/mysql/plugin/`
- Register with `CREATE FUNCTION`

See: [MYSQL_UDF.md](MYSQL_UDF.md)

### 2. Data Ingestion: ingest.tcl

**File:** `tools/ingest.tcl`

Process:
1. Load document
2. Generate embedding (384-dim vector)
3. Convert to binary (BINARY(1536))
4. Store in MySQL

```bash
tclsh ingest.tcl
```

See: [tools/README.md](tools/README.md)

### 3. Semantic Search: search.tcl

**File:** `tools/search.tcl`

Process:
1. Generate query embedding
2. Find similar documents using UDF
3. Rank by cosine similarity
4. Display results

```bash
tclsh search.tcl
```

## Database Schema

```sql
CREATE TABLE youtube_rag (
    id INT AUTO_INCREMENT PRIMARY KEY,
    categoria ENUM('transcripcion', 'metadatos', 'comentario'),
    contenido TEXT,
    embedding BINARY(1536),  -- 384 floats × 4 bytes
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
```

See: `tools/schema.sql`

## Common Tasks

### Ingest Your Own Documents

Edit `tools/ingest.tcl`:

```tcl
set documents {
    {categoria "article" texto "Your document text..."}
    {categoria "blog" texto "Another document..."}
}
```

Run:
```bash
tclsh ingest.tcl
```

### Custom Search

Edit `tools/search.tcl`:

```tcl
semantic_search $db "Your query here" 5
```

Or run interactively:
```tcl
tclsh
% package require tclembedding
% package require mysqltcl
% set db [mysql::connect -u root -db rag]
% set results [semantic_search $db "your query" 5]
```

### Check Database

```bash
mysql -u root rag -e "SELECT COUNT(*) FROM youtube_rag;"
mysql -u root rag -e "SELECT * FROM youtube_rag LIMIT 5\G"
```

## Troubleshooting

### "Unknown function cosine_similarity"

```bash
# Check if registered
mysql -u root -e "SHOW FUNCTION STATUS WHERE Db = 'rag';"

# Register if missing
mysql -u root rag -e \
  "CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'mysql_cosine_similarity.so';"
```

### "Can't find libonnxruntime"

Ensure tclembedding is installed and in library path:

```bash
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
tclsh search.tcl
```

### "MySQL Connection Failed"

```bash
# Start MySQL
sudo systemctl start mysql

# Verify connectivity
mysql -u root -p -e "SELECT 1;"

# Check credentials in scripts
```

## Performance Tips

1. **Filter first:** Apply WHERE clauses before similarity calculation
2. **Limit results:** Use LIMIT to stop early
3. **Index categories:** Create indexes on frequently filtered columns
4. **Cache connections:** Keep MySQL connection open for multiple searches

```sql
-- Fast query
SELECT * FROM documents
WHERE category = 'news'  -- Filter first
ORDER BY cosine_similarity(embedding, @query) DESC
LIMIT 5;
```

## Complete Example Workflow

```bash
# 1. Setup (one-time)
sudo systemctl start mysql
cd src/
gcc -shared -fPIC -march=native -O3 -msse3 -msse4a \
  -o mysql_cosine_similarity.so rag_optimizations.c \
  $(mysql_config --include) -lm
sudo cp mysql_cosine_similarity.so /usr/lib/mysql/plugin/

mysql -u root -p -e "
  CREATE DATABASE rag;
  CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'mysql_cosine_similarity.so';"

mysql -u root -p rag < tools/schema.sql

# 2. Ingest documents
cd tools/
tclsh ingest.tcl

# 3. Search documents
tclsh search.tcl

# 4. Verify results
mysql -u root rag -e "SELECT COUNT(*) FROM youtube_rag;"
```

## File Reference

| File | Purpose |
|------|---------|
| `src/rag_optimizations.c` | MySQL UDF source code |
| `tools/schema.sql` | Database schema |
| `tools/ingest.tcl` | Ingestion script |
| `tools/search.tcl` | Search script |
| `tools/README.md` | Detailed tool documentation |
| `MYSQL_UDF.md` | UDF compilation guide |
| `MYSQL_INTEGRATION.md` | Full integration guide |
| `RAG_EXAMPLE.md` | Complete RAG application |

## What's Happening

1. **tclembedding** generates embeddings (384-dimensional vectors)
2. **mysqltcl** connects Tcl to MySQL
3. **MySQL UDF** (cosine_similarity) calculates vector similarity at database level
4. **Tools** (ingest.tcl, search.tcl) orchestrate the workflow

### Data Flow

```
Document Text
    ↓
[tclembedding] Generate 384-dim embedding
    ↓
[binary format] Convert to BINARY(1536)
    ↓
[MySQL INSERT] Store in database
    ↓
Query Text
    ↓
[tclembedding] Generate 384-dim embedding
    ↓
[cosine_similarity UDF] Find similar documents
    ↓
[MySQL SELECT] Retrieve top results
    ↓
Results ranked by similarity
```

## Next Steps

- **For detailed UDF documentation:** See [MYSQL_UDF.md](MYSQL_UDF.md)
- **For full integration guide:** See [MYSQL_INTEGRATION.md](MYSQL_INTEGRATION.md)
- **For complete RAG system:** See [RAG_EXAMPLE.md](RAG_EXAMPLE.md)
- **For tool usage:** See [tools/README.md](tools/README.md)

## Key Concepts

### E5 Model Prefixes

The E5 embedding model uses specific prefixes:

- **Documents:** `"passage: "` - Add before indexing
- **Queries:** `"query: "` - Add before searching

Both scripts handle this automatically.

### Cosine Similarity

```
Similarity = (vec1 · vec2) / (|vec1| × |vec2|)
```

Returns -1.0 to 1.0:
- 1.0 = identical (100% similar)
- 0.5 = 50% similar
- 0.0 = unrelated
- -1.0 = opposite

### Binary Embedding Format

384 dimensions × 4 bytes per float = 1536 bytes

Stored as `BINARY(1536)` in MySQL for efficient comparison.

## Support

For questions or issues:

1. Check the detailed documentation:
   - [MYSQL_UDF.md](MYSQL_UDF.md) - UDF details
   - [MYSQL_INTEGRATION.md](MYSQL_INTEGRATION.md) - Integration details
   - [tools/README.md](tools/README.md) - Tool documentation

2. Review example code:
   - `tools/ingest.tcl` - Ingestion example
   - `tools/search.tcl` - Search example
   - `RAG_EXAMPLE.md` - Complete application

3. Verify setup:
   - Check MySQL is running
   - Verify UDF is registered
   - Test basic queries

---

This quick start gets you up and running with semantic search in ~5 minutes.
For production use, see the detailed guides for optimization and scaling.
