// What units.mbt's mutants are judged by first. The tests of the packages
// that import units judge those that survive these.

///|
test "a number inside the range is in it" {
  assert_true(@units.within(2, 1, 3))
}

///|
test "a number below the range is not in it" {
  assert_false(@units.within(0, 1, 3))
}

///|
test "a number beyond the end of a range is past it" {
  assert_true(@units.past(5, 3))
}
