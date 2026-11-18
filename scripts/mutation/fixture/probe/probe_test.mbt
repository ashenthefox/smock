// A package that imports units (scripts/mutation/fixture/units), for its
// tests, and builds only natively. A pure package's verdict is taken on
// wasm-gc, so this test, which would kill `n >= high`, gives no credit.

///|
test "the end of a range is not past it" {
  assert_false(@units.past(3, 3))
}
