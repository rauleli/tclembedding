#!/usr/bin/env tclsh
# Token-aware, lossless fragmentation of extractor JSONL records.
package require Tcl 8.6
package require rl_json 0.15.7
namespace eval ::fragment {
    variable expected_tokenizer 0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39
    variable document_prefix "passage: "
    variable unknown_id 3
}
namespace import ::rl_json::json

proc ::fragment::next_boundary {text pos} {
    set n [string length $text]
    set c [scan [string index $text $pos] %c]
    if {$c >= 0xD800 && $c <= 0xDBFF} {
        if {$pos+1 >= $n} {error "unpaired Unicode surrogate"}
        set next [scan [string index $text [expr {$pos+1}]] %c]
        if {$next < 0xDC00 || $next > 0xDFFF} {error "unpaired Unicode surrogate"}
        return [expr {$pos+2}]
    }
    if {$c >= 0xDC00 && $c <= 0xDFFF} {error "unpaired Unicode surrogate"}
    return [expr {$pos+1}]
}
proc ::fragment::choose_boundary {text start ends budget scan_until_fit} {
    variable document_prefix
    set first [expr {[lsearch -sorted -integer -bisect $ends $start] + 1}]
    set size [llength $ends]; set offset 0; set step 1
    set best -1; set best_count 0
    while {$first + $offset < $size} {
        set end [lindex $ends [expr {$first + $offset}]]
        set candidate [string range $text $start [expr {$end-1}]]
        set ids [tokenizer::tokenize "$document_prefix$candidate"]
        set count [llength $ids]
        if {$count <= $budget} {
            set best $end; set best_count $count; set best_ids $ids
            incr offset $step
            set step [expr {$step * 2}]
        } elseif {$best >= 0} {
            break
        } elseif {$scan_until_fit} {
            incr offset
        } else {
            break
        }
    }
    if {$best < 0} {return {}}
    return [list $best $best_count $best_ids]
}
proc ::fragment::split_text {text budget} {
    variable document_prefix
    if {![string is entier -strict $budget] || $budget < 1 || $budget > 512} {error "token budget must be an integer from 1 to 512"}
    set length [string length $text]
    if {$length == 0} {error "text must not be empty"}
    # Validate boundaries even when the entire string fits in one fragment.
    set cursor 0; set boundaries {}; set natural {}
    while {$cursor < $length} {
        set cursor [next_boundary $text $cursor]
        lappend boundaries $cursor
        set tail [string index $text [expr {$cursor-1}]]
        if {[string is space $tail] || [string first $tail ".!?;:"] >= 0} {lappend natural $cursor}
    }
    set chunks {}; set start 0
    while {$start < $length} {
        # Token counts can be non-monotonic: test the entire remainder first.
        set remaining [string range $text $start end]
        set remaining_ids [tokenizer::tokenize "$document_prefix$remaining"]
        set remaining_count [llength $remaining_ids]
        if {$remaining_count <= $budget} {
            lappend chunks [list $start $length $remaining_count $remaining $remaining_ids]
            break
        }
        set chosen [choose_boundary $text $start $natural $budget 0]
        if {$chosen eq ""} {set chosen [choose_boundary $text $start $boundaries $budget 1]}
        if {$chosen eq ""} {error "remaining text cannot fit within token budget"}
        lassign $chosen last count ids
        if {$last <= $start} {error "fragmentation did not advance"}
        lappend chunks [list $start $last $count [string range $text $start [expr {$last-1}]] $ids]
        set start $last
    }
    return $chunks
}
proc ::fragment::max_nonspace_units {text} {
    set longest 0; set current 0
    foreach c [split $text ""] {
        if {[string is space -strict $c]} {set current 0} else {incr current [string length $c]}
        if {$current > $longest} {set longest $current}
    }
    return $longest
}
proc ::fragment::required_string {record name} {
    if {![json exists $record $name] || [json type $record $name] ne "string"} {error "invalid string field: $name"}
    set value [json get $record $name]
    if {$value eq ""} {error "empty field: $name"}
    return $value
}
proc ::fragment::required_index {record name} {
    if {![json exists $record $name] || [json type $record $name] ne "number"} {error "invalid integer field: $name"}
    set value [json get $record $name]
    if {![string is entier -strict $value] || $value < 0} {error "invalid integer field: $name"}
    return $value
}
proc ::fragment::process {in out source_id input_hash budget} {
    variable expected_tokenizer
    variable unknown_id
    if {[string trim $source_id] eq ""} {error "source ID must not be empty"}
    if {![regexp {^[0-9a-f]{64}$} $input_hash]} {error "invalid input SHA-256"}
    if {![string is entier -strict $budget] || $budget < 1 || $budget > 512} {error "token budget must be an integer from 1 to 512"}
    set budget [expr {$budget + 0}]
    array set seen {}; set records 0; set fragments 0
    while {[gets $in line] >= 0} {
        if {![json valid $line] || [json type $line] ne "object"} {error "invalid JSONL record"}
        set version [required_string $line version]
        if {$version ne "1"} {error "unsupported extractor version"}
        set source [required_string $line source]
        set conv [required_string $line conversation_id]
        set node [required_string $line node_id]
        set message [required_string $line message_id]
        set role [required_string $line role]
        if {$role ni {user assistant}} {error "invalid role"}
        set position [required_index $line position]
        set part [required_index $line part]
        set text [required_string $line text]
        if {[lsearch -exact [json keys $line] create_time] < 0} {error "missing timestamp field"}
        set time_type [json type $line create_time]
        if {$time_type ni {string number null}} {error "invalid timestamp field"}
        set timestamp [json extract $line create_time]
        set key [list $source $conv $node $part]
        if {[info exists seen($key)]} {error "duplicate provenance key in input"}
        set seen($key) 1
        set index 0
        foreach piece [split_text $text $budget] {
            lassign $piece start end token_count chunk ids
            set unk_count 0
            foreach id $ids {if {$id == $unknown_id} {incr unk_count}}
            set max_run [max_nonspace_units $chunk]
            set row [format {{"fragment_version":"2","input_source_id":%s,"input_sha256":%s,"tokenizer_sha256":%s,"token_budget":%s,"extractor_version":%s,"source":%s,"conversation_id":%s,"node_id":%s,"message_id":%s,"role":%s,"position":%s,"create_time":%s,"part":%s,"fragment_index":%d,"char_start":%d,"char_end":%d,"token_count":%d,"unk_id":%d,"unk_count":%d,"content_token_count":null,"max_nonspace_tcl_units":%d,"text":%s}} \
                [json string $source_id] [json string $input_hash] [json string $expected_tokenizer] $budget [json string $version] [json string $source] [json string $conv] [json string $node] [json string $message] [json string $role] $position $timestamp $part $index $start $end $token_count $unknown_id $unk_count $max_run [json string $chunk]]
            puts $out $row
            incr index; incr fragments
        }
        incr records
    }
    return [list $records $fragments]
}
proc ::fragment::main {args} {
    array set opt {-input {} -output {} -source-id {} -tokenizer {} -budget 512}
    if {[llength $args] % 2} {error "options require values"}
    foreach {key value} $args {if {![info exists opt($key)]} {error "unknown option"}; set opt($key) $value}
    foreach key {-input -output -source-id -tokenizer} {if {[string trim $opt($key)] eq ""} {error "missing required option: $key"}}
    if {![string is entier -strict $opt(-budget)] || $opt(-budget) < 1 || $opt(-budget) > 512} {error "token budget must be an integer from 1 to 512"}
    if {![file isfile $opt(-input)] || ![file readable $opt(-input)]} {error "input must be a readable file"}
    if {[file exists $opt(-output)]} {error "output already exists"}
    set output [file normalize $opt(-output)]
    set root [file normalize [file join [file dirname [info script]] .. ..]]
    if {$output eq $root || [string first "$root/" $output] == 0} {error "output must be outside the source tree"}
    package require sha256
    variable expected_tokenizer
    if {[::sha2::sha256 -hex -filename $opt(-tokenizer)] ne $expected_tokenizer} {error "tokenizer hash does not match the characterized E5 artifact"}
    set input_hash [::sha2::sha256 -hex -filename $opt(-input)]
    package require tokenizer 1.0.0
    set loaded 0; set in {}; set out {}
    try {
        tokenizer::load_vocab $opt(-tokenizer); set loaded 1
        set in [open $opt(-input) r]; fconfigure $in -encoding utf-8 -translation lf
        set out [file tempfile partial [file join [file dirname $output] .fragment-partial]]
        fconfigure $out -encoding utf-8 -translation lf
        lassign [process $in $out $opt(-source-id) $input_hash $opt(-budget)] records fragments
        close $out; set out {}
        close $in; set in {}
        if {[::sha2::sha256 -hex -filename $opt(-input)] ne $input_hash} {error "input changed during fragmentation"}
        tokenizer::free; set loaded 0
        file rename -- $partial $output
        catch {puts "records=$records fragments=$fragments"}
    } finally {
        if {$out ne ""} {close $out}
        if {$in ne ""} {close $in}
        if {$loaded} {tokenizer::free}
    }
}
if {[file normalize $argv0] eq [file normalize [info script]]} {
    if {[catch {::fragment::main {*}$argv} message]} {
        puts stderr "Fragmentation failed; no completed output was published. Inspect inputs and partial files privately."
        exit 1
    }
}
