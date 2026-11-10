# Synthetic direct-ingestion regression; all files must be outside the source tree.
if {[llength $argv] != 5} {error "usage: fragments model tokenizer new-directory sqlite-extension"}
lassign $argv fragments model tokenizer directory extension
if {[file exists $directory]} {error "test directory exists"}
file mkdir $directory
source [file join [file dirname [file normalize [info script]]] sqlite_retrieval.tcl]
set database [file join $directory corpus.sqlite3]
::store::init $database
set ::sql_ingest::fail_after 2
if {![catch {::store::ingest $database $fragments $model $tokenizer 4}]} {error "expected transactional failure"}
::store::open_db $database 0
if {[::store::db onecolumn {SELECT COUNT(*) FROM fragments}] != 0} {error "rollback failed"}
::store::db close
set ::sql_ingest::fail_after -1
set ::sql_ingest::stop_after 4
if {![catch {::store::ingest $database $fragments $model $tokenizer 4}]} {error "expected interrupted ingestion"}
::store::open_db $database 0
if {[::store::db onecolumn {SELECT COUNT(*) FROM fragments}] != 4 || [::store::db onecolumn {SELECT progress FROM corpora}] != 4} {error "checkpoint failed"}
if {[::store::db onecolumn {PRAGMA journal_mode}] ne "wal"} {error "WAL not enabled"}
set corpus [::pipeline::file_hash $fragments]
if {![catch {::store::validate_query $corpus [lrepeat 384 0.1] 3}]} {error "incomplete corpus was queryable"}
::store::db close
set ::sql_ingest::stop_after -1
::store::ingest $database $fragments $model $tokenizer 4
::store::ingest $database $fragments $model $tokenizer 4
::store::open_db $database 0
set saved [::store::db onecolumn {SELECT vector FROM fragments WHERE corpus=$corpus AND sequence=0}]
::store::db eval {UPDATE fragments SET vector=zeroblob(1536) WHERE corpus=$corpus AND sequence=0}
::store::db close
if {![catch {::store::ingest $database $fragments $model $tokenizer 4} reason] ||
    $reason ne "stored vector or identity mismatch"} {error "corrupt vector not rejected as expected"}
::store::open_db $database 0
::store::db eval {UPDATE fragments SET vector=$saved WHERE corpus=$corpus AND sequence=0}
::store::db close
set hits [::store::query_results $database $corpus $model $tokenizer {synthetic maintenance} 3 $extension]
if {[llength $hits] != 3 || [llength [lindex $hits 0]] != 17} {error "retrieval failed"}
set input [open $fragments]
fconfigure $input -encoding utf-8 -translation lf
set lines [split [string trimright [read $input] "\n"] "\n"]
close $input
foreach hit $hits {
  set line [lindex $lines [lindex $hit 1]]
  foreach {index field} {2 text 3 input_source_id 4 input_sha256 5 source 6 conversation_id 7 node_id 8 message_id 9 role 10 position 12 part 13 fragment_index 14 char_start 15 char_end} {
    if {[lindex $hit $index] ne [json get $line $field]} {error "retrieved provenance mismatch"}
  }
  if {[lindex $hit 11] ne [json extract $line create_time]} {error "retrieved timestamp mismatch"}
}
::store::open_db $database 0
if {[::store::db onecolumn {PRAGMA integrity_check}] ne "ok" || [::store::db onecolumn {SELECT COUNT(*) FROM fragments}] != 12} {error "database integrity failure"}
if {![catch {::store::begin_corpus $corpus 12 {incompatible configuration}}]} {error "configuration mismatch accepted"}
set config [::store::db onecolumn {SELECT configuration FROM corpora WHERE id=$corpus}]
::store::db eval {UPDATE corpora SET pooling='cls' WHERE id=$corpus}
if {![catch {::store::begin_corpus $corpus 12 $config}]} {error "incompatible model metadata accepted"}
::store::db eval {UPDATE corpora SET pooling='mean' WHERE id=$corpus}
::store::db close
puts "SQLite direct ingestion, rollback, resumption and retrieval passed"
