// The fixture of the mutation runner's own tests
// (scripts/mutation/test_mutation.py). Each site's mutant has a known
// outcome, which a comment beside it gives, with the reason, from what
// calc_test.mbt checks.

///|
/// Whether `n` lies in the closed range from `low` to `high`.
pub fn in_range(n : Int32, low : Int32, high : Int32) -> Bool {
  // ROR `low <= n` to `low < n`: killed, by the snapshot of 1 in the range
  // from 1 to 3, which `moon test -u` would rewrite instead.
  // ROR `n <= high` to `n < high`: survives, since no test has a number at
  // the high end.
  low <= n && n <= high
}

///|
/// Halves `n` until it is at most `limit`.
pub fn halve_until(n : Int32, limit : Int32) -> Int32 {
  let mut x = n
  // ROR `x > limit` to `x >= limit`: times out, since 0 halves to 0 for
  // ever when the limit is 0.
  while x > limit {
    x = x / 2
  }
  x
}

///|
/// Whether `text` is blank: empty, or, unless `spaces` is false, made of
/// spaces only.
pub fn is_blank(text : String, spaces~ : Bool = true) -> Bool {
  // BOOL `true` to `false`, the default above, and NOT `!spaces` to
  // `spaces`: both survive, since the tests give only the empty text and
  // a letter, which are blank, or not, either way.
  if !spaces {
    return text.length() == 0
  }
  for c in text {
    if c != ' ' {
      // BOOL `false` to `true`: killed, by the letter.
      return false
    }
  }
  // BOOL `true` to `false`: killed, by the empty text.
  true
}

///|
/// Whether `n` is odd.
pub fn is_odd(n : Int32) -> Bool {
  // NOT `!` removed: killed, by 3.
  !(n % 2 == 0)
}

///|
test "a test block has no sites" {
  assert_true(1 < 2)
}
