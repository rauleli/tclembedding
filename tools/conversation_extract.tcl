#!/usr/bin/env tclsh
# Deterministic, text-only extraction from two explicitly selected exports.
package require Tcl 8.6
package require rl_json 0.15.7
namespace import ::rl_json::json

proc require_string {obj key} {
    if {![json exists $obj $key] || [json type $obj $key] ne "string"} {
        error "missing or invalid required string field: $key"
    }
    return [json get $obj $key]
}
proc extract_file {path out statsName} {
    upvar 1 $statsName stats
    set source [file tail $path]
    set f [open $path r]
    fconfigure $f -encoding utf-8 -translation lf
    try {set raw [read $f]} finally {close $f}
    if {[json type $raw] ne "array"} {error "export root must be an array"}
    set parsed $raw
    unset raw
    json foreach conv $parsed {
        if {[json type $conv] ne "object"} {error "conversation must be an object"}
        set conversation [require_string $conv id]
        set current [require_string $conv current_node]
        if {![json exists $conv mapping] || [json type $conv mapping] ne "object"} {error "invalid mapping"}
        set mapping [json extract $conv mapping]
        unset -nocomplain seen
        array set seen {}
        set path_nodes {}
        while {1} {
            if {[info exists seen($current)]} {error "cycle in active path"}
            set seen($current) 1
            if {![json exists $mapping $current] || [json type $mapping $current] ne "object"} {error "missing active node"}
            set node [json extract $mapping $current]
            if {[require_string $node id] ne $current} {error "node ID does not match mapping key"}
            lappend path_nodes $current
            if {[lsearch -exact [json keys $node] parent] < 0} {error "node has no parent field"}
            set ptype [json type $node parent]
            if {$ptype eq "null"} break
            if {$ptype ne "string"} {error "invalid parent field"}
            set current [json get $node parent]
        }
        incr stats(conversations)
        set position 0
        foreach current [lreverse $path_nodes] {
            set node [json extract $mapping $current]
            incr stats(nodes)
            if {[lsearch -exact [json keys $node] message] < 0} {error "node has no message field"}
            if {[json type $node message] eq "null"} {incr stats(structural); incr position; continue}
            if {[json type $node message] ne "object"} {error "invalid message"}
            set msg [json extract $node message]
            incr stats(messages)
            set message [require_string $msg id]
            if {$message ne $current} {error "message ID does not match node"}
            if {![json exists $msg author] || [json type $msg author] ne "object"} {incr stats(excluded_role); incr position; continue}
            set author [json extract $msg author]
            if {![json exists $author role] || [json type $author role] ne "string"} {incr stats(excluded_role); incr position; continue}
            set role [json get $author role]
            if {$role ni {user assistant}} {incr stats(excluded_role); incr position; continue}
            if {![json exists $msg content] || [json type $msg content] ne "object"} {incr stats(excluded_content); incr stats(excluded_other); incr position; continue}
            set content [json extract $msg content]
            if {![json exists $content content_type] || [json type $content content_type] ne "string"} {
                incr stats(excluded_content); incr stats(excluded_other); incr position; continue
            }
            set kind [json get $content content_type]
            if {$kind ne "text"} {
                incr stats(excluded_content)
                switch -- $kind {
                    thoughts {incr stats(excluded_thoughts)}
                    reasoning_recap {incr stats(excluded_reasoning)}
                    multimodal_text {incr stats(excluded_multimodal)}
                    default {incr stats(excluded_other)}
                }
                incr position; continue
            }
            if {![json exists $content parts] || [json type $content parts] ne "array"} {incr stats(excluded_parts); incr position; continue}
            set timestamp null
            if {[json exists $msg create_time]} {
                set time_type [json type $msg create_time]
                if {$time_type in {number string null}} {set timestamp [json extract $msg create_time]} else {error "invalid message timestamp"}
            }
            set emitted 0
            set index 0
            set parts [json extract $content parts]
            json foreach part $parts {
                if {[json type $part] ne "string"} {incr stats(nonstring_parts); incr index; continue}
                set text [json get $part]
                if {[string trim $text] eq ""} {incr stats(empty_parts); incr index; continue}
                # Exclude entire parts containing known attachment URI schemes.
                if {[regexp -nocase {file-service://|sandbox:/|attachment://|sediment://} $text]} {
                    incr stats(reference_parts); incr index; continue
                }
                set row [format {{"version":"1","source":%s,"conversation_id":%s,"node_id":%s,"message_id":%s,"position":%d,"role":%s,"create_time":%s,"part":%d,"text":%s}} \
                    [json string $source] [json string $conversation] [json string $current] [json string $message] $position [json string $role] $timestamp $index [json string $text]]
                puts $out $row
                incr stats(records)
                incr stats(chars) [string length $text]
                incr stats(utf8_bytes) [string length [encoding convertto utf-8 $text]]
                set emitted 1
                incr index
            }
            if {$emitted} {incr stats(extracted_messages)} else {incr stats(no_text)}
            incr position
        }
    }
}
proc main {argv} {
    if {[llength $argv] != 3} {error "usage: conversation_extract.tcl conversations-000.json conversations-001.json output.jsonl"}
    lassign $argv first second output
    if {[file tail $first] ne "conversations-000.json" || [file tail $second] ne "conversations-001.json"} {error "input names or order are invalid"}
    if {[file normalize $output] in [list [file normalize $first] [file normalize $second]]} {error "output must differ from inputs"}
    array set stats {conversations 0 nodes 0 structural 0 messages 0 excluded_role 0 excluded_content 0 excluded_thoughts 0 excluded_reasoning 0 excluded_multimodal 0 excluded_other 0 excluded_parts 0 no_text 0 nonstring_parts 0 empty_parts 0 reference_parts 0 records 0 extracted_messages 0 chars 0 utf8_bytes 0}
    set out [open $output {WRONLY CREAT EXCL} 0600]
    fconfigure $out -encoding utf-8 -translation lf
    try {
        extract_file $first $out stats
        extract_file $second $out stats
    } finally {close $out}
    foreach key {conversations nodes structural messages excluded_role excluded_content excluded_thoughts excluded_reasoning excluded_multimodal excluded_other excluded_parts no_text nonstring_parts empty_parts reference_parts records extracted_messages chars utf8_bytes} {puts "$key=$stats($key)"}
}
if {[catch {main $argv} problem]} {
    # Avoid displaying paths, identifiers or source text on malformed private input.
    puts stderr "Extraction failed; output may be incomplete. Inspect input and output privately."
    exit 1
}
