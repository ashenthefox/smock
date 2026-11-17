// What same.mbt's mutants are judged by.

///|
test "the total of 1 and 2 is 3, and traces nothing" {
  let trace = []
  inspect(@same.total([1, 2], trace), content="3")
  debug_inspect(trace, content="[]")
}

///|
test "2 and 1 are kept, and 0 is not" {
  let kept = []
  @same.keep_positive(kept, 2)
  @same.keep_positive(kept, 1)
  @same.keep_positive(kept, 0)
  debug_inspect(kept, content="[2, 1]")
}

///|
test "refuse fails" {
  let outcome = try @same.refuse() catch {
    _ => "failed"
  } noraise {
    _ => "returned"
  }
  inspect(outcome, content="failed")
}

///|
test "a tally of 2 is described as 2 things" {
  inspect(@same.describe({ count: 2, }), content="2 things")
}

///|
test "two tallies of 2 are equal" {
  inspect(@same.Tally::{ count: 2, } == { count: 2, }, content="true")
}
