# Three fixed synthetic cases, no retries and no corpus or models downloaded.
source [file join [file dirname [file normalize [info script]]] structured.tcl]
proc synthetic_hit {id text} {return [list 0.9 $id $text synthetic synthetic synthetic conversation node$id message$id user $id null 0 0 0 [string length $text] synthetic-model]}
set a [synthetic_hit 1 {The fictional workshop opens at 9.}]
set b [synthetic_hit 2 {The fictional workshop opens at 10.}]
set cases [list [list explicit {When does the workshop open?} [list $a]] [list absent {When does the workshop close?} [list $a]] [list contradiction {When does the workshop open?} [list $a $b]]]
set model gemma3:1b
::evidence::local_model 11434 $model 3000 5000
foreach case $cases {
    lassign $case name question hits
    set selected [::evidence::select $hits 2 1000]
    set request [::structured::request $question $selected $model 192]
    set start [clock milliseconds]
    if {[catch {::evidence::http POST 11434 /api/chat $request 3000 120000} response]} {puts [list case $name elapsed_ms [expr {[clock milliseconds]-$start}] request_error $response]; continue}
    set elapsed [expr {[clock milliseconds]-$start}]
    if {[catch {json get $response done_reason} reason]} {set reason unavailable}
    if {[catch {json get $response message content} content]} {set content unavailable}
    set failed [catch {::structured::validate $response $selected} result]
    puts [list case $name http 200 elapsed_ms $elapsed done_reason $reason output $content structural [expr {$failed ? "invalid" : [lindex $result 0]}] detail $result]
}
