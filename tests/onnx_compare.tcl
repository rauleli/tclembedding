# Laboratory-only Tcl path. Input is max-length and UTF-8 hex, separated by a tab.
package require Tcl 8.6
package require tokenizer 1.0.0
package require tclembedding 1.0
if {[llength $argv] != 2} {error "usage: onnx_compare.tcl tokenizer.json model.onnx"}
tokenizer::load_vocab [lindex $argv 0]
set handle [embedding::init_raw [lindex $argv 1]]
while {[gets stdin line] >= 0} {
    lassign [split $line "\t"] limit hex
    set text [encoding convertfrom utf-8 [binary decode hex $hex]]
    if {$limit} {set ids [tokenizer::tokenize $text -max-length $limit]} else {set ids [tokenizer::tokenize $text]}
    set vector [embedding::compute $handle $ids]
    puts "[join $ids ,]\t[join $vector ,]"
    flush stdout
}
embedding::free $handle
tokenizer::free
