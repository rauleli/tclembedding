# Synthetic ONNX lifecycle test. The model is an external, hash-identified fixture.
package require Tcl 8.6
package require tclembedding 1.0
if {[llength $argv] != 1} {
  error "usage: embedding_lifecycle_test.tcl model.onnx"
}
set model [lindex $argv 0]
set expected_sha 10f7a088420252b26caf819236ca2c9d2987afd0fc06fec7553b542a5655a05a
if {[lindex [exec sha256sum -- $model] 0] ne $expected_sha} {
  error "unexpected ONNX fixture hash"
}

# Verify that a command reports an error.
proc require_error {script} {
  if {![catch {uplevel 1 $script} message]} {
    error "expected error: $script"
  }
  if {$message eq ""} {
    error "error lacks a diagnostic: $script"
  }
}

require_error {embedding::init_raw /nonexistent/tclembedding-model.onnx}
require_error [list embedding::init_raw [info script]]
require_error {embedding::free}
require_error {embedding::free missing extra}
require_error {embedding::free puts}
require_error {embedding::compute puts {0 2}}
require_error {embedding::compute missing {0 2}}
set a [embedding::init_raw $model]
set ids {0 739 143 2}
set vector [embedding::compute $a $ids]
if {[llength $vector] != 384} {
  error "incorrect vector dimension"
}
set baseline_file [file join [file dirname [info script]] embedding_baseline.tcllist]
set f [open $baseline_file r]
set baseline [split [string trimright [read $f] "\n"] "\n"]
close $f
set all_ids {{0 739 143 2} {0 51 125583 115 56 282 2} {0 576 114566 7 39192 1414 2}}
if {[llength $baseline] != [llength $all_ids]} {
  error "invalid baseline case count"
}
foreach expected_vector $baseline case_ids $all_ids {
  set actual_vector [embedding::compute $a $case_ids]
  if {[llength $expected_vector] != 384 || [llength $actual_vector] != 384} {
    error "invalid baseline dimension"
  }
  foreach actual $actual_vector expected $expected_vector {
    if {abs($actual - $expected) > 1e-5} {
      error "embedding regression"
    }
  }
}
set b [embedding::init_raw $model]
if {$a eq $b} {
  error "handles are not independent"
}
embedding::free $a
require_error [list embedding::free $a]
require_error [list embedding::compute $a $ids]
if {[embedding::compute $b $ids] ne $vector} {
  error "second handle changed"
}
rename $b ::renamed_embedding_for_test
require_error [list embedding::free $b]
if {[embedding::compute ::renamed_embedding_for_test $ids] ne $vector} {
  error "renamed handle changed"
}
embedding::free ::renamed_embedding_for_test
require_error {embedding::free ::renamed_embedding_for_test}
set c [embedding::init_raw $model]
if {$c eq $a || $c eq $b} {
  error "stale handle was reused"
}
require_error [list embedding::compute $a $ids]
rename $c {}
require_error [list embedding::free $c]
for {set i 0} {$i < 3} {incr i} {
  set h [embedding::init_raw $model]
  embedding::free $h
}
set parent [embedding::init_raw $model]
interp create child
interp eval child [list set auto_path $auto_path]
interp eval child { package require tclembedding 1.0 }
set child_handle [interp eval child [list embedding::init_raw $model]]
require_error [list embedding::free $child_handle]
if {![interp eval child [list catch [list embedding::free $parent]]]} {
  error "child accepted parent handle"
}
interp delete child
if {[embedding::compute $parent $ids] ne $vector} {
  error "child teardown affected parent"
}
embedding::free $parent
puts "ONNX lifecycle: passed"
