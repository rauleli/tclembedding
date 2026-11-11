#!/usr/bin/env tclsh
# MySQL prepared statements using the Tcl Database Connectivity driver.
package require Tcl 8.6
package require tdbc::mysql
set ::mysql_store_dir [file dirname [file normalize [info script]]]
source [file join $::mysql_store_dir sql_ingest.tcl]
# MySQL schema, batch ingestion, and retrieval operations.
namespace eval ::mysql_store {
  variable fail_after -1
  variable exit_after -1
  variable init_exit_after_first 0
}

# Connect to the explicitly selected local MySQL socket.
proc ::mysql_store::connect {socket database user} {
  if {![file exists $socket] || $database eq "" || $user eq ""} {
    error "provide an existing socket, database and user"
  }
  set options [list -socket $socket -database $database -user $user]
  if {[info exists ::env(TCLEMBEDDING_MYSQL_PASSWORD)]} {
    lappend options -password $::env(TCLEMBEDDING_MYSQL_PASSWORD)
  }
  tdbc::mysql::connection create ::mysql_store::db {*}$options
}

# All data values are bound parameters. The statement text is a fixed literal.
# Execute a parameterized SQL statement and collect its rows.
proc ::mysql_store::run {sql values {binary_names {}}} {
  set stmt [db prepare $sql]
  try {
    foreach name $binary_names {
      $stmt paramtype $name varbinary
    }
    set rs [$stmt execute $values]
    try {
      set result {}
      while {[$rs nextlist row]} {
        lappend result $row
      }
      return $result
    } finally {
      $rs close
    }
  } finally {
    $stmt close
  }
}

# Initialize an empty MySQL schema.
proc ::mysql_store::init {} {
  variable init_exit_after_first
  set existing \
    [run \
    {SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name IN ('l2_schema','l2_corpora','l2_fragments')} \
    {}]
  if {[lindex $existing 0 0] != 0} {
    error "existing or partially initialized L2 schema; inspect it and choose an empty schema"
  }
  run {CREATE TABLE l2_schema (version INTEGER NOT NULL)} {}
  if {$init_exit_after_first} {
    exit 86
  }
  run \
    {CREATE TABLE l2_corpora (id CHAR(64) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY, config_sha CHAR(64) NOT NULL, expected INTEGER NOT NULL, progress INTEGER NOT NULL, header_json TEXT NOT NULL, status VARCHAR(16) NOT NULL) ENGINE=InnoDB} \
    {}
  run \
    {CREATE TABLE l2_fragments (corpus CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL, sequence_no BIGINT NOT NULL, line_sha CHAR(64) NOT NULL, line_data LONGBLOB NOT NULL, vector_sha CHAR(64) NOT NULL, vector BLOB NOT NULL, PRIMARY KEY(corpus,sequence_no), FOREIGN KEY(corpus) REFERENCES l2_corpora(id)) ENGINE=InnoDB} \
    {}
  run {INSERT INTO l2_schema VALUES(2)} {}
}

# Reject incompatible or partially initialized MySQL schemas.
proc ::mysql_store::check {} {
  foreach {table expected} {
        l2_schema version:int:NO:
        l2_corpora id:char(64):NO:PRI,config_sha:char(64):NO:,expected:int:NO:,progress:int:NO:,header_json:text:NO:,status:varchar(16):NO:
        l2_fragments corpus:char(64):NO:PRI,sequence_no:bigint:NO:PRI,line_sha:char(64):NO:,line_data:longblob:NO:,vector_sha:char(64):NO:,vector:blob:NO:
    } {
    set columns \
      [run \
      {SELECT GROUP_CONCAT(CONCAT(column_name,':',column_type,':',is_nullable,':',column_key) ORDER BY ordinal_position SEPARATOR ',') FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name=:table} \
      [list table $table]]
    if {[llength $columns] != 1 || [lindex $columns 0 0] ne $expected} {
      error "incomplete or incompatible L2 schema"
    }
  }
  set engines \
    [run \
    {SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name IN ('l2_corpora','l2_fragments') AND engine='InnoDB'} \
    {}]
  if {[lindex $engines 0 0] != 2} {
    error "incompatible L2 transaction engine"
  }
  set rows [run {SELECT version FROM l2_schema} {}]
  if {[llength $rows] != 1 || [lindex $rows 0 0] != 2} {
    error "unsupported schema"
  }
}

# Check the installed cosine similarity function contract.
proc ::mysql_store::check_udf {} {
  set v [binary format r 1.0]
  set z [binary format r 0.0]
  set rows \
    [run {SELECT cosine_similarity_v2(:v,:v) AS score, cosine_similarity_v2(:z,:v) IS NULL AS invalid} \
    [list v $v z $z] {v z}]
  if {[llength $rows] != 1 || abs([lindex $rows 0 0]-1.0) > 1e-12 || [lindex $rows 0 1] != 1} {
    error "cosine UDF contract check failed"
  }
}

# Validate corpus identity and return the committed checkpoint.
proc ::mysql_store::begin_corpus {corpus count config} {
  check
  set vhash [::pipeline::digest [encoding convertto utf-8 $config]]
  set metadata \
    [json object model {string intfloat/multilingual-e5-small} revision \
    {string 614241f622f53c4eeff9890bdc4f31cfecc418b3} onnx_sha256 [list string $::pipeline::model_hash] \
    tokenizer_sha256 [list string $::pipeline::tokenizer_hash] dimension {number 384} pooling {string mean} \
    normalization {string l2} prefix {string {passage: }} configuration [list string $config]]
  db begintransaction
  try {
    set found \
      [run {SELECT config_sha,expected,progress,status,header_json FROM l2_corpora WHERE id=:corpus FOR UPDATE} \
      [list corpus $corpus]]
    if {![llength $found]} {
      run \
        {INSERT INTO l2_corpora(id,config_sha,expected,progress,header_json,status) VALUES(:corpus,:vhash,:count,0,:metadata,'building')} \
        [list corpus $corpus vhash $vhash count $count metadata $metadata]
      set progress 0
    } else {
      if {
        [llength $found] != 1
        || [lindex $found 0 0] ne $vhash
        || [lindex $found 0 1] != $count
        || [lindex $found 0 3] ni {building complete}
        || [lindex $found 0 4] ne $metadata
      } {
        error "corpus configuration conflict"
      }
      set progress [lindex $found 0 2]
    }
    set rows [run {SELECT COUNT(*),MAX(sequence_no) FROM l2_fragments WHERE corpus=:corpus} [list corpus $corpus]]
    if {[lindex $rows 0 0] != $progress || ($progress > 0 && [lindex $rows 0 1] != $progress-1)} {
      error "checkpoint mismatch"
    }
    db commit
  } on error {message options} {
    catch { db rollback }
    return -options $options $message
  }
  return $progress
}

# Check a committed fragment and vector against input.
proc ::mysql_store::verify_row {corpus index line line_hash} {
  set rows \
    [run {SELECT line_sha,line_data,vector_sha,vector FROM l2_fragments WHERE corpus=:corpus AND sequence_no=:index} \
    [list corpus $corpus index $index]]
  if {
    [llength $rows] != 1
    || [lindex $rows 0 0] ne $line_hash
    || [lindex $rows 0 1] ne [encoding convertto utf-8 $line]
    || [string length [lindex $rows 0 3]] != 1536
    || [::pipeline::digest [lindex $rows 0 3]] ne [lindex $rows 0 2]
  } {
    error "stored row mismatch"
  }
  ::pipeline::validate_blob [lindex $rows 0 3]
}

# Commit a batch and advance its checkpoint atomically.
proc ::mysql_store::commit_batch {corpus rows count fail_after} {
  db begintransaction
  try {
    set state \
      [run {SELECT progress FROM l2_corpora WHERE id=:corpus AND status='building' FOR UPDATE} [list corpus $corpus]]
    if {[llength $state] != 1 || [lindex $state 0 0] != [lindex [lindex $rows 0] 0]} {
      error "checkpoint changed"
    }
    foreach item $rows {
      lassign $item i line line_hash blob
      set bytes [encoding convertto utf-8 $line]
      set bhash [::pipeline::digest $blob]
      run \
        {INSERT INTO l2_fragments(corpus,sequence_no,line_sha,line_data,vector_sha,vector) VALUES(:corpus,:i,:line_hash,:bytes,:bhash,:blob)} [list corpus $corpus i $i line_hash $line_hash bytes $bytes bhash $bhash blob $blob] \
        {bytes blob}
      if {$fail_after == $i} {
        error "synthetic transaction failure"
      }
    }
    set progress [expr {[lindex [lindex $rows end] 0] + 1}]
    run {UPDATE l2_corpora SET progress=:progress WHERE id=:corpus AND status='building'} \
      [list progress $progress corpus $corpus]
    db commit
  } on error {message options} {
    catch { db rollback }
    return -options $options $message
  }
}

# Verify completeness and mark the corpus ready for queries.
proc ::mysql_store::finish {corpus count} {
  db begintransaction
  try {
    set state [run {SELECT expected,progress FROM l2_corpora WHERE id=:corpus FOR UPDATE} [list corpus $corpus]]
    set rows [run {SELECT COUNT(*) FROM l2_fragments WHERE corpus=:corpus} [list corpus $corpus]]
    if {
      [llength $state] != 1
      || [lindex $state 0 0] != $count
      || [lindex $state 0 1] != $count
      || [lindex $rows 0 0] != $count
    } {
      error "incomplete corpus"
    }
    run {UPDATE l2_corpora SET status='complete' WHERE id=:corpus} [list corpus $corpus]
    db commit
  } on error {message options} {
    catch { db rollback }
    return -options $options $message
  }
}

# Generate and store embeddings through the shared ingestion loop.
proc ::mysql_store::ingest {fragments model tokenizer {batch_size 8}} {
  ::sql_ingest::run ::mysql_store $fragments $model $tokenizer $batch_size
}

# Embed a question and return validated results with provenance.
proc ::mysql_store::query_results {corpus model tokenizer text topk} {
  if {
    ![regexp {^[0-9a-f]{64}$} $corpus]
    || [string trim $text] eq ""
    || ![string is integer -strict $topk]
    || $topk < 1
    || $topk > 256
  } {
    error "invalid query"
  }
  if {
    [::pipeline::file_hash $model] ne $::pipeline::model_hash
    || [::pipeline::file_hash $tokenizer] ne $::pipeline::tokenizer_hash
  } {
    error "artifact hash mismatch"
  }
  check
  check_udf
  set rows \
    [run {SELECT expected,header_json FROM l2_corpora WHERE id=:corpus AND status='complete'} [list corpus $corpus]]
  if {[llength $rows] != 1} {
    error "corpus unavailable"
  }
  set expected [lindex $rows 0 0]
  set meta [lindex $rows 0 1]
  if {
    [json get $meta model] ne "intfloat/multilingual-e5-small"
    || [json get $meta revision] ne "614241f622f53c4eeff9890bdc4f31cfecc418b3"
    || [json get $meta onnx_sha256] ne $::pipeline::model_hash
    || [json get $meta tokenizer_sha256] ne $::pipeline::tokenizer_hash
    || [json get $meta dimension] != 384
    || [json get $meta pooling] ne "mean"
    || [json get $meta normalization] ne "l2"
    || [json get $meta prefix] ne "passage: "
  } {
    error "incompatible model metadata"
  }
  set rows \
    [run {SELECT COUNT(*),MIN(sequence_no),MAX(sequence_no) FROM l2_fragments WHERE corpus=:corpus} \
    [list corpus $corpus]]
  if {[lindex $rows 0 0] != $expected || [lindex $rows 0 1] != 0 || [lindex $rows 0 2] != $expected-1} {
    error "incomplete corpus"
  }
  package require tokenizer 1.0.0
  package require tclembedding 1.0
  set loaded 0
  set handle {}
  try {
    tokenizer::load_vocab $tokenizer
    set loaded 1
    set ids [tokenizer::tokenize "query: $text"]
    if {[llength $ids] < 1 || [llength $ids] > 512} {
      error "query exceeds token limit"
    }
    set handle [embedding::init_raw $model]
    set vector [::pipeline::vector_blob [embedding::compute $handle $ids -pooling mean]]
    set rows \
      [run \
      {SELECT sequence_no,line_data,cosine_similarity_v2(vector,:vector) AS score,line_sha,vector_sha,vector FROM l2_fragments WHERE corpus=:corpus ORDER BY score DESC,sequence_no ASC LIMIT :topk} [list corpus $corpus vector $vector topk $topk] \
      {vector}]
    foreach row $rows {
      if {[lindex $row 2] eq ""} {
        error "UDF returned NULL"
      }
    }
    foreach row [lrange $rows 0 [expr {$topk-1}]] {
      if {
        [string length [lindex $row 5]] != 1536
        || [::pipeline::digest [lindex $row 5]] ne [lindex $row 4]
        || [::pipeline::digest [lindex $row 1]] ne [lindex $row 3]
      } {
        error "corrupt stored vector or fragment"
      }
    }
    set k 0
    set hits {}
    foreach row $rows {
      if {$k < $topk} {
        set line [encoding convertfrom utf-8 [lindex $row 1]]
        lappend hits \
          [list [lindex $row 2] [lindex $row 0] [json get $line text] [json get $line input_source_id] \
          [json get $line input_sha256] [json get $line source] [json get $line conversation_id] \
          [json get $line node_id] [json get $line message_id] [json get $line role] [json get $line position] \
          [json extract $line create_time] [json get $line part] [json get $line fragment_index] \
          [json get $line char_start] [json get $line char_end] intfloat/multilingual-e5-small]
      }
      incr k
    }
    return $hits
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

# Print the results of a MySQL retrieval query.
proc ::mysql_store::query {corpus model tokenizer text topk} {
  foreach hit [query_results $corpus $model $tokenizer $text $topk] {
    puts $hit
  }
}

if {[file normalize $argv0] eq [file normalize [info script]]} {
  if {[catch {
        if {[llength $argv] < 4} {error "usage: operation socket database user ?arguments?"}
        lassign $argv op socket database user
        set args [lrange $argv 4 end]
        ::mysql_store::connect $socket $database $user
        try {
            switch -- $op {
                init {if {[llength $args]} {error "usage: init socket database user"}; ::mysql_store::init}
                ingest {if {[llength $args] ni {3 4}} {error "usage: ingest socket database user fragments model tokenizer ?batch-size?"}; ::mysql_store::ingest {*}$args}
                query {if {[llength $args] != 5} {error "usage: query socket database user corpus model tokenizer text top-k"}; ::mysql_store::query {*}$args}
                default {error "expected init, ingest or query"}
            }
        } finally {::mysql_store::db close}
    } message]} {
    puts stderr "Error: $message"
    exit 1
  }
}
