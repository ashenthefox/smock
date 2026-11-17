// Seam 2 tests of the mockoon log format's error lines: when a Stub's
// template cannot be rendered or its data write cannot be applied, smock
// writes `Error while serving the content: …` to stdout, after the
// response's last byte, just before the request's Transaction recorded
// line, whether or not the Journal records the request. Lines are compared
// whole, byte for byte, with only the value of `timestamp` masked, once
// its form is checked.

///|
async test "a template failure, a data write failure and a variable value that fails each write the error line, then the Transaction recorded line, with the Journal on, off globally and off for the Mock" {
  // The Mock's journal and SMOCK_JOURNAL: off globally, off for the Mock,
  // then on.
  let runs = [(true, "off"), (false, "on"), (true, "on")]
  let out = []
  let recorded = []
  for run in runs {
    let (journal, global) = run
    with_definitions(failing_shop(journal~), dir => {
      let env = { "SMOCK_LOG_FORMAT": "mockoon", "SMOCK_JOURNAL": global }
      let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
        let statuses = [
          smock.send("POST", "/orders", body="{\"customer\":{}}"),
          smock.send("POST", "/visits"),
          smock.send("POST", "/count", body="{}"),
        ].map(status_line)
        smock.transaction_lines(3) |> ignore
        let lines = served_lines(smock.stdout)
        recorded.push(
          match smock.journal() {
            (200, Object({ "entries": Array(entries), .. })) =>
              "\{entries.length()} entries"
            (status, _) => "the query answers \{status}"
          },
        )
        // Each line takes its own time, and the error line comes first.
        let mut ordered = true
        for i in 0..<(lines.length() / 2) {
          if written_at(lines[2 * i]) > written_at(lines[2 * i + 1]) {
            ordered = false
          }
        }
        out.push(
          (
            $|\{statuses.join("\n")}
            $|\{masked_lines(lines)}
            $|each error line written at or before its Transaction recorded line: \{ordered}
          ),
        )
      })
    })
  }
  inspect(
    (
      $|\{out[2]}
      $|the same with the Journal off globally: \{out[0] == out[2]}
      $|the same with the Journal off for the Mock: \{out[1] == out[2]}
      $|Journal off globally, off for the Mock, on: \{recorded.join(", ")}
    ),
    content=(
      #|HTTP/1.1 500 Internal Server Error
      #|HTTP/1.1 500 Internal Server Error
      #|HTTP/1.1 500 Internal Server Error
      #|{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: body.customer.name is missing","routePath":"/orders","routeUUID":"create-order","timestamp":"<timestamp>"}
      #|{"app":"smock","environmentName":"shop","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/orders","requestProxied":false,"responseStatus":500,"timestamp":"<timestamp>"}
      #|{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: the Data bucket \"visits\" holds a number, and \"merge\" needs an object","routePath":"/visits","routeUUID":"visit","timestamp":"<timestamp>"}
      #|{"app":"smock","environmentName":"shop","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/visits","requestProxied":false,"responseStatus":500,"timestamp":"<timestamp>"}
      #|{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: body.count is missing","routePath":"/count","routeUUID":"count","timestamp":"<timestamp>"}
      #|{"app":"smock","environmentName":"shop","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/count","requestProxied":false,"responseStatus":500,"timestamp":"<timestamp>"}
      #|each error line written at or before its Transaction recorded line: true
      #|the same with the Journal off globally: true
      #|the same with the Journal off for the Mock: true
      #|Journal off globally, off for the Mock, on: the query answers 409, 0 entries, 3 entries
    ),
  )
}

///|
async test "after a delay, a template failure writes the error line and the Transaction recorded line once the delay is over" {
  with_definitions(failing_shop(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let conn = smock.connect()
      defer conn.close()
      let start = @async.now()
      conn.write(
        raw_request("POST", "/slow-orders", host="localhost", body="{}"),
      )
      @async.sleep(500)
      let during = served_lines(smock.stdout).length()
      let status = status_line(read_response(conn))
      smock.transaction_lines(1) |> ignore
      let lines = served_lines(smock.stdout)
      let late = lines
        .iter()
        .all(line => (written_at(line) - start >= 1000) catch { _ => false })
      inspect(
        (
          $|during the delay: \{during} lines
          $|\{status}
          $|\{masked_lines(lines)}
          $|both written once the delay was over: \{late}
        ),
        content=(
          #|during the delay: 0 lines
          #|HTTP/1.1 500 Internal Server Error
          #|{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: body.customer.name is missing","routePath":"/slow-orders","routeUUID":"slow-order","timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/slow-orders","requestProxied":false,"responseStatus":500,"timestamp":"<timestamp>"}
          #|both written once the delay was over: true
        ),
      )
    })
  })
}

///|
async test "when a reset Fault replaces the 500 of a template failure, the error line is still written, and the Transaction recorded line shows the Fault" {
  with_definitions(failing_shop(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let conn = smock.connect()
      defer conn.close()
      conn.write(
        raw_request("POST", "/reset-orders", host="localhost", body="{}"),
      )
      let (received, ending) = sent_until_end(conn, within=patience_ms)
      smock.transaction_lines(1) |> ignore
      inspect(
        (
          $|\{received.length()} bytes, then \{ending}
          $|\{masked_lines(served_lines(smock.stdout))}
        ),
        content=(
          #|0 bytes, then an RST
          #|{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: body.customer.name is missing","routePath":"/reset-orders","routeUUID":"reset-order","timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","fault":"reset","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/reset-orders","requestProxied":false,"timestamp":"<timestamp>"}
        ),
      )
    })
  })
}

///|
async test "a 507 from the state bound, a CRUD Stub's 404 and 400, and a no-match 404 write no error line" {
  with_definitions(failing_shop(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let args = ["--dir", dir, "--port", "0", "--state-max-bytes", "256"]
    let _ = with_smock(args, env~, smock => {
      let statuses = [
        smock.send("POST", "/big", body="\"\{"x".repeat(300)}\""),
        smock.send("GET", "/items/nope"),
        smock.send("POST", "/items", body="[]"),
        smock.send("GET", "/nope"),
      ].map(status_line)
      smock.transaction_lines(4) |> ignore
      inspect(
        (
          $|\{statuses.join("\n")}
          $|\{masked_lines(served_lines(smock.stdout))}
        ),
        content=(
          #|HTTP/1.1 507 
          #|HTTP/1.1 404 Not Found
          #|HTTP/1.1 400 Bad Request
          #|HTTP/1.1 404 Not Found
          #|{"app":"smock","environmentName":"shop","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/big","requestProxied":false,"responseStatus":507,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/items/nope","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/items","requestProxied":false,"responseStatus":400,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/nope","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
        ),
      )
    })
  })
}
