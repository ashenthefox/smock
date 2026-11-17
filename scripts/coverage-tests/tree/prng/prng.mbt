///|
/// A counter that stands in for a generator, in the tests of
/// scripts/coverage-report.py.
pub struct Generator {
  mut state : UInt64
}

///|
pub fn Generator::next(self : Generator) -> UInt64 {
  self.state = self.state + 1
  self.state
}

///|
pub fn Generator::below(self : Generator, count : UInt64) -> UInt64 {
  if count == 0 { abort("count is 0") } else { self.next() % count }
}
