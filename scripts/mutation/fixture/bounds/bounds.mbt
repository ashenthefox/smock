// The fixture of the mutation runner's own tests of the native verdict
// (scripts/mutation/test_mutation.py, NativeTest). A site whose enclosing
// definition uses an unchecked array access, such as `unsafe_get`, is
// judged natively as well as on wasm-gc: wasm-gc traps on a read out of
// bounds, so a test fails there, where the native binary reads on without
// a sign. Each site's mutant in the pinned set has a known outcome on each
// backend, which a comment beside it gives with its reason, from what
// bounds_test.mbt checks.

///|
/// Whether `name` holds a dot just after its first `n` characters, as
/// protobuf's reflection asks of a symbol inside a name. The character is
/// read without a bounds check, so the length test before it keeps the read
/// inside the name.
pub fn dot_after(name : String, n : Int32) -> Bool {
  // BODY `{ false }`: killed on both backends, by "a.b", which has a dot
  // after its first character.
  // ROR `name.length() > n` to `>=`: for "a" and 1, the read is one past the
  // end of the name. wasm-gc traps there, so the test of a name that ends
  // after its first characters fails: killed. Natively, the read finds the
  // 0 that the C runtime puts after every string, which is no dot, so the
  // result is false, as it should be, and every test passes: survived.
  // LCR `&&` to `||`: killed on both backends, by "ab", which is longer
  // than 1 and so has a dot after its first character by `||`. On wasm-gc,
  // the test of "a" also fails, by the trap.
  name.length() > n && name.unsafe_get(n) == '.'
}

///|
/// Whether `name` is empty. It uses no unchecked array access, so its
/// sites are judged on wasm-gc alone.
pub fn is_empty_name(name : String) -> Bool {
  // BODY `{ false }`: killed, by "".
  // INT `0` to `1` and to `-1`: killed, by "", whose length is 0.
  name.length() == 0
}
