package require rl_json 0.15.7
package require tclembedding 1.0
namespace import ::rl_json::json
lassign $argv model reference pooling
set f [open $reference r]
set data [read $f]
close $f
set h [embedding::init_raw $model]
set num [json length $data cases]
set worst 0.0
set mincos 1.0
set count 0
for {set i 0} {$i < $num} {incr i} {
  set ids [json get $data cases $i ids]
  set expected [json get $data cases $i binding_vector]
  set actual [embedding::compute $h $ids -pooling $pooling]
  if {[llength $actual] != [llength $expected]} {
    error "dimension mismatch"
  }
  set dot 0.0
  set aa 0.0
  set bb 0.0
  foreach a $actual b $expected {
    set d [expr {abs($a-$b)}]
    if {$d>$worst} {
      set worst $d
    }
    set dot [expr {$dot+$a*$b}]
    set aa [expr {$aa+$a*$a}]
    set bb [expr {$bb+$b*$b}]
  }
  set cos [expr {$dot/sqrt($aa*$bb)}]
  if {$cos<$mincos} {
    set mincos $cos
  }
  incr count
}
embedding::free $h
puts "cases=$count max_abs=$worst min_cos=$mincos"
