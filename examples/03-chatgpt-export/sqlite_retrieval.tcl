#!/usr/bin/env tclsh
# SQLite storage for directly generated embeddings.
package require Tcl 8.6
package require sqlite3
set ::store_dir [file dirname [file normalize [info script]]]
source [file join $::store_dir sql_ingest.tcl]
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
                PRAGMA user_version=2;
                CREATE TABLE corpora (id TEXT PRIMARY KEY, configuration_sha256 TEXT NOT NULL, configuration TEXT NOT NULL, model TEXT NOT NULL, revision TEXT NOT NULL, model_sha256 TEXT NOT NULL, tokenizer_sha256 TEXT NOT NULL, dimension INTEGER NOT NULL CHECK(dimension=384), pooling TEXT NOT NULL, normalization TEXT NOT NULL, prefix TEXT NOT NULL, token_budget INTEGER NOT NULL, expected INTEGER NOT NULL CHECK(expected>0), progress INTEGER NOT NULL CHECK(progress>=0 AND progress<=expected), status TEXT NOT NULL CHECK(status IN ('building','complete')));
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
    if {[db onecolumn {PRAGMA user_version}] != 2} {error "unsupported database schema"}
    foreach {table columns} {
        corpora {{id TEXT 0 1} {configuration_sha256 TEXT 1 0} {configuration TEXT 1 0} {model TEXT 1 0} {revision TEXT 1 0} {model_sha256 TEXT 1 0} {tokenizer_sha256 TEXT 1 0} {dimension INTEGER 1 0} {pooling TEXT 1 0} {normalization TEXT 1 0} {prefix TEXT 1 0} {token_budget INTEGER 1 0} {expected INTEGER 1 0} {progress INTEGER 1 0} {status TEXT 1 0}}
        messages {{corpus TEXT 1 1} {message_key TEXT 1 2} {source_id TEXT 1 0} {origin_sha256 TEXT 1 0} {source TEXT 1 0} {conversation_id TEXT 1 0} {node_id TEXT 1 0} {message_id TEXT 1 0} {role TEXT 1 0} {position INTEGER 1 0} {created_json TEXT 1 0} {part INTEGER 1 0}}
        fragments {{corpus TEXT 1 1} {sequence INTEGER 1 2} {message_key TEXT 1 0} {fragment_index INTEGER 1 0} {char_start INTEGER 1 0} {char_end INTEGER 1 0} {line_sha256 TEXT 1 0} {text TEXT 1 0} {text_sha256 TEXT 1 0} {vector_sha256 TEXT 1 0} {vector BLOB 1 0}}
    } {
        set actual {}
        db eval "PRAGMA table_info($table)" row {lappend actual [list $row(name) $row(type) $row(notnull) $row(pk)]}
        if {$actual ne $columns} {error "incomplete or incompatible database schema"}
    }
}
proc ::store::begin_corpus {corpus count config} {
  check_schema
  db eval {PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL}
  set config_hash [::pipeline::digest [encoding convertto utf-8 $config]]
  set expected_model $::pipeline::model_hash
  set expected_tokenizer $::pipeline::tokenizer_hash
  set revision 614241f622f53c4eeff9890bdc4f31cfecc418b3
  set prefix {passage: }
  db transaction {
    set exists [db onecolumn {SELECT COUNT(*) FROM corpora WHERE id=$corpus}]
    if {!$exists} {
      db eval {INSERT INTO corpora VALUES($corpus,$config_hash,$config,'intfloat/multilingual-e5-small',$revision,$expected_model,$expected_tokenizer,384,'mean','l2',$prefix,128,$count,0,'building')}
    }
  }
  set rows [db eval {SELECT progress FROM corpora WHERE id=$corpus AND configuration_sha256=$config_hash AND configuration=$config AND expected=$count AND model='intfloat/multilingual-e5-small' AND revision=$revision AND model_sha256=$expected_model AND tokenizer_sha256=$expected_tokenizer AND dimension=384 AND pooling='mean' AND normalization='l2' AND prefix=$prefix AND token_budget=128 AND status IN ('building','complete')}]
  if {[llength $rows] != 1} {error "incompatible corpus configuration"}
  set progress [lindex $rows 0]
  if {[db onecolumn {SELECT COUNT(*) FROM fragments WHERE corpus=$corpus}] != $progress} {error "checkpoint row count mismatch"}
  if {$progress > 0 && [db onecolumn {SELECT MAX(sequence) FROM fragments WHERE corpus=$corpus}] != $progress-1} {error "checkpoint sequence mismatch"}
  return $progress
}

proc ::store::verify_row {corpus index line line_hash} {
  set result {}
  db eval {SELECT f.line_sha256,f.vector_sha256,f.vector,f.text,f.text_sha256,f.message_key,m.source_id,m.origin_sha256,m.source,m.conversation_id,m.node_id,m.message_id,m.role,m.position,m.created_json,m.part,f.fragment_index,f.char_start,f.char_end FROM fragments f JOIN messages m ON f.corpus=m.corpus AND f.message_key=m.message_key WHERE f.corpus=$corpus AND f.sequence=$index} row {
    set result [array get row]
  }
  if {$result eq ""} {error "missing stored fragment"}
  array set row $result
  if {$row(line_sha256) ne $line_hash || [string length $row(vector)] != 1536 || [::pipeline::digest $row(vector)] ne $row(vector_sha256)} {error "stored vector or identity mismatch"}
  ::pipeline::validate_blob $row(vector)
  set key [::pipeline::digest [encoding convertto utf-8 [list $row(source_id) $row(origin_sha256) $row(source) $row(conversation_id) $row(node_id) $row(part)]]]
  if {$row(message_key) ne $key || [::pipeline::digest [encoding convertto utf-8 $row(text)]] ne $row(text_sha256)} {error "stored text or message identity mismatch"}
  foreach {field col} {text text input_source_id source_id input_sha256 origin_sha256 source source conversation_id conversation_id node_id node_id message_id message_id role role position position part part fragment_index fragment_index char_start char_start char_end char_end} {
    if {[json get $line $field] ne $row($col)} {error "stored provenance mismatch"}
  }
  if {[json extract $line create_time] ne $row(created_json)} {error "stored timestamp mismatch"}
}

proc ::store::commit_batch {corpus rows count fail_after} {
  db transaction {
    set progress [db onecolumn {SELECT progress FROM corpora WHERE id=$corpus AND status='building'}]
    if {$progress eq "" || $progress != [lindex [lindex $rows 0] 0]} {error "checkpoint changed"}
    foreach item $rows {
      lassign $item i line line_hash blob
      set text [json get $line text];set source [json get $line source]
      set conversation [json get $line conversation_id];set node [json get $line node_id]
      set message [json get $line message_id];set role [json get $line role]
      set position [json get $line position];set created [json extract $line create_time]
      set part [json get $line part];set source_id [json get $line input_source_id]
      set origin_hash [json get $line input_sha256]
      set key [::pipeline::digest [encoding convertto utf-8 [list $source_id $origin_hash $source $conversation $node $part]]]
      set frag_index [json get $line fragment_index];set start [json get $line char_start];set end [json get $line char_end]
      set text_hash [::pipeline::digest [encoding convertto utf-8 $text]];set vector_hash [::pipeline::digest $blob]
      db eval {INSERT OR IGNORE INTO messages VALUES($corpus,$key,$source_id,$origin_hash,$source,$conversation,$node,$message,$role,$position,$created,$part)}
      set matches [db onecolumn {SELECT COUNT(*) FROM messages WHERE corpus=$corpus AND message_key=$key AND source_id=$source_id AND origin_sha256=$origin_hash AND source=$source AND conversation_id=$conversation AND node_id=$node AND message_id=$message AND role=$role AND position=$position AND created_json=$created AND part=$part}]
      if {$matches != 1} {error "message provenance conflict"}
      db eval {INSERT INTO fragments VALUES($corpus,$i,$key,$frag_index,$start,$end,$line_hash,$text,$text_hash,$vector_hash,$blob)}
      if {$fail_after == $i} {error "synthetic transaction failure"}
      incr progress
    }
    db eval {UPDATE corpora SET progress=$progress WHERE id=$corpus AND status='building'}
  }
}

proc ::store::finish {corpus count} {
  db transaction {
    set ready [db onecolumn {SELECT COUNT(*) FROM corpora WHERE id=$corpus AND expected=$count AND progress=$count}]
    if {$ready != 1 || [db onecolumn {SELECT COUNT(*) FROM fragments WHERE corpus=$corpus}] != $count} {error "incomplete corpus"}
    db eval {UPDATE corpora SET status='complete' WHERE id=$corpus}
  }
}

proc ::store::ingest {path fragments model tokenizer {batch_size 8}} {
  open_db $path 0
  try {
    ::sql_ingest::run ::store $fragments $model $tokenizer $batch_size
  } finally {
    db close
  }
}
proc ::store::compare {a b} {
    if {[lindex $a 0] > [lindex $b 0]} {return -1}
    if {[lindex $a 0] < [lindex $b 0]} {return 1}
    return [expr {[lindex $a 1] < [lindex $b 1] ? -1 : ([lindex $a 1] > [lindex $b 1] ? 1 : 0)}]
}
proc ::store::validate_query {corpus vector topk} {
    if {![regexp {^[0-9a-f]{64}$} $corpus] || ![string is integer -strict $topk] || $topk < 1 || $topk > 256 || [llength $vector] != 384} {error "invalid query parameters"}
    set expected_model $::pipeline::model_hash; set expected_tokenizer $::pipeline::tokenizer_hash
    set expected [db onecolumn {SELECT expected FROM corpora WHERE id=$corpus AND model='intfloat/multilingual-e5-small' AND revision='614241f622f53c4eeff9890bdc4f31cfecc418b3' AND model_sha256=$expected_model AND tokenizer_sha256=$expected_tokenizer AND dimension=384 AND pooling='mean' AND normalization='l2' AND prefix='passage: ' AND status='complete'}]
    if {$expected eq "" || [db onecolumn {SELECT COUNT(*) FROM fragments WHERE corpus=$corpus}] != $expected || [db onecolumn {SELECT MIN(sequence) FROM fragments WHERE corpus=$corpus}] != 0 || [db onecolumn {SELECT MAX(sequence) FROM fragments WHERE corpus=$corpus}] != $expected-1} {error "corpus unavailable or incomplete"}
    return $expected
}
proc ::store::retrieve {corpus vector topk} {
    set expected [validate_query $corpus $vector $topk]
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
proc ::store::retrieve_native {corpus vector packed topk} {
    set expected [validate_query $corpus $vector $topk]
    if {[string length $packed] != 1536 || [binary format r* $vector] ne $packed} {error "invalid query vector bytes"}
    set hits {}; set count 0
    db eval {SELECT cosine_similarity_v2(f.vector,$packed) AS score,f.sequence,f.text,f.text_sha256,f.vector,f.vector_sha256,f.fragment_index,f.char_start,f.char_end,m.source_id,m.origin_sha256,m.source,m.conversation_id,m.node_id,m.message_id,m.role,m.position,m.created_json,m.part FROM fragments f JOIN messages m ON f.corpus=m.corpus AND f.message_key=m.message_key WHERE f.corpus=$corpus ORDER BY score DESC,f.sequence ASC} row {
        if {[string length $row(vector)] != 1536 || $row(score) eq ""} {error "invalid stored vector"}
        if {$count < $topk} {
            if {[::pipeline::digest $row(vector)] ne $row(vector_sha256) || [::pipeline::digest [encoding convertto utf-8 $row(text)]] ne $row(text_sha256)} {error "invalid stored vector or text"}
            lappend hits [list $row(score) $row(sequence) $row(text) $row(source_id) $row(origin_sha256) $row(source) $row(conversation_id) $row(node_id) $row(message_id) $row(role) $row(position) $row(created_json) $row(part) $row(fragment_index) $row(char_start) $row(char_end) intfloat/multilingual-e5-small]
        }
        incr count
    }
    if {$count != $expected} {error "missing fragment provenance"}
    return $hits
}
proc ::store::compare_wrapped {a b} {return [compare [lindex $a 0] [lindex $b 0]]}
proc ::store::query_results {path corpus model tokenizer text topk {extension {}}} {
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
        try {
            check_schema
            if {$extension eq ""} {return [retrieve $corpus $vector $topk]}
            if {![file isfile $extension]} {error "SQLite extension file does not exist"}
            try {
                db enable_load_extension 1
                db eval {SELECT load_extension($extension,'sqlite3_similarity_init')}
            } finally {db enable_load_extension 0}
            return [retrieve_native $corpus $vector $packed $topk]
        } finally {db close}
    } finally {try {if {$handle ne ""} {embedding::free $handle}} finally {if {$loaded} {tokenizer::free}}}
}
proc ::store::query {path corpus model tokenizer text topk} {
    foreach hit [query_results $path $corpus $model $tokenizer $text $topk] {puts $hit}
}
if {[file normalize $argv0] eq [file normalize [info script]]} {
    if {[catch {
        set op [lindex $argv 0]; set args [lrange $argv 1 end]
        switch -- $op {
            init {if {[llength $args] != 1} {error "usage: init database"}; ::store::init {*}$args}
            ingest {if {[llength $args] ni {4 5}} {error "usage: ingest database fragments model tokenizer ?batch-size?"}; ::store::ingest {*}$args}
            query {if {[llength $args] != 6} {error "usage: query database corpus-sha256 model tokenizer text top-k"}; ::store::query {*}$args}
            default {error "expected init, ingest or query"}
        }
    } message]} {puts stderr "Error: $message"; exit 1}
}
