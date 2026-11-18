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
  // to stdout and exits with 1 (docs/commands.md). The first run is as
  // every test sees smock: without the variable, or, when the tests collect
  // coverage, with it and with the counters taken out by the harness.
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
          $|exit status \{status}, and \{dumped_status} with the counters
          $|stdout as tests see it is empty: \{stdout == ""}
          $|stdout with the counters, before them, the same: \{before == stdout}
          $|then: \{counters_shape(lines[begin:lines.length() - 1])}
          $|then the end of stdout: \{lines[lines.length() - 1] == ""}
          $|stderr the same: \{dumped_stderr == stderr}
        ),
        content=(
          #|exit status 1, and 1 with the counters
          #|stdout as tests see it is empty: false
          #|stdout with the counters, before them, the same: true
          #|then: the coverage counters
          #|then the end of stdout: true
          #|stderr the same: true
        ),
      )
    },
  )
}

///|
async test "with SMOCK_COVERAGE_DUMP set, smock serve writes its coverage counters to stdout as it exits after SIGTERM, after its last log line in the mockoon log format" {
  // #341, as above. docs/running.md: on SIGTERM, smock drains and exits
  // with 0, and the mockoon format "also writes `Server stopped` for each
  // Mock served, right after `drain ended`": here only the Default Mock,
  // with no definitions directory. The first run is as every test sees
  // smock, as above.
  let env = { "SMOCK_LOG_FORMAT": "mockoon" }
  let stopped = with_smock(["--port", "0"], env~, _ => ())
  let dumped = with_smock(["--port", "0"], env~, dump=true, _ => ())
  guard dumped.stdout.search("----- BEGIN MOONBIT COVERAGE -----")
    is Some(begin) else {
    fail("no coverage counters on stdout:\n\{dumped.stdout.join("\n")}")
  }
  let last = (lines : ArrayView[String]) => {
    match lines {
      [.., line] => message_of(line)
      [] => "none"
    }
  }
  inspect(
    (
      $|exit status \{stopped.status}, and \{dumped.status} with the counters
      $|the last log line as tests see them: \{last(stopped.stdout)}
      $|with the counters, before them, as many log lines: \{begin == stopped.stdout.length()}, the last: \{last(dumped.stdout[:begin])}
      $|then: \{counters_shape(dumped.stdout[begin:])}
    ),
    content=(
      #|exit status 0, and 0 with the counters
      #|the last log line as tests see them: Server stopped
      #|with the counters, before them, as many log lines: true, the last: Server stopped
      #|then: the coverage counters
    ),
  )
}
