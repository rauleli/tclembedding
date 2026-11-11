package require Tcl 8.6
package require rl_json 0.15.7
package require sha256
namespace import ::rl_json::json
# Shared E5 artifact, fragment, and vector integrity helpers.
namespace eval ::pipeline {
  variable model_hash ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665
  variable tokenizer_hash 0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39
  variable backend_hash 9197dcf251bd220ebc023155b65911eff4913b6125c3325acb5fed5563ce2e5f
  variable runtime_hash a96f132e5eb5ca04e23a7d2fc1078fb95aa591e8d71d0f237702ece3a1e0f4ea
}

# Return the SHA-256 digest of a byte sequence.
proc ::pipeline::digest {bytes} {
  return [::sha2::sha256 -hex $bytes]
}

# Return the SHA-256 digest of a file.
proc ::pipeline::file_hash {path} {
  return [::sha2::sha256 -hex -filename $path]
}

# Determine whether a numeric value is finite.
proc ::pipeline::finite {v} {
  if {![string is double -strict $v]} {
    return 0
  }
  if {[catch {expr {double($v) == double($v) && abs(double($v)) < Inf}} good]} {
    return 0
  }
  return $good
}

# Validate and encode an E5 vector as float32 little endian.
proc ::pipeline::vector_blob {v} {
  if {[llength $v] != 384} {
    error "unexpected embedding dimension"
  }
  set norm 0.0
  foreach x $v {
    if {![finite $x]} {
      error "non-finite embedding"
    }
    set norm [expr {$norm+double($x)*double($x)}]
  }
  if {abs(sqrt($norm)-1.0) > 1e-5} {
    error "embedding is not L2 normalized"
  }
  set b [binary format r* $v]
  if {[string length $b] != 1536} {
    error "invalid vector encoding"
  }
  binary scan $b r* decoded
  foreach x $decoded {
    if {![finite $x]} {
      error "non-finite float32 embedding"
    }
  }
  return $b
}

# Validate the dimensions, finiteness, and norm of a stored vector.
proc ::pipeline::validate_blob {blob} {
  if {[string length $blob] != 1536} {
    error "invalid vector length"
  }
  binary scan $blob r* vector
  if {[llength $vector] != 384} {
    error "invalid vector dimension"
  }
  set norm 0.0
  foreach value $vector {
    if {![finite $value]} {
      error "non-finite stored vector"
    }
    set norm [expr {$norm + double($value) * double($value)}]
  }
  if {abs(sqrt($norm) - 1.0) > 1e-5} {
    error "invalid stored vector norm"
  }
}

# Validate a fragment and return its text and integrity metadata.
proc ::pipeline::read_fragment {line budget seenName} {
  upvar 1 $seenName seen
  if {![json valid $line] || [json type $line] ne "object"} {
    error "invalid fragment record"
  }
  set fields [json keys $line]
  foreach field \
    {fragment_version input_source_id input_sha256 tokenizer_sha256 extractor_version source conversation_id node_id message_id role position create_time part fragment_index char_start char_end token_count token_budget unk_id unk_count content_token_count max_nonspace_tcl_units text} \
    {
    if {[lsearch -exact $fields $field] < 0} {
      error "missing fragment field: $field"
    }
  }
  if {[json type $line fragment_version] ne "string" || [json get $line fragment_version] ne "2"} {
    error "unsupported fragment version"
  }
  if {
    [json type $line extractor_version] ne "string"
    || [json get $line extractor_version] ne "1"
    || [json type $line create_time] ni {string number null}
    || [json type $line content_token_count] ne "null"
  } {
    error "invalid fragment metadata"
  }
  foreach field {input_source_id source conversation_id node_id message_id role text} {
    if {[json type $line $field] ne "string" || [json get $line $field] eq ""} {
      error "invalid fragment field: $field"
    }
  }
  if {[json get $line role] ni {user assistant}} {
    error "invalid fragment role"
  }
  foreach field \
    {position part fragment_index char_start char_end token_count token_budget unk_id unk_count max_nonspace_tcl_units} \
    {
    if {
      [json type $line $field] ne "number"
      || ![string is entier -strict [json get $line $field]]
      || [json get $line $field] < 0
    } {
      error "invalid fragment number: $field"
    }
  }
  if {
    [json get $line token_budget] != $budget
    || [json get $line token_count] < 1
    || [json get $line token_count] > $budget
  } {
    error "incompatible fragment budget"
  }
  if {[json get $line tokenizer_sha256] ne $::pipeline::tokenizer_hash} {
    error "incompatible fragment tokenizer"
  }
  if {[json get $line unk_id] != 3 || [json get $line unk_count] > [json get $line token_count]} {
    error "invalid unknown-token metadata"
  }
  if {![regexp {^[0-9a-f]{64}$} [json get $line input_sha256]]} {
    error "invalid source hash"
  }
  set text [json get $line text]
  if {[json get $line char_end] - [json get $line char_start] != [string length $text]} {
    error "invalid fragment range"
  }
  set key \
    [list [json get $line input_source_id] [json get $line input_sha256] [json get $line source] \
    [json get $line conversation_id] [json get $line node_id] [json get $line part] [json get $line fragment_index]]
  if {[info exists seen($key)]} {
    error "duplicate fragment provenance"
  }
  set seen($key) 1
  return [list $text [json get $line token_count] [digest [encoding convertto utf-8 $line]] [json get $line unk_count]]
}

# Identify and hash one loaded native library.
proc ::pipeline::mapped_hash {name} {
  set f [open /proc/self/maps r]
  set paths {}
  try {
    while {[gets $f line] >= 0} {
      if {[regexp {(/[^ ]+)$} $line -> path] && [string match "*/$name" $path] && [lsearch -exact $paths $path] < 0} {
        lappend paths $path
      }
    }
  } finally {
    close $f
  }
  if {[llength $paths] != 1} {
    error "cannot identify the loaded $name"
  }
  return [file_hash [lindex $paths 0]]
}
