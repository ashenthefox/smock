// Seam 2 tests of the coverage dump (#341): with SMOCK_COVERAGE_DUMP set,
// smock writes its coverage counters to stdout as it exits, after all else
// it writes there, and nothing else in what it does changes. The harness
// relies on it when the tests run with coverage: it gives the variable to
// every smock it starts and takes the counters out of what the tests see.

///|
/// What `lines`, smock's stdout from its coverage counters on, hold: the
/// form core's coverage runtime prints them in (`@coverage.end`), which is
/// `----- BEGIN MOONBIT COVERAGE -----`, a JSON object of one array of
/// counts for each instrumented file (none in a build without coverage),
/// then `----- END MOONBIT COVERAGE -----`. Anything else is shown as it
/// is.
fn counters_shape(lines : ArrayView[String]) -> String {
  let shown = lines.join("\n")
  guard lines.length() >= 3 &&
    lines[0] == "----- BEGIN MOONBIT COVERAGE -----" &&
    lines[lines.length() - 1] == "----- END MOONBIT COVERAGE -----" else {
    return "not the coverage counters:\n\{shown}"
  }
  let object = @json.parse(lines[1:lines.length() - 1].join("\n")) catch {
    _ => return "not a JSON object of counters:\n\{shown}"
  }
  guard object is Object(files) &&
    files
    .values()
    .all(counts => {
      counts is Array(counts) &&
      counts.iter().all(count => count is Number(count, ..) && count >= 0.0)
    }) else {
    return "not a JSON object of counters:\n\{shown}"
  }
  "the coverage counters"
}

///|
async test "with SMOCK_COVERAGE_DUMP set, smock check writes its coverage counters to stdout as it exits, after the same output, with the same exit status and stderr" {
  // #341: "With the variable set, it writes its counters to stdout as it
  // exits; with it unset, its output and behaviour are unchanged, byte for
  // byte." An invalid definition set, so that smock check writes problems
  // to stdout and exits with 1 (docs/commands.md).
  with_definitions(
    [
      (
        "10-users.json",
        (
          #|{ "mocks": [{ "name": "users" }, { "name": "users" }] }
        ),
      ),
    ],
    dir => {
      let (status, stdout, stderr) = smock_output(["check", dir])
      let (dumped_status, dumped, dumped_stderr) = smock_output(
        ["check", dir],
        dump=true,
      )
      let lines = dumped.split("\n").map(line => line.to_owned()).collect()
      guard lines.search("----- BEGIN MOONBIT COVERAGE -----") is Some(begin) else {
        fail("no coverage counters on stdout:\n\{dumped}")
      }
      // The output ends with a newline, so the last piece is empty.
      let before = lines[:begin].iter().map(line => "\{line}\n").join("")
      inspect(
        (
          $|exit status \{status}, and \{dumped_status} with the variable
          $|stdout without the variable is empty: \{stdout == ""}
          $|stdout with it, before the counters, the same: \{before == stdout}
          $|then: \{counters_shape(lines[begin:lines.length() - 1])}
          $|then the end of stdout: \{lines[lines.length() - 1] == ""}
          $|stderr the same: \{dumped_stderr == stderr}
        ),
        content=(
          #|exit status 1, and 1 with the variable
          #|stdout without the variable is empty: false
          #|stdout with it, before the counters, the same: true
          #|then: the coverage counters
          #|then the end of stdout: true
          #|stderr the same: true
        ),
      )
    },
  )
}
