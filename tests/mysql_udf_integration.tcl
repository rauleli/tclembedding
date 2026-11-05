# SQL checks against an explicitly supplied, TCP-disabled isolated MySQL server.
package require Tcl 8.6
package require mysqltcl
if {[llength $argv] != 2} {error "usage: mysql_udf_integration.tcl isolated-socket isolated-root"}
lassign $argv socket root
set socket [file normalize $socket]; set root [file normalize $root]
if {![file isdirectory $root] || [file dirname $socket] ne $root} {error "socket must be inside the isolated root"}
set db [mysql::connect -user root -host localhost -socket $socket]
proc scalar {db sql} {set rows [mysql::sel $db $sql -list]; return [lindex [lindex $rows 0] 0]}
proc require {condition message} {if {![uplevel 1 [list expr $condition]]} {error $message}}
proc ashex {vector} {return [binary encode hex [binary format r* $vector]]}
proc reference {a b} {
    binary scan [binary format r* $a] r* a32
    binary scan [binary format r* $b] r* b32
    set dot 0.0; set aa 0.0; set bb 0.0
    foreach x $a32 y $b32 {set dot [expr {$dot+$x*$y}];set aa [expr {$aa+$x*$x}];set bb [expr {$bb+$y*$y}]}
    return [expr {($dot/sqrt($aa))/sqrt($bb)}]
}
proc valid_case {db name a b} {
    set ah [ashex $a]; set bh [ashex $b]
    set actual [scalar $db "SELECT cosine_similarity_v2(X'$ah',X'$bh')"]
    set expected [reference $a $b]
    require {[string is double -strict $actual] && abs($actual-$expected) < 1e-12} "numeric mismatch in $name"
    puts "$name=ok"
    return $actual
}
proc null_case {db name a b} {
    set result [scalar $db "SELECT cosine_similarity_v2($a,$b) IS NULL"]
    require {$result == 1} "expected SQL NULL in $name"
    set warnings [scalar $db {SHOW COUNT(*) WARNINGS}]
    puts "$name=sql_null warnings=$warnings"
}
try {
    require {[scalar $db {SELECT @@skip_networking}] == 1} "TCP must be disabled"
    set actual_socket [file normalize [scalar $db {SELECT @@socket}]]
    set plugin [file normalize [scalar $db {SELECT @@plugin_dir}]]
    set data [file normalize [scalar $db {SELECT @@datadir}]]
    require {$actual_socket eq $socket && $plugin eq [file join $root plugins] && [file dirname $data] eq $root} "server is not the supplied isolated instance"
    require {[scalar $db {SELECT COUNT(*) FROM mysql.func WHERE name='cosine_similarity_v2' AND dl='mysql_cosine_v2.so'}] == 1} "test UDF not registered"
    puts "isolated_server=[scalar $db {SELECT VERSION()}] tcp_disabled=yes"
    valid_case $db identical {1 0} {1 0}
    valid_case $db orthogonal {1 0} {0 1}
    valid_case $db opposite {1 0} {-1 0}
    set signed [valid_case $db signed {-2 3} {4 -5}]
    require {abs($signed - (-0.9962405881956831)) < 1e-12} "fractional precision lost"
    puts "signed_direct=$signed"
    set positive [valid_case $db positive_fraction {2 3} {4 5}]
    puts "positive_direct=$positive"
    set near [valid_case $db near_zero {1 0} {1e-8 1}]
    require {$near != 0.0} "near-zero precision lost"
    puts "near_zero_direct=$near"
    foreach n {384 768} {
        set a {}; set b {}
        for {set i 0} {$i < $n} {incr i} {lappend a [expr {(($i%13)-6)/7.0}]; lappend b [expr {(($i%17)-8)/9.0}]}
        valid_case $db "dimension_$n" $a $b
    }
    valid_case $db largest_float {3.4028234663852886e38 3.4028234663852886e38} {3.4028234663852886e38 -3.4028234663852886e38}
    valid_case $db smallest_subnormal {1.401298464324817e-45} {1.401298464324817e-45}
    set swapped [scalar $db {SELECT cosine_similarity_v2(X'3F80000040000000',X'0000803F00000040')}]
    require {[string is double -strict $swapped] && abs($swapped-1.0) > 0.1} "byte-order example unexpectedly identical"
    puts "wrong_endian_interpreted_as_different_finite_values=ok"
    foreach {name a b} {
        null_left NULL X'0000803F'
        null_right X'0000803F' NULL
        unequal_dimensions X'0000803F' X'0000803F00000000'
        malformed_length X'0000' X'0000'
        empty X'' X''
        zero X'00000000' X'0000803F'
        nan X'0000C07F' X'0000803F'
        positive_infinity X'0000807F' X'0000803F'
        negative_infinity X'000080FF' X'0000803F'
    } {null_case $db $name $a $b}
    set rows [mysql::sel $db {SELECT id, cosine_similarity_v2(v,X'0000803F') FROM (SELECT 1 AS id,X'0000803F' AS v UNION ALL SELECT 2,X'00000000' UNION ALL SELECT 3,X'0000803F') AS sample ORDER BY id} -list]
    require {[llength $rows] == 3 && [lindex $rows 0 1] == 1 && [lindex $rows 1 1] eq "" && [lindex $rows 2 1] == 1} "invalid row affected other rows"
    set top [mysql::sel $db {SELECT id, score FROM (SELECT id, cosine_similarity_v2(v,X'0000803F') AS score FROM (SELECT 1 AS id,X'0000803F' AS v UNION ALL SELECT 2,X'00000000' UNION ALL SELECT 3,X'0000803F') AS samples) AS scored WHERE score IS NOT NULL ORDER BY score DESC,id LIMIT 2} -list]
    require {[llength $top] == 2 && [lindex $top 0 0] == 1 && [lindex $top 1 0] == 3} "top-k included null or lost a valid row"
    require {[scalar $db {SELECT cosine_similarity_v2(X'0000803F',X'0000803F')}] == 1} "subsequent statement did not recover"
    puts "same_statement_valid_invalid_valid=1,NULL,1 top_k=1,3 subsequent_statement=recovers"
    set rc [catch {mysql::sel $db {SELECT cosine_similarity_v2(42,X'0000803F')} -list} msg]
    require {$rc == 1} "non-string argument unexpectedly accepted"
    require {[scalar $db {SELECT cosine_similarity_v2(X'0000803F',X'0000803F')}] == 1} "server did not recover after initialization error"
    puts "non_string_argument=controlled_error subsequent_statement=recovers"
    puts "SQL integration tests passed"
} finally {mysql::close $db}
