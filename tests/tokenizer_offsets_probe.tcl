package require tokenizer 1.0.0
if {[llength $argv] != 5} {
  error "usage: tokenizer_offsets_probe.tcl tokenizer prefix budget normal|unknown unknown_id"
}
lassign $argv path prefix budget mode unknown_id
source [file join [file dirname [info script]] .. examples 03-chatgpt-export fragment.tcl]
set ::fragment::document_prefix $prefix
tokenizer::load_vocab $path
if {$mode eq "unknown"} {
  set text [string repeat x 101]
} else {
  set text [string range [string repeat {Manual ficticio. Restart device.  Review network. } 120] 0 4999]
}
rename ::tokenizer::tokenize ::tokenizer::real_tokenize
rename ::tokenizer::encode_details ::tokenizer::real_details
set ::calls 0
set ::units 0

# Tokenize or instrument text for the test fixture.
proc ::tokenizer::tokenize {s args} {
  incr ::calls
  incr ::units [string length $s]
  tailcall ::tokenizer::real_tokenize $s {*}$args
}

# Provide controlled token details for the test.
proc ::tokenizer::encode_details {s args} {
  incr ::calls
  incr ::units [string length $s]
  tailcall ::tokenizer::real_details $s {*}$args
}

set t [clock microseconds]
set base [::fragment::split_text $text $budget]
puts "existing calls=$::calls units=$::units fragments=[llength $base] ms=[expr {([clock microseconds]-$t)/1000.0}]"
set ::calls 0
set ::units 0
set t [clock microseconds]
set rows [tokenizer::encode_details "$prefix$text"]
set idx [expr {min($budget-2,[llength $rows]-2)}]
set end [lindex $rows $idx 2]
set cut [expr {$end-[string length $prefix]}]
if {$cut <= 0 || $cut > [string length $text]} {
  error "invalid proposed ASCII byte boundary"
}
set candidate [string range $text 0 [expr {$cut-1}]]
set ids [tokenizer::tokenize "$prefix$candidate"]
set nunk 0
foreach row $rows {
  if {[lindex $row 0] == $unknown_id} {
    incr nunk
  }
}
puts \
  "proposal calls=$::calls units=$::units cut=$cut tokens=[llength $ids] valid=[expr {[llength $ids] <= $budget}] unknown=$nunk ms=[expr {([clock microseconds]-$t)/1000.0}]"
tokenizer::free
