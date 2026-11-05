# Synthetic SQLite tests; no ONNX model is required.
source [file join [file dirname [file normalize [info script]]] persistent.tcl]
proc assert {condition message} {if {![uplevel 1 [list expr $condition]]} {error $message}}
proc must_fail {script} {if {![catch {uplevel 1 $script}]} {error "expected a controlled error"}}
set tmp [file join /tmp "persistent-retrieval-test-[pid]-[clock clicks]"]
file mkdir $tmp
set path [file join $tmp test.sqlite3]
set vector [lrepeat 384 0.0]
lset vector 0 1.0
lset vector 1 -0.25
set blob [::persistent::encode $vector 384]
assert {[string length $blob] == 1536} "blob length"
binary scan [string range $blob 0 3] H* bytes
assert {$bytes eq "0000803f"} "float32 little-endian encoding"
set roundtrip [::persistent::decode $blob 384]
assert {[llength $roundtrip] == 384 && abs([lindex $roundtrip 1] + 0.25) < 1e-7} "float round trip"
set small [::persistent::decode [::persistent::encode {0.1 -0.2} 2] 2]
assert {abs([lindex $small 0] - 0.1) < 1e-7 && abs([lindex $small 1] + 0.2) < 1e-7} "float32 rounding"
must_fail {::persistent::encode {1 2} 3}
must_fail {::persistent::encode {NaN} 1}
must_fail {::persistent::encode {1e100} 1}
must_fail {::persistent::decode abc 1}
must_fail {::persistent::decode [binary decode hex 0000c07f] 1}
must_fail {::persistent::decode [binary decode hex 0000807f] 1}
::persistent::initialize $path synthetic-model synthetic-tokenizer
must_fail {::persistent::initialize $path synthetic-model synthetic-tokenizer}
::persistent::open_existing $path
::persistent::check_metadata synthetic-model synthetic-tokenizer
must_fail {::persistent::check_metadata other synthetic-tokenizer}
must_fail {::persistent::check_metadata synthetic-model other}
set docs [list [list B {B's title} {Quoted ' text}] [list A Alpha {Another source}]]
::persistent::store $docs [list $vector $vector]
assert {[::persistent::db onecolumn {SELECT COUNT(*) FROM documents}] == 2} "insert count"
::persistent::db close
::persistent::open_existing $path
::persistent::check_metadata synthetic-model synthetic-tokenizer
set result [::persistent::retrieve $vector 2]
assert {[lindex $result 0 1 0] eq "A" && [lindex $result 1 1 0] eq "B"} "ranking tie"
assert {[lindex $result 1 1 1] eq "B's title" && [lindex $result 1 1 2] eq "Quoted ' text"} "quoted values"
assert {[llength [::persistent::retrieve $vector 1]] == 1} "top-k"
::persistent::store [list [list B {New title} {Updated content}]] [list $vector]
assert {[::persistent::db onecolumn {SELECT COUNT(*) FROM documents}] == 2} "upsert duplicated document"
assert {[::persistent::db onecolumn {SELECT title FROM documents WHERE id='B'}] eq "New title"} "upsert failed"
set invalid [lrepeat 384 0.0]; lset invalid 0 NaN
must_fail {::persistent::store [list [list B {Must roll back} content] [list C title content]] [list $vector $invalid]}
assert {[::persistent::db onecolumn {SELECT title FROM documents WHERE id='B'}] eq "New title"} "transaction did not roll back update"
assert {[::persistent::db onecolumn {SELECT COUNT(*) FROM documents WHERE id='C'}] == 0} "transaction did not roll back insert"
::persistent::db eval {UPDATE metadata SET vector_format='invalid'}
must_fail {::persistent::check_metadata synthetic-model synthetic-tokenizer}
::persistent::db eval {UPDATE metadata SET vector_format='float32-le'; PRAGMA ignore_check_constraints=ON; UPDATE documents SET dimensions=385 WHERE id='A'}
must_fail {::persistent::retrieve $vector 2}
::persistent::db eval {UPDATE documents SET dimensions=384 WHERE id='A'; PRAGMA ignore_check_constraints=OFF}
# Query-mode test uses a synthetic query vector and must never batch documents.
namespace eval ::tokenizer {}
namespace eval ::embedding {}
package provide tokenizer 1.0.0
package provide tclembedding 1.0
set ::batch_calls 0
set ::tokenizer_freed 0
set ::embedding_freed 0
proc ::tokenizer::load_vocab {path} {}
proc ::tokenizer::tokenize {text} {return {1 2}}
proc ::tokenizer::free {} {incr ::tokenizer_freed}
proc ::embedding::init_raw {path} {return synthetic-handle}
proc ::embedding::compute_batch {args} {incr ::batch_calls; error "unexpected document embedding"}
proc ::embedding::compute {args} {return $::vector}
proc ::embedding::free {handle} {incr ::embedding_freed}
proc synthetic_query {} {
    set query "synthetic query"
    set topk 1
    ::persistent::load_embeddings synthetic synthetic query
}
synthetic_query
assert {$::batch_calls == 0} "query recalculated document embeddings"
assert {$::tokenizer_freed == 1 && $::embedding_freed == 1} "query resources not released"
::persistent::db eval {PRAGMA user_version=2}
must_fail {::persistent::check_metadata synthetic-model synthetic-tokenizer}
::persistent::db eval {PRAGMA user_version=1}
::persistent::db close
must_fail {::persistent::open_existing [file join $tmp absent.sqlite3]}
assert {![llength [info commands ::persistent::db]]} "connection not closed"
# A failed query closes its connection and both inference resources.
rename ::persistent::verify_artifacts ::persistent::real_verify_artifacts
proc ::persistent::verify_artifacts {model tokenizer} {return {synthetic-model synthetic-tokenizer}}
rename ::embedding::compute ::embedding::working_compute
proc ::embedding::compute {args} {error "synthetic query failure"}
try {
    must_fail [list ::persistent::main query -db $path -model synthetic -tokenizer synthetic -query synthetic]
    assert {![llength [info commands ::persistent::db]]} "connection left open after error"
    assert {$::tokenizer_freed == 2 && $::embedding_freed == 2} "query failure did not release resources"
    must_fail [list ::persistent::main init -db [file join $::persistent_script_dir forbidden.sqlite3] -model synthetic -tokenizer synthetic]
} finally {
    rename ::persistent::verify_artifacts {}
    rename ::persistent::real_verify_artifacts ::persistent::verify_artifacts
    rename ::embedding::compute {}
    rename ::embedding::working_compute ::embedding::compute
}
puts "Persistent semantic retrieval tests passed"
