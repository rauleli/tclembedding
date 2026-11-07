# Fixed synthetic transport experiment; the production prompt remains unchanged.
source [file join [file dirname [file normalize [info script]]] rag.tcl]
set question {When does the fictional workshop open?}
set hit [list 0.9 0 {The fictional workshop opens at 9.} synthetic synthetic synthetic synthetic synthetic synthetic user 0 null 0 0 0 33 intfloat/multilingual-e5-small]
set selected [::evidence::select [list $hit] 1 1000]
set model gemma3:1b
::evidence::local_model 11434 $model 3000 5000
set original [::evidence::request $question $selected $model 256]
set system [json get $original messages 0 content]
set user [json get $original messages 1 content]
set stronger "$system End your factual answer with the exact citation \[S1\]."
set msg1 [json object role {string system} content [list string $stronger]]
set msg2 [json object role {string user} content [list string $user]]
set messages [json array [list json $msg1] [list json $msg2]]
set variant [json object model [list string $model] messages [list json $messages] stream {boolean 0} options [list json [json object num_predict {number 256}]]]
foreach {label payload} [list original $original explicit $variant] {
    set start [clock milliseconds]
    if {[catch {::evidence::http POST 11434 /api/chat $payload 3000 120000} response]} {puts [list variant $label error $response]; continue}
    set elapsed [expr {[clock milliseconds]-$start}]
    if {[catch {json get $response done_reason} reason]} {set reason missing}
    if {[catch {json get $response message content} content]} {set content missing}
    set status [catch {::evidence::answer $response $selected} detail]
    puts [list variant $label milliseconds $elapsed done_reason $reason accepted [expr {!$status}] response $content diagnostic $detail]
}
