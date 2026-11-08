# Synthetic E5 and native SQLite retrieval with a simulated structured generator.
if {[llength $argv] != 4} {error "usage: structured_integration_test.tcl synthetic-db extension model tokenizer"}
lassign $argv database extension model tokenizer
source [file join [file dirname [file normalize [info script]]] structured.tcl]
set corpus 70ade3bb43add618812b62b83582d8279d702ac2d2e4e08c0b5c839ec3a92f57
rename ::evidence::http ::evidence::http_real
set ::saw_chat 0
proc ::evidence::http {method port path body connect response} {
    if {$path eq "/api/tags"} {return {{"models":[{"name":"fixture"}]}}}
    if {$path ne "/api/chat" || [json type $body format] ne "object" || [json get $body messages 1 role] ne "user"} {error "invalid simulated request"}
    set user [json get $body messages 1 content]
    if {[string first {"id":"S1"} $user] < 0} {error "missing evidence"}
    set ::saw_chat 1
    set content {{"status":"answered","answer":"Synthetic answer.","citations":["S1"]}}
    return [json object done {boolean 1} message [list json [json object role {string assistant} content [list string $content]]]]
}
::structured::run sqlite-native [list $database $extension] $corpus $model $tokenizer maintenance 2 5000 11434 fixture 128 1000 1000
if {!$::saw_chat} {error "generator not called"}
puts "Structured E5 native SQLite simulated integration passed"
