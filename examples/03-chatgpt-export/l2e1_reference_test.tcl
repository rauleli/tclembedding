# Independent L2E1 reader and synthetic corruption checks.
package require Tcl 8.6
package require rl_json 0.15.7
package require sha256
namespace import ::rl_json::json

proc read_binary {path} {
    set channel [open $path rb]
    try {return [read $channel]} finally {close $channel}
}
proc sha {bytes} {return [::sha2::sha256 -hex $bytes]}
proc require_condition {condition message} {
    if {![uplevel 1 [list expr $condition]]} {error $message}
}
# Input is a complete byte string. Returns the decoded float vectors in order.
# This intentionally does not source or call the embedding pipeline.
proc read_l2e1 {bytes source} {
    set size [string length $bytes]
    require_condition {$size >= 79} "incomplete header"
    require_condition {[string range $bytes 0 4] eq "L2E1\n"} "wrong magic"
    set length_field [string range $bytes 5 13]
    require_condition {[regexp {^[0-9a-f]{8}\n$} $length_field]} "invalid header length"
    scan [string range $length_field 0 7] %x meta_size
    require_condition {$meta_size > 0 && $meta_size <= 65536} "invalid metadata size"
    set first [expr {14 + $meta_size + 65}]
    require_condition {$size >= $first} "incomplete metadata"
    set meta_bytes [string range $bytes 14 [expr {13+$meta_size}]]
    set meta_hash [string range $bytes [expr {14+$meta_size}] [expr {77+$meta_size}]]
    require_condition {[regexp {^[0-9a-f]{64}$} $meta_hash] && $meta_hash eq [sha $meta_bytes]} "metadata checksum mismatch"
    require_condition {[string index $bytes [expr {78+$meta_size}]] eq "\n"} "missing header delimiter"
    set meta [encoding convertfrom utf-8 $meta_bytes]
    require_condition {[json valid $meta] && [json get $meta format] eq "tclembedding-e5-f32le-v1" && [json get $meta fragment_version] eq "2" && [json get $meta dimension] == 384} "unsupported format"
    set count [json get $meta records]
    require_condition {[string is entier -strict $count] && $count > 0} "invalid record count"
    require_condition {$size == $first + 1672*$count} "incomplete records or unexpected trailing bytes"
    require_condition {[sha $source] eq [json get $meta fragment_sha256]} "source checksum mismatch"
    set lines [split [encoding convertfrom utf-8 $source] "\n"]
    if {[lindex $lines end] eq ""} {set lines [lrange $lines 0 end-1]}
    require_condition {[llength $lines] == $count} "source count mismatch"
    set vectors {}
    for {set i 0} {$i < $count} {incr i} {
        set base [expr {$first + 1672*$i}]
        set record [string range $bytes $base [expr {$base+1671}]]
        binary scan [string range $record 0 7] w index
        require_condition {$index == $i} "record index mismatch"
        set identity [string range $record 8 71]
        require_condition {[regexp {^[0-9a-f]{64}$} $identity] && $identity eq [sha [encoding convertto utf-8 [lindex $lines $i]]]} "fragment identity mismatch"
        set vector_bytes [string range $record 72 1607]
        binary scan $vector_bytes r* vector
        require_condition {[llength $vector] == 384 && [binary format r* $vector] eq $vector_bytes} "float32 decoding mismatch"
        set norm 0.0
        foreach value $vector {
            require_condition {![catch {expr {double($value) == double($value) && abs(double($value)) < Inf}} finite] && $finite} "non-finite vector"
            set norm [expr {$norm + double($value)*double($value)}]
        }
        require_condition {abs(sqrt($norm)-1.0) <= 1e-5} "invalid vector norm"
        set checksum [string range $record 1608 1671]
        require_condition {[regexp {^[0-9a-f]{64}$} $checksum] && $checksum eq [sha [string range $record 0 1607]]} "record checksum mismatch"
        lappend vectors $vector
    }
    return $vectors
}
if {[llength $argv] != 2} {error "usage: l2e1_reference_test.tcl file.l2e fragments.jsonl"}
lassign $argv vector_path source_path
set data [read_binary $vector_path]
set source [read_binary $source_path]
set vectors [read_l2e1 $data $source]
require_condition {[binary encode hex [binary format r 1.0]] eq "0000803f"} "little-endian float check failed"
foreach invalid [list [string range $data 0 end-1] "${data}x" [string replace $data end end z]] {
    if {![catch {read_l2e1 $invalid $source}]} {error "invalid file was accepted"}
}
puts "Independent L2E1 reader: [llength $vectors] records verified; incomplete, corrupt and trailing data rejected"
