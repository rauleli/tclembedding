# Build and run bounded standalone C tests without a database server.
package require Tcl 8.6
set root [file normalize [file join [file dirname [info script]] ..]]
set tmp [file join /tmp "mysql-cosine-test-[pid]-[clock clicks]"]
file mkdir $tmp
set test [file join $root tests mysql_cosine_test.c]
set scalar [file join $tmp scalar]
set simd [file join $tmp sse2]
set rc [catch {exec cc -std=c11 -O3 -ffast-math $test -o [file join $tmp fastmath] -lm} result options]
array set failure $options
if {
  !$rc
  || ![info exists failure(-errorcode)]
  || [lindex $failure(-errorcode) 0] ne "CHILDSTATUS"
  || [string first "requires non-finite checks" $result] < 0
} {
  error "fast-math build was not rejected"
}
puts "fast_math=rejected"
set udf_test [file join $root tests mysql_udf_contract_test.c]
exec cc -std=c11 -O3 -Wall -Wextra -Werror -I[file join $root tests mysql_udf_stub] $udf_test -o \
  [file join $tmp udf-contract] -lm
puts [exec [file join $tmp udf-contract]]
exec cc -std=c11 -O3 -fno-tree-vectorize -DCOSINE_FORCE_SCALAR $test -o $scalar -lm
for {set i 0} {$i < 5} {incr i} {
  puts [exec $scalar]
}
set cpu [open /proc/cpuinfo r]
set cpuinfo [read $cpu]
close $cpu
if {
  [regexp -nocase {(^|[[:space:]])sse2([[:space:]]|$)} $cpuinfo]
  && [info exists ::tcl_platform(machine)]
  && $::tcl_platform(machine) in {x86_64 i386 i686}
} {
  exec cc -std=c11 -O3 -msse2 -DCOSINE_ENABLE_SSE2 $test -o $simd -lm
  for {set i 0} {$i < 5} {incr i} {
    puts [exec $simd]
  }
  # Advanced code is compiled only; it is not run on unsupported hardware.
  exec cc -std=c11 -O3 -mavx2 -mfma -DCOSINE_ENABLE_SSE2 $test -o [file join $tmp advanced-compile-only] -lm
  puts "avx2_fma=compiled_only"
} else {
  puts "sse2=not_tested avx2_fma=not_tested"
}
