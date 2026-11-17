// The fixture of the mutation runner's own tests
// (scripts/mutation/test_mutation.py). Each site's mutant in the pinned
// set has a known outcome, which a comment beside it gives, with the
// reason, from what calc_test.mbt checks. Where the full set adds other
// alternatives, the comment says so, without an outcome: the tests run
// only the pinned set of this package.

///|
/// Whether `n` lies in the closed range from `low` to `high`.
pub fn in_range(n : Int32, low : Int32, high : Int32) -> Bool {
  // BODY `{ false }`: killed, by 1 in the range from 1 to 3.
  // ROR `low <= n` to `low < n`: killed, by the snapshot of 1 in the range
  // from 1 to 3, which `moon test -u` would rewrite instead.
  // LCR `&&` to `||`: killed, by 0, which is below the range.
  // ROR `n <= high` to `n < high`: survives, since no test has a number at
  // the high end.
  low <= n && n <= high
}

///|
/// Halves `n` until it is at most `limit`.
pub fn halve_until(n : Int32, limit : Int32) -> Int32 {
  // BODY `{ 0 }`: survives, since the only test halves to 0.
  let mut x = n
  // IFC `x > limit` to `false`: killed, since 100 is not halved at all.
  // The full set adds `true`.
  // ROR `x > limit` to `x >= limit`: times out, since 0 halves to 0 for
  // ever when the limit is 0.
  while x > limit {
    // DEL `x = x / 2`: unviable, since `x` is then never changed, and the
    // compiler refuses a `mut` that is never used.
    // AOR `/` to `*`: killed, since doubling 100 turns negative after 25
    // steps and stops there.
    // INT `2` to `3`: survives, since dividing by 3 reaches 0 as well. The
    // full set adds `1` and `0`.
    x = x / 2
  }
  x
}

///|
/// Whether `text` is blank: empty, or, unless `spaces` is false, made of
/// spaces only.
pub fn is_blank(text : String, spaces~ : Bool = true) -> Bool {
  // BOOL `true` to `false`, the default above, IFC `!spaces` to `false`
  // and NOT `!spaces` to `spaces`: all survive, since the tests give only
  // the empty text and a letter, which are blank, or not, either way. The
  // full set adds `true` for the condition.
  // BODY `{ false }`: killed, by the empty text.
  if !spaces {
    // INT `0` to `1` and to `-1`: both survive, since no test sets
    // `spaces` to false.
    return text.length() == 0
  }
  for c in text {
    // IFC `c != ' '` to `false`: killed, since the letter is then blank.
    // The full set adds `true`.
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
  // BODY `{ false }`: killed, by 3.
  // NOT `!` removed: killed, by 3.
  // INT `2` to `3` and to `1`, and INT `0` to `1`: killed, by 3. The full
  // set adds `0` for the `2`.
  // INT `0` to `-1`: survives, since no test has a negative odd number.
  !(n % 2 == 0)
}

///|
test "a test block has no sites" {
  assert_true(1 < 2)
}
