package require Tcl 8.6
package require tclembedding 1.0
lassign $argv model pad pooling mode
set h [embedding::init_raw $model]
gets stdin line
set seqs [split $line {;}]
proc execute {h pad pooling mode seqs} {
    if {$mode eq "batch"} {embedding::compute_batch $h $seqs -pad-id $pad -pooling $pooling} else {
        foreach ids $seqs {embedding::compute $h $ids -pooling $pooling}
    }
}
execute $h $pad $pooling $mode $seqs
set times {}
for {set i 0} {$i<3} {incr i} {
    set t [clock microseconds]
    execute $h $pad $pooling $mode $seqs
    lappend times [expr {([clock microseconds]-$t)/1000.0}]
}
puts [join [lsort -real $times] ,]
embedding::free $h
