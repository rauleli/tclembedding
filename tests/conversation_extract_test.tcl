# Synthetic tests for active-path extraction and JSONL provenance.
package require Tcl 8.6
package require rl_json 0.15.7
namespace import ::rl_json::json
set script [file normalize [file join [file dirname [info script]] .. tools conversation_extract.tcl]]
set root [file join /tmp "conversation-extract-test-[pid]-[clock clicks]"]
file mkdir $root
set first [file join $root conversations-000.json]
set second [file join $root conversations-001.json]
set output [file join $root result.jsonl]
proc writefile {path data} {set f [open $path {WRONLY CREAT EXCL} 0600]; fconfigure $f -encoding utf-8 -translation lf; puts -nonewline $f $data; close $f}
proc check {condition message} {if {![uplevel 1 [list expr $condition]]} {error $message}}
proc mustfail {args} {
    set rc [catch {exec {*}$args} result options]
    array set fields $options
    if {!$rc || ![info exists fields(-errorcode)] ||
        [lindex $fields(-errorcode) 0] ne "CHILDSTATUS" ||
        [lindex $fields(-errorcode) 2] != 1} {
        error "expected controlled nonzero child exit"
    }
}
set data {[
 {"id":"c1","current_node":"b","ignored":"extra","mapping":{
  "r":{"id":"r","parent":null,"message":null},
  "a":{"id":"a","parent":"r","message":{"id":"a","author":{"role":"user"},"create_time":1.5,"content":{"content_type":"text","parts":["Hola á",null,"", "English\n\"quoted\" \\ slash", "sandbox:/synthetic-attachment"]}}},
  "b":{"id":"b","parent":"a","message":{"id":"b","author":{"role":"assistant"},"content":{"content_type":"text","parts":["Reply 😀"]}}},
  "z":{"id":"z","parent":"a","message":{"id":"z","author":{"role":"assistant"},"content":{"content_type":"text","parts":["wrong branch"]}}}
 }},
 {"id":"c2","current_node":"a","mapping":{
  "r":{"id":"r","parent":null,"message":null},
  "a":{"id":"a","parent":"r","message":{"id":"a","author":{"role":"user"},"create_time":null,"content":{"content_type":"text","parts":["Hola á"]}}}
 }}]}
set excluded {[
 {"id":"c3","current_node":"d","mapping":{
  "r":{"id":"r","parent":null,"message":null},
  "a":{"id":"a","parent":"r","message":{"id":"a","author":{"role":"assistant"},"content":{"content_type":"thoughts","parts":["skip"]}}},
  "b":{"id":"b","parent":"a","message":{"id":"b","author":{"role":"user"},"content":{"content_type":"multimodal_text","parts":["skip"]}}},
  "c":{"id":"c","parent":"b","message":{"id":"c","author":{"role":"tool"},"content":{"content_type":"text","parts":["skip"]}}},
  "d":{"id":"d","parent":"c","message":{"id":"d","author":{"role":"user"},"content":{"content_type":"text","parts":[null,"  "]}}}
 }}]}
writefile $first $data
writefile $second $excluded
set result [exec [info nameofexecutable] $script $first $second $output]
check {[string first "records=4" $result] >= 0} "wrong record count"
check {[string first "extracted_messages=3" $result] >= 0} "wrong message count"
check {[string first "reference_parts=1" $result] >= 0} "attachment reference was not excluded"
set f [open $output r]; fconfigure $f -encoding utf-8 -translation lf; set lines [split [string trimright [read $f] "\n"] "\n"]; close $f
check {[llength $lines] == 4} "wrong line count"
set expected [list "Hola á" "English\n\"quoted\" \\ slash" "Reply 😀" "Hola á"]
set i 0
foreach line $lines text $expected {
    check {[json valid $line]} "invalid JSONL"
    check {[json get $line text] eq $text} "text round trip failed"
    check {[json get $line version] eq "1"} "version missing"
    incr i
}
check {[json get [lindex $lines 0] position] == 1} "wrong path position"
check {[json get [lindex $lines 0] create_time] == 1.5} "timestamp not preserved"
check {[json get [lindex $lines 0] source] eq "conversations-000.json"} "source not preserved"
check {[json get [lindex $lines 1] part] == 3} "wrong part index"
check {[json get [lindex $lines 2] role] eq "assistant"} "wrong role"
check {[json isnull [lindex $lines 2] create_time]} "missing time must be null"
check {[json get [lindex $lines 3] conversation_id] eq "c2"} "repeated ID lost provenance"
set output2 [file join $root result2.jsonl]
set result2 [exec [info nameofexecutable] $script $first $second $output2]
set f [open $output r]; fconfigure $f -translation binary; set bytes1 [read $f]; close $f
set f [open $output2 r]; fconfigure $f -translation binary; set bytes2 [read $f]; close $f
check {$bytes1 eq $bytes2 && $result eq $result2} "extraction is not deterministic"
mustfail [info nameofexecutable] $script $first $second $output
set f [open $output r]; fconfigure $f -translation binary; set after [read $f]; close $f
check {$after eq $bytes1} "existing output overwritten"
set badroot [file join $root bad]; file mkdir $badroot
set bad1 [file join $badroot conversations-000.json]; set bad2 [file join $badroot conversations-001.json]
writefile $bad2 {[]}
writefile $bad1 {[{"id":"c","current_node":"a","mapping":{"a":{"id":"a","parent":"missing","message":null}}}]}
mustfail [info nameofexecutable] $script $bad1 $bad2 [file join $badroot missing.jsonl]
set cycleroot [file join $root cycle]; file mkdir $cycleroot
set cycle1 [file join $cycleroot conversations-000.json]; set cycle2 [file join $cycleroot conversations-001.json]
writefile $cycle2 {[]}
writefile $cycle1 {[{"id":"c","current_node":"a","mapping":{"a":{"id":"a","parent":"b","message":null},"b":{"id":"b","parent":"a","message":null}}}]}
mustfail [info nameofexecutable] $script $cycle1 $cycle2 [file join $cycleroot cycle.jsonl]
set partial [file join $root partial.jsonl]
mustfail [info nameofexecutable] $script $first [file join $badroot absent conversations-001.json] $partial
check {[file exists $partial]} "partial output case not exercised"
puts "Synthetic conversation extractor tests passed"
