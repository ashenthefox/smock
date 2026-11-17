// A package that reaches units (scripts/mutation/fixture/units) only through
// meter, and only in its tests. It kills one mutant of units that neither
// units' tests nor meter's kill: `n < high`.

///|
test "a reading at the high end of a scale from 0 to 10 is on it" {
  assert_true(@meter.on_scale(10, 0, 10))
}
