# Synthetic laboratory input: one Tcl list of integer token IDs per line.
package require Tcl 8.6
package require tclembedding 1.0
if {[llength $argv] != 1} {
  error "usage: compare_primary.tcl model.onnx"
}
set handle [embedding::init_raw [lindex $argv 0]]
while {[gets stdin ids] >= 0} {
  puts [join [embedding::compute $handle $ids] ,]
  flush stdout
}
embedding::free $handle
