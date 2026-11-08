# Synthetic requests for explicitly selected local models; no retries.
if {[llength $argv] ni {1 2}} {error "usage: mistral_experiment.tcl /path/outside/repository/output.jsonl ?model?"}
set root [file dirname [file normalize [info script]]]
source [file join $root structured.tcl]
set repo [file normalize [file join $root .. ..]]
set path [file normalize [lindex $argv 0]]
if {$path eq $repo || [string first "$repo/" $path] == 0} {error "output must be outside the source tree"}
namespace eval ::mistral_lab {variable server_peak 0; variable runner_peak 0; variable swap_peak 0; variable available_min -1; variable samples 0; variable timer {}}
proc ::mistral_lab::memory {} {
    set server 0; set runner 0; set available -1; set total -1; set free -1
    if {![catch {exec ps -C ollama -o rss=,args=} rows]} {
        foreach line [split $rows \n] {
            if {![regexp {^\s*([0-9]+)\s+(.*)$} $line -> rss args]} continue
            if {[string match {*ollama serve*} $args]} {incr server $rss}
            if {[string match {*ollama runner*} $args]} {incr runner $rss}
        }
    } else {set server -1; set runner -1}
    set f [open /proc/meminfo r]
    try {
        while {[gets $f line] >= 0} {
            if {[regexp {^MemAvailable:\s+([0-9]+)} $line -> n]} {set available $n}
            if {[regexp {^SwapTotal:\s+([0-9]+)} $line -> n]} {set total $n}
            if {[regexp {^SwapFree:\s+([0-9]+)} $line -> n]} {set free $n}
        }
    } finally {close $f}
    set swap -1; if {$total >= 0 && $free >= 0} {set swap [expr {$total-$free}]}
    return [list $server $runner $available $swap]
}
proc ::mistral_lab::sample {} {
    variable server_peak; variable runner_peak; variable swap_peak; variable available_min; variable samples; variable timer
    lassign [memory] server runner available swap
    if {$server > $server_peak} {set server_peak $server}
    if {$runner > $runner_peak} {set runner_peak $runner}
    if {$swap > $swap_peak} {set swap_peak $swap}
    if {$available >= 0 && ($available_min < 0 || $available < $available_min)} {set available_min $available}
    incr samples; set timer [after 5000 ::mistral_lab::sample]
}
proc ::mistral_lab::hit {id text} {return [list 0.9 $id $text synthetic synthetic synthetic conversation node$id message$id user $id null 0 0 0 [string length $text] synthetic-model]}
set model [lindex $argv 1]; if {$model eq ""} {set model mistral:7b-instruct}
switch -- $model {
    mistral:7b-instruct {set expected_digest f974a74358d62a017b37c6f424fcdf2744ca02926c4f952513ddf474b2fa5091; set origin mistral_7b; set timeout_ms 900000}
    deepseek-r1:7b {set expected_digest 0a8c266910232fd3291e71e5ba1e058cc5af9d411192cf88b6d30e92b6e73163; set origin deepseek_7b; set timeout_ms 900000}
    gpt-oss:20b {set expected_digest f2b8351c629c005bd3f0a0e3046f905afcbffede19b648e4bd7c884cdfd63af6; set origin gpt_oss_20b; set timeout_ms 1200000}
    default {error "unsupported model selection"}
}
::evidence::local_model 11434 $model 3000 5000
set tags [::evidence::http GET 11434 /api/tags {} 3000 5000]; set digest {}
for {set i 0} {$i < [json length [json extract $tags models]]} {incr i} {if {[json get $tags models $i name] eq $model} {set digest [json get $tags models $i digest]; break}}
if {$digest ne $expected_digest} {error "unexpected model digest"}
set a [::mistral_lab::hit 1 {The fictional workshop opens at 9.}]
set b [::mistral_lab::hit 2 {The fictional workshop opens at 10.}]
set cases [list [list explicit {When does the workshop open?} [list $a]] [list absent {When does the workshop close?} [list $a]] [list contradiction {When does the workshop open?} [list $a $b]]]
if {$model eq "gpt-oss:20b"} {set cases [lrange $cases 0 0]}
set out [open $path {WRONLY CREAT EXCL} 0600]; fconfigure $out -encoding utf-8 -translation lf
try {
 foreach case $cases {
    lassign $case label question hits
    set selected [::evidence::select $hits 2 1000]
    set body [::structured::request $question $selected $model 192]
    json set body options [json object num_predict {number 192} temperature {number 0}]
    set ::mistral_lab::server_peak 0; set ::mistral_lab::runner_peak 0; set ::mistral_lab::swap_peak 0; set ::mistral_lab::available_min -1; set ::mistral_lab::samples 0
    lassign [::mistral_lab::memory] before_server before_runner before_available before_swap
    ::mistral_lab::sample
    puts [list starting $label]; flush stdout
    set start [clock milliseconds]; set code 0; set transport {}; set response {}
    if {[catch {set t [::http::geturl http://localhost:11434/api/chat -headers {Connection close} -type application/json -query [encoding convertto utf-8 $body] -timeout $timeout_ms]} why]} {set transport failed} else {
        try {set code [::http::ncode $t]; set transport [::http::status $t]; set response [::http::data $t]} finally {::http::cleanup $t}
        if {![string is integer -strict $code]} {set code 0}
    }
    set elapsed [expr {[clock milliseconds]-$start}]
    after cancel $::mistral_lab::timer
    lassign [::mistral_lab::memory] after_server after_runner after_available after_swap
    set structural invalid; set diagnostic request_failed
    if {$transport eq "ok" && $code == 200} {if {[catch {::structured::validate $response $selected} v]} {set diagnostic $v} else {set structural [lindex $v 0]; set diagnostic accepted}}
    set evidence {}; foreach item $selected {lappend evidence [list string $item]}
    set fields [list origin [list string $origin] kind {string model} case [list string $label] model [list string $model] model_digest [list string $digest] corpus {string synthetic} evidence [list json [json array {*}$evidence]] request [list json $body] http [list number $code] transport [list string $transport] elapsed_ms [list number $elapsed] structural [list string $structural] diagnostic [list string $diagnostic] server_before_kib [list number $before_server] runner_before_kib [list number $before_runner] available_before_kib [list number $before_available] swap_before_kib [list number $before_swap] server_sampled_max_kib [list number $::mistral_lab::server_peak] runner_sampled_max_kib [list number $::mistral_lab::runner_peak] available_sampled_min_kib [list number $::mistral_lab::available_min] swap_sampled_max_kib [list number $::mistral_lab::swap_peak] server_after_kib [list number $after_server] runner_after_kib [list number $after_runner] available_after_kib [list number $after_available] swap_after_kib [list number $after_swap] rss_samples [list number $::mistral_lab::samples]]
    if {$response ne "" && [json valid $response]} {lappend fields response [list json $response]}
    puts $out [json object {*}$fields]; flush $out
    puts [list result $label http $code transport $transport elapsed_ms $elapsed structural $structural diagnostic $diagnostic memory_before [list $before_server $before_runner $before_available $before_swap] memory_sampled [list $::mistral_lab::server_peak $::mistral_lab::runner_peak $::mistral_lab::available_min $::mistral_lab::swap_peak] memory_after [list $after_server $after_runner $after_available $after_swap]]
    if {$response ne "" && [json valid $response] && ![catch {json get $response message content} content]} {puts [list generated $content]}; flush stdout
    if {$transport ne "ok" || $code != 200} {puts "Stopping after transport or HTTP failure; subsequent cases were not run."; break}
    if {$before_swap >= 0 && $::mistral_lab::swap_peak - $before_swap > 1048576} {puts "Stopping after sampled swap increased by more than 1 GiB."; break}
 }
} finally {close $out}
