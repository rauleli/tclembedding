# Run with a tokenizer.json whose SHA-256 matches the fixture below.
package require Tcl 8.6
package require tokenizer 1.0.0
if {[llength $argv] != 1} { error "usage: tokenizer_test.tcl tokenizer.json" }
set model [lindex $argv 0]
set expected_sha 2c3387be76557bd40970cec13153b3bbf80407865484b209e655e5e4729076b8
if {[lindex [exec sha256sum -- $model] 0] ne $expected_sha} { error "unexpected tokenizer fixture hash" }
source [file join [file dirname [info script]] tokenizer_cases.tcl]
proc check {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}
check {[catch {tokenizer::tokenize hello}]} "tokenize before load must fail"
check {[catch {tokenizer::free}]} "free before load must fail"
tokenizer::load_vocab $model
set details [tokenizer::encode_details "café 😀"]
check {[lmap row $details {lindex $row 0}] eq [tokenizer::tokenize "café 😀"]} "detail IDs"
check {[lrange [lindex $details 1] 1 2] eq {0 5}} "byte offsets"
check {[lrange [lindex $details end] 1 3] eq {0 0 1}} "inserted special mask"
check {[catch {tokenizer::encode_details hola -max-length 1}]} "detail limit error"
check {[lmap row [tokenizer::encode_details hola] {lindex $row 0}] eq {0 739 143 2}} "detail recovery"
set count 0
foreach case $tokenizer_cases {
    lassign $case group limit hex expected
    set text [encoding convertfrom utf-8 [binary decode hex $hex]]
    if {$limit == 0} {
        set actual [tokenizer::tokenize $text]
    } else {
        set actual [tokenizer::tokenize $text -max-length $limit]
    }
    check {$actual eq $expected} "case $count ($group) differs: $actual != $expected"
    incr count
}
check {$count == 58} "expected 58 cases"
check {[catch {tokenizer::load_vocab /nonexistent/tokenizer.json}]} "missing file must fail"
check {[catch {tokenizer::load_vocab [file join [file dirname [info script]] invalid_tokenizer.json]}]} "corrupt configuration must fail"
if {[file exists /dev/null]} {
    check {[catch {tokenizer::load_vocab /dev/null}]} "empty configuration must fail"
}
check {[tokenizer::tokenize hola] eq {0 739 143 2}} "failed load replaced current model"
check {[catch {tokenizer::tokenize hola -max-length 1}]} "invalid model-specific limit must fail"
check {[tokenizer::tokenize hola -max-length 3] eq {0 739 2}} "truncation failed"
check {[tokenizer::tokenize hola] eq {0 739 143 2}} "truncation affected later calls"
foreach {limit expected} {
    2 {0 2} 3 {0 739 2} 128 {0 739 143 2}
    9223372036854775806 {0 739 143 2} 9223372036854775807 {0 739 143 2}
    0x7fffffffffffffff {0 739 143 2} 0x80 {0 739 143 2}
    +3 {0 739 2} 0b11 {0 739 2} 0o3 {0 739 2}
} {
    check {[tokenizer::tokenize hola -max-length $limit] eq $expected} "valid limit $limit changed IDs"
}
foreach limit {
    0 -1 -9223372036854775808 -9223372036854775809
    9223372036854775808 18446744073709551615 18446744073709551617
    -18446744073709551613 -18446744073709551488 -18446744073709551615
    -18446744073709551616 999999999999999999999999999999999
    0xffffffffffffffff 1.5 not-an-integer
} {
    check {[catch {tokenizer::tokenize hola -max-length $limit}]} "invalid limit $limit accepted"
    check {[tokenizer::tokenize hola] eq {0 739 143 2}} "handle changed after invalid limit $limit"
}
check {[catch {tokenizer::tokenize hola -max-length 1} message]} "limit 1 must fail"
check {$message eq "max_length is smaller than the required special tokens"} "limit 1 error changed"
check {[tokenizer::tokenize hola] eq {0 739 143 2}} "handle changed after limit 1"
set boundary_text "[string repeat {hola } 63]a"
set boundary_full [tokenizer::tokenize $boundary_text]
check {[llength $boundary_full] == 129} "boundary fixture is not 129 IDs"
set boundary_limited [tokenizer::tokenize $boundary_text -max-length 128]
check {[llength $boundary_limited] == 128 && [lindex $boundary_limited end] == 2} "boundary terminator was not retained"
check {$boundary_limited eq [concat [lrange $boundary_full 0 126] 2]} "boundary IDs differ"
check {[catch {tokenizer::tokenize hola -max-length 1}]} "short limit must fail"
check {[tokenizer::tokenize hola -max-length 3] eq {0 739 2}} "alternating limit failed"
check {[tokenizer::tokenize $boundary_text] eq $boundary_full} "default state changed after limits or error"
check {[catch {tokenizer::tokenize hola -unknown 4}]} "unknown option must fail"
check {[catch {tokenizer::tokenize [format %c 55296]}]} "unpaired surrogate must fail"
tokenizer::free
check {[catch {tokenizer::free}]} "double free must fail"
check {[catch {tokenizer::tokenize hola}]} "tokenize after free must fail"
tokenizer::load_vocab $model
check {[tokenizer::tokenize hola] eq {0 739 143 2}} "reload failed"
interp create child
interp eval child [list set auto_path $auto_path]
interp eval child {package require tokenizer 1.0.0}
interp eval child [list tokenizer::load_vocab $model]
check {[interp eval child {tokenizer::tokenize hola}] eq {0 739 143 2}} "child tokenizer failed"
check {[interp eval child {lmap row [tokenizer::encode_details hola] {lindex $row 0}}] eq {0 739 143 2}} "child details failed"
tokenizer::free
check {[interp eval child {tokenizer::tokenize hola}] eq {0 739 143 2}} "parent free affected child"
tokenizer::load_vocab $model
interp delete child
check {[tokenizer::tokenize hola] eq {0 739 143 2}} "child teardown affected parent"
for {set i 0} {$i < 10} {incr i} {
    check {[tokenizer::tokenize hola] eq {0 739 143 2}} "repeated tokenization failed"
}
tokenizer::free
for {set i 0} {$i < 3} {incr i} {
    tokenizer::load_vocab $model
    check {[tokenizer::tokenize hola] eq {0 739 143 2}} "repeated load failed"
    tokenizer::free
}
puts "tokenizer: $count cases passed; lifecycle and error checks passed"
