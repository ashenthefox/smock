// The fixture of the mutation runner's own tests in the full set
// (scripts/mutation/test_mutation.py). STR's scope holds this file, as it
// holds smock's own log package but its reader of request targets. Each
// site's mutant, in the pinned set and in the full set, has a known
// outcome, which a comment beside it gives, from what log_test.mbt checks.

///|
/// The line of `message`, such as `info: started`.
pub fn line(message : String) -> String {
  // BODY `{ "" }`: killed, by the exact line.
  // STR `"info: "` to `"_nfo: "`, and to `""` in the full set: both
  // killed, by the exact line.
  // AOR `+` to `-`: skipped, since the operand is a string.
  "info: " + message
}

///|
/// Whether `line` is a comment: it starts with `#`.
pub fn is_comment(line : String) -> Bool {
  // BODY `{ false }`: killed, by a comment.
  // STR `"#"` to `"_"`: killed, by a comment.
  // STR `"#"` to `""`, in the full set: survives, since no test gives a
  // line that is not a comment.
  line.has_prefix("#")
}

///|
/// The mark that ends a line cut short.
pub fn cut_mark() -> String {
  // BODY `{ "" }`: killed, since the mark is one character.
  // STR `"~"` to `"_"`: survives, since the tests check the mark's length
  // only. The full set's `""` makes the same mutant as BODY, so it is no
  // site of its own.
  "~"
}
