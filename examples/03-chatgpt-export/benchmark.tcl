package require Tcl 8.6
package require rl_json 0.15.7
package require sha256
namespace import ::rl_json::json
if {[llength $argv] != 7} {error "model tokenizer hash budget prefix scenario repo"}
lassign $argv model tokenizer expected budget prefix scenario repo
switch -- $model {
 minilm {set known 2c3387be76557bd40970cec13153b3bbf80407865484b209e655e5e4729076b8; set unknown_id 3}
 bge {set known d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66; set unknown_id 100}
 e5 {set known 0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39; set unknown_id 3}
 mpnet {set known b8be2c30ba5dd723a6d5ee26d013da103d5408d92ddcb23747622f9e48f1d842; set unknown_id 104}
 default {error "unknown model"}
}
if {$expected ne $known} {error "model and tokenizer hash do not match the characterized pair"}
if {[::sha2::sha256 -hex -filename $tokenizer] ne $expected} {error "tokenizer hash mismatch"}
set fragment_script [file join $repo examples 03-chatgpt-export fragment.tcl]
if {[info exists ::env(FRAGMENT_SCRIPT)]} {set fragment_script $::env(FRAGMENT_SCRIPT)}
source $fragment_script
set ::fragment::document_prefix $prefix
set ::fragment::expected_tokenizer $expected
set ::fragment::unknown_id $unknown_id
package require tokenizer 1.0.0
set t0 [clock microseconds]
tokenizer::load_vocab $tokenizer
set load_us [expr {[clock microseconds]-$t0}]
rename ::tokenizer::tokenize ::tokenizer::original_tokenize
set ::calls 0; set ::units 0; set ::max_units 0
proc ::tokenizer::tokenize {args} {
    incr ::calls
    set n [string length [lindex $args 0]]
    incr ::units $n
    if {$n > $::max_units} {set ::max_units $n}
    tailcall ::tokenizer::original_tokenize {*}$args
}
rename ::fragment::split_text ::fragment::original_split_text
set ::split_us 0
proc ::fragment::split_text {text budget} {
    set t [clock microseconds]
    try {::fragment::original_split_text $text $budget} finally {incr ::split_us [expr {[clock microseconds]-$t}]}
}
switch -- $scenario {
 short {set n 350; set seed "Hola, this is a synthetic support note.  Check the device.\n"}
 structured {set n 5000; set seed "Manual ficticio. Restart the device.  Revise la conexión.\n\n"}
 structured_long {set n 10000; set seed "Manual ficticio. Restart the device.  Revise la conexión.\n\n"}
 very_long {set n 42000; set seed "Manual ficticio. Restart the device.  Revise la conexión.\n\n"}
 unbroken {set n 5000; set seed "abcdefghijklmnopqrstuvwxzy"}
 unbroken42 {set n 42000; set seed "abcdefghijklmnopqrstuvwxzy"}
 many5 {set n 5000; set seed "alpha beta gamma delta.  Uno dos tres.\n"}
 many10 {set n 10000; set seed "alpha beta gamma delta.  Uno dos tres.\n"}
 many20 {set n 20000; set seed "alpha beta gamma delta.  Uno dos tres.\n"}
 unicode {set n 5000; set seed "Español e\u0301 café 😀 العربية 中文 English.  ¡Sí!\n\n"}
 default {error "unknown scenario"}
}
set text [string range [string repeat $seed [expr {$n/[string length $seed]+1}]] 0 [expr {$n-1}]]
# Do not leave a partial surrogate in a synthetic string.
if {[catch {::fragment::next_boundary $text [expr {[string length $text]-1}]}]} {set text [string range $text 0 end-1]}
set record [format {{"version":"1","source":"synthetic.json","conversation_id":"synthetic-conversation","node_id":"synthetic-node","message_id":"synthetic-message","position":1,"role":"user","create_time":null,"part":0,"text":%s}} [json string $text]]
set dir /tmp
if {[info exists ::env(TMPDIR)] && $::env(TMPDIR) ne ""} {set dir $::env(TMPDIR)}
set in [file tempfile inpath [file join $dir input]]; fconfigure $in -encoding utf-8 -translation lf; puts $in $record; close $in
puts "START model=$model scenario=$scenario chars=[string length $text] load_ms=[format %.3f [expr {$load_us/1000.0}]]"; flush stdout
set in [open $inpath r]; fconfigure $in -encoding utf-8 -translation lf
set out [file tempfile outpath [file join $dir output]]; fconfigure $out -encoding utf-8 -translation lf
set t0 [clock microseconds]
lassign [::fragment::process $in $out synthetic [string repeat a 64] $budget] records fragments
flush $out
set total [expr {[clock microseconds]-$t0}]
set primary_calls $::calls
set primary_units $::units; set primary_max $::max_units
close $in; close $out
set f [open $outpath r]; fconfigure $f -encoding utf-8 -translation lf
set reconstructed {}; set pos 0; set ix 0; set min 999999; set max 0; set sum 0; set unknowns 0; set layout {}
while {[gets $f row] >= 0} {
 if {![json valid $row] || [json get $row conversation_id] ne "synthetic-conversation" || [json get $row node_id] ne "synthetic-node" || [json get $row message_id] ne "synthetic-message" || [json get $row input_source_id] ne "synthetic" || [json get $row position] != 1 || [json get $row part] != 0 || [json get $row fragment_index] != $ix || [json get $row char_start] != $pos} {error "provenance or ordering failure"}
 set part [json get $row text]; set end [json get $row char_end]; set count [json get $row token_count]
 set actual_ids [::tokenizer::original_tokenize "$prefix$part"]
 set unknown 0; foreach id $actual_ids {if {$id == $::fragment::unknown_id} {incr unknown}}
 incr unknowns $unknown
 if {[json exists $row unk_count] && ([json get $row unk_count] != $unknown || [json get $row unk_id] != $::fragment::unknown_id)} {error "unknown count mismatch"}
 if {[json exists $row max_nonspace_tcl_units] && [json get $row max_nonspace_tcl_units] != [::fragment::max_nonspace_units $part]} {error "nonspace run mismatch"}
 append layout "$pos,$end,$count;"
 if {$part eq "" || $end <= $pos || $part ne [string range $text $pos [expr {$end-1}]] || $count != [llength [::tokenizer::original_tokenize "$prefix$part"]] || $count > $budget} {error "fragment integrity failure"}
 set pos $end; append reconstructed $part; incr ix; incr sum $count
 if {$count < $min} {set min $count}; if {$count > $max} {set max $count}
}
close $f
if {$reconstructed ne $text || $pos != [string length $text] || $ix != $fragments} {error "reconstruction failure"}
puts "RESULT model=$model scenario=$scenario chars=[string length $text] fragments=$fragments calls=$primary_calls tcl_units=$primary_units max_tcl_units=$primary_max split_ms=[format %.3f [expr {$::split_us/1000.0}]] process_ms=[format %.3f [expr {$total/1000.0}]] token_min=$min token_mean=[format %.2f [expr {double($sum)/$fragments}]] token_max=$max occupancy=[format %.6f [expr {double($sum)/($fragments*$budget)}]] unk=$unknowns layout_sha256=[::sha2::sha256 -hex $layout] integrity=pass"; flush stdout
set in [open $inpath r]; fconfigure $in -encoding utf-8 -translation lf
set out [file tempfile secondpath [file join $dir second]]; fconfigure $out -encoding utf-8 -translation lf
::fragment::process $in $out synthetic [string repeat a 64] $budget
close $in; close $out
set a [open $outpath rb]; set b [open $secondpath rb]; set one [read $a]; set two [read $b]; close $a; close $b
if {$one ne $two} {error "non-deterministic output"}
puts "DETERMINISM model=$model scenario=$scenario pass"; flush stdout
tokenizer::free
file delete -- $inpath $outpath $secondpath
