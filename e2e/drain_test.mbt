// Seam 2 tests of the drain on SIGTERM: smock stops accepting connections,
// closes the idle ones, lets responses in progress finish, cuts what is
// still running when the drain timeout expires, and exits with status 0.

///|
/// Whether a new connection to `port` is accepted or refused.
async fn connection_to(port : Int32) -> String {
  try @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{port}")) catch {
    err =>
      if err.to_string().contains("Connection refused") {
        "refused"
      } else {
        "failed: \{err}"
      }
  } noraise {
    conn => {
      conn.close()
      "accepted"
    }
  }
}

///|
async test "on SIGTERM, smock refuses new connections, closes idle ones at once, fails /readyz, finishes the responses in progress, closing their connections after them, and exits with status 0 as soon as nothing is in flight" {
  with_definitions([("m.json", drain_defs)], dir => {
    with_certificates(certs => {
      let stopped = with_smock(
        [
          "--dir",
          dir,
          "--port",
          "0",
          "--drain-timeout-ms",
          "10000",
          ..certs.args(),
        ],
        smock => {
          let idle = []
          for over in [Plain, Tls(certs)] {
            let conn = smock.connect(over~)
            conn.write("GET /fast HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let _ = read_response(conn)
            idle.push(conn)
          }
          defer idle.each(conn => conn.close())
          let slow = smock.connect()
          defer slow.close()
          slow.write("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n")
          // A stream that began before SIGTERM, and ends during the drain.
          let stream = smock.connect()
          defer stream.close()
          stream.write("GET /brief HTTP/1.1\r\nHost: localhost\r\n\r\n")
          let _ = read_head(stream)
          @async.sleep(settle_ms)
          // As docs/running.md's The drain says: idle keep-alive connections
          // "close at once", before the response in progress, due about
          // 700 ms after SIGTERM, is answered; responses in progress finish;
          // and smock exits "as soon as nothing is in flight, and at the
          // latest when the drain timeout ... expires", so before it.
          let drain = 10000L
          let start = @async.now()
          smock.terminate()
          let out = []
          // The response in progress is read beside the rest, keeping when
          // it came.
          let (idle_ends, during, (response, answered)) = @async.with_task_group(group => {
              let answer = group.spawn(() => {
                let response = read_response(slow)
                (response, @async.now() - start)
              })
              let ends = []
              for conn in idle {
                ends.push(ended(conn, start))
              }
              // Read before smock exits, once the response and the stream
              // are over.
              let during = [
                smock.probes(),
                "new plain connection: \{connection_to(smock.port)}",
                "new TLS connection: \{connection_to(smock.tls_port)}",
              ]
              (ends, during, answer.wait())
            },
          )
          for i, idle_end in idle_ends {
            let (elapsed, received) = idle_end
            out.push(
              "idle \{["plain", "TLS"][i]} connection closed at once, before the response in progress was answered: \{elapsed < answered && received == ""}",
            )
          }
          out.append(during)
          out.push(response)
          out.push(
            "answered after its delay, before the drain timeout: \{answered < drain}",
          )
          out.push("then closed: \{closed(slow)}")
          let (_, stream_end, events) = until_end(stream, start)
          out.push(
            "the stream ended with its last chunk: \{events.has_suffix("\n0\n\n")}, then closed, before the drain timeout: \{stream_end < drain}",
          )
          let status = smock.exited()
          let exited = @async.now() - start
          out.push(
            "exit status \{status}, once nothing was in flight, before the drain timeout: \{exited < drain}",
          )
          inspect(
            out.join("\n"),
            content=(
              #|idle plain connection closed at once, before the response in progress was answered: true
              #|idle TLS connection closed at once, before the response in progress was answered: true
              #|/startupz: 200 {"status":"ok","warnings":[]}
              #|/readyz: 503 {"error":"not_ready","message":"smock is draining its connections before it exits","warnings":[]}
              #|/livez: 200 {"status":"ok","warnings":[]}
              #|new plain connection: refused
              #|new TLS connection: refused
              #|HTTP/1.1 200 OK
              #|Smock-Mock: m; via=default
              #|Date: <now>
              #|Connection: close
              #|Content-Length: 4
              #|
              #|slow
              #|answered after its delay, before the drain timeout: true
              #|then closed: true
              #|the stream ended with its last chunk: true, then closed, before the drain timeout: true
              #|exit status 0, once nothing was in flight, before the drain timeout: true
            ),
          )
        },
      )
      inspect(
        drain_entries(stopped.logs),
        content=(
          #|{"level":"info","msg":"drain started","timeoutMs":10000}
          #|{"level":"info","msg":"drain ended","connectionsCut":0}
        ),
      )
    })
  })
}

///|
async test "a request still arriving when SIGTERM comes is answered once the rest of it arrives, with Connection: close, and its connection closes after the response" {
  with_definitions([("m.json", drain_defs)], dir => {
    with_certificates(certs => {
      let _ = with_smock(
        [
          "--dir",
          dir,
          "--port",
          "0",
          "--drain-timeout-ms",
          "10000",
          ..certs.args(),
        ],
        smock => {
          let conns = []
          for over in [Plain, Tls(certs)] {
            let conn = smock.connect(over~)
            // The head, without the empty line that ends it.
            conn.write("GET /fast HTTP/1.1\r\nHost: localhost\r\n")
            conns.push(conn)
          }
          defer conns.each(conn => conn.close())
          @async.sleep(settle_ms)
          smock.terminate()
          @async.sleep(settle_ms)
          let out = []
          for i, conn in conns {
            conn.write("\r\n")
            out.push("\{["plain", "TLS"][i]}:")
            out.push(read_response(conn))
            out.push("then closed: \{closed(conn)}")
          }
          out.push("exit status \{smock.exited()}")
          inspect(
            out.join("\n"),
            content=(
              #|plain:
              #|HTTP/1.1 200 OK
              #|Smock-Mock: m; via=default
              #|Date: <now>
              #|Connection: close
              #|Content-Length: 4
              #|
              #|fast
              #|then closed: true
              #|TLS:
              #|HTTP/1.1 200 OK
              #|Smock-Mock: m; via=default
              #|Date: <now>
              #|Connection: close
              #|Content-Length: 4
              #|
              #|fast
              #|then closed: true
              #|exit status 0
            ),
          )
        },
      )
    })
  })
}

///|
async test "Server-Sent Event streams and delays still running when the drain timeout expires are cut, and smock exits with status 0" {
  with_definitions([("m.json", drain_defs)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0"],
      env={ "SMOCK_DRAIN_TIMEOUT_MS": "1500" },
      smock => {
        let stream = smock.connect()
        defer stream.close()
        stream.write("GET /ticks HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let _ = read_head(stream)
        let stalled = smock.connect()
        defer stalled.close()
        stalled.write("GET /stalled HTTP/1.1\r\nHost: localhost\r\n\r\n")
        @async.sleep(settle_ms)
        // The drain timeout cuts what is still running (docs/running.md, The
        // drain). The test allows up to 3 times it, still well before the
        // stream's own end (10 s) and the delay's (60 s).
        let drain = 1500L
        let start = @async.now()
        smock.terminate()
        let (streamed, delayed) = @async.with_task_group(group => {
          let streamed = group.spawn(() => until_end(stream, start))
          let delayed = group.spawn(() => until_end(stalled, start))
          (streamed.wait(), delayed.wait())
        })
        let status = smock.exited()
        let exited = @async.now() - start
        let (last_event, stream_end, events) = streamed
        let (_, delay_end, response) = delayed
        inspect(
          (
            $|the stream went on during the drain: \{last_event >= 1000}
            $|then was cut at the drain timeout: \{stream_end >= drain && stream_end < 3 * drain}
            $|without its last chunk: \{!events.has_suffix("0\n\n")}
            $|the delayed response was cut at the drain timeout: \{delay_end >= drain && delay_end < 3 * drain}
            $|before a byte of it was sent: \{response == ""}
            $|exit status \{status}, once the drain timeout expired: \{exited >= drain && exited < 3 * drain}
          ),
          content=(
            #|the stream went on during the drain: true
            #|then was cut at the drain timeout: true
            #|without its last chunk: true
            #|the delayed response was cut at the drain timeout: true
            #|before a byte of it was sent: true
            #|exit status 0, once the drain timeout expired: true
          ),
        )
      },
    )
    inspect(
      drain_entries(stopped.logs),
      content=(
        #|{"level":"info","msg":"drain started","timeoutMs":1500}
        #|{"level":"info","msg":"drain ended","connectionsCut":2}
      ),
    )
  })
}

///|
async test "a client that stops reading does not hold up the drain: with a longer write timeout, its connection is cut at the drain timeout, on the plain and the TLS port" {
  with_definitions(big_files(), dir => {
    with_certificates(certs => {
      let stopped = with_smock(
        [
          "--dir",
          dir,
          "--port",
          "0",
          "--drain-timeout-ms",
          "1000",
          "--write-timeout-ms",
          "30000",
          ..certs.args(),
        ],
        smock => {
          // Each asks for the large body and never reads, so smock's write
          // waits on it until the drain timeout cuts it.
          let stuck = []
          for over in [Plain, Tls(certs)] {
            let conn = smock.connect(over~)
            conn.write("GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n")
            stuck.push(conn)
          }
          defer stuck.each(conn => conn.close())
          @async.sleep(settle_ms)
          // The drain timeout cuts the stuck writes (docs/running.md, The
          // drain), long before the write timeout would. The test allows up
          // to 3 times the drain timeout.
          let drain = 1000L
          let start = @async.now()
          smock.terminate()
          let status = smock.exited()
          let exited = @async.now() - start
          inspect(
            "exit status \{status}, once the drain timeout expired: \{exited >= drain && exited < 3 * drain}",
            content="exit status 0, once the drain timeout expired: true",
          )
        },
      )
      inspect(
        drain_entries(stopped.logs),
        content=(
          #|{"level":"info","msg":"drain started","timeoutMs":1000}
          #|{"level":"info","msg":"drain ended","connectionsCut":2}
        ),
      )
    })
  })
}

///|
async test "SIGINT and SIGHUP end smock at once, without a drain: a response still delayed is cut, and nothing about a drain is logged" {
  with_definitions([("m.json", drain_defs)], dir => {
    let out = []
    for signal in ["INT", "HUP"] {
      let stopped = with_smock(
        ["--dir", dir, "--port", "0", "--drain-timeout-ms", "10000"],
        smock => {
          let stalled = smock.connect()
          defer stalled.close()
          stalled.write("GET /stalled HTTP/1.1\r\nHost: localhost\r\n\r\n")
          @async.sleep(settle_ms)
          // SIGINT and SIGHUP "end smock at once" (docs/running.md, The
          // drain): before the drain timeout that a drain would wait for.
          let drain = 10000L
          let start = @async.now()
          let _ = @process.run("kill", ["-\{signal}", smock.pid.to_string()])
          let (_, end, response) = until_end(stalled, start)
          let status = smock.exited()
          let exited = @async.now() - start
          out.push(
            "SIG\{signal}: the delayed response was cut at once, before a drain timeout: \{end < drain && response == ""}; exit status \{status}, at once, before a drain timeout: \{exited < drain}",
          )
        },
      )
      out.push("a drain logged: \{drain_entries(stopped.logs) != ""}")
    }
    inspect(
      out.join("\n"),
      content=(
        #|SIGINT: the delayed response was cut at once, before a drain timeout: true; exit status -2, at once, before a drain timeout: true
        #|a drain logged: false
        #|SIGHUP: the delayed response was cut at once, before a drain timeout: true; exit status -1, at once, before a drain timeout: true
        #|a drain logged: false
      ),
    )
  })
}
