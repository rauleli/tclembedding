# Complete E5 and SQLite native path with a simulated local generator.
if {[llength $argv] != 5} {error "usage: integration_test.tcl synthetic-db extension model tokenizer corpus"}
lassign $argv database extension model tokenizer corpus
source [file join [file dirname [file normalize [info script]]] rag.tcl]
rename ::evidence::http ::evidence::http_real
set ::chat_seen 0
proc ::evidence::http {method port path body connect_ms response_ms} {
    if {$path eq "/api/tags"} {return {{"models":[{"name":"fixture"}]}}}
    if {$path ne "/api/chat" || $method ne "POST" || ![json valid $body]} {error "unexpected request"}
    if {[json get $body messages 0 role] ne "system" || [json get $body messages 1 role] ne "user"} {error "incorrect role separation"}
    set message [json get $body messages 1 content]
    if {[string first {"id":"S1"} $message] < 0 || [string first {"evidence"} $message] < 0} {error "missing evidence in actual request"}
    set ::chat_seen 1
    return {{"done":true,"message":{"role":"assistant","content":"Synthetic response [S1]."}}}
}
::evidence::run sqlite-native [list $database $extension] $corpus $model $tokenizer {maintenance} 2 5000 11434 fixture 128 1000 1000
if {!$::chat_seen} {error "chat was not called"}
puts "E5 to native SQLite to simulated generator integration passed"
