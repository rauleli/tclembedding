# Run only against a fresh, disposable server with TCP disabled.
if {[llength $argv] != 6} {
  error "usage: socket database user fragments model tokenizer"
}
lassign $argv socket database user fragments model tokenizer
source [file join [file dirname [file normalize [info script]]] mysql_retrieval.tcl]
::mysql_store::connect $socket $database $user
try {
  set networking [::mysql_store::run {SHOW VARIABLES LIKE 'skip_networking'} {}]
  set server_socket [::mysql_store::run {SHOW VARIABLES LIKE 'socket'} {}]
  set data_dir [::mysql_store::run {SHOW VARIABLES LIKE 'datadir'} {}]
  set plugin_dir [::mysql_store::run {SHOW VARIABLES LIKE 'plugin_dir'} {}]
  set lab [file dirname [file normalize $socket]]
  if {
    [string first "/tmp/" "$lab/"] != 0
    || [lindex $networking 0 1] ne "ON"
    || [file normalize [lindex $server_socket 0 1]] ne [file normalize $socket]
    || [file normalize [lindex $data_dir 0 1]] ne [file join $lab data]
    || [file normalize [lindex $plugin_dir 0 1]] ne [file join $lab plugins]
  } {
    error "server is not isolated"
  }
  ::mysql_store::init
  ::mysql_store::check_udf
  set ::sql_ingest::fail_after 2
  if {![catch {::mysql_store::ingest $fragments $model $tokenizer 4}]} {
    error "expected transactional failure"
  }
  if {[lindex [::mysql_store::run {SELECT COUNT(*) FROM l2_fragments} {}] 0 0] != 0} {
    error "rollback failed"
  }
  set ::sql_ingest::fail_after -1
  set ::sql_ingest::stop_after 4
  if {![catch {::mysql_store::ingest $fragments $model $tokenizer 4}]} {
    error "expected interrupted ingestion"
  }
  if {[lindex [::mysql_store::run {SELECT COUNT(*) FROM l2_fragments} {}] 0 0] != 4} {
    error "checkpoint failed"
  }
  set corpus [::pipeline::file_hash $fragments]
  if {
    ![catch {::mysql_store::query_results $corpus $model $tokenizer {synthetic maintenance} 3} reason]
    || $reason ne "corpus unavailable"
  } {
    error "incomplete corpus was queryable"
  }
  set ::sql_ingest::stop_after -1
  ::mysql_store::ingest $fragments $model $tokenizer 4
  ::mysql_store::ingest $fragments $model $tokenizer 4
  set saved \
    [lindex \
    [::mysql_store::run {SELECT vector FROM l2_fragments WHERE corpus=:corpus AND sequence_no=0} [list corpus $corpus]] 0 \
    0]
  set zeros [binary format a1536 {}]
  ::mysql_store::run {UPDATE l2_fragments SET vector=:zeros WHERE corpus=:corpus AND sequence_no=0} \
    [list zeros $zeros corpus $corpus] {zeros}
  if {
    ![catch {::mysql_store::ingest $fragments $model $tokenizer 4} reason]
    || $reason ne "stored row mismatch"
  } {
    error "corrupt vector not rejected as expected"
  }
  ::mysql_store::run {UPDATE l2_fragments SET vector=:saved WHERE corpus=:corpus AND sequence_no=0} \
    [list saved $saved corpus $corpus] {saved}
  set hits [::mysql_store::query_results $corpus $model $tokenizer {synthetic maintenance} 3]
  if {[llength $hits] != 3 || [llength [lindex $hits 0]] != 17} {
    error "retrieval failed"
  }
  set input [open $fragments]
  fconfigure $input -encoding utf-8 -translation lf
  set lines [split [string trimright [read $input] "\n"] "\n"]
  close $input
  foreach hit $hits {
    set line [lindex $lines [lindex $hit 1]]
    foreach {index field} \
      {2 text 3 input_source_id 4 input_sha256 5 source 6 conversation_id 7 node_id 8 message_id 9 role 10 position 12 part 13 fragment_index 14 char_start 15 char_end} \
      {
      if {[lindex $hit $index] ne [json get $line $field]} {
        error "retrieved provenance mismatch"
      }
    }
    if {[lindex $hit 11] ne [json extract $line create_time]} {
      error "retrieved timestamp mismatch"
    }
  }
  if {![catch {::mysql_store::begin_corpus $corpus 12 {incompatible configuration}}]} {
    error "configuration mismatch accepted"
  }
  puts "MySQL direct ingestion, rollback, resumption and retrieval passed"
} finally {
  ::mysql_store::db close
}
