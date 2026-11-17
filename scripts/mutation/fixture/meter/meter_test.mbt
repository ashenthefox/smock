// It kills one mutant of units that units' own tests leave: `low < n`.

///|
test "a reading at the low end of the scale is on it" {
  assert_true(@meter.on_scale(1, 1, 3))
}
