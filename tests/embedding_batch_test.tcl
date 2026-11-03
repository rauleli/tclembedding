# Synthetic batch masking, errors, shape checks and recovery.
package require Tcl 8.6
package require tclembedding 1.0
if {[llength $argv] != 1} {error "usage: embedding_batch_test.tcl fixture_directory"}
set root [lindex $argv 0]
proc mustfail {script} {if {![catch {uplevel 1 $script}]} {error "expected controlled error: $script"}}
# These fixtures use exact integer-to-float casts; 1e-12 checks double pooling
# without depending on byte-identical Tcl formatting or model inference.
proc closebatch {actual expected} {
    if {[llength $actual] != [llength $expected]} {error "unexpected batch size"}
    foreach a $actual b $expected {closevec $a $b}
}
proc closevec {actual expected} {
    if {[llength $actual] != [llength $expected]} {error "unexpected vector dimension"}
    foreach a $actual b $expected {if {abs($a-$b) > 1e-12} {error "unexpected vector: $actual"}}
}
foreach fixture {batch-two-inputs batch-three-inputs} {
    set h [embedding::init_raw [file join $root $fixture.onnx]]
    set values [embedding::compute_batch $h {{1 2} {5}} -pad-id 99 -pooling mean]
    if {[llength $values] != 2} {error "unexpected batch size"}
    closevec [lindex $values 0] [list [expr {1.5/sqrt(3.25)}] [expr {1.0/sqrt(3.25)}]]
    closevec [lindex $values 1] [list [expr {5.0/sqrt(26.0)}] [expr {1.0/sqrt(26.0)}]]
    closebatch [embedding::compute_batch $h {{1 2} {5}} -pad-id 9223372036854775807] $values
    set pad_as_valid [embedding::compute_batch $h {{99} {5 6}} -pad-id 99]
    closevec [lindex $pad_as_valid 0] [list [expr {99.0/sqrt(9802.0)}] [expr {1.0/sqrt(9802.0)}]]
    # Three unequal rows exercise row stride, order, masks and a valid pad-valued ID.
    set triple [embedding::compute_batch $h {{1 2 3} {99} {4 5}} -pad-id 99 -pooling mean]
    if {[llength $triple] != 3} {error "unexpected triple batch size"}
    closevec [lindex $triple 0] [list [expr {2.0/sqrt(5.0)}] [expr {1.0/sqrt(5.0)}]]
    closevec [lindex $triple 1] [list [expr {99.0/sqrt(9802.0)}] [expr {1.0/sqrt(9802.0)}]]
    closevec [lindex $triple 2] [list [expr {4.5/sqrt(21.25)}] [expr {1.0/sqrt(21.25)}]]
    set triple_cls [embedding::compute_batch $h {{1 2 3} {99} {4 5}} -pad-id 99 -pooling cls]
    closevec [lindex $triple_cls 0] [list [expr {1.0/sqrt(2.0)}] [expr {1.0/sqrt(2.0)}]]
    closevec [lindex $triple_cls 1] [list [expr {99.0/sqrt(9802.0)}] [expr {1.0/sqrt(9802.0)}]]
    closevec [lindex $triple_cls 2] [list [expr {4.0/sqrt(17.0)}] [expr {1.0/sqrt(17.0)}]]
    set cls [embedding::compute_batch $h {{1 2} {5}} -pad-id 99 -pooling cls]
    closevec [lindex $cls 0] [list [expr {1.0/sqrt(2.0)}] [expr {1.0/sqrt(2.0)}]]
    closevec [lindex $cls 1] [list [expr {5.0/sqrt(26.0)}] [expr {1.0/sqrt(26.0)}]]
    closevec [lindex [embedding::compute_batch $h {{1 2}} -pad-id 0] 0] [embedding::compute $h {1 2}]
    foreach bad [list [list] [list {}] [list {1} {}] [list {-1}] [list {-18446744073709551613}] [list {x}] [list {1.0}] [list {9223372036854775808}] [list {18446744073709551616}]] {
        mustfail [list embedding::compute_batch $h $bad -pad-id 0]
    }
    foreach bad {-1 -18446744073709551613 9223372036854775808 18446744073709551616 x} {mustfail [list embedding::compute_batch $h {{1}} -pad-id $bad]}
    mustfail [list embedding::compute_batch $h {{1}} -pad-id 0 -pooling invalid]
    mustfail [list embedding::compute_batch $h [lrepeat 257 {1}] -pad-id 0]
    mustfail [list embedding::compute_batch $h [list [lrepeat 513 1]] -pad-id 0]
    mustfail [list embedding::compute_batch $h [lrepeat 9 [lrepeat 512 1]] -pad-id 0]
    closebatch [embedding::compute_batch $h {{1 2} {5}} -pad-id 99] $values
    embedding::free $h
    mustfail [list embedding::compute_batch $h {{1}} -pad-id 0]
}
foreach name {rank batch sequence type zero nan inf large-hidden} {
    set invalid [embedding::init_raw [file join $root $name.onnx]]
    mustfail [list embedding::compute_batch $invalid {{1 2}} -pad-id 0]
    mustfail [list embedding::compute_batch $invalid {{1 2}} -pad-id 0]
    embedding::free $invalid
}
# Runtime dimensions must agree with declared metadata before pooling allocation.
foreach name {output-mismatch-small output-mismatch-large} {
    set h [embedding::init_raw [file join $root $name.onnx]]
    if {![catch {embedding::compute_batch $h {{1 2}} -pad-id 0} message] ||
        ![string match {*safe shape*} $message]} {error "unexpected shape-mismatch result: $message"}
    embedding::free $h
}
# A rejected batch leaves the handle usable by the unchanged single path.
set mismatch [embedding::init_raw [file join $root output-mismatch-small.onnx]]
mustfail [list embedding::compute_batch $mismatch {{1 2}} -pad-id 0]
if {[llength [embedding::compute $mismatch {1 2}]] != 3} {error "single path or handle changed"}
embedding::free $mismatch
set fixed [embedding::init_raw [file join $root two-768.onnx]]
closevec [lindex [embedding::compute_batch $fixed {{1 2}} -pad-id 0] 0] [embedding::compute $fixed {1 2}]
mustfail [list embedding::compute_batch $fixed {{1 2} {3 4}} -pad-id 0]
embedding::free $fixed
puts "ONNX batch: synthetic masks, pooling and errors passed"
