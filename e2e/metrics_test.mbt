// Seam 2 tests of the Prometheus metrics on the admin port. Every response
// is checked against the OpenAPI document (contract_test.mbt).

///|
async test "the build-info metric carries the version, commit and toolchain smock --version prints, as labels" {
  let (_, version_line) = smock_stdout(["--version"])
  let (version, commit, toolchain) = version_parts(version_line)
  let build_info = "smock_build_info{version=\"\{version}\",commit=\"\{commit}\",toolchain=\"\{toolchain}\"} 1"
  let _ = with_smock(["--port", "0"], smock => {
    let response = smock.admin("GET", "/metrics")
    let lines = metric_lines(response.body, "smock_build_info", help=true).map(line => {
      if line == build_info {
        "<build info>"
      } else {
        line
      }
    })
    inspect(
      "\{response.status} \{response.header("Content-Type").unwrap_or("")}\n\{lines.join("\n")}",
      content=(
        #|200 text/plain; version=0.0.4; charset=utf-8
        #|# HELP smock_build_info The smock build: its version, commit and MoonBit toolchain, as labels. Always 1.
        #|# TYPE smock_build_info gauge
        #|<build info>
      ),
    )
  })
}

///|
async test "/metrics needs no token, also with authentication on, and names the replica" {
  let (_, uname) = @process.collect_stdout("uname", ["-n"])
  let host = uname.text().trim().to_owned()
  let _ = with_smock(["--port", "0"], smock => {
    let out = []
    for call in [("no token", None), ("a wrong token", Some("wrong"))] {
      let (name, token) = call
      let response = smock.admin("GET", "/metrics", token~)
      let replica = response.header("Smock-Replica") == Some(host)
      out.push(
        "\{name}: \{response.status}, Smock-Replica is the host name: \{replica}",
      )
    }
    out.push(
      "status without a token: \{smock.admin("GET", "/v1/status", token=None).status}",
    )
    inspect(
      out.join("\n"),
      content=(
        #|no token: 200, Smock-Replica is the host name: true
        #|a wrong token: 200, Smock-Replica is the host name: true
        #|status without a token: 401
      ),
    )
  })
}
