// Seam 2 tests of the probes on the admin port: /startupz, /readyz and
// /livez. Every probe response is checked against the OpenAPI document
// (contract_test.mbt).

///|
async test "the probes need no token while authentication is on, and pass once smock serves" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.probes(),
        content=(
          #|/startupz: 200 {"status":"ok","warnings":[]}
          #|/readyz: 200 {"status":"ok","warnings":[]}
          #|/livez: 200 {"status":"ok","warnings":[]}
        ),
      )
    })
  })
}

///|
/// Starts `smock serve <args>` and runs `f` as soon as smock listens on its
/// admin port, which it opens before it loads its definitions; then stops
/// smock with SIGTERM and waits for it to exit. `f` gets smock without its
/// plain and TLS ports, which are not known yet (0).
async fn while_starting(
  args : Array[String],
  f : async (Smock) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let serving = Serving::start(group, args)
    guard serving.listening_on(["admin"]) is Some(ports) else {
      fail("smock exited before it listened on its admin port")
    }
    f(serving.smock(ports))
    let _ = serving.stop()
  })
}

///|
/// What the probes and status answer, without a token for the probes, as
/// `<path> <status>`, with the error code of a failure. With `messages`,
/// the message of each failure is added to it, as `<path>: <message>`.
async fn Smock::startup_state(
  self : Smock,
  messages? : Array[String],
) -> String {
  let out = []
  for path in [..probes, "/v1/status"] {
    let token = if path == "/v1/status" { Some(test_token) } else { None }
    let response = self.admin("GET", path, token~)
    let code = match response.json() {
      Object(body) => {
        if messages is Some(messages) &&
          body.get("message") is Some(String(message)) {
          messages.push("\{path}: \{message}")
        }
        match body.get("error") {
          Some(String(code)) => " \{code}"
          _ => ""
        }
      }
      _ => ""
    }
    out.push("\{path} \{response.status}\{code}")
  }
  out.join(", ")
}

///|
async test "until the first definition set has loaded, /startupz and /readyz fail with not_started while /livez passes" {
  // Enough Definition files that smock takes a while to load them, so that
  // the first answers come before it has.
  let files = [("mocks.json", "{ \"mocks\": [{ \"name\": \"m\" }] }")]
  for i in 0..<3000 {
    files.push(
      (
        "stub-\{i}.json",
        "{ \"stubs\": [{ \"id\": \"s\{i}\", \"mock\": \"m\", \"request\": { \"path\": \"/\{i}\" }, \"response\": { \"status\": 200 } }] }",
      ),
    )
  }
  with_definitions(files, dir => {
    while_starting(["--dir", dir, "--port", "0"], smock => {
      let messages = []
      let first = smock.startup_state(messages~)
      let mut last = first
      let mut startup_passed = false
      let mut startup_kept = true
      let started = @async.with_timeout_opt(patience_ms, () => {
        while !last.has_prefix("/startupz 200, /readyz 200") {
          last = smock.startup_state()
          let startup = last.has_prefix("/startupz 200")
          if startup_passed && !startup {
            startup_kept = false
          }
          startup_passed = startup_passed || startup
        }
      })
      guard started is Some(_) else { fail("smock did not start in time") }
      // The message of not_started is the one openapi/admin.json gives it
      // (ErrorCode): "the first definition set has not loaded yet".
      inspect(
        (
          $|first: \{first}
          $|its messages: \{messages.join("; ")}
          $|then: \{last}
          $|/startupz never failed again once it passed: \{startup_kept}
        ),
        content=(
          #|first: /startupz 503 not_started, /readyz 503 not_started, /livez 200, /v1/status 503 not_started
          #|its messages: /startupz: the first definition set has not loaded yet; /readyz: the first definition set has not loaded yet; /v1/status: the first definition set has not loaded yet
          #|then: /startupz 200, /readyz 200, /livez 200, /v1/status 200
          #|/startupz never failed again once it passed: true
        ),
      )
    })
  })
}

///|
/// Opens the FIFO at `path` for writing, which waits until smock opens it
/// for reading, and returns it. Fails the test when smock has not opened
/// it in time.
async fn fifo_writer(path : String) -> @fs.File {
  let fifo = @async.with_timeout_opt(patience_ms, () => {
    @fs.open(path, mode=WriteOnly)
  })
  guard fifo is Some(fifo) else { fail("smock did not open \{path} in time") }
  fifo
}

///|
async test "after the first definition set has loaded and before the plain and TLS ports open, /readyz fails with not_ready while /startupz passes" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      // FIFOs as the certificate and key files hold smock in that window:
      // smock reads the files after the first definition set has loaded and
      // before it opens the plain and TLS ports (#291), and the read of each
      // lasts until the test has written it and closed the FIFO.
      let cert = "\{certs.dir}/fifo-chain.pem"
      let key = "\{certs.dir}/fifo-key.pem"
      let (status, output) = @process.collect_output_merged("mkfifo", [
        cert, key,
      ])
      guard status == 0 else { fail("mkfifo failed: \{output.text()}") }
      @async.with_task_group(group => {
        let serving = Serving::start(
          group,
          ["--dir", dir, "--port", "0", ..certs.args(cert~, key~)],
        )
        // Before its admin port opens, smock opens the certificate file and
        // then the key file to note their times, for the polls that rotate
        // certificates: let both opens through. An open of a FIFO waits for
        // the other end, whichever side comes first. A writer of this test
        // still open when smock opens a file to read it would let that open
        // through, and the read would end empty when the writer closed. So
        // each writer closes before the next one opens, and smock gets past
        // each open only once a writer opens: it reaches the read of the
        // certificate after the key's writer opened, so after the
        // certificate's first writer closed.
        fifo_writer(cert).close()
        fifo_writer(key).close()
        guard serving.listening_on(["admin"]) is Some(ports) else {
          fail("smock exited before it listened on its admin port")
        }
        let smock = serving.smock(ports)
        // Then it reads the certificate file, once the first definition set
        // has loaded, and then the key file, after the certificate's writer
        // has closed, so after the key's first writer closed too.
        let writer = fifo_writer(cert)
        let during = smock.probes()
        writer.write(@utf8.encode(@testcerts.rsa_chain + "\n"))
        writer.close()
        let writer = fifo_writer(key)
        writer.write(@utf8.encode(@testcerts.rsa_key + "\n"))
        writer.close()
        guard serving.listening_on(["plain", "tls"]) is Some(_) else {
          fail("smock exited before it listened:\n\{serving.log().join("\n")}")
        }
        // The probes answer as docs/admin-api.md, Probes, says, and with the
        // error shape when they fail: /readyz fails "with `not_ready` ("the
        // plain and TLS ports are not open yet") after that [the first
        // definition set has loaded] and until smock listens on the plain
        // and TLS ports", which the maintainer confirmed on 2026-11-17
        // (#275), as #291's criterion gives it; openapi/admin.json's
        // ErrorCode makes not_ready a 503.
        inspect(
          (
            $|while smock reads the certificate file:
            $|\{during}
            $|once it listens on the plain and TLS ports:
            $|\{smock.probes()}
          ),
          content=(
            #|while smock reads the certificate file:
            #|/startupz: 200 {"status":"ok","warnings":[]}
            #|/readyz: 503 {"error":"not_ready","message":"the plain and TLS ports are not open yet","warnings":[]}
            #|/livez: 200 {"status":"ok","warnings":[]}
            #|once it listens on the plain and TLS ports:
            #|/startupz: 200 {"status":"ok","warnings":[]}
            #|/readyz: 200 {"status":"ok","warnings":[]}
            #|/livez: 200 {"status":"ok","warnings":[]}
          ),
        )
        let _ = serving.stop()
      })
    })
  })
}

///|
async test "after a failed reload, /readyz still passes and the previous definition set keeps serving" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let before = smock.status()
      write(dir, "users.json", "{ \"stubs\": [{ \"id\": 7 }] }")
      let after = smock.reloaded(before)
      inspect(
        (
          $|reload: \{last_reload(after).split("\n").next().unwrap_or("")}
          $|\{smock.probes()}
          $|/users/1: \{smock.brief("/users/1")}
        ),
        content=(
          #|reload: "failed"
          #|/startupz: 200 {"status":"ok","warnings":[]}
          #|/readyz: 200 {"status":"ok","warnings":[]}
          #|/livez: 200 {"status":"ok","warnings":[]}
          #|/users/1: 200 {"id":1,"name":"Alice"}
        ),
      )
    })
  })
}
