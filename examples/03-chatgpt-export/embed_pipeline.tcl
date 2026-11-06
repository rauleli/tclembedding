#!/usr/bin/env tclsh
# Resumable E5 embedding records for synthetic and local JSONL input.
package require Tcl 8.6
package require rl_json 0.15.7
package require sha256
namespace import ::rl_json::json
namespace eval ::pipeline {
    variable source_root [file normalize [file join [file dirname [info script]] .. ..]]
    variable model_hash ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665
    variable tokenizer_hash 0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39
    variable backend_hash 9197dcf251bd220ebc023155b65911eff4913b6125c3325acb5fed5563ce2e5f
    variable runtime_hash a96f132e5eb5ca04e23a7d2fc1078fb95aa591e8d71d0f237702ece3a1e0f4ea
    variable record_size 1672
    variable test_after -1
    variable test_partial 0
    variable test_hard_exit 0
    variable token_us 0
    variable infer_us 0
    variable batch_counts {}
}
proc ::pipeline::digest {bytes} {return [::sha2::sha256 -hex $bytes]}
proc ::pipeline::file_hash {path} {return [::sha2::sha256 -hex -filename $path]}
proc ::pipeline::finite {v} {
    if {![string is double -strict $v]} {return 0}
    if {[catch {expr {double($v) == double($v) && abs(double($v)) < Inf}} good]} {return 0}
    return $good
}
proc ::pipeline::vector_blob {v} {
    if {[llength $v] != 384} {error "unexpected embedding dimension"}
    set norm 0.0
    foreach x $v {if {![finite $x]} {error "non-finite embedding"}; set norm [expr {$norm+double($x)*double($x)}]}
    if {abs(sqrt($norm)-1.0) > 1e-5} {error "embedding is not L2 normalized"}
    set b [binary format r* $v]
    if {[string length $b] != 1536} {error "invalid vector encoding"}
    binary scan $b r* decoded
    foreach x $decoded {if {![finite $x]} {error "non-finite float32 embedding"}}
    return $b
}
proc ::pipeline::read_fragment {line budget seenName} {
    upvar 1 $seenName seen
    if {![json valid $line] || [json type $line] ne "object"} {error "invalid fragment record"}
    set fields [json keys $line]
    foreach field {fragment_version input_source_id input_sha256 tokenizer_sha256 extractor_version source conversation_id node_id message_id role position create_time part fragment_index char_start char_end token_count token_budget unk_id unk_count content_token_count max_nonspace_tcl_units text} {
        if {[lsearch -exact $fields $field] < 0} {error "missing fragment field: $field"}
    }
    if {[json type $line fragment_version] ne "string" || [json get $line fragment_version] ne "2"} {error "unsupported fragment version"}
    if {[json type $line extractor_version] ne "string" || [json get $line extractor_version] ne "1" || [json type $line create_time] ni {string number null} || [json type $line content_token_count] ne "null"} {error "invalid fragment metadata"}
    foreach field {input_source_id source conversation_id node_id message_id role text} {
        if {[json type $line $field] ne "string" || [json get $line $field] eq ""} {error "invalid fragment field: $field"}
    }
    if {[json get $line role] ni {user assistant}} {error "invalid fragment role"}
    foreach field {position part fragment_index char_start char_end token_count token_budget unk_id unk_count max_nonspace_tcl_units} {
        if {[json type $line $field] ne "number" || ![string is entier -strict [json get $line $field]] || [json get $line $field] < 0} {error "invalid fragment number: $field"}
    }
    if {[json get $line token_budget] != $budget || [json get $line token_count] < 1 || [json get $line token_count] > $budget} {error "incompatible fragment budget"}
    if {[json get $line tokenizer_sha256] ne $::pipeline::tokenizer_hash} {error "incompatible fragment tokenizer"}
    if {[json get $line unk_id] != 3 || [json get $line unk_count] > [json get $line token_count]} {error "invalid unknown-token metadata"}
    if {![regexp {^[0-9a-f]{64}$} [json get $line input_sha256]]} {error "invalid source hash"}
    set text [json get $line text]
    if {[json get $line char_end] - [json get $line char_start] != [string length $text]} {error "invalid fragment range"}
    set key [list [json get $line input_source_id] [json get $line input_sha256] [json get $line source] [json get $line conversation_id] [json get $line node_id] [json get $line part] [json get $line fragment_index]]
    if {[info exists seen($key)]} {error "duplicate fragment provenance"}
    set seen($key) 1
    return [list $text [json get $line token_count] [digest [encoding convertto utf-8 $line]] [json get $line unk_count]]
}
proc ::pipeline::header {input_hash count budget batch backend runtime bridge embedding} {
    set metadata [format {{"format":"tclembedding-e5-f32le-v1","fragment_sha256":"%s","fragment_version":"2","records":%d,"model":"intfloat/multilingual-e5-small","revision":"614241f622f53c4eeff9890bdc4f31cfecc418b3","onnx_sha256":"%s","tokenizer_sha256":"%s","dimension":384,"pooling":"mean","normalization":"l2","prefix":"passage: ","token_budget":%d,"batch_size":%d,"padding_id":1,"tcl":"%s","rl_json":"%s","sha256_package":"%s","tokenizers":"0.23.2","onnxruntime":"1.31.1","execution_provider":"CPUExecutionProvider","backend_sha256":"%s","runtime_sha256":"%s","bridge_sha256":"%s","embedding_sha256":"%s"}} \
        $input_hash $count $::pipeline::model_hash $::pipeline::tokenizer_hash $budget $batch [info patchlevel] [package provide rl_json] [package provide sha256] $backend $runtime $bridge $embedding]
    set bytes [encoding convertto utf-8 $metadata]
    return "L2E1\n[format %08x [string length $bytes]]\n$bytes[digest $bytes]\n"
}
proc ::pipeline::mapped_hash {name} {
    set f [open /proc/self/maps r]; set paths {}
    try {
        while {[gets $f line] >= 0} {
            if {[regexp {(/[^ ]+)$} $line -> path] && [string match "*/$name" $path] && [lsearch -exact $paths $path] < 0} {lappend paths $path}
        }
    } finally {close $f}
    if {[llength $paths] != 1} {error "cannot identify the loaded $name"}
    return [file_hash [lindex $paths 0]]
}
proc ::pipeline::record {index key blob} {
    set payload "[binary format w $index]$key$blob"
    return "$payload[digest $payload]"
}
proc ::pipeline::valid_record {data expected_index} {
    variable record_size
    if {[string length $data] != $record_size} {error "incomplete record"}
    set payload [string range $data 0 end-64]
    set sum [string range $data end-63 end]
    if {![regexp {^[0-9a-f]{64}$} $sum] || [digest $payload] ne $sum} {error "record checksum mismatch"}
    binary scan [string range $payload 0 7] w index
    if {$index != $expected_index} {error "record sequence mismatch"}
    set key [string range $payload 8 71]
    if {![regexp {^[0-9a-f]{64}$} $key]} {error "invalid fragment checksum"}
    set blob [string range $payload 72 end]
    binary scan $blob r* vec
    if {[llength $vec] != 384} {error "invalid vector length"}
    set norm 0.0
    foreach x $vec {if {![finite $x]} {error "non-finite stored vector"}; set norm [expr {$norm+double($x)*double($x)}]}
    if {abs(sqrt($norm)-1.0) > 1e-5} {error "invalid stored vector norm"}
    return $key
}
proc ::pipeline::verify_file {path {input {}}} {
    variable record_size
    set f [open $path r]; fconfigure $f -translation binary -encoding binary
    set in {}
    try {
        if {[read $f 5] ne "L2E1\n"} {error "invalid file magic"}
        set length_text [read $f 9]
        if {![regexp {^[0-9a-f]{8}\n$} $length_text]} {error "invalid header length"}
        scan [string range $length_text 0 7] %x length
        if {$length < 1 || $length > 65536} {error "invalid header length"}
        set bytes [read $f $length]
        set checksum [read $f 65]
        if {[string length $bytes] != $length || $checksum ne "[digest $bytes]\n"} {error "header checksum mismatch"}
        set metadata [encoding convertfrom utf-8 $bytes]
        if {![json valid $metadata] || [json get $metadata format] ne "tclembedding-e5-f32le-v1" || [json get $metadata dimension] != 384 || [json get $metadata fragment_version] ne "2"} {error "unsupported header"}
        if {[json get $metadata model] ne "intfloat/multilingual-e5-small" || [json get $metadata revision] ne "614241f622f53c4eeff9890bdc4f31cfecc418b3" || [json get $metadata onnx_sha256] ne $::pipeline::model_hash || [json get $metadata tokenizer_sha256] ne $::pipeline::tokenizer_hash || [json get $metadata pooling] ne "mean" || [json get $metadata normalization] ne "l2" || [json get $metadata prefix] ne "passage: "} {error "incompatible metadata"}
        set count [json get $metadata records]
        if {![string is entier -strict $count] || $count < 1} {error "invalid record count"}
        if {[file size $path] != 14 + $length + 65 + $count*$record_size} {error "invalid file length"}
        if {$input ne ""} {
            set input_hash [file_hash $input]
            if {$input_hash ne [json get $metadata fragment_sha256]} {error "fragment file hash mismatch"}
            set in [open $input r]; fconfigure $in -encoding utf-8 -translation lf
            array set seen {}
        }
        for {set i 0} {$i < $count} {incr i} {
            set key [valid_record [read $f $record_size] $i]
            if {$in ne ""} {
                if {[gets $in line] < 0} {error "missing input fragment"}
                lassign [read_fragment $line [json get $metadata token_budget] seen] text n expected
                if {$expected ne $key} {error "fragment identity mismatch"}
            }
        }
        if {[read $f 1] ne ""} {error "unexpected trailing bytes"}
        if {$in ne "" && ([gets $in extra] >= 0 || [file_hash $input] ne $input_hash)} {error "fragment input changed or has extra records"}
        set matched [expr {$input ne ""}]
        puts "verified_records=$count fragment_match=$matched"
    } finally {if {$in ne ""} {close $in}; close $f}
}
proc ::pipeline::process_batch {handle batch stored out} {
    variable token_us; variable infer_us; variable batch_counts; variable test_after; variable test_partial; variable test_hard_exit
    if {[llength $batch] == 0} {return}
    set first [lindex [lindex $batch 0] 0]; set last [lindex [lindex $batch end] 0]
    set completed [llength $stored]
    if {$last < $completed} {return}
    set idslist {}
    foreach item $batch {
        lassign $item index text expected key expected_unk
        set t [clock microseconds]
        set ids [tokenizer::tokenize "passage: $text"]
        incr token_us [expr {[clock microseconds]-$t}]
        if {[llength $ids] != $expected} {error "fragment token count mismatch"}
        set actual_unk 0; foreach id $ids {if {$id == 3} {incr actual_unk}}
        if {$actual_unk != $expected_unk} {error "fragment unknown-token count mismatch"}
        lappend idslist $ids
    }
    set t [clock microseconds]
    if {[llength $idslist] == 1} {
        set vectors [list [embedding::compute $handle [lindex $idslist 0] -pooling mean]]
    } else {
        set vectors [embedding::compute_batch $handle $idslist -pad-id 1 -pooling mean]
    }
    incr infer_us [expr {[clock microseconds]-$t}]
    if {[llength $vectors] != [llength $batch]} {error "batch result count mismatch"}
    lappend batch_counts [llength $batch]
    foreach item $batch vector $vectors {
        lassign $item index text expected key
        set data [record $index $key [vector_blob $vector]]
        if {$index < $completed} {
            if {$data ne [lindex $stored $index]} {error "resumed batch does not reproduce completed record"}
        } else {
            if {$test_after == $index && $test_partial} {puts -nonewline $out [string range $data 0 99]; flush $out; if {$test_hard_exit} {exit 86}; error "synthetic partial interruption"}
            if {$test_after == $index} {if {$test_hard_exit} {exit 86}; error "synthetic interruption"}
            puts -nonewline $out $data; flush $out
        }
    }
}
proc ::pipeline::main {args} {
    variable model_hash; variable tokenizer_hash; variable backend_hash; variable runtime_hash; variable record_size
    variable token_us; variable infer_us; variable batch_counts
    set token_us 0; set infer_us 0; set batch_counts {}
    array set opt {-input {} -output {} -model {} -tokenizer {} -budget 512 -batch-size 8}
    if {[llength $args] % 2} {error "options require values"}
    foreach {key value} $args {if {![info exists opt($key)]} {error "unknown option"}; set opt($key) $value}
    foreach key {-input -output -model -tokenizer} {if {$opt($key) eq ""} {error "missing option $key"}}
    foreach {key max} {-budget 512 -batch-size 256} {if {![string is integer -strict $opt($key)] || $opt($key) < 1 || $opt($key) > $max} {error "invalid $key"}}
    set output [file normalize $opt(-output)]
    set root $::pipeline::source_root
    if {$output eq $root || [string first "$root/" $output] == 0} {error "output must be outside the source tree"}
    set partial "$output.partial"
    if {[file exists $output]} {error "output already exists"}
    foreach {file expected} [list $opt(-model) $model_hash $opt(-tokenizer) $tokenizer_hash] {if {![file isfile $file] || [file_hash $file] ne $expected} {error "model or tokenizer hash mismatch"}}
    set start [clock microseconds]
    set input_hash [file_hash $opt(-input)]
    set in [open $opt(-input) r]; fconfigure $in -encoding utf-8 -translation lf
    set count 0; set unknown_fragments 0; array set seen {}
    try {while {[gets $in line] >= 0} {lassign [read_fragment $line $opt(-budget) seen] ignored ignored key unknown; if {$unknown > 0} {incr unknown_fragments}; incr count}} finally {close $in}
    if {$count == 0} {error "input contains no fragments"}
    package require tokenizer 1.0.0; package require tclembedding 1.0
    set handle {}; set loaded 0; set out {}; set in {}
    try {
        tokenizer::load_vocab $opt(-tokenizer); set loaded 1
        set handle [embedding::init_raw $opt(-model)]
        set bh [mapped_hash libtclembedding_tokenizer.so]
        set rh [mapped_hash libonnxruntime.so.1.31.1]
        set ch [mapped_hash tcltokenizer.so]
        set eh [mapped_hash tclembedding.so]
        if {$bh ne $backend_hash || $rh ne $runtime_hash} {error "uncharacterized loaded backend or ONNX Runtime"}
        set hdr [header $input_hash $count $opt(-budget) $opt(-batch-size) $bh $rh $ch $eh]
        set stored {}; set recovery_start [clock microseconds]
        if {[file exists $partial]} {
            file lstat $partial partial_info
            if {$partial_info(type) ne "file"} {error "checkpoint must be a regular file"}
            set out [open $partial r+]; fconfigure $out -translation binary -encoding binary
            set existing [read $out [string length $hdr]]
            if {$existing ne $hdr} {error "incompatible or incomplete checkpoint header"}
            set index 0
            while {1} {
                set pos [tell $out]; set data [read $out $record_size]; set n [string length $data]
                if {$n == 0} break
                if {$n < $record_size} {chan truncate $out $pos; seek $out $pos; break}
                if {$index >= $count} {error "checkpoint has excess records"}
                valid_record $data $index
                lappend stored $data; incr index
            }
        } else {
            set out [open $partial {RDWR CREAT EXCL} 0600]; fconfigure $out -translation binary -encoding binary
            puts -nonewline $out $hdr; flush $out
        }
        set recovery_us [expr {[clock microseconds]-$recovery_start}]
        set in [open $opt(-input) r]; fconfigure $in -encoding utf-8 -translation lf
        array unset seen; array set seen {}; set index 0; set batch {}; set longest 0
        while {[gets $in line] >= 0} {
            lassign [read_fragment $line $opt(-budget) seen] text n key unknown
            if {$index < [llength $stored] && [valid_record [lindex $stored $index] $index] ne $key} {error "checkpoint fragment identity mismatch"}
            set newlong [expr {max($longest,$n)}]
            if {[llength $batch] && ([llength $batch] >= $opt(-batch-size) || ([llength $batch]+1)*$newlong > 4096)} {
                process_batch $handle $batch $stored $out
                set batch {}; set longest 0; set newlong $n
            }
            lappend batch [list $index $text $n $key $unknown]; set longest $newlong; incr index
        }
        process_batch $handle $batch $stored $out
        close $in; set in {}; flush $out; close $out; set out {}
        if {$index != $count || [file_hash $opt(-input)] ne $input_hash} {error "input changed during processing"}
        if {[file_hash $opt(-model)] ne $model_hash || [file_hash $opt(-tokenizer)] ne $tokenizer_hash} {error "model or tokenizer changed during processing"}
        set f [open $partial r]; fconfigure $f -translation binary -encoding binary
        try {
            if {[read $f [string length $hdr]] ne $hdr} {error "header changed"}
            for {set i 0} {$i < $count} {incr i} {valid_record [read $f $record_size] $i}
            if {[read $f 1] ne ""} {error "unexpected trailing bytes"}
        } finally {close $f}
        if {[file exists $output]} {error "output already exists"}
        file rename -- $partial $output
        catch {puts "records=$count unknown_fragments=$unknown_fragments resumed_records=[llength $stored] recovery_ms=[format %.3f [expr {$recovery_us/1000.0}]] token_ms=[format %.3f [expr {$token_us/1000.0}]] inference_ms=[format %.3f [expr {$infer_us/1000.0}]] total_ms=[format %.3f [expr {([clock microseconds]-$start)/1000.0}]] batch_sizes=[join $batch_counts ,]"}
    } finally {
        if {$in ne ""} {close $in}
        if {$out ne ""} {close $out}
        try {if {$handle ne ""} {embedding::free $handle}} finally {if {$loaded} {tokenizer::free}}
    }
}
if {[file normalize $argv0] eq [file normalize [info script]]} {
    if {[lindex $argv 0] eq "-verify"} {
        if {[llength $argv] ni {2 4} || ([llength $argv] == 4 && [lindex $argv 2] ne "-input")} {puts stderr "Error: usage -verify file ?-input fragments.jsonl?"; exit 1}
        set verify_input {}; if {[llength $argv] == 4} {set verify_input [lindex $argv 3]}
        if {[catch {::pipeline::verify_file [lindex $argv 1] $verify_input} message]} {puts stderr "Error: $message"; exit 1}
    } elseif {[catch {::pipeline::main {*}$argv} message]} {puts stderr "Error: $message"; exit 1}
}
