# Synthetic fixtures and restart tests; no private corpus is read.
package require Tcl 8.6
package require rl_json 0.15.7
package require sha256
namespace import ::rl_json::json
set root [file dirname [file normalize [info script]]]
source [file join $root embed_pipeline.tcl]
source [file join $root fragment.tcl]
proc assert {expr message} {if {![uplevel 1 [list expr $expr]]} {error $message}}
proc filebytes {p} {set f [open $p rb]; try {return [read $f]} finally {close $f}}
if {[llength $argv] != 3} {error "usage: embed_pipeline_test.tcl model tokenizer output-directory"}
lassign $argv model tok dir
set ::test_model [file normalize $model]
set ::test_model_hash [::pipeline::file_hash $model]
if {$::test_model_hash ne $::pipeline::model_hash} {error "test model hash mismatch"}
# The immutable model is verified once for this multi-run test; production hashes each run.
rename ::pipeline::file_hash ::pipeline::original_file_hash
proc ::pipeline::file_hash {path} {
 if {[file normalize $path] eq $::test_model} {return $::test_model_hash}
 return [original_file_hash $path]
}
if {[file exists $dir]} {error "test directory already exists"}
file mkdir $dir
set input [file join $dir fragments.jsonl]
package require tokenizer 1.0.0
tokenizer::load_vocab $tok
set f [open $input {WRONLY CREAT EXCL} 0600]; fconfigure $f -encoding utf-8 -translation lf
for {set i 0} {$i < 12} {incr i} {
 set text "Synthetic document $i: una frase breve."
 set ids [tokenizer::tokenize "passage: $text"]; set n [llength $ids]; set unk 0
 foreach id $ids {if {$id == 3} {incr unk}}
 puts $f [format {{"fragment_version":"2","input_source_id":"synthetic","input_sha256":"%s","tokenizer_sha256":"%s","extractor_version":"1","token_budget":128,"source":"synthetic.json","conversation_id":"c","node_id":"n%d","message_id":"m%d","role":"user","position":%d,"create_time":null,"part":0,"fragment_index":0,"char_start":0,"char_end":%d,"token_count":%d,"unk_id":3,"unk_count":%d,"content_token_count":null,"max_nonspace_tcl_units":%d,"text":%s}} [string repeat a 64] $::pipeline::tokenizer_hash $i $i $i [string length $text] $n $unk [::fragment::max_nonspace_units $text] [json string $text]]
}
close $f; tokenizer::free
set common [list -input $input -model $model -tokenizer $tok -budget 128 -batch-size 4]
set full [file join $dir full.bin]
::pipeline::main {*}$common -output $full
::pipeline::verify_file $full $input
foreach {name partial} {restart 0 torn 1} {
 set output [file join $dir "$name.bin"]
 set worker [file join $dir "$name-worker.tcl"]
 set wf [open $worker {WRONLY CREAT EXCL} 0600]
 puts $wf [format {source %s; set ::pipeline::test_after 5; set ::pipeline::test_partial %d; set ::pipeline::test_hard_exit 1; ::pipeline::main {*}$argv} [list [file join $root embed_pipeline.tcl]] $partial]
 close $wf
 set rc [catch {exec [info nameofexecutable] $worker {*}$common -output $output} message options]
 array set result $options
 if {!$rc || ![info exists result(-errorcode)] || [lindex $result(-errorcode) 0] ne "CHILDSTATUS" || [lindex $result(-errorcode) 2] != 86} {error "expected interrupted child process: $message"}
 assert {![file exists $output] && [file exists "$output.partial"]} "interruption published output"
 if {![catch {::pipeline::verify_file "$output.partial"}]} {error "partial checkpoint accepted as complete"}
 ::pipeline::main {*}$common -output $output
 assert {[filebytes $full] eq [filebytes $output]} "resumed bytes differ"
}
set bad [file join $dir corrupt.bin]
set ::pipeline::test_after 5
if {![catch {::pipeline::main {*}$common -output $bad}]} {error "expected interruption"}
set ::pipeline::test_after -1
set repeated [file join $dir repeated.bin]
file copy -- "$bad.partial" "$repeated.partial"
set fd [open "$repeated.partial" r+]; fconfigure $fd -translation binary -encoding binary
set prefix [read $fd 14]
scan [string range $prefix 5 12] %x header_length
seek $fd [expr {14+$header_length+65}]
set first [read $fd $::pipeline::record_size]
seek $fd 0 end; puts -nonewline $fd $first; close $fd
if {![catch {::pipeline::main {*}$common -output $repeated}]} {error "duplicate checkpoint record accepted"}
set fd [open "$bad.partial" r+]; fconfigure $fd -translation binary -encoding binary
seek $fd -1 end; set old [read $fd 1]; seek $fd -1 end
puts -nonewline $fd [expr {$old eq "a" ? "b" : "a"}]; close $fd
if {![catch {::pipeline::main {*}$common -output $bad}]} {error "corrupt record accepted"}
if {![catch {::pipeline::main {*}$common -output $bad -batch-size 3}]} {error "incompatible checkpoint accepted"}
if {![catch {::pipeline::main {*}$common -output $bad -model $tok}]} {error "different model accepted"}
set changed [file join $dir changed.jsonl]; set fd [open $changed {WRONLY CREAT EXCL} 0600]; fconfigure $fd -translation binary; puts -nonewline $fd [string map {{"input_source_id":"synthetic"} {"input_source_id":"changed"}} [filebytes $input]]; close $fd
if {![catch {::pipeline::main -input $changed -model $model -tokenizer $tok -budget 128 -batch-size 4 -output $bad}]} {error "changed input accepted"}
set duplicated [file join $dir duplicated.jsonl]; set fd [open $duplicated {WRONLY CREAT EXCL} 0600]; fconfigure $fd -translation binary; set content [filebytes $input]; puts -nonewline $fd "$content$content"; close $fd
if {![catch {::pipeline::main -input $duplicated -model $model -tokenizer $tok -budget 128 -batch-size 4 -output [file join $dir duplicate.bin]}]} {error "duplicate accepted"}
if {![catch {::pipeline::main {*}$common -output $full}]} {error "overwrite accepted"}
assert {[binary encode hex [binary format r 1.0]] eq "0000803f"} "float32 little-endian encoding"
puts "Pipeline synthetic tests passed"
