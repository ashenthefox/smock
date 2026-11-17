// A package that imports bounds (scripts/mutation/fixture/bounds), for its
// tests only. Its test kills, natively, a mutant of bounds that bounds' own
// tests kill on wasm-gc by a trap alone.

///|
test "no dot after the first characters" {
  assert_false(@bounds.dot_after("ab", 1))
}
