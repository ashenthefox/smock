// What host.mbt's mutants are judged by, natively.

///|
test "0 and 999 are system accounts" {
  assert_true(@host.is_system(0))
  assert_true(@host.is_system(999))
}

///|
test "5000 is no system account" {
  assert_false(@host.is_system(5000))
}
