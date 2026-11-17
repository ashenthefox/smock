// The site finder's fixture (scripts/mutation/test_mutation.py): one site
// in each kind of top-level definition, which names it, and the look-alikes
// that are not sites. The runner does not run it, and it has no tests.

///|
/// A closed range of numbers.
pub(all) struct Span {
  low : Int32
  high : Int32
}

///|
/// Whether the span holds no number.
pub fn Span::is_empty(self : Span) -> Bool {
  self.low > self.high
}

///|
pub impl Show for Span with fn output(self, logger) {
  logger.write_string(if self.low <= self.high { "span" } else { "empty" })
}

///|
/// A shape that may be round.
pub trait Round {
  fn is_round(Self) -> Bool = _
}

///|
impl Round with fn is_round(_self) {
  false
}

///|
let threshold : Bool = !(1 >= 2)

///|
/// Strings, bytes and characters that read like sites are not, nor are
/// patterns, ranges, equality and arrows.
pub fn look_alikes(flag : Bool) -> Int32 {
  let words = ["true", "<", "!x"]
  let raw = b"false"
  let quote = '<'
  let text =
    #|true < false
  let mut sum = 0
  for i in 0..<3 {
    sum = sum + i
  }
  match flag {
    true => sum + words.length() + raw.length() + text.length()
    false => if quote == '>' && sum != 1 { 1 } else { 2 }
  }
}

///|
fn init {
  ignore(threshold || 2 < 1)
}
