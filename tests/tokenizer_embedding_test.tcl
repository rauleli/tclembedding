# Integration test for the tokenizer and ONNX embedding path.
package require Tcl 8.6
package require tokenizer 1.0.0
package require tclembedding
if {[llength $argv] != 2} {
  error "usage: tokenizer_embedding_test.tcl tokenizer.json model.onnx"
}
set tokenizer_path [lindex $argv 0]
set model_path [lindex $argv 1]
set tok_sha 2c3387be76557bd40970cec13153b3bbf80407865484b209e655e5e4729076b8
set model_sha 10f7a088420252b26caf819236ca2c9d2987afd0fc06fec7553b542a5655a05a
if {[lindex [exec sha256sum -- $tokenizer_path] 0] ne $tok_sha} {
  error "unexpected tokenizer fixture hash"
}
if {[lindex [exec sha256sum -- $model_path] 0] ne $model_sha} {
  error "unexpected ONNX fixture hash"
}
tokenizer::load_vocab $tokenizer_path
set h [embedding::init_raw $model_path]
set cases {
    {hola {0 739 143 2} {0.023325116646 0.040003508708 0.055999693634}}
    {{un gato duerme} {0 51 125583 115 56 282 2} {0.076809923717 0.000929218811 -0.011494213856}}
    {{las estrellas brillan} {0 576 114566 7 39192 1414 2} {0.048691624506 0.077722572660 0.028239445020}}
}
set vectors {}
foreach case $cases {
  lassign $case text expected_ids expected_first
  set ids [tokenizer::tokenize $text]
  if {$ids ne $expected_ids} {
    error "unexpected token IDs for $text"
  }
  set vector [embedding::compute $h $ids]
  if {[llength $vector] != 384} {
    error "unexpected vector dimension"
  }
  set sum 0.0
  foreach x $vector {
    set sum [expr {$sum + $x * $x}]
  }
  if {abs(sqrt($sum) - 1.0) > 1e-6} {
    error "unexpected vector norm"
  }
  foreach x [lrange $vector 0 2] expected $expected_first {
    if {abs($x - $expected) > 1e-5} {
      error "unexpected embedding component"
    }
  }
  foreach prior $vectors {
    if {$prior eq $vector} {
      error "different texts produced identical vectors"
    }
  }
  lappend vectors $vector
}
tokenizer::free
puts "tokenizer to ONNX: 3 cases passed"
