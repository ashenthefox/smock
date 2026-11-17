// What lines.mbt's mutants are judged by.

///|
test "a line is info: and the message" {
  inspect(@log.line("started"), content="info: started")
}

///|
test "a line that starts with # is a comment" {
  assert_true(@log.is_comment("# note"))
}

///|
test "the cut mark is one character" {
  assert_eq(@log.cut_mark().length(), 1)
}
