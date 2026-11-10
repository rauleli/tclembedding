# Generate deterministic synthetic JSONL v2 fixtures for local testing.
package require Tcl 8.6
package require rl_json 0.15.7
package require tokenizer 1.0.0
namespace import ::rl_json::json
source [file join [file dirname [file normalize [info script]]] fragment.tcl]
if {[llength $argv] != 3} {error "usage: sql_fixture.tcl tokenizer.json output.jsonl count"}
lassign $argv tok output count
if {![string is integer -strict $count] || $count < 1 || $count > 1000} {error "invalid fixture count"}
set hash 0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39
package require sha256
if {[::sha2::sha256 -hex -filename $tok] ne $hash} {error "fixture tokenizer hash mismatch"}
set f [open $output {WRONLY CREAT EXCL} 0600]; fconfigure $f -encoding utf-8 -translation lf
set loaded 0
try {
 tokenizer::load_vocab $tok; set loaded 1
 for {set i 0} {$i < $count} {incr i} {
  set text "Synthetic document $i. [string repeat {Una frase breve sobre mantenimiento y recuperación. } [expr {1+$i%6}]]"
  set ids [tokenizer::tokenize "passage: $text"]; set n [llength $ids]; set unk 0
  foreach id $ids {if {$id == 3} {incr unk}}
  puts $f [format {{"fragment_version":"2","input_source_id":"synthetic","input_sha256":"%s","tokenizer_sha256":"%s","extractor_version":"1","token_budget":128,"source":"synthetic.json","conversation_id":"c","node_id":"n%d","message_id":"m%d","role":"user","position":%d,"create_time":null,"part":0,"fragment_index":0,"char_start":0,"char_end":%d,"token_count":%d,"unk_id":3,"unk_count":%d,"content_token_count":null,"max_nonspace_tcl_units":%d,"text":%s}} [string repeat a 64] $hash $i $i $i [string length $text] $n $unk [::fragment::max_nonspace_units $text] [json string $text]]
 }
} finally {if {$loaded} {tokenizer::free}; close $f}
puts "synthetic_records=$count"
