# Tests generated synthetic ONNX fixtures; no model download is required.
package require Tcl 8.6
package require tclembedding 1.0
if {[llength $argv] != 1} {error "usage: embedding_safety_test.tcl fixture_directory"}
set root [lindex $argv 0]
proc expect_error {script pattern} {
    if {![catch {uplevel 1 $script} message]} {error "expected error: $script"}
    if {![string match $pattern $message]} {error "unexpected error: $message"}
}
set h [embedding::init_raw [file join $root valid.onnx]]
set good [embedding::compute $h {0 2}]
if {[llength $good] != 384} {error "valid fixture failed"}
foreach ids {{} {x} {1.0} {-1} {9223372036854775808} {18446744073709551616} {-9223372036854775809} {-18446744073709551615} {9999999999999999999999999999999} {0xffffffffffffffff} {0x8000000000000000} {-0xffffffffffffffff}} {
    expect_error [list embedding::compute $h $ids] *
    if {[embedding::compute $h {0 2}] ne $good} {error "handle did not recover"}
}
if {[embedding::compute $h {0 9223372036854775807}] ne $good} {error "valid int64 maximum rejected"}
set big [expr {-(2**64) + 1}]
expect_error [list embedding::compute $h [list $big]] *
embedding::free $h
foreach {name pattern} {
    rank {*rank 3*} batch {*shape*} sequence {*shape*} type {*float32*}
    zero {*norm*} nan {*non-finite*} inf {*non-finite*}
} {
    set h [embedding::init_raw [file join $root $name.onnx]]
    expect_error [list embedding::compute $h {0 2}] $pattern
    expect_error [list embedding::compute $h {0 2}] $pattern
    embedding::free $h
}
set h [embedding::init_raw [file join $root tiny.onnx]]
set tiny [embedding::compute $h {0 2}]
if {[llength $tiny] != 384 || abs([lindex $tiny 0] - 0.001) > 1e-9} {error "small nonzero norm behavior changed"}
embedding::free $h
puts "ONNX safety fixtures: passed"

# The hidden dimension is derived from the actual output, not a fixed 384.
set small [embedding::init_raw [file join $root hidden.onnx]]
if {[llength [embedding::compute $small {0 2}]] != 3} {error "dynamic hidden dimension failed"}
embedding::free $small
foreach name {two-768 three-768 fixed-input} {
    set h [embedding::init_raw [file join $root $name.onnx]]
    set mean [embedding::compute $h {0 2}]
    set explicit [embedding::compute $h {0 2} -pooling mean]
    set cls [embedding::compute $h {0 2} -pooling cls]
    if {[llength $mean] != 768 || $mean ne $explicit || [llength $cls] != 768} {error "invalid dimension or mean"}
    if {abs([lindex $mean 0] - 1.0/sqrt(2.0)) > 1e-12 || abs([lindex $mean 1] - 1.0/sqrt(2.0)) > 1e-12} {error "incorrect mean"}
    if {[lindex $cls 0] != 1.0 || [lindex $cls 1] != 0.0} {error "incorrect cls"}
    expect_error [list embedding::compute $h {0 2} -pooling bogus] *
    if {[embedding::compute $h {0 2}] ne $mean} {error "handle failed to recover"}
    if {$name eq "fixed-input"} {expect_error [list embedding::compute $h {0 2 3}] *sequence*}
    embedding::free $h
}
foreach name {unknown-input missing-input input-type input-rank input-batch} {
    expect_error [list embedding::init_raw [file join $root $name.onnx]] *
}
puts "ONNX signatures and pooling: passed"
