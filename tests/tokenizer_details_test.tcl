# Synthetic coverage for four hash-identified tokenizers.
package require Tcl 8.6
package require tokenizer 1.0.0
if {[llength $argv] != 4} {
  error "usage: tokenizer_details_test.tcl minilm bge e5 mpnet"
}
set hashes \
  {2c3387be76557bd40970cec13153b3bbf80407865484b209e655e5e4729076b8 d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66 0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39 b8be2c30ba5dd723a6d5ee26d013da103d5408d92ddcb23747622f9e48f1d842}
set unknowns {3 100 3 104}
set specials {{<s> <unk> </s>} {[CLS] [UNK] [SEP]} {<s> <unk> </s>} {<s> [UNK] </s>}}
set inputs \
  [list {} hello "café" "cafe\u0301" "x\u0301\u0327" "😀 👍🏽 👩‍💻" "中文、句。" "  spaces   test " \
  "a\u0000b" "＜mask＞" [string repeat x 101]]
set model_index 0
foreach path $argv hash $hashes unknown $unknowns literal $specials {
  if {[lindex [exec sha256sum -- $path] 0] ne $hash} {
    error "tokenizer fixture hash mismatch"
  }
  tokenizer::load_vocab $path
  set tested 0
  set saw_unknown 0
  set saw_literal 0
  foreach text [concat $inputs [list $literal]] {
    foreach limit {0 3 128} {
      set options {}
      if {$limit} {
        set options [list -max-length $limit]
      }
      set ids [tokenizer::tokenize $text {*}$options]
      set rows [tokenizer::encode_details $text {*}$options]
      if {[llength $ids] != [llength $rows]} {
        error "length mismatch"
      }
      set bytes [encoding convertto utf-8 $text]
      set length [string length $bytes]
      foreach id $ids row $rows {
        if {[llength $row] != 6} {
          error "record length"
        }
        lassign $row got start end special attention type
        if {
          $id != $got
          || $start < 0
          || $end < $start
          || $end > $length
          || $special ni {0 1}
          || $attention != 1
          || $type != 0
        } {
          error "invalid record"
        }
        if {$id == $unknown && $special == 0} {
          set saw_unknown 1
        }
        if {$text eq $literal && $special == 0 && $end > $start} {
          set saw_literal 1
        }
      }
      if {$limit && [llength $rows] > $limit} {
        error "truncation"
      }
      incr tested
    }
  }
  if {!$saw_unknown || !$saw_literal} {
    error "missing unknown or literal observation"
  }
  set empty [tokenizer::encode_details {}]
  if {[lindex $empty 0 1] != 0 || [lindex $empty 0 2] != 0 || [lindex $empty 0 3] != 1} {
    error "missing inserted special"
  }
  set first_id [lindex $empty 0 0]
  set first_literal [expr {$model_index == 1 ? "\[CLS\]" : "<s>"}]
  set literal_match 0
  foreach row [tokenizer::encode_details $first_literal] {
    lassign $row id start end special attention type
    if {$id == $first_id && $special == 0 && $end > $start} {
      set literal_match 1
    }
  }
  if {!$literal_match} {
    error "literal special token must retain its source offsets"
  }
  if {![catch {tokenizer::encode_details hello -max-length -1}]} {
    error "invalid limit accepted"
  }
  if {![catch {tokenizer::encode_details [format %c 55296]}]} {
    error "unpaired surrogate accepted"
  }
  if {[lmap row [tokenizer::encode_details recovery] {lindex $row 0}] ne [tokenizer::tokenize recovery]} {
    error "recovery"
  }
  tokenizer::free
  if {![catch {tokenizer::encode_details hello}]} {
    error "use after free"
  }
  puts "model=$model_index cases=$tested unknown=yes literal=yes"
  incr model_index
}
