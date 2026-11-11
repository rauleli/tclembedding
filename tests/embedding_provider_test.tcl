# Exercise provider options and profiling with a synthetic token sequence.
package require Tcl 8.6
package require tclembedding 1.0
if {[llength $argv] != 2} {
  error "usage: embedding_provider_test.tcl model.onnx private-test-directory"
}
lassign $argv model directory
if {![file isdirectory $directory]} {
  error "test directory must already exist"
}

# Require an error without hiding the diagnostic.
proc expect_error {command} {
  if {![catch {uplevel 1 $command} message] || $message eq ""} {
    error "expected diagnostic for $command"
  }
  return $message
}

set ids {0 739 143 2}
set base [embedding::init_raw $model]
set cpu [embedding::init_raw $model -provider cpu]
set expected [embedding::compute $base $ids]
if {$expected ne [embedding::compute $cpu $ids]} {
  error "explicit CPU differs from default"
}
set batch [embedding::compute_batch $cpu [list $ids $ids] -pad-id 1]
if {[llength $batch] != 2 || [lindex $batch 0] ne $expected} {
  error "CPU batch differs from individual inference"
}
foreach options {
  {-provider invalid} {-provider cpu -device 0} {-device 0}
  {-provider cuda -device -1} {-provider cuda -device 0x1}
  {-provider cuda -device 2147483648} {-provider cpu -provider cuda}
  {-profile {}} {-profile /} {-unknown x} {-profile x -profile y}
  {-profile /nonexistent-tclembedding-profile-directory/profile}
  {-provider} {-device} {-profile}
} {
  expect_error [list embedding::init_raw $model {*}$options]
}
expect_error [list embedding::init_raw $model -profile "bad\u0000prefix"]
expect_error [list embedding::init_raw $model "-provider\u0000extra" cpu]
set message [expect_error [list embedding::init_raw $model -provider cuda -device 0]]
if {![string match *CUDAExecutionProvider* $message]} {
  error "CUDA unavailability was not identified: $message"
}
set recovered [embedding::init_raw $model -provider cpu]
embedding::free $recovered
set prefix [file join $directory profile]
set profiled [embedding::init_raw $model -provider cpu -profile $prefix]
if {[embedding::compute $profiled $ids] ne $expected} {
  error "profiling changed the vector"
}
embedding::free $profiled
set profiles [glob -nocomplain "${prefix}*.json"]
if {[llength $profiles] != 1 || [file size [lindex $profiles 0]] == 0} {
  error "profile was not written"
}
set renamed [embedding::init_raw $model -profile [file join $directory renamed]]
rename $renamed {}
if {[llength [glob -nocomplain [file join $directory renamed*.json]]] != 1} {
  error "renamed handle did not finish profiling"
}
set library {}
foreach entry [info loaded] {
  if {[lindex $entry 1] eq "Tclembedding"} {
    set library [lindex $entry 0]
  }
}
if {$library eq ""} {
  error "could not identify loaded extension"
}
interp create provider_test_child
interp eval provider_test_child [list load $library Tclembedding]
interp eval provider_test_child [list embedding::init_raw $model -profile [file join $directory child]]
interp delete provider_test_child
if {[llength [glob -nocomplain [file join $directory child*.json]]] != 1} {
  error "interpreter destruction did not finish profiling"
}
embedding::free $cpu
embedding::free $base
expect_error [list embedding::free $base]
puts "CPU provider, options, unavailable CUDA, recovery and profiling passed"
