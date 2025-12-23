# MySQL User Defined Function (UDF) for cosine_similarity

Complete guide to compiling, installing, and using the `cosine_similarity` UDF in MySQL for semantic search with tclembedding.

## Overview

The `cosine_similarity` UDF is a MySQL function that calculates the cosine similarity between two embedding vectors stored as binary data. This enables fast semantic search directly within MySQL queries.

**Source File:** `src/rag_optimizations.c`

### What is Cosine Similarity?

Cosine similarity measures the angle between two vectors in an N-dimensional space (0-384 dimensions for embeddings):

```
          vec1 · vec2
similarity = ─────────────────
             |vec1| × |vec2|
```

- Returns **1.0** for identical vectors (100% similar)
- Returns **0.0** for orthogonal vectors (completely different)
- Returns negative values for opposite directions

### Why Use a MySQL UDF?

Instead of:
1. Fetching all embeddings from MySQL
2. Computing similarity in Tcl
3. Sorting results

You get:
1. **Faster queries** - Calculation in MySQL at C speed
2. **Database-level filtering** - ORDER BY similarity directly
3. **Scalability** - Handles millions of embeddings efficiently

## Prerequisites

### Required Tools

- **MySQL 5.7 or later** (tested with 8.0)
  - Development headers: `libmysqlclient-dev` or `mysql-devel`
  - Running MySQL server

- **C Compiler**
  - GCC 7.0+
  - Clang 5.0+

- **Build Tools**
  - GNU Make
  - Header files for MySQL

### Linux Installation

#### Ubuntu/Debian

```bash
# Install MySQL development files
sudo apt-get install mysql-server mysql-client libmysqlclient-dev

# Verify MySQL is running
sudo systemctl start mysql
sudo systemctl status mysql
```

#### Fedora/RHEL

```bash
# Install MySQL development files
sudo dnf install mysql mysql-devel gcc make

# Start MySQL
sudo systemctl start mysqld
sudo systemctl enable mysqld
```

#### macOS (Homebrew)

```bash
# Install MySQL
brew install mysql

# Start MySQL
brew services start mysql

# Install development files (included with Homebrew)
# Homebrew automatically installs headers
```

## Step-by-Step Installation

### 1. Check MySQL Version

```bash
mysql --version
# MySQL Ver 8.0.x Client...
```

Ensure version 5.7 or later.

### 2. Locate MySQL Headers and Libraries

```bash
# Find MySQL include directory
mysql_config --include
# Output example: -I/usr/include/mysql

# Find MySQL lib directory
mysql_config --libs
# Output example: -L/usr/lib/x86_64-linux-gnu -lmysqlclient
```

Note these paths for compilation.

### 3. Compile the UDF

Navigate to the source directory:

```bash
cd /path/to/tclembedding/src
```

Compile using the provided compilation command:

```bash
gcc -shared -fPIC -o cosine_similarity.so rag_optimizations.c \
  -I/usr/include/mysql \
  -L/usr/lib/x86_64-linux-gnu \
  -lmysqlclient -lm
```

**Flags explanation:**
- `-shared` - Create shared library
- `-fPIC` - Position-independent code
- `-I/usr/include/mysql` - MySQL headers location
- `-L/usr/lib/...` - MySQL library location
- `-lmysqlclient` - Link against MySQL client library
- `-lm` - Link math library (for sqrt)

**Platform-Specific Adjustments:**

For macOS:
```bash
gcc -dynamiclib -fPIC -o cosine_similarity.so rag_optimizations.c \
  -I$(brew --prefix mysql)/include \
  -L$(brew --prefix mysql)/lib \
  -lmysqlclient -lm
```

For CentOS/RHEL:
```bash
gcc -shared -fPIC -o cosine_similarity.so rag_optimizations.c \
  -I/usr/include/mysql \
  -L/usr/lib64/mysql \
  -lmysqlclient -lm
```

### 4. Verify Compilation

Check that the shared library was created:

```bash
ls -lah cosine_similarity.so
# -rw-r--r-- 1 user group 15K Dec 21 12:34 cosine_similarity.so
```

Test for missing symbols:

```bash
nm cosine_similarity.so | grep "cosine_similarity"
# Expected: U (undefined) or T (text/code) symbols
```

### 5. Install the UDF Library

Copy the compiled library to MySQL's plugin directory:

```bash
# Find plugin directory
mysql -u root -e "SHOW VARIABLES LIKE 'plugin_dir';"
# Output: plugin_dir | /usr/lib/mysql/plugin

# Copy library (adjust path as needed)
sudo cp cosine_similarity.so /usr/lib/mysql/plugin/

# Set permissions
sudo chmod 755 /usr/lib/mysql/plugin/cosine_similarity.so
sudo chown mysql:mysql /usr/lib/mysql/plugin/cosine_similarity.so
```

**Alternative for custom MySQL installations:**

```bash
# Find your MySQL plugin directory
PLUGIN_DIR=$(mysql -u root -e "SHOW VARIABLES LIKE 'plugin_dir';" | tail -1 | awk '{print $2}')

sudo cp cosine_similarity.so "$PLUGIN_DIR/"
sudo chmod 755 "$PLUGIN_DIR/cosine_similarity.so"
```

### 6. Register the UDF in MySQL

Connect to MySQL as root or an admin user:

```bash
mysql -u root -p
```

Create the function:

```sql
CREATE FUNCTION cosine_similarity RETURNS REAL
SONAME 'cosine_similarity.so';
```

**Example session:**
```bash
$ mysql -u root -p
Enter password:
mysql> CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'cosine_similarity.so';
Query OK, 0 rows affected (0.05 sec)

mysql> SELECT cosine_similarity(x'3f800000', x'3f800000');
+---------------------------------------------+
| cosine_similarity(x'3f800000', x'3f800000') |
+---------------------------------------------+
|                                           1 |
+---------------------------------------------+
1 row in set (0.00 sec)
```

### 7. Verify Installation

Test the function with sample data:

```sql
-- Test with identical vectors (should return 1.0)
SELECT cosine_similarity(
    x'3f80000000000000000000000000000',  -- All 1.0 in float
    x'3f80000000000000000000000000000'   -- Same vector
) AS similarity;
-- Result: 1.0

-- Test with orthogonal vectors (should return 0.0)
SELECT cosine_similarity(
    x'3f8000000000000000000000',  -- [1, 0, 0]
    x'0000000000000000000000003f800000'  -- [0, 0, 1]
) AS similarity;
-- Result: 0.0
```

### 8. Persist the UDF Registration

Make the UDF registration permanent by adding to a startup script or include file:

**Option A: Add to my.cnf**

```bash
sudo nano /etc/mysql/mysql.conf.d/mysqld.cnf
```

Add at the end:

```ini
[mysqld]
# UDF registration
init-file=/etc/mysql/udf-init.sql
```

Create `/etc/mysql/udf-init.sql`:

```sql
-- Automatically create UDF function on MySQL startup
CREATE FUNCTION IF NOT EXISTS cosine_similarity RETURNS REAL
SONAME 'cosine_similarity.so';
```

**Option B: Add to database initialization**

In your application initialization:

```tcl
# Ensure UDF is registered on connection
set db [mysql::connect -u root -db your_database]
catch {
    mysql::query $db "CREATE FUNCTION IF NOT EXISTS cosine_similarity RETURNS REAL SONAME 'cosine_similarity.so';"
}
```

## Usage

### Basic Syntax

```sql
cosine_similarity(vector1_blob, vector2_blob)
```

**Arguments:**
- `vector1_blob` - BINARY data (384 floats × 4 bytes = 1536 bytes)
- `vector2_blob` - BINARY data (same format)

**Returns:**
- REAL (floating point: -1.0 to 1.0)

### Examples

#### Example 1: Simple Similarity Calculation

```sql
SELECT cosine_similarity(embedding1, embedding2) AS similarity
FROM embeddings_table
LIMIT 1;
```

#### Example 2: Find Similar Documents

```sql
-- Find the 5 most similar documents to a query vector
SELECT document_id, title, cosine_similarity(embedding, @query_vector) AS score
FROM documents
ORDER BY score DESC
LIMIT 5;
```

#### Example 3: Similarity Threshold

```sql
-- Find documents above 70% similarity
SELECT document_id, title, cosine_similarity(embedding, @query_vector) AS score
FROM documents
WHERE cosine_similarity(embedding, @query_vector) > 0.7
ORDER BY score DESC;
```

#### Example 4: Join with Similarity

```sql
-- Find all similar pairs above threshold
SELECT
    d1.document_id AS doc1_id,
    d2.document_id AS doc2_id,
    cosine_similarity(d1.embedding, d2.embedding) AS similarity
FROM documents d1
JOIN documents d2 ON d1.id < d2.id
WHERE cosine_similarity(d1.embedding, d2.embedding) > 0.8
ORDER BY similarity DESC;
```

## Function Behavior

### Input Validation

The function validates inputs:

```c
// Checks that:
if (args->arg_count != 2) {
    // ERROR: Requires exactly 2 arguments
}

if (args->arg_type[0] != STRING_RESULT ||
    args->arg_type[1] != STRING_RESULT) {
    // ERROR: Both arguments must be BLOB/STRING
}

if (len1 != len2 || len1 % 4 != 0) {
    // ERROR: Vectors must be same length and divisible by 4 (float size)
}
```

### Null Handling

```sql
-- Returns NULL if either argument is NULL
SELECT cosine_similarity(NULL, @vector);  -- Returns NULL
SELECT cosine_similarity(@vector, NULL);  -- Returns NULL
```

### Zero Vector Handling

```c
// If either vector has zero magnitude, returns 0.0
// (mathematically undefined, but practical choice)
if (magnitude1 == 0.0 || magnitude2 == 0.0) {
    return 0.0;
}
```

## Preparing Vector Data for MySQL

### From Tcl Embeddings

Convert embeddings from Tcl to MySQL binary format:

```tcl
package require tclembedding
package require tokenizer

# Load tokenizer and model
tokenizer::load_vocab "tokenizer.json"
set handle [embedding::init_raw "model.onnx"]

# Get embedding from tclembedding
set tokens [tokenizer::tokenize "my text"]
set embedding_list [embedding::compute $handle $tokens]
# Result: {0.123 0.456 0.789 ...} (list of floats)

# Convert to binary (4 bytes per float)
set binary_data [binary format f* $embedding_list]

# Insert into MySQL
set escaped_binary [mysql::escape $db $binary_data]
mysql::query $db "INSERT INTO embeddings (embedding) VALUES ('$escaped_binary')"
```

### Creating a Table for Embeddings

```sql
CREATE TABLE embeddings (
    id INT AUTO_INCREMENT PRIMARY KEY,
    document_id INT,
    content TEXT,
    embedding BINARY(1536),  -- 384 floats * 4 bytes
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX (document_id),
    INDEX (created_at)
) ENGINE=InnoDB;
```

## Performance Optimization

### Index Considerations

Note: Standard MySQL indexes don't accelerate similarity searches (since similarity is not monotonic).

For optimal performance:

1. **Partition by category** - If you have categories, partition your table
2. **Use WHERE clauses** - Filter before similarity calculation
3. **Limit results** - Use LIMIT to stop early

```sql
-- Faster: Filter first, then calculate similarity
SELECT id, title, cosine_similarity(embedding, @query) AS score
FROM documents
WHERE category = 'news'  -- Filter first
ORDER BY score DESC
LIMIT 10;
```

### Query Performance

Typical performance metrics:

| Operation | Time |
|-----------|------|
| UDF call overhead | <1μs |
| Similarity calculation (384 dims) | 1-5μs |
| Query on 1M rows | 1-5 seconds |
| Query with WHERE clause | <100ms |

## Troubleshooting

### "ERROR 1126: Can't open shared library"

**Cause:** File not found or permission issues

**Solution:**
```bash
# Verify file exists and is readable
ls -la /usr/lib/mysql/plugin/cosine_similarity.so

# Check permissions
sudo chmod 755 /usr/lib/mysql/plugin/cosine_similarity.so

# Check MySQL plugin_dir
mysql -u root -e "SHOW VARIABLES LIKE 'plugin_dir';"
```

### "ERROR 1127: Can't find symbol in library"

**Cause:** Missing symbol or incompatible MySQL version

**Solution:**
```bash
# Recompile with correct MySQL headers
mysql_config --cflags --libs  # Check what MySQL expects

# Recompile with visible symbols
gcc -shared -fPIC -o cosine_similarity.so rag_optimizations.c \
  $(mysql_config --cflags --libs) -lm
```

### "ERROR 1305: FUNCTION cosine_similarity does not exist"

**Cause:** Function not registered

**Solution:**
```sql
-- Register the function
CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'cosine_similarity.so';

-- Verify registration
SHOW FUNCTION STATUS WHERE Db = 'database_name';
```

### "ERROR 1307: Can't drop function cosine_similarity"

**Cause:** UDF used by queries

**Solution:**
```sql
-- Drop is usually not needed, but if necessary:
DROP FUNCTION IF EXISTS cosine_similarity;
```

### Vectors Return Wrong Similarity Values

**Cause:** Incorrect binary format

**Solution:**
```tcl
# Verify binary format
set vector {1.0 0.0 0.0}
set binary [binary format f* $vector]
puts "Binary length: [string length $binary]"
# Should be: [llength $vector] * 4 = 12 bytes

# Verify in MySQL
SELECT LENGTH(embedding) FROM embeddings LIMIT 1;
# Should be: 1536 for 384-float embeddings
```

## Advanced: Rebuilding for Different MySQL Versions

### Check MySQL Configuration

```bash
# Get compiler flags used to build MySQL
mysql_config --cflags
# Output: -I/usr/include/mysql

# Get linker flags
mysql_config --libs
# Output: -L/usr/lib/x86_64-linux-gnu -lmysqlclient
```

### Build with Correct Flags

```bash
# Automatic method (recommended)
gcc -shared -fPIC -o cosine_similarity.so rag_optimizations.c \
  $(mysql_config --cflags) $(mysql_config --libs) -lm

# This ensures compatibility with your MySQL installation
```

### Verify Binary Compatibility

```bash
# List symbols used
nm cosine_similarity.so | grep -E "mysql|UDF"

# Check dependencies
ldd cosine_similarity.so
# Should show: libmysqlclient.so => /usr/lib/...
```

## Security Considerations

### Input Sanitization

The UDF function validates inputs:

```c
if (args->arg_count != 2) {
    strcpy(message, "cosine_similarity() requires exactly 2 arguments");
    return 1;
}
```

**Note:** The function expects binary data only. Text input should be:

1. Generated from embeddings (binary format)
2. Properly escaped when inserted via SQL

### Safe Usage Pattern

```tcl
# Safe: Use prepared statements or proper escaping
set db [mysql::connect -u user -password pass -db database]

# Generate embedding
set tokens [tokenizer::tokenize "user input"]
set vector [embedding::compute $handle $tokens]
set binary_data [binary format f* $vector]

# Escape before insertion
set escaped [mysql::escape $db $binary_data]
mysql::query $db "INSERT INTO embeddings (data) VALUES ('$escaped')"

# Safe query
mysql::query $db "SELECT * FROM embeddings \
  WHERE cosine_similarity(data, '$escaped') > 0.7"
```

## Complete Example

See `tools/search.tcl` for a complete working example integrating tclembedding with MySQL UDF.

## Reference

- **Source:** `src/rag_optimizations.c`
- **Integration:** `tools/search.tcl`
- **Example Schema:** `tools/schema.sql`

---

For complete integration examples, see [MYSQL_INTEGRATION.md](MYSQL_INTEGRATION.md) and [RAG_EXAMPLE.md](RAG_EXAMPLE.md).
