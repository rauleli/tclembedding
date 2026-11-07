# Synthetic 200-record integration; creates a private copy of the supplied database.
if {[llength $argv] != 4} {error "usage: native_test.tcl extension synthetic-database model tokenizer"}
lassign $argv extension source_db model tokenizer
source [file join [file dirname [file normalize [info script]]] .. 03-chatgpt-export sqlite_retrieval.tcl]
proc require {expression message} {if {![uplevel 1 [list expr $expression]]} {error $message}}
set dir [file join /tmp "rag-native-[pid]-[clock clicks]"]
if {[file exists $dir]} {error "temporary test directory already exists"}
file mkdir $dir
file attributes $dir -permissions 0700
set dbpath [file join $dir corpus.sqlite3]
file copy $source_db $dbpath
::store::open_db $dbpath 0
try {
    ::store::check_schema
    set corpus [::store::db onecolumn {SELECT id FROM corpora}]
    require {[::store::db onecolumn {SELECT COUNT(*) FROM fragments}] == 200} "expected 200 records"
    set packed [::store::db onecolumn {SELECT vector FROM fragments WHERE corpus=$corpus AND sequence=0}]
    binary scan $packed r* vector
    set scalar [::store::retrieve $corpus $vector 10]
    try {
        ::store::db enable_load_extension 1
        ::store::db eval {SELECT load_extension($extension,'sqlite3_similarity_init')}
    } finally {::store::db enable_load_extension 0}
    require {[catch {::store::db eval {SELECT load_extension($extension,'sqlite3_similarity_init')}}]} "extension loading still enabled"
    set native [::store::retrieve_native $corpus $vector $packed 10]
    require {[llength $native] == [llength $scalar]} "top-k size mismatch"
    set maxdiff 0.0
    foreach a $native b $scalar {
        require {[lrange $a 1 end] eq [lrange $b 1 end]} "top-k provenance mismatch"
        set d [expr {abs([lindex $a 0]-[lindex $b 0])}]
        if {$d > $maxdiff} {set maxdiff $d}
        require {$d <= 1e-12} "score mismatch"
    }
    set tie {}; ::store::db eval {SELECT id FROM (SELECT 2 AS id,$packed AS v UNION ALL SELECT 1,$packed) ORDER BY cosine_similarity_v2(v,$packed) DESC,id ASC} r {lappend tie $r(id)}
    require {$tie eq {1 2}} "tie ordering"
    ::store::db eval {UPDATE fragments SET vector=zeroblob(1536) WHERE corpus=$corpus AND sequence=0}
    require {[catch {::store::retrieve_native $corpus $vector $packed 10}]} "invalid vector accepted"
    ::store::db eval {UPDATE fragments SET vector=$packed WHERE corpus=$corpus AND sequence=0}
    ::store::db eval {PRAGMA ignore_check_constraints=ON}
    set truncated [binary format H* 0000]
    ::store::db eval {UPDATE fragments SET vector=$truncated WHERE corpus=$corpus AND sequence=0}
    require {[catch {::store::retrieve_native $corpus $vector $packed 10}]} "truncated vector accepted"
    ::store::db eval {UPDATE fragments SET vector=$packed WHERE corpus=$corpus AND sequence=0}
    ::store::db eval {PRAGMA ignore_check_constraints=OFF}
    ::store::db eval {UPDATE fragments SET text='synthetic alteration' WHERE corpus=$corpus AND sequence=0}
    require {[catch {::store::retrieve_native $corpus $vector $packed 10}]} "altered selected text accepted"
    ::store::db eval {DELETE FROM fragments WHERE corpus=$corpus AND sequence=0}
    require {[catch {::store::retrieve_native $corpus $vector $packed 10}]} "missing row accepted"
    puts "records=200 top_k=10 max_abs=$maxdiff provenance=equal tie=ok invalid=ok"
} finally {::store::db close}
# Full query path against the untouched source fixture, including E5 tokenization.
set scalar [::store::query_results $source_db $corpus $model $tokenizer maintenance 5]
set native [::store::query_results $source_db $corpus $model $tokenizer maintenance 5 $extension]
foreach a $scalar b $native {
    require {[lrange $a 1 end] eq [lrange $b 1 end] && abs([lindex $a 0]-[lindex $b 0]) <= 1e-12} "E5 query mismatch"
}
require {[llength $scalar] == 5 && [llength $native] == 5} "E5 query count"
require {[catch {::store::query_results $source_db $corpus $model $tokenizer maintenance 5 /nonexistent/synthetic-extension.so}]} "missing extension accepted"
require {[catch {::store::query_results $source_db $corpus $model $tokenizer maintenance 5 $dbpath}]} "invalid extension accepted"
puts "E5 query and extension failure checks passed"
