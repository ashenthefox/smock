// The ranges of smock serve's numeric settings, at each end: the value at
// each end is accepted, and the value just past it is refused with the
// message a user sees, as is a value that is not a decimal integer. Each is
// given by the flag and, apart, by its variable, which the Settings table
// pairs with it (#320). The e2e settings test refuses some of these values
// through the binary; these run in-process. The message names the flag and
// its variable, as docs/running.md's Settings table pairs them, in the form
// `InvalidSetting::message` documents, and the range in the words `must be
// an integer from <min> to <max>`. No document gives those words: they are
// the code's, which the maintainer confirmed on 2026-11-17 (#275), and the
// e2e settings test pins them too.

///|
/// What `smock serve <argv>` makes of its settings: `show` of the settings
/// when they are valid, or the message a user sees when they are not.
fn serve_with(
  argv : Array[String],
  show : (@settings.ServeSettings) -> Int32,
) -> String {
  let matches = @settings.serve_command().parse(argv~, env={}) catch {
    err => return "parse: \{err}"
  }
  try @settings.ServeSettings::from_matches(matches) catch {
    err => err.message()
  } noraise {
    settings => show(settings).to_string()
  }
}

///|
/// What `smock serve` makes of `value`, given by the flag `flag` and, apart,
/// by its variable `variable`: `show` of the settings when they are valid,
/// or the message a user sees when they are not, after the value and a
/// colon. One result when the flag and the variable give the same, as the
/// Settings table pairs them, and both when they do not.
fn by_flag_and_variable(
  flag : String,
  variable : String,
  value : String,
  show : (@settings.ServeSettings) -> String,
) -> String {
  let read = (argv : Array[String], env : Map[String, String]) => {
    let matches = @settings.serve_command().parse(argv~, env~) catch {
      err => return "parse: \{err}"
    }
    try @settings.ServeSettings::from_matches(matches) catch {
      err => err.message()
    } noraise {
      settings => show(settings)
    }
  }
  // `--port=-1`, as a user gives a value that starts with `-`.
  let by_flag = read(["\{flag}=\{value}"], {})
  let by_variable = read([], Map([(variable, value)]))
  if by_flag == by_variable {
    "\{value}: \{by_flag}"
  } else {
    "\{value}: \{by_flag}; by \{variable}: \{by_variable}"
  }
}

///|
/// `by_flag_and_variable` for each of `values`, one line each.
fn each_by_flag_and_variable(
  flag : String,
  variable : String,
  values : Array[String],
  show : (@settings.ServeSettings) -> String,
) -> String {
  values
  .map(value => by_flag_and_variable(flag, variable, value, show))
  .join("\n")
}

///|
test "ranges: each port, by its flag or its variable, takes 0 and 65535, and refuses -1, 65536 and a value that is not a decimal integer" {
  // docs/running.md, Settings: each port's flag and variable, and "0 picks
  // a free port". RFC 9293, section 3.1: a TCP header's Source Port and
  // Destination Port are 16 bits each, so a port is a number from 0 to
  // 65535.
  inspect(
    [
      each_by_flag_and_variable(
        "--port",
        "SMOCK_PORT",
        ["0", "65535", "-1", "65536", "eighty"],
        settings => settings.port.to_string(),
      ),
      each_by_flag_and_variable(
        "--tls-port",
        "SMOCK_TLS_PORT",
        ["0", "65535", "-1", "65536", "https"],
        settings => settings.tls_port.to_string(),
      ),
      each_by_flag_and_variable(
        "--admin-port",
        "SMOCK_ADMIN_PORT",
        ["0", "65535", "-1", "65536", "0x50"],
        settings => settings.admin_port.to_string(),
      ),
    ].join("\n"),
    content=(
      #|0: 0
      #|65535: 65535
      #|-1: invalid value "-1" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|65536: invalid value "65536" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|eighty: invalid value "eighty" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|0: 0
      #|65535: 65535
      #|-1: invalid value "-1" for --tls-port (SMOCK_TLS_PORT): must be an integer from 0 to 65535
      #|65536: invalid value "65536" for --tls-port (SMOCK_TLS_PORT): must be an integer from 0 to 65535
      #|https: invalid value "https" for --tls-port (SMOCK_TLS_PORT): must be an integer from 0 to 65535
      #|0: 0
      #|65535: 65535
      #|-1: invalid value "-1" for --admin-port (SMOCK_ADMIN_PORT): must be an integer from 0 to 65535
      #|65536: invalid value "65536" for --admin-port (SMOCK_ADMIN_PORT): must be an integer from 0 to 65535
      #|0x50: invalid value "0x50" for --admin-port (SMOCK_ADMIN_PORT): must be an integer from 0 to 65535
    ),
  )
}

///|
test "ranges: each port flag takes 65535, the largest port TCP's 16-bit fields hold, and refuses 65536" {
  // RFC 9293, section 3.1: a TCP header's Source Port and Destination Port
  // are 16 bits each, so 65535 is the largest port.
  let port = (settings : @settings.ServeSettings) => settings.port
  let tls_port = (settings : @settings.ServeSettings) => settings.tls_port
  let admin_port = (settings : @settings.ServeSettings) => settings.admin_port
  inspect(
    [
      serve_with(["--port", "65535"], port),
      serve_with(["--tls-port", "65535"], tls_port),
      serve_with(["--admin-port", "65535"], admin_port),
      serve_with(["--port", "65536"], port),
      serve_with(["--tls-port", "65536"], tls_port),
      serve_with(["--admin-port", "65536"], admin_port),
    ].join("\n"),
    content=(
      #|65535
      #|65535
      #|65535
      #|invalid value "65536" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|invalid value "65536" for --tls-port (SMOCK_TLS_PORT): must be an integer from 0 to 65535
      #|invalid value "65536" for --admin-port (SMOCK_ADMIN_PORT): must be an integer from 0 to 65535
    ),
  )
}

///|
test "ranges: --replicas takes 10000 and refuses 10001" {
  // docs/running.md, Settings: --replicas takes 1 to 10000.
  let replicas = (settings : @settings.ServeSettings) => settings.replicas
  inspect(
    [
      serve_with(["--replicas", "10000"], replicas),
      serve_with(["--replicas", "10001"], replicas),
    ].join("\n"),
    content=(
      #|10000
      #|invalid value "10001" for --replicas (SMOCK_REPLICAS): must be an integer from 1 to 10000
    ),
  )
}

///|
test "ranges: --header-count-limit takes 1073741824 and refuses 1073741825" {
  // docs/running.md, Settings: --header-count-limit takes 1 to 1073741824
  // (2^30).
  let header_count_limit = (settings : @settings.ServeSettings) => {
    settings.header_count_limit
  }
  inspect(
    [
      serve_with(["--header-count-limit", "1073741824"], header_count_limit),
      serve_with(["--header-count-limit", "1073741825"], header_count_limit),
    ].join("\n"),
    content=(
      #|1073741824
      #|invalid value "1073741825" for --header-count-limit (SMOCK_HEADER_COUNT_LIMIT): must be an integer from 1 to 1073741824
    ),
  )
}

///|
test "ranges: --journal-max-entries takes 1073741824 and refuses 1073741825" {
  // docs/running.md, Settings: --journal-max-entries takes 1 to 1073741824
  // (2^30).
  let journal_max_entries = (settings : @settings.ServeSettings) => {
    settings.journal_max_entries
  }
  inspect(
    [
      serve_with(["--journal-max-entries", "1073741824"], journal_max_entries),
      serve_with(["--journal-max-entries", "1073741825"], journal_max_entries),
    ].join("\n"),
    content=(
      #|1073741824
      #|invalid value "1073741825" for --journal-max-entries (SMOCK_JOURNAL_MAX_ENTRIES): must be an integer from 1 to 1073741824
    ),
  )
}
