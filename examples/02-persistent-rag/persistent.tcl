#!/usr/bin/env tclsh
# Persistent semantic retrieval with SQLite and explicit float32 encoding.
package require Tcl 8.6
package require sqlite3
set ::persistent_script_dir [file dirname [file normalize [info script]]]
source [file join $::persistent_script_dir .. 01-in-memory-rag rag.tcl]
# Functions for the persistent retrieval example.
namespace eval ::persistent {
  variable model_id intfloat/multilingual-e5-small
  variable revision 614241f622f53c4eeff9890bdc4f31cfecc418b3
  variable expected_model ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665
  variable expected_tokenizer 0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39
  variable dimension 384
  variable format float32-le
}

# Validate and encode a vector for storage.
proc ::persistent::encode {vector dimension} {
  if {![string is integer -strict $dimension] || $dimension <= 0 || [llength $vector] != $dimension} {
    error "invalid vector dimension"
  }
  foreach value $vector {
    if {![::rag::finite $value] || abs(double($value)) > 3.4028234663852886e38} {
      error "vector must contain representable finite float32 numbers"
    }
  }
  set blob [binary format r* $vector]
  if {[string length $blob] != $dimension * 4} {
    error "invalid encoded vector length"
  }
  binary scan $blob r* decoded
  foreach value $decoded {
    if {![::rag::finite $value]} {
      error "float32 value is non-finite"
    }
  }
  return $blob
}

# Decode and validate a stored vector.
proc ::persistent::decode {blob dimension} {
  if {![string is integer -strict $dimension] || $dimension <= 0 || [string length $blob] != $dimension * 4} {
    error "invalid vector blob or dimension"
  }
  if {[binary scan $blob r* vector] != 1 || [llength $vector] != $dimension} {
    error "invalid vector encoding"
  }
  foreach value $vector {
    if {![::rag::finite $value]} {
      error "vector contains non-finite float32"
    }
  }
  return $vector
}

# Verify the identities of the model and tokenizer artifacts.
proc ::persistent::verify_artifacts {model tokenizer} {
  package require sha256
  variable expected_model
  variable expected_tokenizer
  if {![file isfile $model] || ![file readable $model] || ![file isfile $tokenizer] || ![file readable $tokenizer]} {
    error "model and tokenizer must be readable files"
  }
  set model_hash [::sha2::sha256 -hex -filename $model]
  set tokenizer_hash [::sha2::sha256 -hex -filename $tokenizer]
  if {$model_hash ne $expected_model || $tokenizer_hash ne $expected_tokenizer} {
    error "model or tokenizer hash does not match the characterized artifacts"
  }
  return [list $model_hash $tokenizer_hash]
}

# Open an existing persistent corpus.
proc ::persistent::open_existing {path} {
  if {![file isfile $path]} {
    error "database file does not exist"
  }
  sqlite3 ::persistent::db $path -create false
}

# Initialize the persistent corpus and artifact metadata.
proc ::persistent::initialize {path model_hash tokenizer_hash} {
  variable model_id
  variable revision
  variable dimension
  variable format
  # Reserve a new file exclusively; never take over an existing database.
  set reserve [open $path {WRONLY CREAT EXCL} 0600]
  close $reserve
  sqlite3 ::persistent::db $path -create false
  try {
    db transaction {
            db eval {
                PRAGMA user_version = 1;
                CREATE TABLE metadata (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    schema_version INTEGER NOT NULL, model_id TEXT NOT NULL,
                    model_revision TEXT NOT NULL, model_sha256 TEXT NOT NULL,
                    tokenizer_sha256 TEXT NOT NULL, dimensions INTEGER NOT NULL,
                    vector_format TEXT NOT NULL
                );
                CREATE TABLE documents (
                    id TEXT PRIMARY KEY, title TEXT NOT NULL, content TEXT NOT NULL,
                    dimensions INTEGER NOT NULL, embedding BLOB NOT NULL,
                    CHECK(dimensions > 0),
                    CHECK(typeof(embedding) = 'blob' AND length(embedding) = dimensions * 4)
                );
                INSERT INTO metadata VALUES (1, 1, $model_id, $revision, $model_hash, $tokenizer_hash, $dimension, $format);
            }
        }
  } finally {
    db close
  }
}

# Check the persistent corpus artifact metadata.
proc ::persistent::check_metadata {model_hash tokenizer_hash} {
  variable model_id
  variable revision
  variable dimension
  variable format
  if {[db onecolumn {PRAGMA user_version}] != 1 || [db onecolumn {SELECT COUNT(*) FROM metadata}] != 1} {
    error "unsupported database schema"
  }
  set matches [db onecolumn {
        SELECT COUNT(*) FROM metadata WHERE singleton = 1 AND schema_version = 1
          AND model_id = $model_id AND model_revision = $revision
          AND model_sha256 = $model_hash AND tokenizer_sha256 = $tokenizer_hash
          AND dimensions = $dimension AND vector_format = $format
    }]
  if {$matches != 1} {
    error "incompatible database model, tokenizer or vector format"
  }
}

# Store documents and their vectors.
proc ::persistent::store {docs vectors} {
  variable dimension
  ::rag::validate_documents $docs
  if {[llength $docs] != [llength $vectors]} {
    error "document and vector counts differ"
  }
  db transaction {
        foreach doc $docs vector $vectors {
            lassign $doc id title content
            set blob [encode $vector $dimension]
            db eval {
                INSERT INTO documents (id, title, content, dimensions, embedding)
                VALUES ($id, $title, $content, $dimension, $blob)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, content=excluded.content,
                    dimensions=excluded.dimensions, embedding=excluded.embedding;
            }
        }
    }
}

# Retrieve the best matches for a query vector.
proc ::persistent::retrieve {query_vector topk} {
  variable dimension
  set docs {}
  set vectors {}
  db eval {SELECT id, title, content, dimensions, embedding FROM documents ORDER BY id} row {
        if {$row(dimensions) != $dimension} {error "document vector dimension mismatch"}
        lappend docs [list $row(id) $row(title) $row(content)]
        lappend vectors [decode $row(embedding) $dimension]
    }
  if {[llength $docs] == 0} {
    error "database contains no documents"
  }
  return [::rag::rank $docs $vectors $query_vector $topk]
}

# Prepare embeddings using the requested computation mode.
proc ::persistent::load_embeddings {model tokenizer mode} {
  package require tokenizer 1.0.0
  package require tclembedding 1.0
  set loaded 0
  set handle ""
  try {
    tokenizer::load_vocab $tokenizer
    set loaded 1
    set handle [embedding::init_raw $model]
    if {$mode eq "ingest"} {
      source [file join $::persistent_script_dir .. 01-in-memory-rag corpus.tcl]
      ::rag::validate_documents $corpus
      set all {}
      set longest 0
      foreach doc $corpus {
        set ids [tokenizer::tokenize "passage: [lindex $doc 2]"]
        set n [llength $ids]
        if {$n < 1 || $n > 512} {
          error "document token count exceeds the supported limit"
        }
        if {$n > $longest} {
          set longest $n
        }
        lappend all $ids
      }
      if {[llength $all] * $longest > 4096} {
        error "padded batch exceeds the supported limit"
      }
      set vectors [embedding::compute_batch $handle $all -pad-id 1 -pooling mean]
      store $corpus $vectors
      puts "Stored [llength $corpus] documents."
    } else {
      upvar 1 query query topk topk
      set ids [tokenizer::tokenize "query: $query"]
      if {[llength $ids] < 1 || [llength $ids] > 512} {
        error "query token count exceeds the supported limit"
      }
      set vector [embedding::compute $handle $ids -pooling mean]
      foreach hit [retrieve $vector $topk] {
        lassign [lindex $hit 1] id title text
        puts [format "%s | %s | %.6f\n%s\n" $id $title [lindex $hit 0] $text]
      }
    }
  } finally {
    try {
      if {$handle ne ""} {
        embedding::free $handle
      }
    } finally {
      if {$loaded} {
        tokenizer::free
      }
    }
  }
}

# Run the persistent retrieval command-line interface.
proc ::persistent::main {args} {
  if {[llength $args] < 1} {
    error "expected init, ingest or query"
  }
  set mode [lindex $args 0]
  if {$mode ni {init ingest query}} {
    error "expected init, ingest or query"
  }
  set pairs [lrange $args 1 end]
  if {[llength $pairs] % 2} {
    error "options require values"
  }
  array set opt {-db {} -model {} -tokenizer {} -query {} -top-k 3}
  foreach {key value} $pairs {
    if {![info exists opt($key)]} {
      error "unknown option: $key"
    }
    set opt($key) $value
  }
  if {$opt(-db) eq "" || $opt(-model) eq "" || $opt(-tokenizer) eq ""} {
    error "provide -db, -model and -tokenizer"
  }
  set source_root [file normalize [file join $::persistent_script_dir .. ..]]
  set database_path [file normalize $opt(-db)]
  if {$database_path eq $source_root || [string first "$source_root/" $database_path] == 0} {
    error "database must be outside the source tree"
  }
  set query $opt(-query)
  set topk $opt(-top-k)
  if {
    $mode eq "query"
    && ([string trim $query] eq "" || ![string is integer -strict $topk] || $topk < 1 || $topk > 256)
  } {
    error "provide a nonempty query and top-k from 1 to 256"
  }
  lassign [verify_artifacts $opt(-model) $opt(-tokenizer)] model_hash tokenizer_hash
  if {$mode eq "init"} {
    initialize $opt(-db) $model_hash $tokenizer_hash
    puts "Initialized database."
    return
  }
  open_existing $opt(-db)
  try {
    check_metadata $model_hash $tokenizer_hash
    load_embeddings $opt(-model) $opt(-tokenizer) $mode
  } finally {
    db close
  }
}

if {[file normalize $argv0] eq [file normalize [info script]]} {
  if {[catch {::persistent::main {*}$argv} message]} {
    puts stderr "Error: $message"
    exit 1
  }
}
