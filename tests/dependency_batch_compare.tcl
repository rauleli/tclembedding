package require tokenizer 1.0.0
package require tclembedding 1.0
lassign $argv tok model pad pooling prefix
tokenizer::load_vocab $tok
set h [embedding::init_raw $model]
set seqs {}; foreach text [list "short" "A longer synthetic text for comparing batch processing."] {lappend seqs [tokenizer::tokenize "$prefix$text"]}
set batch [embedding::compute_batch $h $seqs -pad-id $pad -pooling $pooling]
set worst 0.0; set n 0
foreach ids $seqs vec $batch {set single [embedding::compute $h $ids -pooling $pooling]; if {[llength $single] != [llength $vec]} {error "dimension mismatch"}; foreach a $single b $vec {set d [expr {abs($a-$b)}];if {$d>$worst} {set worst $d}};incr n}
puts "rows=$n dimensions=[llength [lindex $batch 0]] max_abs=$worst"
embedding::free $h
tokenizer::free
