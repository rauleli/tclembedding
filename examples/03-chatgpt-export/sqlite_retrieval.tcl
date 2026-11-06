#!/usr/bin/env tclsh
# SQLite storage for verified L2E1 records; no database service is required.
package require Tcl 8.6
package require sqlite3
set ::store_dir [file dirname [file normalize [info script]]]
source [file join $::store_dir embed_pipeline.tcl]
source [file join $::store_dir .. 01-in-memory-rag rag.tcl]
namespace eval ::store {variable fail_after -1; variable exit_after -1; variable init_exit_after_reserve 0; variable init_exit_after_first 0}
proc ::store::open_db {path create} {
    set root [file normalize [file join $::store_dir .. ..]]
    set path [file normalize $path]
    if {$path eq $root || [string first "$root/" $path] == 0} {error "database must be outside the source tree"}
    if {$create} {
        if {[file exists $path]} {error "database already exists or is partially initialized; inspect it and choose a new path"}
        set f [open $path {WRONLY CREAT EXCL} 0600]; close $f
        if {$::store::init_exit_after_reserve} {exit 86}
    } elseif {![file isfile $path]} {error "database does not exist"}
    sqlite3 ::store::db $path -create false
    db eval {PRAGMA foreign_keys=ON}
}
proc ::store::init {path} {
    open_db $path 1
    try {
        db transaction {
            db eval {
                PRAGMA user_version=1;
                CREATE TABLE corpora (id TEXT PRIMARY KEY, embeddings_sha256 TEXT NOT NULL, model TEXT NOT NULL, revision TEXT NOT NULL, model_sha256 TEXT NOT NULL, tokenizer_sha256 TEXT NOT NULL, dimension INTEGER NOT NULL CHECK(dimension=384), pooling TEXT NOT NULL, normalization TEXT NOT NULL, prefix TEXT NOT NULL, token_budget INTEGER NOT NULL, expected INTEGER NOT NULL CHECK(expected>0), status TEXT NOT NULL CHECK(status='complete'));
            }
            if {$::store::init_exit_after_first} {exit 86}
            db eval {
                CREATE TABLE messages (corpus TEXT NOT NULL, message_key TEXT NOT NULL, source_id TEXT NOT NULL, origin_sha256 TEXT NOT NULL, source TEXT NOT NULL, conversation_id TEXT NOT NULL, node_id TEXT NOT NULL, message_id TEXT NOT NULL, role TEXT NOT NULL, position INTEGER NOT NULL, created_json TEXT NOT NULL, part INTEGER NOT NULL, PRIMARY KEY(corpus,message_key), FOREIGN KEY(corpus) REFERENCES corpora(id));
                CREATE TABLE fragments (corpus TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(sequence>=0), message_key TEXT NOT NULL, fragment_index INTEGER NOT NULL, char_start INTEGER NOT NULL, char_end INTEGER NOT NULL, line_sha256 TEXT NOT NULL, text TEXT NOT NULL, text_sha256 TEXT NOT NULL, vector_sha256 TEXT NOT NULL, vector BLOB NOT NULL CHECK(typeof(vector)='blob' AND length(vector)=1536), PRIMARY KEY(corpus,sequence), UNIQUE(corpus,message_key,fragment_index), FOREIGN KEY(corpus,message_key) REFERENCES messages(corpus,message_key));
                CREATE INDEX fragments_message ON fragments(corpus,message_key);
            }
        }
    } finally {db close}
}
proc ::store::check_schema {} {
    if {[db onecolumn {PRAGMA user_version}] != 1} {error "unsupported database schema"}
    foreach {table columns} {
        corpora {{id TEXT 0 1} {embeddings_sha256 TEXT 1 0} {model TEXT 1 0} {revision TEXT 1 0} {model_sha256 TEXT 1 0} {tokenizer_sha256 TEXT 1 0} {dimension INTEGER 1 0} {pooling TEXT 1 0} {normalization TEXT 1 0} {prefix TEXT 1 0} {token_budget INTEGER 1 0} {expected INTEGER 1 0} {status TEXT 1 0}}
        messages {{corpus TEXT 1 1} {message_key TEXT 1 2} {source_id TEXT 1 0} {origin_sha256 TEXT 1 0} {source TEXT 1 0} {conversation_id TEXT 1 0} {node_id TEXT 1 0} {message_id TEXT 1 0} {role TEXT 1 0} {position INTEGER 1 0} {created_json TEXT 1 0} {part INTEGER 1 0}}
        fragments {{corpus TEXT 1 1} {sequence INTEGER 1 2} {message_key TEXT 1 0} {fragment_index INTEGER 1 0} {char_start INTEGER 1 0} {char_end INTEGER 1 0} {line_sha256 TEXT 1 0} {text TEXT 1 0} {text_sha256 TEXT 1 0} {vector_sha256 TEXT 1 0} {vector BLOB 1 0}}
    } {
        set actual {}
        db eval "PRAGMA table_info($table)" row {lappend actual [list $row(name) $row(type) $row(notnull) $row(pk)]}
        if {$actual ne $columns} {error "incomplete or incompatible database schema"}
    }
}
proc ::store::ingest {path fragments vectors} {
    variable fail_after
    variable exit_after
    ::pipeline::verify_file $vectors $fragments
    set source_hash [::pipeline::file_hash $fragments]
    set vector_hash [::pipeline::file_hash $vectors]
    set vf [open $vectors rb]; set jf [open $fragments r]; fconfigure $jf -encoding utf-8 -translation lf
    try {
        set prefix [read $vf 14]; scan [string range $prefix 5 12] %x length
        set header [encoding convertfrom utf-8 [read $vf $length]]; read $vf 65
        set count [json get $header records]; set budget [json get $header token_budget]
        set model [json get $header model]; set revision [json get $header revision]; set model_hash [json get $header onnx_sha256]; set tokenizer_hash [json get $header tokenizer_sha256]
        set pooling [json get $header pooling]; set normalization [json get $header normalization]; set doc_prefix [json get $header prefix]
        open_db $path 0
        try {
            check_schema
            db transaction {
                set exists [db onecolumn {SELECT COUNT(*) FROM corpora WHERE id=$source_hash}]
                if {$exists} {
                    set compatible [db onecolumn {SELECT COUNT(*) FROM corpora WHERE id=$source_hash AND embeddings_sha256=$vector_hash AND model=$model AND revision=$revision AND model_sha256=$model_hash AND tokenizer_sha256=$tokenizer_hash AND dimension=384 AND pooling=$pooling AND normalization=$normalization AND prefix=$doc_prefix AND token_budget=$budget AND expected=$count AND status='complete'}]
                    if {$compatible != 1} {error "corpus metadata conflicts with embeddings"}
                    set old_count [db onecolumn {SELECT COUNT(*) FROM fragments WHERE corpus=$source_hash}]
                    if {$old_count != $count} {error "stored corpus is incomplete"}
                } else {
                    db eval {INSERT INTO corpora VALUES($source_hash,$vector_hash,$model,$revision,$model_hash,$tokenizer_hash,384,$pooling,$normalization,$doc_prefix,$budget,$count,'complete')}
                }
                array set seen {}
                for {set i 0} {$i < $count} {incr i} {
                    if {[gets $jf line] < 0} {error "missing fragment"}
                    lassign [::pipeline::read_fragment $line $budget seen] text n line_hash
                    set record [read $vf 1672]
                    if {[::pipeline::valid_record $record $i] ne $line_hash} {error "fragment mismatch"}
                    set blob [string range $record 72 1607]
                    set blob_hash [::pipeline::digest $blob]
                    set text_hash [::pipeline::digest [encoding convertto utf-8 $text]]
                    set source [json get $line source]; set conversation [json get $line conversation_id]; set node [json get $line node_id]; set message [json get $line message_id]; set role [json get $line role]; set position [json get $line position]; set created [json extract $line create_time]; set part [json get $line part]
                    set source_id [json get $line input_source_id]; set origin_hash [json get $line input_sha256]
                    set message_key [::pipeline::digest [encoding convertto utf-8 [list $source_id $origin_hash $source $conversation $node $part]]]
                    set frag_index [json get $line fragment_index]; set start [json get $line char_start]; set end [json get $line char_end]
                    if {!$exists} {
                        set has_message [db onecolumn {SELECT COUNT(*) FROM messages WHERE corpus=$source_hash AND message_key=$message_key}]
                        if {!$has_message} {db eval {INSERT INTO messages VALUES($source_hash,$message_key,$source_id,$origin_hash,$source,$conversation,$node,$message,$role,$position,$created,$part)}} else {
                            set matches [db onecolumn {SELECT COUNT(*) FROM messages WHERE corpus=$source_hash AND message_key=$message_key AND source_id=$source_id AND origin_sha256=$origin_hash AND source=$source AND conversation_id=$conversation AND node_id=$node AND message_id=$message AND role=$role AND position=$position AND created_json=$created AND part=$part}]
                            if {$matches != 1} {error "message provenance conflict"}
                        }
                        db eval {INSERT INTO fragments VALUES($source_hash,$i,$message_key,$frag_index,$start,$end,$line_hash,$text,$text_hash,$blob_hash,$blob)}
                    } else {
                        set matches [db onecolumn {SELECT COUNT(*) FROM fragments AS f JOIN messages AS m ON f.corpus=m.corpus AND f.message_key=m.message_key WHERE f.corpus=$source_hash AND f.sequence=$i AND f.message_key=$message_key AND f.fragment_index=$frag_index AND f.char_start=$start AND f.char_end=$end AND f.line_sha256=$line_hash AND f.text=$text AND f.text_sha256=$text_hash AND f.vector_sha256=$blob_hash AND f.vector=$blob AND m.source_id=$source_id AND m.origin_sha256=$origin_hash AND m.source=$source AND m.conversation_id=$conversation AND m.node_id=$node AND m.message_id=$message AND m.role=$role AND m.position=$position AND m.created_json=$created AND m.part=$part}]
                        if {$matches != 1} {error "stored fragment or vector conflict"}
                    }
                    if {$fail_after == $i} {error "synthetic interrupted transaction"}
                    if {$exit_after == $i} {exit 86}
                }
                if {[::pipeline::file_hash $fragments] ne $source_hash || [::pipeline::file_hash $vectors] ne $vector_hash} {error "input changed during import"}
                if {[db onecolumn {SELECT COUNT(*) FROM fragments WHERE corpus=$source_hash}] != $count} {error "fragment count mismatch"}
            }
            puts "corpus=$source_hash records=$count existing=$exists"
        } finally {db close}
    } finally {close $vf; close $jf}
}
proc ::store::compare {a b} {
    if {[lindex $a 0] > [lindex $b 0]} {return -1}
    if {[lindex $a 0] < [lindex $b 0]} {return 1}
    return [expr {[lindex $a 1] < [lindex $b 1] ? -1 : ([lindex $a 1] > [lindex $b 1] ? 1 : 0)}]
}
proc ::store::retrieve {corpus vector topk} {
    if {![regexp {^[0-9a-f]{64}$} $corpus] || ![string is integer -strict $topk] || $topk < 1 || $topk > 256 || [llength $vector] != 384} {error "invalid query parameters"}
    set expected_model $::pipeline::model_hash; set expected_tokenizer $::pipeline::tokenizer_hash
    set expected [db onecolumn {SELECT expected FROM corpora WHERE id=$corpus AND model='intfloat/multilingual-e5-small' AND revision='614241f622f53c4eeff9890bdc4f31cfecc418b3' AND model_sha256=$expected_model AND tokenizer_sha256=$expected_tokenizer AND dimension=384 AND pooling='mean' AND normalization='l2' AND prefix='passage: ' AND status='complete'}]
    if {$expected eq "" || [db onecolumn {SELECT COUNT(*) FROM fragments WHERE corpus=$corpus}] != $expected || [db onecolumn {SELECT MIN(sequence) FROM fragments WHERE corpus=$corpus}] != 0 || [db onecolumn {SELECT MAX(sequence) FROM fragments WHERE corpus=$corpus}] != $expected-1} {error "corpus unavailable or incomplete"}
    set result {}
    db eval {SELECT f.sequence,f.text,f.text_sha256,f.vector,f.vector_sha256,f.fragment_index,f.char_start,f.char_end,m.source_id,m.origin_sha256,m.source,m.conversation_id,m.node_id,m.message_id,m.role,m.position,m.created_json,m.part FROM fragments f JOIN messages m ON f.corpus=m.corpus AND f.message_key=m.message_key WHERE f.corpus=$corpus} row {
        if {[string length $row(vector)] != 1536} {error "invalid stored vector length"}
        binary scan $row(vector) r* values
        set score [::rag::cosine $vector $values]
        set hit [list $score $row(sequence) $row(text) $row(source_id) $row(origin_sha256) $row(source) $row(conversation_id) $row(node_id) $row(message_id) $row(role) $row(position) $row(created_json) $row(part) $row(fragment_index) $row(char_start) $row(char_end) intfloat/multilingual-e5-small]
        lappend result [list $hit $row(vector) $row(vector_sha256) $row(text_sha256)]
    }
    if {[llength $result] != $expected} {error "missing fragment provenance"}
    set hits {}
    foreach item [lrange [lsort -command ::store::compare_wrapped $result] 0 [expr {$topk-1}]] {
        lassign $item hit blob vector_hash text_hash
        if {[::pipeline::digest $blob] ne $vector_hash || [::pipeline::digest [encoding convertto utf-8 [lindex $hit 2]]] ne $text_hash} {error "invalid stored vector or text"}
        lappend hits $hit
    }
    return $hits
}
proc ::store::compare_wrapped {a b} {return [compare [lindex $a 0] [lindex $b 0]]}
proc ::store::query {path corpus model tokenizer text topk} {
    if {[string trim $text] eq ""} {error "empty query"}
    if {[::pipeline::file_hash $model] ne $::pipeline::model_hash || [::pipeline::file_hash $tokenizer] ne $::pipeline::tokenizer_hash} {error "model or tokenizer hash mismatch"}
    package require tokenizer 1.0.0; package require tclembedding 1.0
    set loaded 0; set handle {}
    try {
        tokenizer::load_vocab $tokenizer; set loaded 1
        set ids [tokenizer::tokenize "query: $text"]
        if {[llength $ids] < 1 || [llength $ids] > 512} {error "query exceeds token limit"}
        set handle [embedding::init_raw $model]
        set packed [::pipeline::vector_blob [embedding::compute $handle $ids -pooling mean]]
        binary scan $packed r* vector
        open_db $path 0
        try {check_schema; foreach hit [retrieve $corpus $vector $topk] {puts $hit}} finally {db close}
    } finally {try {if {$handle ne ""} {embedding::free $handle}} finally {if {$loaded} {tokenizer::free}}}
}
if {[file normalize $argv0] eq [file normalize [info script]]} {
    if {[catch {
        set op [lindex $argv 0]; set args [lrange $argv 1 end]
        switch -- $op {
            init {if {[llength $args] != 1} {error "usage: init database"}; ::store::init {*}$args}
            ingest {if {[llength $args] != 3} {error "usage: ingest database fragments vectors"}; ::store::ingest {*}$args}
            query {if {[llength $args] != 6} {error "usage: query database corpus-sha256 model tokenizer text top-k"}; ::store::query {*}$args}
            default {error "expected init, ingest or query"}
        }
    } message]} {puts stderr "Error: $message"; exit 1}
}
