# Validate the public synthetic observations without invoking a model or database.
package require rl_json
package require sha256
namespace import ::rl_json::json
set root [file dirname [file normalize [info script]]]
source [file join $root structured.tcl]
if {[llength $argv] > 1} {error "usage: legacy_observations_test.tcl ?observations.jsonl?"}
if {[llength $argv]} {set path [lindex $argv 0]} else {set path [file join $root .. .. docs legacy_hardware_observations.jsonl]}
set bf [open $path rb]
try {set bytes [read $bf]} finally {close $bf}
set end -1
for {set i 0} {$i < 13} {incr i} {
    set end [string first "\n" $bytes [expr {$end+1}]]
    if {$end < 0} {error "missing historical record"}
}
if {[::sha2::sha256 -hex [string range $bytes 0 $end]] ne "22334339b9d8bf892329f362d49be4b96e9c574f6b6c4ff5d96dd695f3b7d332"} {error "historical records changed"}
set f [open $path r]; fconfigure $f -encoding utf-8
set count 0
try {
 while {[gets $f row] >= 0} {
    if {![json valid $row]} {error "invalid JSONL"}
    if {$count >= 13} {
        set expected_cases {{mistral:7b-instruct explicit} {mistral:7b-instruct absent} {mistral:7b-instruct contradiction} {deepseek-r1:7b explicit} {deepseek-r1:7b absent} {deepseek-r1:7b contradiction} {gpt-oss:20b explicit}}
        if {[list [json get $row model] [json get $row case]] ne [lindex $expected_cases [expr {$count-13}]]} {error "unexpected added observation"}
    }
    set request [json extract $row request]
    if {[json get $request stream] != 0 || [json get $request options temperature] != 0 || [json get $request options num_predict] != 192} {error "unexpected request configuration"}
    set message [json get $request messages 1 content]
    set split [string first \n $message]
    if {$split < 0} {error "missing structured context"}
    set context [string range $message [expr {$split+1}] end]
    if {![json valid $context] || [json type $context evidence] ne "array"} {error "invalid evidence context"}
    set selected {}
    set n [json length [json extract $context evidence]]
    for {set i 0} {$i < $n} {incr i} {lappend selected [list [json get $context evidence $i id] {}]}
    if {[catch {json extract $row response} response]} {
        if {[json get $row structural] ne "invalid" || ([json get $row http] == 200 && [json get $row transport] eq "ok")} {error "missing response without an error"}
        incr count; continue
    }
    set message [json object role [list string [json get $response role]] content [list string [json get $response content]]]
    set envelope [json object done [list boolean [json get $response done]] done_reason [list string [json get $response done_reason]] message [list json $message]]
    if {[catch {::structured::validate $envelope $selected} result]} {set actual invalid} else {set actual [lindex $result 0]}
    if {![catch {json get $row structural} expected] && $actual ne $expected} {error "structural result mismatch"}
    incr count
 }
} finally {close $f}
if {$count != 20} {error "unexpected observation count"}
puts "Validated $count synthetic observations and request settings; original 13-record digest is unchanged"
