// The fixture of the mutation runner's own tests of kill credit
// (scripts/mutation/test_mutation.py, ImportersTest). Each site's mutant in
// the pinned set has a known outcome, which a comment beside it gives with
// its reason: from what units_test.mbt checks, and, for the mutants that
// survive those tests, from what the tests of the packages that import
// units check. meter imports units; dial imports meter, for its tests only;
// probe imports units, for its tests only, but builds only natively, as
// smock's server, defdir, schema, protobuf-conformance and e2e do, so its
// tests give no credit.

///|
/// Whether `n` lies in the closed range from `low` to `high`.
pub fn within(n : Int32, low : Int32, high : Int32) -> Bool {
  // BODY `{ false }`: killed by units' own tests, by 2 in the range from 1
  // to 3.
  // ROR `low <= n` to `low < n`: survives units' own tests, which have no
  // number at the low end; killed by meter's, by a reading at the low end
  // of its scale.
  // LCR `&&` to `||`: killed by units' own tests, by 0, below the range.
  // ROR `n <= high` to `n < high`: survives the tests of units and of
  // meter, which have no number at the high end; killed by dial's, by a
  // reading at the high end of meter's scale.
  low <= n && n <= high
}

///|
/// Whether `n` is past the end of a range that ends at `high`.
pub fn past(n : Int32, high : Int32) -> Bool {
  // BODY `{ false }`: killed by units' own tests, by 5, past 3.
  // ROR `n > high` to `n >= high`: survives, since only probe's test has a
  // number at the end, and probe builds only natively.
  n > high
}
