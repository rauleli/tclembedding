#!/usr/bin/env tclsh
# Generate E5 embeddings and persist committed batches through a SQL backend.
set ::sql_ingest_dir [file dirname [file normalize [info script]]]
source [file join $::sql_ingest_dir embedding_common.tcl]
# Coordinates bounded embedding batches and committed SQL checkpoints.
namespace eval ::sql_ingest {
  variable fail_after -1
  variable stop_after -1
}

# Validate input and artifacts, then generate and commit resumable batches.
proc ::sql_ingest::run {backend fragments model tokenizer {batch_size 8}} {
  variable fail_after
  variable stop_after
  if {![string is integer -strict $batch_size] || $batch_size < 1 || $batch_size > 32} {
    error "batch size must be between 1 and 32"
  }
  if {
    [::pipeline::file_hash $model] ne $::pipeline::model_hash
    || [::pipeline::file_hash $tokenizer] ne $::pipeline::tokenizer_hash
  } {
    error "model or tokenizer hash mismatch"
  }
  set corpus [::pipeline::file_hash $fragments]
  set budget 128
  set count 0
  array set seen {}
  set file [open $fragments]
  fconfigure $file -encoding utf-8 -translation lf
  try {
    while {[gets $file line] >= 0} {
      ::pipeline::read_fragment $line $budget seen
      incr count
    }
  } finally {
    close $file
  }
  if {$count == 0} {
    error "input contains no fragments"
  }
  if {[::pipeline::file_hash $fragments] ne $corpus} {
    error "fragment input changed"
  }
  package require tokenizer 1.0.0
  package require tclembedding 1.0
  tokenizer::load_vocab $tokenizer
  set handle {}
  try {
    set handle [embedding::init_raw $model]
    set backend_hash [::pipeline::mapped_hash libtclembedding_tokenizer.so]
    set runtime_hash [::pipeline::mapped_hash libonnxruntime.so.1.31.1]
    set bridge_hash [::pipeline::mapped_hash tcltokenizer.so]
    set embedding_hash [::pipeline::mapped_hash tclembedding.so]
    if {$backend_hash ne $::pipeline::backend_hash || $runtime_hash ne $::pipeline::runtime_hash} {
      error "uncharacterized loaded backend or ONNX Runtime"
    }
    set config \
      [list e5-sql-v1 $::pipeline::model_hash $::pipeline::tokenizer_hash $backend_hash $runtime_hash $bridge_hash \
      $embedding_hash $budget $batch_size]
    set checkpoint [${backend}::begin_corpus $corpus $count $config]
    if {$checkpoint < 0 || $checkpoint > $count} {
      error "invalid checkpoint"
    }
    set file [open $fragments]
    fconfigure $file -encoding utf-8 -translation lf
    array unset seen
    array set seen {}
    set batch {}
    set index 0
    try {
      while {[gets $file line] >= 0} {
        lassign [::pipeline::read_fragment $line $budget seen] text tokens line_hash unknown
        if {$index < $checkpoint} {
          ${backend}::verify_row $corpus $index $line $line_hash
        } else {
          set ids [tokenizer::tokenize "passage: $text"]
          set unknown_count 0
          foreach id $ids {
            if {$id == 3} {
              incr unknown_count
            }
          }
          if {[llength $ids] != $tokens || $unknown_count != $unknown} {
            error "fragment token metadata mismatch"
          }
          lappend batch [list $index $line $line_hash $ids]
          if {[llength $batch] == $batch_size || $index == $count - 1} {
            set all_ids {}
            foreach item $batch {
              lappend all_ids [lindex $item 3]
            }
            if {[llength $batch] == 1} {
              set vectors [list [embedding::compute $handle [lindex $all_ids 0] -pooling mean]]
            } else {
              set vectors [embedding::compute_batch $handle $all_ids -pad-id 1 -pooling mean]
            }
            if {[llength $vectors] != [llength $batch]} {
              error "batch output count mismatch"
            }
            set rows {}
            foreach item $batch vector $vectors {
              lappend rows [list [lindex $item 0] [lindex $item 1] [lindex $item 2] [::pipeline::vector_blob $vector]]
            }
            ${backend}::commit_batch $corpus $rows $count $fail_after
            set batch {}
            if {$stop_after >= 0 && $index + 1 >= $stop_after} {
              error "synthetic interruption after committed batch"
            }
          }
        }
        incr index
      }
    } finally {
      close $file
    }
    if {
      $index != $count
      || [::pipeline::file_hash $fragments] ne $corpus
      || [::pipeline::file_hash $model] ne $::pipeline::model_hash
      || [::pipeline::file_hash $tokenizer] ne $::pipeline::tokenizer_hash
    } {
      error "input or artifact changed"
    }
    ${backend}::finish $corpus $count
    puts "corpus=$corpus records=$count resumed=$checkpoint"
  } finally {
    if {$handle ne ""} {
      embedding::free $handle
    }
    tokenizer::free
  }
}
