// The ranges of smock serve's numeric settings, at each end: the largest
// value a flag takes is accepted, and one more is refused with the message a
// user sees. The e2e settings test refuses some of these values through the
// binary; these run in-process.

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
