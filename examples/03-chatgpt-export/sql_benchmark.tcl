# Synthetic L-4 laboratory. Uses existing ingestion code and L-3 extensions.
package require Tcl 8.6
if {[llength $argv] != 7} {error "usage: fragments vectors model tokenizer sqlite-extension mysql-socket new-output-directory"}
lassign $argv fragments vectors model tokenizer extension socket outdir
set root [file normalize [file join [file dirname [info script]] .. ..]]
source [file join $root examples 03-chatgpt-export sqlite_retrieval.tcl]
source [file join $root examples 03-chatgpt-export mysql_retrieval.tcl]
proc require {condition message} {if {![uplevel 1 [list expr $condition]]} {error $message}}
proc micros {} {return [clock clicks -microseconds]}
proc elapsed {start} {set x [expr {[micros]-$start}]; if {$x < 0} {error "clock moved backwards"}; return $x}
proc pct {values p} {set sorted [lsort -integer $values]; set i [expr {int(ceil($p*[llength $sorted]))-1}]; return [lindex $sorted $i]}
proc median {values} {set s [lsort -integer $values]; set n [llength $s]; if {$n%2} {return [lindex $s [expr {$n/2}]]}; return [expr {([lindex $s [expr {$n/2-1}]]+[lindex $s [expr {$n/2}]])/2.0}]}
proc memory {pid field} {
    set p "/proc/$pid/status"; if {![file readable $p]} {return unavailable}
    set f [open $p r]; try {set s [read $f]} finally {close $f}
    if {[regexp -line [format {^%s:\s+([0-9]+)\s+kB} $field] $s -> n]} {return $n}; return unavailable
}
proc size_or_zero {path} {if {[file exists $path]} {return [file size $path]}; return 0}
proc sqlite_rows {corpus vector topk} {
    set rows {}
    ::store::db eval {SELECT cosine_similarity_v2(f.vector,$vector) AS score,f.sequence,f.text,m.source_id,m.origin_sha256,m.source,m.conversation_id,m.node_id,m.message_id,m.role,m.position,m.created_json,m.part,f.fragment_index,f.char_start,f.char_end,f.vector,f.vector_sha256,f.text_sha256 FROM fragments f JOIN messages m ON f.corpus=m.corpus AND f.message_key=m.message_key WHERE f.corpus=$corpus ORDER BY score DESC,f.sequence ASC LIMIT $topk} r {
        lappend rows [list $r(score) $r(sequence) $r(text) $r(source_id) $r(origin_sha256) $r(source) $r(conversation_id) $r(node_id) $r(message_id) $r(role) $r(position) $r(created_json) $r(part) $r(fragment_index) $r(char_start) $r(char_end) $r(vector) $r(vector_sha256) $r(text_sha256)]
    }
    return $rows
}
proc mysql_rows {stmt corpus vector topk} {
    set rs [$stmt execute [list corpus $corpus vector $vector topk $topk]]
    try {set rows {}; while {[$rs nextlist row]} {lappend rows $row}; return $rows} finally {$rs close}
}
proc normalize_sqlite {rows} {
    set out {}
    foreach row $rows {
        lassign $row score seq text sid origin source conv node message role position created part fi start end blob bh th
        require {[::pipeline::digest $blob] eq $bh && [::pipeline::digest [encoding convertto utf-8 $text]] eq $th} "SQLite selected row integrity mismatch"
        lappend out [lrange $row 0 15]
    }
    return $out
}
proc normalize_mysql {rows} {
    set out {}
    foreach row $rows {
        lassign $row seq bytes score line_hash vector_hash blob
        require {$score ne "" && [::pipeline::digest $bytes] eq $line_hash && [::pipeline::digest $blob] eq $vector_hash} "MySQL selected row integrity mismatch"
        set line [encoding convertfrom utf-8 $bytes]
        lappend out [list $score $seq [json get $line text] [json get $line input_source_id] [json get $line input_sha256] [json get $line source] [json get $line conversation_id] [json get $line node_id] [json get $line message_id] [json get $line role] [json get $line position] [json extract $line create_time] [json get $line part] [json get $line fragment_index] [json get $line char_start] [json get $line char_end]]
    }
    return $out
}
proc compare_hits {a b} {
    require {[llength $a] == 5 && [llength $b] == 5} "top-k count mismatch"
    set maxabs 0.0; set maxrel 0.0
    foreach x $a y $b {
        require {[lrange $x 1 end] eq [lrange $y 1 end]} "top-k provenance mismatch"
        set d [expr {abs([lindex $x 0]-[lindex $y 0])}]
        require {$d <= 1e-12} "top-k score mismatch"
        set maxabs [expr {max($maxabs,$d)}]
        if {abs([lindex $x 0]) > 1e-12} {set maxrel [expr {max($maxrel,$d/abs([lindex $x 0]))}]}
    }
    return [list $maxabs $maxrel]
}
set outdir [file normalize $outdir]
if {[string first "/tmp/" "$outdir/"] != 0} {error "output must be a private path under /tmp"}
if {[file exists $outdir]} {error "output directory already exists"}
file mkdir $outdir
file attributes $outdir -permissions 0700
set f [open [file join $outdir samples.csv] {WRONLY CREAT EXCL} 0600]
puts $f "kind,engine,query,iteration,elapsed_us"
set socket [file normalize $socket]; set lab [file dirname $socket]
require {[string first "/tmp/" "$lab/"] == 0 && [regexp {^tclembedding-l4-[A-Za-z0-9-]+$} [file tail $lab]] && [file owned $lab] && [file isdirectory [file join $lab data]] && [file isdirectory [file join $lab plugins]] && [file type $socket] eq "socket"} "a user-owned isolated L-4 laboratory under /tmp is required"
::mysql_store::connect $socket mysql root
set networking [::mysql_store::run {SHOW VARIABLES LIKE 'skip_networking'} {}]
set actual_socket [::mysql_store::run {SHOW VARIABLES LIKE 'socket'} {}]
set datadir [::mysql_store::run {SHOW VARIABLES LIKE 'datadir'} {}]
set plugins [::mysql_store::run {SHOW VARIABLES LIKE 'plugin_dir'} {}]
require {[lindex $networking 0 1] eq "ON" && [file normalize [lindex $actual_socket 0 1]] eq $socket && [file normalize [lindex $datadir 0 1]] eq [file join $lab data] && [file normalize [lindex $plugins 0 1]] eq [file join $lab plugins]} "MySQL is not an isolated laboratory"
set schema "l4_benchmark_[pid]"
set exists [::mysql_store::run {SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name=:schema} [list schema $schema]]
require {[lindex $exists 0 0] == 0} "benchmark schema already exists"
::mysql_store::run "CREATE DATABASE `$schema`" {}
::mysql_store::db close
::mysql_store::connect $socket $schema root
::mysql_store::check_udf
set t [micros]; ::pipeline::verify_file $vectors $fragments; puts $f "input_verify,both,-,0,[elapsed $t]"
set corpus [::pipeline::file_hash $fragments]
set vectors_hash [::pipeline::file_hash $vectors]
set vf [open $vectors rb]; set first [read $vf 14]; scan [string range $first 5 12] %x hlen; set meta [encoding convertfrom utf-8 [read $vf $hlen]]; close $vf
set count [json get $meta records]
require {$count > 0} "fixture must contain at least one record"
set sqlite_db [file join $outdir benchmark.sqlite3]
set t [micros]; ::store::init $sqlite_db; puts $f "init,sqlite,-,0,[elapsed $t]"
set t [micros]; ::mysql_store::init; puts $f "init,mysql,-,0,[elapsed $t]"
set t [micros]; ::store::ingest $sqlite_db $fragments $vectors; puts $f "ingest,sqlite,-,0,[elapsed $t]"
set t [micros]; ::mysql_store::ingest $fragments $vectors; puts $f "ingest,mysql,-,0,[elapsed $t]"
set t [micros]; ::store::ingest $sqlite_db $fragments $vectors; puts $f "reimport,sqlite,-,0,[elapsed $t]"
set t [micros]; ::mysql_store::ingest $fragments $vectors; puts $f "reimport,mysql,-,0,[elapsed $t]"
require {[::pipeline::file_hash $model] eq $::pipeline::model_hash && [::pipeline::file_hash $tokenizer] eq $::pipeline::tokenizer_hash} "model or tokenizer mismatch"
package require tokenizer 1.0.0; package require tclembedding 1.0
set t [micros]; tokenizer::load_vocab $tokenizer; set handle [embedding::init_raw $model]; puts $f "model_load,both,-,0,[elapsed $t]"
set queries {}
try {
    set ort_hash [::pipeline::mapped_hash libonnxruntime.so.1.31.1]
    set tokenizer_backend_hash [::pipeline::mapped_hash libtclembedding_tokenizer.so]
    require {$ort_hash eq $::pipeline::runtime_hash && $tokenizer_backend_hash eq $::pipeline::backend_hash} "uncharacterized runtime or tokenizer backend"
    foreach text {{recuperar información} {maintenance procedure}} {
        set t [micros]; set ids [tokenizer::tokenize "query: $text"]; set token_us [elapsed $t]
        set t [micros]; set blob [::pipeline::vector_blob [embedding::compute $handle $ids -pooling mean]]; set infer_us [elapsed $t]
        lappend queries $blob
        set q [llength $queries]; puts $f "tokenize,both,$q,0,$token_us"; puts $f "inference,both,$q,0,$infer_us"
    }
} finally {embedding::free $handle; tokenizer::free}
::store::open_db $sqlite_db 0
::store::check_schema
::store::db enable_load_extension 1
::store::db eval {SELECT load_extension($extension,'sqlite3_similarity_init')}
::store::db enable_load_extension 0
set st [::mysql_store::db prepare {SELECT sequence_no,line_data,cosine_similarity_v2(vector,:vector) AS score,line_sha,vector_sha,vector FROM l2_fragments WHERE corpus=:corpus ORDER BY score DESC,sequence_no ASC LIMIT :topk}]
$st paramtype vector varbinary
set valid [open $vectors rb]; set h [read $valid 14]; scan [string range $h 5 12] %x n; seek $valid [expr {79+$n}]
for {set i 0} {$i < $count} {incr i} {
    set record [read $valid 1672]; ::pipeline::valid_record $record $i; set blob [string range $record 72 1607]
    set x [::store::db onecolumn {SELECT vector FROM fragments WHERE corpus=$corpus AND sequence=$i}]
    set y [::mysql_store::run {SELECT vector FROM l2_fragments WHERE corpus=:corpus AND sequence_no=:i} [list corpus $corpus i $i]]
    require {$x eq $blob && [llength $y] == 1 && [lindex $y 0 0] eq $blob} "imported vector bytes differ"
}
close $valid
set sqlite_count [::store::db onecolumn {SELECT COUNT(*) FROM fragments WHERE corpus=$corpus}]
set mysql_count [lindex [::mysql_store::run {SELECT COUNT(*) FROM l2_fragments WHERE corpus=:corpus} [list corpus $corpus]] 0 0]
require {$sqlite_count == $count && $mysql_count == $count} "imported count differs"
foreach vector $queries {
    set sqlite_echo [::store::db onecolumn {SELECT $vector}]
    set mysql_echo [::mysql_store::run {SELECT HEX(:vector),OCTET_LENGTH(:vector)} [list vector $vector] {vector}]
    require {$sqlite_echo eq $vector && [llength $mysql_echo] == 1 && [string tolower [lindex $mysql_echo 0 0]] eq [binary encode hex $vector] && [lindex $mysql_echo 0 1] == [string length $vector]} "query vector bytes differ"
}
$st close
::store::db close
::mysql_store::db close
# Reopen both connections after the verification reads; the next retrieval is
# the first ranking query on each connection, not a cold operating-system cache.
::store::open_db $sqlite_db 0
::store::db enable_load_extension 1
::store::db eval {SELECT load_extension($extension,'sqlite3_similarity_init')}
::store::db enable_load_extension 0
::mysql_store::connect $socket $schema root
set st [::mysql_store::db prepare {SELECT sequence_no,line_data,cosine_similarity_v2(vector,:vector) AS score,line_sha,vector_sha,vector FROM l2_fragments WHERE corpus=:corpus ORDER BY score DESC,sequence_no ASC LIMIT :topk}]
$st paramtype vector varbinary
set topk 5; set maxabs 0.0; set maxrel 0.0
for {set q 1} {$q <= 2} {incr q} {
    set vector [lindex $queries [expr {$q-1}]]
    set t [micros]; set sa [sqlite_rows $corpus $vector $topk]; puts $f "first_use,sqlite,$q,0,[elapsed $t]"
    set t [micros]; set mb [mysql_rows $st $corpus $vector $topk]; puts $f "first_use,mysql,$q,0,[elapsed $t]"
    set initial_sqlite [normalize_sqlite $sa]
    lassign [compare_hits $initial_sqlite [normalize_mysql $mb]] a b
    set top_ids($q) {}; foreach hit $initial_sqlite {lappend top_ids($q) [lindex $hit 1]}
    set maxabs [expr {max($maxabs,$a)}]; set maxrel [expr {max($maxrel,$b)}]
    sqlite_rows $corpus $vector $topk; mysql_rows $st $corpus $vector $topk
    for {set i 1} {$i <= 30} {incr i} {
        if {$i%2} {set order {sqlite mysql}} else {set order {mysql sqlite}}
        foreach engine $order {
            set t [micros]
            if {$engine eq "sqlite"} {set sa [sqlite_rows $corpus $vector $topk]} else {set mb [mysql_rows $st $corpus $vector $topk]}
            set query_us [elapsed $t]
            set t [micros]
            if {$engine eq "sqlite"} {set na [normalize_sqlite $sa]} else {set nb [normalize_mysql $mb]}
            set validate_us [elapsed $t]
            puts $f "warm,$engine,$q,$i,$query_us"
            puts $f "validate,$engine,$q,$i,$validate_us"
            puts $f "functional,$engine,$q,$i,[expr {$query_us+$validate_us}]"
        }
        lassign [compare_hits $na $nb] a b
        set maxabs [expr {max($maxabs,$a)}]; set maxrel [expr {max($maxrel,$b)}]
    }
}
# An independent Tcl scoring control runs outside all timed SQL intervals.
set tcl_ref_maxabs 0.0
for {set q 1} {$q <= 2} {incr q} {
    set vector [lindex $queries [expr {$q-1}]]
    binary scan $vector r* query_values
    set control {}; foreach hit [::store::retrieve $corpus $query_values $topk] {lappend control [lrange $hit 0 15]}
    set observed [normalize_sqlite [sqlite_rows $corpus $vector $topk]]
    lassign [compare_hits $control $observed] a b
    set tcl_ref_maxabs [expr {max($tcl_ref_maxabs,$a)}]
}
# The exact same vector and SQL ordering test tie handling without altering tables.
set tie [binary format r* {1 0}]
set sqlite_tie {}; ::store::db eval {SELECT id FROM (SELECT 2 AS id,$tie AS v UNION ALL SELECT 1,$tie) ORDER BY cosine_similarity_v2(v,$tie) DESC,id ASC} r {lappend sqlite_tie $r(id)}
set mysql_tie [::mysql_store::run {SELECT id FROM (SELECT 2 AS id,:tie AS v UNION ALL SELECT 1,:tie) AS sample ORDER BY cosine_similarity_v2(v,:tie) DESC,id ASC} [list tie $tie] {tie}]
require {$sqlite_tie eq {1 2} && [lindex $mysql_tie 0 0] == 1 && [lindex $mysql_tie 1 0] == 2} "tie ordering mismatch"
$st close
set sqlite_bytes [file size $sqlite_db]
set sqlite_wal [size_or_zero "$sqlite_db-wal"]; set sqlite_shm [size_or_zero "$sqlite_db-shm"]; set sqlite_journal_bytes [size_or_zero "$sqlite_db-journal"]
set journal_mode [::store::db onecolumn {PRAGMA journal_mode}]
set mysql_sizes [::mysql_store::run {SELECT SUM(data_length),SUM(index_length) FROM information_schema.tables WHERE table_schema=DATABASE()} {}]
set mysql_pid_file [file join $lab mysql.pid]; set pf [open $mysql_pid_file r]; set mysql_pid [string trim [read $pf]]; close $pf
set mysql_rss [memory $mysql_pid VmRSS]; set tcl_rss [memory [pid] VmRSS]
set mysql_peak [memory $mysql_pid VmHWM]; set tcl_peak [memory [pid] VmHWM]
set sqlite_version [::store::db version]; set mysql_version [lindex [::mysql_store::run {SELECT VERSION()} {}] 0 0]
set tdbc_version [package provide tdbc::mysql]; set git_revision [exec git -C $root rev-parse HEAD]
set cpu_file [open /proc/cpuinfo r]; try {set cpu_info [read $cpu_file]} finally {close $cpu_file}
set cpu_model unknown; regexp -line {^model name\s*:\s*(.+)$} $cpu_info -> cpu_model
set cpu_flags unknown; regexp -line {^flags\s*:\s*(.+)$} $cpu_info -> cpu_flags
set kernel [exec uname -srmo]; set stamp [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]
set os unknown
if {[file readable /etc/os-release]} {set osfile [open /etc/os-release r]; try {set osinfo [read $osfile]} finally {close $osfile}; regexp -line {^PRETTY_NAME="([^"]+)"} $osinfo -> os}
set status [exec git -C $root status --porcelain --untracked-files=normal]
::store::db close; ::mysql_store::db close; close $f
set summary [open [file join $outdir summary.md] {WRONLY CREAT EXCL} 0600]
puts $summary "# Synthetic SQL benchmark summary\n"
puts $summary "```"
puts $summary "corpus_sha256=$corpus l2e_sha256=$vectors_hash records=$count query1_sha256=[::pipeline::digest [lindex $queries 0]] query2_sha256=[::pipeline::digest [lindex $queries 1]]"
puts $summary "model=intfloat/multilingual-e5-small revision=614241f622f53c4eeff9890bdc4f31cfecc418b3 model_sha256=$::pipeline::model_hash tokenizer_sha256=$::pipeline::tokenizer_hash"
puts $summary "max_topk_score_abs=$maxabs max_topk_score_relative=$maxrel tcl_control_max_topk_abs=$tcl_ref_maxabs top_k_provenance=matched ties=matched query1_topk=[join $top_ids(1) ,] query2_topk=[join $top_ids(2) ,]"
puts $summary "sqlite_bytes=$sqlite_bytes sqlite_journal_mode=$journal_mode sqlite_journal_bytes=$sqlite_journal_bytes sqlite_wal_bytes=$sqlite_wal sqlite_shm_bytes=$sqlite_shm mysql_data_estimate=[lindex $mysql_sizes 0 0] mysql_index_estimate=[lindex $mysql_sizes 0 1] mysql_rss_kib=$mysql_rss mysql_peak_kib=$mysql_peak tcl_rss_kib=$tcl_rss tcl_peak_kib=$tcl_peak source_bytes=[file size $fragments] l2e_bytes=[file size $vectors]"
puts $summary "timestamp_utc=$stamp tcl=[info patchlevel] sqlite=$sqlite_version mysql=$mysql_version tdbc_mysql=$tdbc_version git=$git_revision worktree_dirty=[expr {$status ne ""}]"
puts $summary "os=$os kernel=$kernel cpu=$cpu_model"
puts $summary "cpu_sse2=[expr {[lsearch -exact $cpu_flags sse2] >= 0}] cpu_avx=[expr {[lsearch -exact $cpu_flags avx] >= 0}] cpu_avx2=[expr {[lsearch -exact $cpu_flags avx2] >= 0}]"
puts $summary "sqlite_extension_sha256=[::pipeline::file_hash $extension] mysql_udf_sha256=[::pipeline::file_hash [file join $lab plugins mysql_cosine_v2.so]] build_flags=-O2,no-fast-math,no-SSE2-opt-in clock=clock-clicks-microseconds"
puts $summary "onnxruntime=1.31.1 onnxruntime_sha256=$ort_hash tokenizers=0.23.2 tokenizer_backend_sha256=$tokenizer_backend_hash benchmark_script_sha256=[::pipeline::file_hash [file join $root examples 03-chatgpt-export sql_benchmark.tcl]]"
set input [open [file join $outdir samples.csv] r]
try {
    gets $input
    while {[gets $input line] >= 0} {
        lassign [split $line ,] kind engine q iteration us
        if {$kind in {warm functional}} {lappend samples($kind,$engine,$q) $us}
    }
} finally {close $input}
foreach kind {warm functional} {
  foreach engine {sqlite mysql} {
    foreach q {1 2} {
        set vals $samples($kind,$engine,$q); set sorted [lsort -integer $vals]; set sum 0
        foreach v $vals {incr sum $v}
        puts $summary [format "latency kind=%s engine=%s query=%d samples=%d min_ms=%.3f mean_ms=%.3f median_ms=%.3f p95_ms=%.3f max_ms=%.3f" $kind $engine $q [llength $vals] [expr {[lindex $sorted 0]/1000.0}] [expr {$sum/double([llength $vals])/1000.0}] [expr {[median $vals]/1000.0}] [expr {[pct $vals 0.95]/1000.0}] [expr {[lindex $sorted end]/1000.0}]]
    }
  }
}
puts $summary "```"
close $summary
puts "benchmark complete: [file join $outdir samples.csv]"
