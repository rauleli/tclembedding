package require tokenizer 1.0.0
lassign $argv tokenizer prefix
tokenizer::load_vocab $tokenizer
set cases [list {} hola "camión e\u0301" "  spaces  " "العربية 中文 😀" {<s> </s> <unk> <mask> <pad> ＜mask＞} [string repeat abcdefghijklmnopqrstuvwxyz 5] [string repeat {hola } 140]]
foreach text $cases {
 foreach limit {0 16 128} {
  if {$limit == 0} {set ids [tokenizer::tokenize "$prefix$text"]} else {set ids [tokenizer::tokenize "$prefix$text" -max-length $limit]}
  puts [join $ids ,]
 }
}
if {![catch {tokenizer::tokenize hello -max-length -1}]} {error "expected error"}
puts [join [tokenizer::tokenize recovery] ,]
tokenizer::free
