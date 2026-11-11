# Compare the optional native SQLite function with Example 03 on synthetic data.
package require Tcl 8.6
if {[llength $argv] != 4} {
  error "usage: extension fragments model tokenizer"
}
lassign $argv extension fragments model tokenizer
set root [file normalize [file join [file dirname [info script]] ..]]
source [file join $root examples 03-chatgpt-export sqlite_retrieval.tcl]
if {[package provide mysqltcl] ne "" || [package provide tdbc::mysql] ne ""} {
  error "unexpected MySQL dependency"
}

# Fail the test if a required condition is false.
proc require {condition message} {
  if {![uplevel 1 [list expr $condition]]} {
    error $message
  }
}

set dir [file join /tmp "sqlite-similarity-integration-[pid]-[clock clicks]"]
file mkdir $dir
set path [file join $dir synthetic.sqlite3]
::store::init $path
::store::ingest $path $fragments $model $tokenizer
set corpus [::pipeline::file_hash $fragments]
if {
  [::pipeline::file_hash $model] ne $::pipeline::model_hash
  || [::pipeline::file_hash $tokenizer] ne $::pipeline::tokenizer_hash
} {
  error "model or tokenizer mismatch"
}
package require tokenizer 1.0.0
package require tclembedding 1.0
set loaded 0
set handle {}
set db_open 0
try {
  tokenizer::load_vocab $tokenizer
  set loaded 1
  set ids [tokenizer::tokenize "query: recuperar información"]
  set handle [embedding::init_raw $model]
  set query_blob [::pipeline::vector_blob [embedding::compute $handle $ids -pooling mean]]
  binary scan $query_blob r* query
  ::store::open_db $path 0
  set db_open 1
  ::store::check_schema
  ::store::db enable_load_extension 1
  ::store::db eval {SELECT load_extension($extension,'sqlite3_similarity_init')}
  ::store::db enable_load_extension 0
  set n 0
  set max_abs 0.0
  ::store::db eval \
    {SELECT vector,cosine_similarity_v2(vector,$query_blob) AS native_score FROM fragments WHERE corpus=$corpus} r {
        binary scan $r(vector) r* values
        set expected [::rag::cosine $query $values]
        set max_abs [expr {max($max_abs,abs($expected-$r(native_score)))}]
        require {abs($expected-$r(native_score)) < 1e-12} "score mismatch"
        incr n
    }
  require {$n >= 5} "expected at least five synthetic vectors"
  set expected [::store::retrieve $corpus $query 5]
  set actual {}
  ::store::db eval \
    {SELECT cosine_similarity_v2(f.vector,$query_blob) AS score,f.sequence,f.text,m.source_id,m.origin_sha256,m.source,m.conversation_id,m.node_id,m.message_id,m.role,m.position,m.created_json,m.part,f.fragment_index,f.char_start,f.char_end FROM fragments f JOIN messages m ON f.corpus=m.corpus AND f.message_key=m.message_key WHERE f.corpus=$corpus ORDER BY score DESC,f.sequence ASC LIMIT 5} r \
    {
        lappend actual [list $r(score) $r(sequence) $r(text) $r(source_id) $r(origin_sha256) $r(source) $r(conversation_id) $r(node_id) $r(message_id) $r(role) $r(position) $r(created_json) $r(part) $r(fragment_index) $r(char_start) $r(char_end) intfloat/multilingual-e5-small]
    }
  require {[llength $actual] == [llength $expected]} "top-k length mismatch"
  set ids_out {}
  foreach a $actual b $expected {
    require {[lrange $a 1 end] eq [lrange $b 1 end]} "rank or provenance mismatch"
    require {abs([lindex $a 0]-[lindex $b 0]) < 1e-12} "top-k score mismatch"
    lappend ids_out [lindex $a 1]
  }
  puts [format "vectors=%d top_k=%s provenance=equal max_score_abs=%.17g" $n [join $ids_out ,] $max_abs]
} finally {
  if {$db_open} {
    ::store::db close
  }
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
