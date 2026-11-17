// What bounds.mbt's mutants are judged by, on wasm-gc and natively.

///|
test "a dot after the first characters" {
  assert_true(@bounds.dot_after("a.b", 1))
}

///|
test "no dot after the first characters" {
  assert_false(@bounds.dot_after("ab", 1))
}

///|
test "a name that ends after its first characters" {
  assert_false(@bounds.dot_after("a", 1))
}

///|
test "the empty name is empty, and a letter is not" {
  assert_true(@bounds.is_empty_name(""))
  assert_false(@bounds.is_empty_name("a"))
}
