// What calc.mbt's mutants are judged by. A test file has no sites: the
// comparison below is not one.

///|
test "a number at the low end is in range" {
  inspect(@calc.in_range(1, 1, 3), content="true")
}

///|
test "a number below the range is not in it" {
  assert_false(@calc.in_range(0, 1, 3))
}

///|
test "halving stops at the limit" {
  assert_eq(@calc.halve_until(100, 0), 0)
}

///|
test "the empty text is blank, and a letter is not" {
  assert_true(@calc.is_blank(""))
  assert_false(@calc.is_blank("a"))
}

///|
test "3 is odd" {
  assert_true(@calc.is_odd(3))
  assert_true(4 > 3)
}
