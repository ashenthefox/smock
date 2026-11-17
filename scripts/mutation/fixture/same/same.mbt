// The fixture of the compiler-output comparison in the mutation runner's
// own tests (scripts/mutation/test_mutation.py). Each site's mutant in the
// pinned set has a known outcome, which a comment beside it gives, with the
// reason, from what same_test.mbt checks. Some of the mutants compile to
// the same output as the package without a mutant, or as another mutant,
// and run no tests. A mutant whose comment says nothing of the comparison
// compiles unlike the package without a mutant and unlike every mutant
// before it.

// BOOL `false` to `true`, below: killed, since the trace then holds the
// steps. Not compared: a constant has no function of its own in the
// output.

///|
/// Whether `total` traces its steps: never, in this build.
const TRACING : Bool = false

///|
/// The sum of `xs`, with each step in `trace` when `TRACING` is true.
pub fn total(xs : Array[Int32], trace : Array[String]) -> Int32 {
  // BODY `{ 0 }`: killed, by the sum 3.
  // INT `0` to `1`: killed, since the sum is then 4. The full set adds
  // `-1`.
  let mut sum = 0
  for x in xs {
    // IFC `TRACING` to `false`: equivalent. The condition is false already,
    // so the compiler leaves the block out either way. The mutant makes its
    // line shorter, which the output does not show. The full set adds
    // `true`.
    // DEL of the call below, over three lines: equivalent, for the same
    // reason. The runner keeps the lines it took, so that the message of
    // `refuse`, which names the line of its call to `fail`, stays the same.
    if TRACING {
      trace.push(
        "adding \{x} to the sum of the numbers before it, which is \{sum} so far",
      )
    }
    // DEL: unviable, since `sum` is then never changed.
    // AOR `+` to `-`: killed, by the sum 3.
    sum = sum + x
  }
  sum
}

///|
/// How many of the letters of `text` are `a`. Its loop keeps the compiler
/// from putting it into its caller, so the package's output holds it as a
/// function of its own.
fn count_a(text : String) -> Int32 {
  // BODY `{ 0 }`: killed, by the 3 of banana. Not compared: the compiler
  // puts that 0 into the caller, so the mutant's output has no function of
  // its own for `count_a`.
  // INT `0` to `1`: killed, since banana then has 4. The full set adds
  // `-1`.
  let mut n = 0
  for c in text {
    // IFC `c == 'a'` to `false`: killed, since banana then has none. The
    // full set adds `true`.
    if c == 'a' {
      // DEL: unviable, since `n` is then never changed.
      // AOR `+=` to `-=`: killed, since banana then has -3.
      // INT `1` to `2`: killed, since banana then has 6. The full set adds
      // `0`.
      n += 1
    }
  }
  n
}

///|
/// How many of the letters of `text` are `a` when `wanted` is true, and 0
/// when it is not.
pub fn count_a_if(text : String, wanted : Bool) -> Int32 {
  // BODY `{ 0 }`: killed, by the 3 of banana.
  // IFC `wanted` to `false`: compiles to what BODY's mutant compiles to, so
  // it is a duplicate of that one, and runs no tests. The full set adds
  // `true`.
  if wanted {
    count_a(text)
  } else {
    // INT `0` to `1`: killed, by banana when it is not wanted.
    0
  }
}

///|
/// Fails, with a message that names the line of the call to `fail`.
pub fn refuse() -> Unit raise {
  // BODY `{ () }`: killed, since nothing fails.
  fail("refused")
}

///|
/// A count of things.
pub(all) struct Tally {
  count : Int32
}

///|
/// Shows the count. `describe` calls it, so the package's output holds it.
pub impl Show for Tally with fn output(self, logger) {
  // BODY `{ () }`: killed, by the tally of 2.
  logger.write_string(self.count.to_string())
}

///|
/// Whether two tallies have the same count. No function of the package's
/// interface calls it, so the package's output leaves it out.
pub impl Eq for Tally with fn equal(self, other) {
  // BODY `{ false }`: killed, by two tallies of 2. Not compared: the output
  // has no function of its own for this method, so it is the same with the
  // mutant as without it.
  self.count == other.count
}

///|
/// The tally in words.
pub fn describe(tally : Tally) -> String {
  // BODY `{ "" }`: killed, by the tally of 2.
  "\{tally} things"
}
