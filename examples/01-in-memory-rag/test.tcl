# Synthetic unit tests; no model or database is needed.
source [file join [file dirname [file normalize [info script]]] rag.tcl]

# Fail the test if a required condition is false.
proc assert {condition message} {
  if {![uplevel 1 [list expr $condition]]} {
    error $message
  }
}

# Verify that a command fails as expected.
proc must_fail {script} {
  if {![catch {uplevel 1 $script}]} {
    error "expected a controlled error"
  }
}

assert {abs([::rag::cosine {1 0} {1 0}] - 1.0) < 1e-12} "identical vectors"
assert {abs([::rag::cosine {1 0} {0 1}]) < 1e-12} "orthogonal vectors"
assert {abs([::rag::cosine {2 0} {3 0}] - 1.0) < 1e-12} "non-unit vectors"
foreach pair {{{} {}} {{1} {1 2}} {{0 0} {1 0}} {{NaN 1} {1 0}} {{Inf 1} {1 0}} {{abc 1} {1 0}} {{1e999 1} {1 0}}} {
  lassign $pair a b
  must_fail [list ::rag::cosine $a $b]
}
set docs {{B {Beta} {Second source.}} {A {Alpha} {First source.}} {C {Gamma} {Third source.}}}
set vectors {{1 0} {1 0} {0 1}}
set result [::rag::rank $docs $vectors {1 0} 2]
assert {[llength $result] == 2} "top-k"
assert {[lindex $result 0 1 0] eq "A" && [lindex $result 1 1 0] eq "B"} "tie order"
assert {[llength [::rag::rank $docs $vectors {1 0} 9]] == 3} "large top-k"
must_fail {::rag::rank $docs $vectors {1 0} 0}
must_fail {::rag::rank $docs $vectors {1 0} 257}
must_fail {::rag::rank $docs $vectors {1 0} nope}
must_fail {::rag::rank $docs {{1 0}} {1 0} 2}
must_fail {::rag::validate_documents {{A x y} {A z w}}}
must_fail {::rag::validate_documents {{A x {}}}}
assert {[lindex $result 0 1 2] eq "First source."} "retrieved source text"
# Simulate an inference error to verify both resources are released.
namespace eval ::tokenizer {}
# Test embedding command namespace.
namespace eval ::embedding {}
package provide tokenizer 1.0.0
package provide tclembedding 1.0
set ::tokenizer_freed 0
set ::embedding_freed 0
set ::fixture_length 2
set ::batch_calls 0

# Provide a controlled tokenizer fixture for the test.
proc ::tokenizer::load_vocab {path} {}

# Tokenize or instrument text for the test fixture.
proc ::tokenizer::tokenize {text} {
  return [lrepeat $::fixture_length 1]
}

# Release the tokenizer fixture state.
proc ::tokenizer::free {} {
  incr ::tokenizer_freed
}

# Initialize the controlled embedding fixture.
proc ::embedding::init_raw {path} {
  return synthetic-handle
}

# Produce controlled batch embeddings for the test.
proc ::embedding::compute_batch {args} {
  incr ::batch_calls
  error "synthetic inference failure"
}

# Release the embedding fixture state.
proc ::embedding::free {handle} {
  incr ::embedding_freed
}

must_fail {::rag::run -model synthetic -tokenizer synthetic -query synthetic}
assert {$::tokenizer_freed == 1 && $::embedding_freed == 1} "resources not released after error"
set ::fixture_length 513
must_fail {::rag::run -model synthetic -tokenizer synthetic -query synthetic}
assert {$::batch_calls == 1} "oversized input reached batch inference"
assert {$::tokenizer_freed == 2 && $::embedding_freed == 2} "resources not released after limit error"
puts "In-memory semantic retrieval unit tests passed"
