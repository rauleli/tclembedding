# Synthetic legacy-hardware experiment; output goes to a new external file.
if {[llength $argv] ni {5 6}} {error "usage: legacy_experiment.tcl database extension e5-model tokenizer output.jsonl ?integration-only?"}
lassign $argv database extension model tokenizer output mode
if {$mode ni {{} integration-only}} {error "invalid experiment mode"}
set root [file dirname [file normalize [info script]]]
source [file join $root structured.tcl]
set repo [file normalize [file join $root .. ..]]
set output [file normalize $output]
if {$output eq $repo || [string first "$repo/" $output] == 0} {error "output must be outside the source tree"}
set out [open $output {WRONLY CREAT EXCL} 0600]
fconfigure $out -encoding utf-8 -translation lf
namespace eval ::legacy {variable server_peak 0; variable runner_peak 0; variable timer {}; variable samples 0}
proc ::legacy::rss {} {
    set server 0; set runner 0
    if {[catch {exec ps -C ollama -o rss=,args=} lines]} {return [list 0 0]}
    foreach line [split $lines \n] {
        if {![regexp {^\s*([0-9]+)\s+(.*)$} $line -> rss args]} continue
        if {[string match {*ollama serve*} $args]} {incr server $rss}
        if {[string match {*ollama runner*} $args]} {incr runner $rss}
    }
    return [list $server $runner]
}
proc ::legacy::sample {} {
    variable server_peak; variable runner_peak; variable timer; variable samples
    lassign [rss] server runner
    if {$server > $server_peak} {set server_peak $server}
    if {$runner > $runner_peak} {set runner_peak $runner}
    incr samples
    set timer [after 5000 ::legacy::sample]
}
proc ::legacy::record {out kind label gen question selected corpus digest} {
    variable server_peak; variable runner_peak; variable timer; variable samples
    set body [::structured::request $question $selected $gen 192]
    json set body options [json object num_predict {number 192} temperature {number 0}]
    set server_peak 0; set runner_peak 0; set samples 0
    lassign [rss] before_server before_runner
    sample
    set started [clock milliseconds]
    set code 0; set error_text {}; set response {}; set transport {}
    if {[catch {set token [::http::geturl http://localhost:11434/api/chat -headers {Connection close} -type application/json -query [encoding convertto utf-8 $body] -timeout 600000]} transport]} {
        set error_text transport_failure
    } else {
        try {set code [::http::ncode $token]; set transport [::http::status $token]; set response [::http::data $token]} finally {::http::cleanup $token}
        if {![string is integer -strict $code]} {set code 0}
    }
    set elapsed [expr {[clock milliseconds]-$started}]
    after cancel $timer; set timer {}
    lassign [rss] after_server after_runner
    set structural invalid; set diagnostic request_failed
    if {$error_text eq "" && $transport eq "ok" && $code == 200} {
        if {[catch {::structured::validate $response $selected} validated]} {set diagnostic $validated} else {set structural [lindex $validated 0]; set diagnostic accepted}
    }
    set evidence {}
    foreach item $selected {lappend evidence [list string $item]}
    set fields [list kind [list string $kind] case [list string $label] model [list string $gen] model_digest [list string $digest] corpus [list string $corpus] evidence [list json [json array {*}$evidence]] request [list json $body] http [list number $code] transport [list string $transport] elapsed_ms [list number $elapsed] structural [list string $structural] diagnostic [list string $diagnostic] server_before_kib [list number $before_server] runner_before_kib [list number $before_runner] server_sampled_max_kib [list number $server_peak] runner_sampled_max_kib [list number $runner_peak] server_after_kib [list number $after_server] runner_after_kib [list number $after_runner] rss_samples [list number $samples]]
    if {$response ne "" && [json valid $response]} {lappend fields response [list json $response]}
    puts $out [json object {*}$fields]; flush $out
    puts [list result $label model $gen http $code transport $transport elapsed_ms $elapsed status $structural diagnostic $diagnostic sampled_server_kib $server_peak sampled_runner_kib $runner_peak samples $samples]
    if {$response ne "" && [json valid $response] && ![catch {json get $response message content} content]} {puts [list generated $content]}
    flush stdout
    return [expr {$error_text eq "" && $transport eq "ok" && $code == 200}]
}
proc ::legacy::hit {id text} {return [list 0.9 $id $text synthetic synthetic synthetic conversation node$id message$id user $id null 0 0 0 [string length $text] synthetic-model]}
set tags [::evidence::http GET 11434 /api/tags {} 3000 5000]
proc ::legacy::digest {tags name} {
    for {set i 0} {$i < [json length [json extract $tags models]]} {incr i} {if {[json get $tags models $i name] eq $name} {return [json get $tags models $i digest]}}
    error "missing model"
}
set corpus 70ade3bb43add618812b62b83582d8279d702ac2d2e4e08c0b5c839ec3a92f57
try {
    set required_models {llama3.2:3b}
    if {$mode ne "integration-only"} {lappend required_models qwen3:1.7b phi4-mini:3.8b}
    foreach gen $required_models {::evidence::local_model 11434 $gen 3000 5000}
    set question {What is the subject of these documents?}
    puts "starting integration E5 and native SQLite"; flush stdout
    set start [clock milliseconds]
    set hits [::evidence::retrieve sqlite-native [list $database $extension] $corpus $model $tokenizer $question 1]
    set selected [::evidence::select $hits 1 1000]
    if {[llength $selected] != 1} {error "synthetic integration evidence not available"}
    puts [list retrieval_ms [expr {[clock milliseconds]-$start}] selected $selected]; flush stdout
    ::legacy::record $out integration e5_sqlite llama3.2:3b $question $selected $corpus [::legacy::digest $tags llama3.2:3b]
    set a [::legacy::hit 1 {The fictional workshop opens at 9.}]
    set b [::legacy::hit 2 {The fictional workshop opens at 10.}]
    set cases [list [list explicit {When does the workshop open?} [list $a]] [list absent {When does the workshop close?} [list $a]] [list contradiction {When does the workshop open?} [list $a $b]]]
    if {$mode ne "integration-only"} {foreach gen {qwen3:1.7b phi4-mini:3.8b} {
        foreach case $cases {
            lassign $case label q hits
            puts [list starting model $gen case $label]; flush stdout
            set selected [::evidence::select $hits 2 1000]
            if {![::legacy::record $out model $label $gen $q $selected synthetic [::legacy::digest $tags $gen]]} {puts [list stopping_model $gen]; break}
        }
    }}
} finally {close $out}
