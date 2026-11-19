///|
/// The next number, in the tests of scripts/coverage-e2e.py.
pub fn next(state : Int) -> Int {
  if state < 0 {
    0
  } else {
    state + 1
  }
}
