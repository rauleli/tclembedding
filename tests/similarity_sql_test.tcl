# Compare scalar MySQL implementations, SQLite and Tcl on synthetic values.
package require Tcl 8.6
package require sqlite3
package require mysqltcl
if {[llength $argv] != 3} {error "usage: sqlite-extension isolated-socket isolated-root"}
lassign $argv extension socket root
set root [file normalize $root]; set socket [file normalize $socket]
if {[file dirname $socket] ne $root || [string first "/tmp/" "$root/"] != 0} {error "isolated test root required"}
source [file join [file dirname [file normalize [info script]]] .. examples 01-in-memory-rag rag.tcl]
proc assert {condition message} {if {![uplevel 1 [list expr $condition]]} {error $message}}
proc scalar {db sql} {return [lindex [mysql::sel $db $sql -list] 0 0]}
set m [mysql::connect -user root -host localhost -socket $socket]
sqlite3 s :memory:
try {
    assert {[scalar $m {SELECT @@skip_networking}] == 1 && [file normalize [scalar $m {SELECT @@socket}]] eq $socket && [file normalize [scalar $m {SELECT @@plugin_dir}]] eq [file join $root plugins] && [file normalize [scalar $m {SELECT @@datadir}]] eq [file join $root data]} "server is not isolated"
    s enable_load_extension 1
    s eval {SELECT load_extension($extension, 'sqlite3_similarity_init')}
    s enable_load_extension 0
    set cases [list [list identical {1 0} {1 0}] [list orthogonal {1 0} {0 1}] [list opposite {1 0} {-1 0}] [list signed {-2 3} {4 -5}] [list magnitude {1 2} {9 18}] [list nearzero {1 0} {1e-8 1}] [list tiny {1.401298464324817e-45} {1.401298464324817e-45}] [list large {3.4028234663852886e38 3.4028234663852886e38} {3.4028234663852886e38 -3.4028234663852886e38}]]
    foreach n {384 768} {
        set a {}; set b {}
        for {set i 0} {$i < $n} {incr i} {lappend a [expr {(($i%13)-6)/7.0}]; lappend b [expr {(($i%17)-8)/9.0}]}
        lappend cases [list dimension_$n $a $b]
    }
    set maxabs 0.0; set maxrel 0.0
    foreach case $cases {
        lassign $case name va vb
        set a [binary format r* $va]; set b [binary format r* $vb]
        binary scan $a r* fa; binary scan $b r* fb
        set expected [::rag::cosine $fa $fb]
        set ha [binary encode hex $a]; set hb [binary encode hex $b]
        set old [scalar $m "SELECT cosine_similarity_old(X'$ha',X'$hb')"]
        set new [scalar $m "SELECT cosine_similarity_v2(X'$ha',X'$hb')"]
        set sqlite [s onecolumn {SELECT cosine_similarity_v2($a,$b)}]
        foreach value [list $old $new $sqlite] {
            set delta [expr {abs($value-$expected)}]
            set maxabs [expr {max($maxabs,$delta)}]
            if {abs($expected) > 1e-12} {set maxrel [expr {max($maxrel,$delta/abs($expected))}]}
            assert {$delta < 1e-12} "numeric mismatch in $name"
        }
        assert {$old == $new} "old/new MySQL mismatch in $name"
    }
    foreach {name ah bh} {unequal 0000803f 0000803f00000000 truncated 0000 0000 empty {} {} zero 00000000 0000803f nan 0000c07f 0000803f inf 0000807f 0000803f negative_inf 000080ff 0000803f} {
        set a [binary decode hex $ah]; set b [binary decode hex $bh]
        assert {[s onecolumn {SELECT cosine_similarity_v2($a,$b) IS NULL}] == 1} "SQLite invalid input: $name"
        foreach fn {cosine_similarity_old cosine_similarity_v2} {assert {[scalar $m "SELECT ${fn}(X'$ah',X'$bh') IS NULL"] == 1} "MySQL invalid input: $name"}
    }
    assert {[s onecolumn {SELECT cosine_similarity_v2(NULL,X'0000803F') IS NULL}] == 1 && [s onecolumn {SELECT cosine_similarity_v2(42,X'0000803F') IS NULL}] == 1} "SQLite non-BLOB behavior"
    assert {[scalar $m {SELECT cosine_similarity_v2(NULL,X'0000803F') IS NULL}] == 1} "MySQL NULL behavior"
    assert {[scalar $m {SELECT cosine_similarity_old(NULL,X'0000803F') IS NULL}] == 1} "old MySQL NULL behavior"
    assert {[catch {s onecolumn {SELECT cosine_similarity_v2(X'0000803F')}}]} "SQLite arity not rejected"
    set query [binary format r* {1 0}]; set ranking {}
    foreach {id vector} {1 {1 0} 2 {0 1} 3 {-1 0} 4 {1 0}} {
        set blob [binary format r* $vector]; set hex [binary encode hex $blob]; set qhex [binary encode hex $query]
        set sa [s onecolumn {SELECT cosine_similarity_v2($blob,$query)}]
        set sm [scalar $m "SELECT cosine_similarity_v2(X'$hex',X'$qhex')"]
        assert {abs($sa-$sm) < 1e-12} "ranking score mismatch"
        lappend ranking [list $sa $id]
    }
    set ordered [lsort -real -decreasing -index 0 $ranking]
    assert {[lmap row $ordered {lindex $row 1}] eq {1 4 2 3}} "unexpected ranking"
    set sqlite_order {}
    s eval {SELECT id FROM (SELECT 1 AS id,X'0000803F00000000' AS v UNION ALL SELECT 2,X'000000000000803F' UNION ALL SELECT 3,X'000080BF00000000' UNION ALL SELECT 4,X'0000803F00000000') ORDER BY cosine_similarity_v2(v,X'0000803F00000000') DESC,id ASC LIMIT 4} result_row {lappend sqlite_order $result_row(id)}
    assert {$sqlite_order eq {1 4 2 3}} "SQLite SQL ranking mismatch"
    foreach fn {cosine_similarity_old cosine_similarity_v2} {
        set sql "SELECT id FROM (SELECT 1 AS id,X'0000803F00000000' AS v UNION ALL SELECT 2,X'000000000000803F' UNION ALL SELECT 3,X'000080BF00000000' UNION ALL SELECT 4,X'0000803F00000000') AS sample ORDER BY ${fn}(v,X'0000803F00000000') DESC,id ASC LIMIT 4"
        set rows [mysql::sel $m $sql -list]; set ids {}; foreach row $rows {lappend ids [lindex $row 0]}
        assert {$ids eq {1 4 2 3}} "MySQL SQL ranking mismatch"
    }
    sqlite3 fresh :memory:
    try {assert {[catch {fresh onecolumn {SELECT cosine_similarity_v2(X'0000803F',X'0000803F')}}]} "function leaked to a new connection"} finally {fresh close}
    puts [format "valid_cases=%d max_abs=%.17g max_relative_nonzero=%.17g top_k=1,4,2,3 invalid_and_null=passed" [llength $cases] $maxabs $maxrel]
} finally {s close; mysql::close $m}
