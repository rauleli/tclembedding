#!/usr/bin/env tclsh
# Small, in-memory semantic retrieval example.
package require Tcl 8.6
# Functions for the in-memory retrieval example.
namespace eval ::rag {}

# Determine whether a numeric value is finite.
proc ::rag::finite {value} {
  if {![string is double -strict $value]} {
    return 0
  }
  if {[catch {expr {double($value) == double($value) && abs(double($value)) < Inf}} ok]} {
    return 0
  }
  return $ok
}

# Compute cosine similarity for finite vectors with nonzero norms.
proc ::rag::cosine {left right} {
  set n [llength $left]
  if {$n == 0 || $n != [llength $right]} {
    error "vectors must have the same nonzero dimension"
  }
  set dot 0.0
  set a2 0.0
  set b2 0.0
  foreach a $left b $right {
    if {![finite $a] || ![finite $b]} {
      error "vectors must contain finite numbers"
    }
    set dot [expr {$dot + double($a)*double($b)}]
    set a2 [expr {$a2 + double($a)*double($a)}]
    set b2 [expr {$b2 + double($b)*double($b)}]
  }
  if {![finite $dot] || ![finite $a2] || ![finite $b2] || $a2 <= 0 || $b2 <= 0} {
    error "vectors must have finite nonzero norms"
  }
  set result [expr {($dot / sqrt($a2)) / sqrt($b2)}]
  if {![finite $result]} {
    error "cosine result is non-finite"
  }
  return $result
}

# Order scored results deterministically.
proc ::rag::compare {a b} {
  set x [lindex $a 0]
  set y [lindex $b 0]
  if {$x > $y} {
    return -1
  }
  if {$x < $y} {
    return 1
  }
  return [string compare [lindex [lindex $a 1] 0] [lindex [lindex $b 1] 0]]
}

# Check document structure and identifier uniqueness.
proc ::rag::validate_documents {docs} {
  if {[llength $docs] == 0 || [llength $docs] > 256} {
    error "corpus must contain between 1 and 256 documents"
  }
  array set seen {}
  foreach doc $docs {
    if {[llength $doc] != 3} {
      error "documents must contain ID, title and text"
    }
    lassign $doc id title text
    if {[string trim $id] eq "" || [string trim $title] eq "" || [string trim $text] eq ""} {
      error "document fields must not be empty"
    }
    if {[info exists seen($id)]} {
      error "document IDs must be unique"
    }
    set seen($id) 1
  }
}

# Rank documents against a query vector.
proc ::rag::rank {docs vectors query topk} {
  validate_documents $docs
  if {![string is integer -strict $topk] || $topk < 1 || $topk > 256} {
    error "top-k must be an integer from 1 to 256"
  }
  if {[llength $docs] != [llength $vectors]} {
    error "document and vector counts differ"
  }
  set ranked {}
  foreach doc $docs vector $vectors {
    lappend ranked [list [cosine $query $vector] $doc]
  }
  return [lrange [lsort -command ::rag::compare $ranked] 0 [expr {$topk-1}]]
}

# Execute the in-memory retrieval example.
proc ::rag::run {args} {
  array set opt {-model {} -tokenizer {} -query {} -top-k 3}
  if {[llength $args] % 2} {
    error "options require values"
  }
  foreach {key value} $args {
    if {![info exists opt($key)]} {
      error "unknown option: $key"
    }
    set opt($key) $value
  }
  if {$opt(-model) eq "" || $opt(-tokenizer) eq "" || [string trim $opt(-query)] eq ""} {
    error "provide -model, -tokenizer and a nonempty -query"
  }
  if {![string is integer -strict $opt(-top-k)] || $opt(-top-k) < 1 || $opt(-top-k) > 256} {
    error "top-k must be an integer from 1 to 256"
  }
  set root [file dirname [file normalize [info script]]]
  source [file join $root corpus.tcl]
  validate_documents $corpus
  package require tokenizer 1.0.0
  package require tclembedding 1.0
  set tokenizer_loaded 0
  set handle ""
  try {
    tokenizer::load_vocab $opt(-tokenizer)
    set tokenizer_loaded 1
    set handle [embedding::init_raw $opt(-model)]
    set all_ids {}
    set longest 0
    foreach doc $corpus {
      set ids [tokenizer::tokenize "passage: [lindex $doc 2]"]
      set n [llength $ids]
      if {$n < 1 || $n > 512} {
        error "document token count exceeds the supported limit"
      }
      if {$n > $longest} {
        set longest $n
      }
      lappend all_ids $ids
    }
    if {[llength $all_ids] * $longest > 4096} {
      error "padded batch exceeds the supported limit"
    }
    set vectors [embedding::compute_batch $handle $all_ids -pad-id 1 -pooling mean]
    set ids [tokenizer::tokenize "query: $opt(-query)"]
    if {[llength $ids] < 1 || [llength $ids] > 512} {
      error "query token count exceeds the supported limit"
    }
    set query_vector [embedding::compute $handle $ids -pooling mean]
    set ranked [rank $corpus $vectors $query_vector $opt(-top-k)]
    puts "Retrieved sources:"
    foreach hit $ranked {
      lassign [lindex $hit 1] id title text
      puts [format "%s | %s | %.6f\n%s\n" $id $title [lindex $hit 0] $text]
    }
  } finally {
    try {
      if {$handle ne ""} {
        embedding::free $handle
      }
    } finally {
      if {$tokenizer_loaded} {
        tokenizer::free
      }
    }
  }
}

if {[file normalize $argv0] eq [file normalize [info script]]} {
  if {[catch {::rag::run {*}$argv} message]} {
    puts stderr "Error: $message"
    exit 1
  }
}
