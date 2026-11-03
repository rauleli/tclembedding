# Synthetic tokenizer timing probe: fixture path and mode are required.
package require Tcl 8.6
package require tokenizer 1.0.0
if {[llength $argv] != 2} {error "usage: tokenizer_perf.tcl tokenizer.json mode"}
lassign $argv fixture mode
if {$mode ni {direct-short limit-short direct-long limit-long}} {error "invalid timing mode"}
set start [clock microseconds]
tokenizer::load_vocab $fixture
set load [expr {([clock microseconds]-$start)/1000.0}]
set text hola
if {[string match *long $mode]} {set text [string repeat {hola } 80]}
set full [tokenizer::tokenize $text]
set opts {}
if {[string match limit-* $mode]} {set opts {-max-length 128}}
set warm [tokenizer::tokenize $text {*}$opts]
set timings {}
for {set i 0} {$i < 10} {incr i} {
 set start [clock microseconds]
 set ids [tokenizer::tokenize $text {*}$opts]
 lappend timings [expr {([clock microseconds]-$start)/1000.0}]
 if {$ids ne $warm} {error "inconsistent IDs"}
}
set sorted [lsort -real $timings]
puts [format "mode=%s load_ms=%.3f full_ids=%d output_ids=%d min_ms=%.6f median_ms=%.6f max_ms=%.6f" $mode $load [llength $full] [llength $warm] [lindex $sorted 0] [expr {([lindex $sorted 4]+[lindex $sorted 5])/2.}] [lindex $sorted 9]]
tokenizer::free
