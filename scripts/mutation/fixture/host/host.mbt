// The fixture of the mutation runner's own tests of a package that builds
// only natively (scripts/mutation/test_mutation.py, NativeTest), as smock's
// defdir, watch, openssl and protobuf-conformance do. The runner runs all
// its mutants natively, with its own in-process tests. Each site's mutant
// in the pinned set has a known outcome, which a comment beside it gives
// with its reason, from what host_test.mbt checks.

///|
/// Whether `uid` is a system account's: below 1000, as Linux distributions
/// number them.
pub fn is_system(uid : Int32) -> Bool {
  // BODY `{ false }`: killed, by 0.
  // ROR `<` to `<=`: survives, since no test has 1000.
  // INT `1000` to `1001`: survives, likewise.
  // INT `1000` to `999`: killed, by 999.
  uid < 1000
}
