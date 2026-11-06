# Synthetic database checks with previously generated L2E1 and JSONL fixtures.
if {[llength $argv] != 3} {error "usage: sqlite_retrieval_test.tcl fragments vectors new-directory"}
lassign $argv fragments vectors dir
source [file join [file dirname [file normalize [info script]]] sqlite_retrieval.tcl]
if {[package provide tdbc::mysql] ne "" || [package provide mysqltcl] ne ""} {error "SQLite test unexpectedly loaded a MySQL driver"}
proc assert {expression message} {if {![uplevel 1 [list expr $expression]]} {error $message}}
if {[file exists $dir]} {error "test directory exists"}; file mkdir $dir
set partial [file join $dir partial.sqlite3]
sqlite3 partial_db $partial
partial_db eval {CREATE TABLE corpora (id TEXT); PRAGMA user_version=1}
partial_db close
if {![catch {::store::init $partial} message] || ![string match "*partially initialized*" $message]} {error "partial initialization not rejected"}
::store::open_db $partial 0
if {![catch {::store::check_schema} message] || ![string match "*incompatible*" $message]} {error "partial schema not rejected"}
assert {[::store::db onecolumn {SELECT COUNT(*) FROM sqlite_master WHERE type='table'}] == 1} "partial schema was changed"
::store::db close
set empty [file join $dir empty.sqlite3]; set fd [open $empty {WRONLY CREAT EXCL} 0600]; close $fd
if {![catch {::store::init $empty}]} {error "existing empty database accepted"}
::store::open_db $empty 0
if {![catch {::store::check_schema}]} {error "empty schema accepted"}
::store::db close
set init_worker [file join $dir init-worker.tcl]
set wf [open $init_worker {WRONLY CREAT EXCL} 0600]
puts $wf [format {source %s; set ::store::init_exit_after_reserve 1; ::store::init [lindex $argv 0]} [list [file join $::store_dir sqlite_retrieval.tcl]]]
close $wf
set interrupted [file join $dir interrupted-init.sqlite3]
set rc [catch {exec [info nameofexecutable] $init_worker $interrupted} child init_options]
array set init_result $init_options
assert {$rc && [lindex $init_result(-errorcode) 0] eq "CHILDSTATUS" && [lindex $init_result(-errorcode) 2] == 86} "initialization was not interrupted"
if {![catch {::store::init $interrupted} message] || ![string match "*partially initialized*" $message]} {error "interrupted initialization not rejected"}
set ddl_worker [file join $dir ddl-worker.tcl]
set wf [open $ddl_worker {WRONLY CREAT EXCL} 0600]
puts $wf [format {source %s; set ::store::init_exit_after_first 1; ::store::init [lindex $argv 0]} [list [file join $::store_dir sqlite_retrieval.tcl]]]
close $wf
set ddl_interrupted [file join $dir interrupted-ddl.sqlite3]
set rc [catch {exec [info nameofexecutable] $ddl_worker $ddl_interrupted} child ddl_options]
array set ddl_result $ddl_options
assert {$rc && [lindex $ddl_result(-errorcode) 0] eq "CHILDSTATUS" && [lindex $ddl_result(-errorcode) 2] == 86} "DDL was not interrupted"
::store::open_db $ddl_interrupted 0
assert {[::store::db onecolumn {SELECT COUNT(*) FROM sqlite_master WHERE type='table'}] == 0 && [::store::db onecolumn {PRAGMA user_version}] == 0} "interrupted DDL was not rolled back"
::store::db close
if {![catch {::store::init $ddl_interrupted} message] || ![string match "*partially initialized*" $message]} {error "interrupted DDL file not protected"}
set database [file join $dir corpus.sqlite3]
::store::init $database
set ::store::fail_after 2
if {![catch {::store::ingest $database $fragments $vectors}]} {error "injected failure accepted"}
set ::store::fail_after -1
::store::open_db $database 0
set quoted {synthetic 'quoted'; value}
assert {[::store::db onecolumn {SELECT $quoted}] eq $quoted} "bound text parameter changed"
assert {[::store::db onecolumn {SELECT COUNT(*) FROM corpora}] == 0} "rollback failed"
::store::db close
set worker [file join $dir worker.tcl]
set wf [open $worker {WRONLY CREAT EXCL} 0600]
puts $wf [format {source %s; set ::store::exit_after 2; ::store::ingest {*}$argv} [list [file join $::store_dir sqlite_retrieval.tcl]]]
close $wf
set code [catch {exec [info nameofexecutable] $worker $database $fragments $vectors} child options]
array set child_result $options
assert {$code && [lindex $child_result(-errorcode) 0] eq "CHILDSTATUS" && [lindex $child_result(-errorcode) 2] == 86} "child did not terminate as expected"
::store::open_db $database 0
assert {[::store::db onecolumn {SELECT COUNT(*) FROM corpora}] == 0} "interrupted process was not rolled back"
::store::db close
::store::ingest $database $fragments $vectors
::store::ingest $database $fragments $vectors
set corpus [::pipeline::file_hash $fragments]
::store::open_db $database 0
::store::db eval {UPDATE corpora SET model='synthetic mismatch' WHERE id=$corpus}
::store::db close
if {![catch {::store::ingest $database $fragments $vectors}]} {error "corrupt corpus metadata accepted"}
::store::open_db $database 0
::store::db eval {UPDATE corpora SET model='intfloat/multilingual-e5-small' WHERE id=$corpus}
::store::db close
::store::open_db $database 0
set rowcount [::store::db onecolumn {SELECT COUNT(*) FROM fragments WHERE corpus=$corpus}]
assert {$rowcount > 2} "missing rows"
set stored [::store::db onecolumn {SELECT vector FROM fragments WHERE corpus=$corpus AND sequence=0}]
set f [open $vectors rb]; set h [read $f 14]; scan [string range $h 5 12] %x n; seek $f [expr {79+$n+72}]; set reference [read $f 1536]; close $f
assert {$stored eq $reference} "stored vector bytes differ"
binary scan $stored r* query
set result [::store::retrieve $corpus $query 3]
assert {[llength $result] == 3 && [lindex [lindex $result 0] 1] == 0} "query ranking failed"
assert {[::store::compare {1.0 2} {1.0 3}] < 0} "tie order is not deterministic"
set selected {}; foreach hit $result {lappend selected [lindex $hit 1]}
set unused 0; while {[lsearch -exact $selected $unused] >= 0} {incr unused}
set prior [::store::db onecolumn {SELECT text FROM fragments WHERE corpus=$corpus AND sequence=$unused}]
::store::db eval {UPDATE fragments SET text='unselected synthetic alteration' WHERE corpus=$corpus AND sequence=$unused}
::store::retrieve $corpus $query 3
::store::db eval {UPDATE fragments SET text=$prior WHERE corpus=$corpus AND sequence=$unused}
set original_text [lindex [lindex $result 0] 2]
::store::db eval {UPDATE fragments SET text='synthetic alteration' WHERE corpus=$corpus AND sequence=0}
if {![catch {::store::retrieve $corpus $query 3}]} {error "query accepted corrupt selected text"}
::store::db eval {UPDATE fragments SET text=$original_text WHERE corpus=$corpus AND sequence=0}
::store::db eval {UPDATE fragments SET vector=zeroblob(1536) WHERE corpus=$corpus AND sequence=0}
if {![catch {::store::retrieve $corpus $query 3}]} {error "query accepted a corrupt vector"}
::store::db close
if {![catch {::store::ingest $database $fragments $vectors}]} {error "modified vector accepted"}
::store::open_db $database 0
::store::db eval {DELETE FROM fragments WHERE corpus=$corpus AND sequence=0}
if {![catch {::store::retrieve $corpus $query 3}]} {error "missing record accepted"}
::store::db close
set corrupt [file join $dir corrupt.l2e]; file copy $vectors $corrupt
set f [open $corrupt r+]; fconfigure $f -translation binary; seek $f -1 end; puts -nonewline $f z; close $f
if {![catch {::store::ingest $database $fragments $corrupt}]} {error "corrupt input accepted"}
puts "SQLite synthetic storage tests passed"
