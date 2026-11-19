///|
/// Whether a file changed, in the tests of scripts/coverage-e2e.py.
pub fn changed(before : Int, after : Int) -> Bool {
  if before == after {
    false
  } else {
    true
  }
}
