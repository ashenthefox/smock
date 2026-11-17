// The site finder's fixture for STR (scripts/mutation/test_mutation.py):
// each form of a string literal. Here, outside STR's scope, each is a
// skipped site; the tests copy this file into STR's scope too, where each
// is a site. The runner does not run this package, and it has no tests.

///|
/// The forms of a literal, and what the pinned set changes in each: its
/// first character, outside any interpolation, to `_`, or to `-` when it
/// is `_`. The full set adds the empty literal.
pub fn strings(x : Int32, c : Char) -> Unit {
  ignore("ab")
  ignore("_b")
  ignore("")
  ignore("\tb")
  ignore("\u{5F}b")
  ignore("\{x}b")
  ignore("\{x}")
  ignore(b"ab")
  ignore('a')
  let text =
    #|ab
    #|cd
  let empty_first =
    #|
    #|cd
  let interpolated =
    $|\{x}ab
  ignore((text, empty_first, interpolated))
  ignore({ "k": c.to_string() })
  match c.to_string() {
    "ab" => ()
    _ => ()
  }
}

///|
/// A body that is one literal: BODY's `{ "" }` and the empty literal make
/// the same mutant, and BODY's is kept.
pub fn name() -> String {
  "ab"
}
