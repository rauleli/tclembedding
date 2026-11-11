# Synthetic unit and optional real-tokenizer tests; no private export is read.
package require Tcl 8.6
package require rl_json 0.15.7
namespace import ::rl_json::json
set dir [file dirname [file normalize [info script]]]
source [file join $dir fragment.tcl]

# Fail the test if a required condition is false.
proc assert {condition message} {
  if {![uplevel 1 [list expr $condition]]} {
    error $message
  }
}

# Verify that a command fails as expected.
proc must_fail {script} {
  if {![catch {uplevel 1 $script}]} {
    error "expected controlled error"
  }
}

# Verify that a child process reports failure.
proc child_fails {args} {
  set rc [catch {exec {*}$args} result options]
  array set fields $options
  if {
    !$rc
    || ![info exists fields(-errorcode)]
    || [lindex $fields(-errorcode) 0] ne "CHILDSTATUS"
    || [lindex $fields(-errorcode) 2] == 0
  } {
    error "expected failing child process"
  }
}

# Construct a synthetic test fixture.
proc fixture {conv message text {role user}} {
  return \
    [format \
    {{"version":"1","source":"synthetic.json","conversation_id":%s,"node_id":%s,"message_id":%s,"position":1,"role":%s,"create_time":null,"part":0,"text":%s}} [json string $conv] \
    [json string $message] [json string $message] [json string $role] [json string $text]]
}

# Write the test fixture to a file.
proc writefile {path text} {
  set f [open $path {WRONLY CREAT EXCL} 0600]
  fconfigure $f -encoding utf-8 -translation lf
  puts -nonewline $f $text
  close $f
}

# Read a test fixture from a file.
proc readfile {path} {
  set f [open $path r]
  fconfigure $f -encoding utf-8 -translation lf
  set text [read $f]
  close $f
  return $text
}

set tmp [file join /tmp "fragment-test-[pid]-[clock clicks]"]
file mkdir $tmp
set text "Hola  mundo.\n\nEnglish café e\u0301 😀 and punctuation! abcdefghijklmnopqrstuvwxyz"
set input [file join $tmp input.jsonl]
writefile $input "[fixture conversation-a shared-id $text]\n[fixture conversation-b shared-id {Other text.}]\n"
if {[llength $argv] == 0} {
  # Test tokenizer command namespace.
  namespace eval ::tokenizer {}

  # Test double: two special IDs plus one per Tcl character.
  proc ::tokenizer::tokenize {value} {
    return [lrepeat [expr {[string length $value]+2}] 1]
  }

  set budget 18
  assert {[llength [::fragment::split_text x 12]] == 1} "exact token boundary"
  assert {[lindex [::fragment::split_text {ab cd ef} 16] 0 3] eq "ab "} "natural word boundary"
  must_fail {::fragment::split_text x 11}
  must_fail {::fragment::split_text {} 18}
  must_fail {::fragment::split_text x 513}
  set chunks [::fragment::split_text $text $budget]
  set rebuilt {}
  set expected 0
  foreach chunk $chunks {
    lassign $chunk start end count piece
    assert {$start == $expected && $end > $start && $count <= $budget} "ranges and budget"
    assert {[string length $piece] > 0} "empty fragment"
    append rebuilt $piece
    set expected $end
  }
  assert {$rebuilt eq $text && $expected == [string length $text]} "lossless reconstruction"
  assert {[::fragment::max_nonspace_units "a😀b  c\nxy!"] == 4} "nonspace run uses Tcl units"
  set adversarial "a\u0301\u0327 b 👍🏽 👩‍💻 漢字、句。"
  set rebuilt {}
  set broken_combining 0
  foreach chunk [::fragment::split_text $adversarial 13] {
    set part [lindex $chunk 3]
    if {[string index $part 0] eq "\u0301" || [string index $part 0] eq "\u0327"} {
      set broken_combining 1
    }
    append rebuilt $part
  }
  assert {$rebuilt eq $adversarial && $broken_combining} "Unicode reconstruction and observed combining cut"
  set long [string repeat x 300]
  set rebuilt {}
  foreach chunk [::fragment::split_text $long $budget] {
    append rebuilt [lindex $chunk 3]
  }
  assert {$rebuilt eq $long} "long unbroken text"
  # A longer candidate can fit even when a shorter one does not.
  rename ::tokenizer::tokenize ::tokenizer::ordinary_tokenize

  # Tokenize or instrument text for the test fixture.
  proc ::tokenizer::tokenize {value} {
    set content [string range $value 9 end]
    if {$content eq "xy" || [string match " *" $content]} {
      return [lrepeat 4 1]
    }
    return [lrepeat 20 1]
  }

  set pieces [::fragment::split_text {xy z} 6]
  assert {[llength $pieces] == 2 && [lindex $pieces 0 3] eq "xy" && [lindex $pieces 1 3] eq " z"} \
    "non-monotonic candidate counts"
  rename ::tokenizer::tokenize {}
  rename ::tokenizer::ordinary_tokenize ::tokenizer::tokenize
  foreach i {1 2} {
    set out [file join $tmp "result$i.jsonl"]
    set fi [open $input r]
    fconfigure $fi -encoding utf-8 -translation lf
    set fo [open $out {WRONLY CREAT EXCL} 0600]
    fconfigure $fo -encoding utf-8 -translation lf
    set counts [::fragment::process $fi $fo synthetic-input [string repeat a 64] $budget]
    close $fi
    close $fo
    assert {[lindex $counts 0] == 2 && [lindex $counts 1] > 2} "record counts"
  }
  assert {[readfile [file join $tmp result1.jsonl]] eq [readfile [file join $tmp result2.jsonl]]} "determinism"
  set combined {}
  set last 0
  set seen_other 0
  set fragment_index 0
  foreach line [split [string trimright [readfile [file join $tmp result1.jsonl]] "\n"] "\n"] {
    assert {[json valid $line]} "invalid fragment JSON"
    set c [json get $line conversation_id]
    if {$c eq "conversation-a"} {
      assert {[json get $line char_start] == $last} "fragment order"
      assert {[json get $line fragment_index] == $fragment_index} "fragment index"
      set last [json get $line char_end]
      append combined [json get $line text]
      incr fragment_index
    } elseif {$c eq "conversation-b"} {
      set seen_other 1
    } else {
      error "lost provenance"
    }
    assert {[json get $line message_id] eq "shared-id" && [json get $line input_source_id] eq "synthetic-input"} \
      "provenance mismatch"
    assert {[json get $line input_sha256] eq [string repeat a 64] && [json get $line token_budget] == $budget} \
      "input identity mismatch"
    assert {[json get $line tokenizer_sha256] eq $::fragment::expected_tokenizer} "tokenizer identity mismatch"
    assert \
      {[json get $line fragment_version] eq "2" && [json get $line unk_id] == 3 && [json get $line unk_count] == 0 && [json type $line content_token_count] eq "null"} \
      "coverage fields"
    assert {[json get $line max_nonspace_tcl_units] == [::fragment::max_nonspace_units [json get $line text]]} \
      "nonspace metric"
    assert \
      {[json get $line source] eq "synthetic.json" && [json get $line position] == 1 && [json get $line part] == 0 && [json type $line create_time] eq "null"} \
      "original metadata mismatch"
  }
  assert {$combined eq $text && $seen_other} "duplicate message IDs or reconstruction"
  set bad [file join $tmp bad.jsonl]
  writefile $bad "[fixture c m {}]\n"
  set fi [open $bad r]
  set fo [open [file join $tmp bad-output] w]
  must_fail {::fragment::process $fi $fo source [string repeat a 64] 18}
  close $fi
  close $fo
  set bad [file join $tmp malformed.jsonl]
  writefile $bad "not-json\n"
  set fi [open $bad r]
  set fo [open [file join $tmp malformed-output] w]
  must_fail {::fragment::process $fi $fo source [string repeat a 64] 18}
  close $fi
  close $fo
  set bad [file join $tmp duplicate.jsonl]
  set same [fixture c m text]
  writefile $bad "$same\n$same\n"
  set fi [open $bad r]
  set fo [open [file join $tmp duplicate-output] w]
  must_fail {::fragment::process $fi $fo source [string repeat a 64] 18}
  close $fi
  close $fo
  puts "Fragmentation synthetic tests passed"
} elseif {[llength $argv] == 2 && [lindex $argv 0] eq "--real"} {
  set tokenizer [lindex $argv 1]
  set output [file join $tmp real.jsonl]
  set script [file join $dir fragment.tcl]
  set result \
    [exec [info nameofexecutable] $script -input $input -output $output -source-id synthetic-input -tokenizer \
    $tokenizer -budget 16]
  set repeat [file join $tmp real-repeat.jsonl]
  set again \
    [exec [info nameofexecutable] $script -input $input -output $repeat -source-id synthetic-input -tokenizer \
    $tokenizer -budget 16]
  assert {$result eq $again && [readfile $output] eq [readfile $repeat]} "real determinism"
  set original [readfile $output]
  child_fails [info nameofexecutable] $script -input $input -output $output -source-id test -tokenizer $tokenizer \
    -budget 16
  assert {[readfile $output] eq $original} "existing output changed"
  package require tokenizer 1.0.0
  package require sha256
  set expected_input_hash [::sha2::sha256 -hex -filename $input]
  tokenizer::load_vocab $tokenizer
  set exact [llength [tokenizer::tokenize "passage: prueba"]]
  set exact_chunks [::fragment::split_text prueba $exact]
  assert {[llength $exact_chunks] == 1 && [lindex $exact_chunks 0 2] == $exact} "real exact token limit"
  must_fail {::fragment::split_text x 1}
  set unknown_pieces [::fragment::split_text {hello <unk> world} 32]
  set unknowns 0
  foreach chunk $unknown_pieces {
    foreach id [lindex $chunk 4] {
      if {$id == 3} {
        incr unknowns
      }
    }
  }
  assert {$unknowns > 0} "literal unknown ID must be observed"
  set combined {}
  set count 0
  set prev 0
  set last_index -1
  foreach line [split [string trimright [readfile $output] "\n"] "\n"] {
    assert {[json valid $line]} "invalid real-tokenizer output"
    assert {[json get $line input_sha256] eq $expected_input_hash} "input hash mismatch"
    set part [json get $line text]
    set n [llength [tokenizer::tokenize "passage: $part"]]
    assert {$n <= 16 && $n == [json get $line token_count]} "real token count"
    set unknowns 0
    foreach id [tokenizer::tokenize "passage: $part"] {
      if {$id == 3} {
        incr unknowns
      }
    }
    assert {[json get $line unk_count] == $unknowns && [json get $line unk_id] == 3} "real unknown count"
    if {[json get $line conversation_id] eq "conversation-a"} {
      assert {[json get $line char_start] == $prev} "real fragment range"
      set prev [json get $line char_end]
      append combined $part
    }
    incr count
  }
  tokenizer::free
  assert {$combined eq $text && $count > 2} "real reconstruction"
  set long_input [file join $tmp long.jsonl]
  set long_text [string repeat x 200]
  writefile $long_input "[fixture long shared-id $long_text]\n"
  set long_output [file join $tmp long-output.jsonl]
  exec [info nameofexecutable] $script -input $long_input -output $long_output -source-id test -tokenizer $tokenizer \
    -budget 16
  set recovered {}
  foreach line [split [string trimright [readfile $long_output] "\n"] "\n"] {
    append recovered [json get $line text]
  }
  assert {$recovered eq $long_text} "real long unbroken text reconstruction"
  set invalid [file join $tmp invalid.jsonl]
  writefile $invalid "[fixture c m {valid}]\nnot-json\n"
  set badout [file join $tmp must-not-exist.jsonl]
  child_fails [info nameofexecutable] $script -input $invalid -output $badout -source-id test -tokenizer $tokenizer \
    -budget 16
  assert {![file exists $badout]} "failure published completed output"
  set impossible [file join $tmp impossible.jsonl]
  child_fails [info nameofexecutable] $script -input $input -output $impossible -source-id test -tokenizer $tokenizer \
    -budget 1
  assert {![file exists $impossible]} "budget failure published completed output"
  set unknown_input [file join $tmp unknown.jsonl]
  writefile $unknown_input "[fixture unknown c {hello <unk> world}]\n"
  set unknown_output [file join $tmp unknown-output.jsonl]
  exec [info nameofexecutable] $script -input $unknown_input -output $unknown_output -source-id test -tokenizer \
    $tokenizer -budget 32
  set unknown_row [string trim [readfile $unknown_output]]
  assert {[json get $unknown_row unk_id] == 3 && [json get $unknown_row unk_count] > 0} \
    "unknown occurrence must be recorded"
  puts "Real tokenizer test passed: $result"
} else {
  error "usage: test.tcl ?--real tokenizer.json?"
}
