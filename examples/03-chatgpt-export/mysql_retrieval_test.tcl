# Run only against a fresh, disposable server with TCP disabled.
if {[llength $argv] != 5} {error "usage: socket database user fragments vectors"}
lassign $argv socket database user fragments vectors
source [file join [file dirname [file normalize [info script]]] mysql_retrieval.tcl]
if {[package provide sqlite3] ne ""} {error "MySQL test unexpectedly loaded SQLite"}
proc assert {expression message} {if {![uplevel 1 [list expr $expression]]} {error $message}}
::mysql_store::connect $socket $database $user
set networking [::mysql_store::run {SHOW VARIABLES LIKE 'skip_networking'} {}]
set server_socket [::mysql_store::run {SHOW VARIABLES LIKE 'socket'} {}]
set data_dir [::mysql_store::run {SHOW VARIABLES LIKE 'datadir'} {}]
set plugin_dir [::mysql_store::run {SHOW VARIABLES LIKE 'plugin_dir'} {}]
set lab [file dirname [file normalize $socket]]
assert {[string first "/tmp/" "$lab/"] == 0 && [lindex $networking 0 1] eq "ON" && [file normalize [lindex $server_socket 0 1]] eq [file normalize $socket] && [file normalize [lindex $data_dir 0 1]] eq [file join $lab data] && [file normalize [lindex $plugin_dir 0 1]] eq [file join $lab plugins]} "server is not isolated"
::mysql_store::init
::mysql_store::check_udf
set quoted {synthetic 'quoted'; value}
set rows [::mysql_store::run {SELECT :quoted} [list quoted $quoted]]
assert {[lindex $rows 0 0] eq $quoted} "prepared text parameter changed"
set ::mysql_store::fail_after 2
if {![catch {::mysql_store::ingest $fragments $vectors}]} {error "injected failure accepted"}
set ::mysql_store::fail_after -1
set rows [::mysql_store::run {SELECT COUNT(*) FROM l2_corpora} {}]
assert {[lindex $rows 0 0] == 0} "rollback failed"
set worker [file join [file dirname [file normalize $socket]] "l2-interrupted-worker-[pid].tcl"]
set wf [open $worker {WRONLY CREAT EXCL} 0600]
puts $wf [format {source %s; ::mysql_store::connect {*}[lrange $argv 0 2]; set ::mysql_store::exit_after 2; ::mysql_store::ingest {*}[lrange $argv 3 4]} [list [file join $::mysql_store_dir mysql_retrieval.tcl]]]
close $wf
set code [catch {exec [info nameofexecutable] $worker $socket $database $user $fragments $vectors} child options]
array set child_result $options
assert {$code && [lindex $child_result(-errorcode) 0] eq "CHILDSTATUS" && [lindex $child_result(-errorcode) 2] == 86} "child did not terminate as expected"
set rows [::mysql_store::run {SELECT COUNT(*) FROM l2_corpora} {}]
assert {[lindex $rows 0 0] == 0} "interrupted process was not rolled back"
::mysql_store::ingest $fragments $vectors
::mysql_store::ingest $fragments $vectors
set corpus [::pipeline::file_hash $fragments]
set header [lindex [::mysql_store::run {SELECT header_json FROM l2_corpora WHERE id=:corpus} [list corpus $corpus]] 0 0]
::mysql_store::run {UPDATE l2_corpora SET header_json='{}' WHERE id=:corpus} [list corpus $corpus]
if {![catch {::mysql_store::ingest $fragments $vectors}]} {error "corrupt corpus metadata accepted"}
::mysql_store::run {UPDATE l2_corpora SET header_json=:header WHERE id=:corpus} [list header $header corpus $corpus]
set rows [::mysql_store::run {SELECT vector FROM l2_fragments WHERE corpus=:corpus AND sequence_no=0} [list corpus $corpus]]
set f [open $vectors rb]; set h [read $f 14]; scan [string range $h 5 12] %x n; seek $f [expr {79+$n+72}]; set reference [read $f 1536]; close $f
assert {[lindex $rows 0 0] eq $reference} "vector bytes differ"
set corrupt [file join $lab "corrupt-synthetic-[pid].l2e"]
file copy $vectors $corrupt
set file [open $corrupt r+]; fconfigure $file -translation binary; seek $file -1 end; puts -nonewline $file z; close $file
if {![catch {::mysql_store::ingest $fragments $corrupt}]} {error "corrupt input accepted"}
set zeros [binary format a1536 {}]
::mysql_store::run {UPDATE l2_fragments SET vector=:zero WHERE corpus=:corpus AND sequence_no=0} [list zero $zeros corpus $corpus] {zero}
if {![catch {::mysql_store::ingest $fragments $vectors}]} {error "modified vector accepted"}
::mysql_store::db close
puts "MySQL isolated synthetic storage tests passed"
