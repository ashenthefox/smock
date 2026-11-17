// Seam 2 tests of the write timeout: smock closes a connection once a write
// to it has waited on the client for --write-timeout-ms without progress, as
// when the client stops reading, on every listener and for every kind of
// response. A client that reads slowly but steadily, and smock's own waits,
// are never cut.

///|
/// Sends `request` on `conn` again and again, pipelined, and never reads,
/// until a write fails because smock has closed the connection. Returns how
/// many milliseconds after `since` that was. smock reads nothing while a
/// response waits on the client, so it has requests left unread when it
/// closes the connection, and the client gets a reset, which fails the
/// write that waits.
async fn send_until_closed(
  conn : Conn,
  request : String,
  since : Int64,
) -> Int64 {
  let batch = @utf8.encode(request.repeat(64 * 1024 / request.length() + 1))
  let result = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      conn.write(batch) catch {
        _ => break
      }
    }
  })
  guard result is Some(_) else { fail("the connection stayed open") }
  @async.now() - since
}

///|
async test "write timeout: a client that stops reading is closed once smock's write to it has waited the write timeout, whether it writes a response at once, after a delay, in part or as a stream" {
  let stopped = on_both_ports(
    files=big_files(),
    args=["--write-timeout-ms", "500"],
    (smock, over) => {
      // A connection whose write makes no progress for the write timeout
      // closes (docs/running.md, The write timeout). The test allows up to
      // 6 times it, as it always has.
      let write = 500L
      let out = []
      for path in ["/big", "/delayed", "/half", "/events"] {
        let conn = smock.connect(over~)
        defer conn.close()
        let since = @async.now()
        let elapsed = send_until_closed(
          conn,
          "GET \{path} HTTP/1.1\r\nHost: localhost\r\n\r\n",
          since,
        )
        out.push(
          "\{path}: closed after at least 500 ms: \{elapsed >= write}, within 6 times the write timeout: \{elapsed < 6 * write}",
        )
      }
      inspect(
        out.join("\n"),
        content=(
          #|/big: closed after at least 500 ms: true, within 6 times the write timeout: true
          #|/delayed: closed after at least 500 ms: true, within 6 times the write timeout: true
          #|/half: closed after at least 500 ms: true, within 6 times the write timeout: true
          #|/events: closed after at least 500 ms: true, within 6 times the write timeout: true
        ),
      )
    },
  )
  // Timeouts are not logged one by one.
  inspect(log_entries(stopped.logs), content=startup_only)
}

///|
async test "write timeout: an Admin API client that stops reading is closed too, with the timeout from SMOCK_WRITE_TIMEOUT_MS" {
  with_definitions(big_files(), dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0"],
      env={ "SMOCK_WRITE_TIMEOUT_MS": "500" },
      smock => {
        let conn = PlainConn(
          @socket.Tcp::connect(
            @socket.Addr::parse("127.0.0.1:\{smock.admin_port}"),
          ),
        )
        defer conn.close()
        // The metrics, asked for again and again: each response is a few
        // KiB, so that they fill the socket buffers. The write timeout runs
        // "on every port and for every write", an Admin API reply included
        // (docs/running.md, The write timeout); the test allows up to 6
        // times it, as it always has.
        let write = 500L
        let since = @async.now()
        let elapsed = send_until_closed(
          conn, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n", since,
        )
        inspect(
          "closed after at least 500 ms: \{elapsed >= write}, within 6 times the write timeout: \{elapsed < 6 * write}",
          content="closed after at least 500 ms: true, within 6 times the write timeout: true",
        )
      },
    )
    inspect(
      log_entries(stopped.logs),
      content=(
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*","protocols":["http/1.1"]}
        #|{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"*","names":["localhost","127.0.0.1","::1"]}
        #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*","protocols":["http/1.1","h2c"]}
        #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*","protocols":["h2","http/1.1"]}
        #|{"level":"info","msg":"drain started","timeoutMs":20000}
        #|{"level":"info","msg":"drain ended","connectionsCut":0}
      ),
    )
  })
}

///|
async test "write timeout: a client that reads slowly but steadily gets the whole response, though smock's write waits on it for well over the write timeout in all" {
  let stopped = on_both_ports(
    files=big_files(),
    args=["--write-timeout-ms", "500"],
    (smock, over) => {
      let conn = smock.connect(over~)
      defer conn.close()
      let since = @async.now()
      conn.write("GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n")
      let head = read_head(conn)
      // 256 KiB every 25 ms, about 10 MiB a second: the body takes at least
      // 1.6 s. The socket buffers hold a few MiB of it, so smock's write
      // waits for most of that time, but never 500 ms without progress.
      let chunk = 256 * 1024
      let expected = @utf8.encode(big_line.repeat(chunk / big_line.length()))
      let mut whole = true
      let mut received = 0
      while received < big_size {
        let bytes = @async.with_timeout_opt(patience_ms, () => {
          conn.read_exactly(chunk)
        })
        guard bytes is Some(bytes) else { fail("no more of the body in time") }
        whole = whole && bytes == expected
        received += bytes.length()
        @async.sleep(25)
      }
      let elapsed = @async.now() - since
      inspect(
        (
          $|\{status_line(head)}
          $|the whole body: \{whole}
          $|in at least three times the write timeout: \{elapsed >= 1500}
        ),
        content=(
          #|HTTP/1.1 200 OK
          #|the whole body: true
          #|in at least three times the write timeout: true
        ),
      )
    },
  )
  inspect(log_entries(stopped.logs), content=startup_only)
}

///|
async test "write timeout: smock's own waits do not count, so a delay Fault and delays between Server-Sent Events longer than the write timeout still give the whole response" {
  // `outlasting`: `/slow` answers after 1000 ms, and `/events` streams three
  // events 400 ms apart.
  let stopped = on_both_ports(
    files=[("users.json", outlasting)],
    args=["--write-timeout-ms", "300"],
    (smock, over) => {
      let delayed = smock.connect(over~)
      defer delayed.close()
      delayed.write("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n")
      let response = read_response(delayed)
      let stream = smock.connect(over~)
      defer stream.close()
      stream.write(
        "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
      )
      let (_, streamed) = ended(stream, @async.now())
      inspect(
        "delayed: \{response.escape()}\nstreamed: \{streamed.escape()}",
        content=(
          #|delayed: "HTTP/1.1 200 OK\nSmock-Mock: users; via=default\nDate: <now>\nContent-Length: 4\n\nslow"
          #|streamed: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nSmock-Mock: users; via=default\r\nDate: <now>\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\nd\r\ndata: first\n\n\r\ne\r\ndata: second\n\n\r\nc\r\ndata: last\n\n\r\n0\r\n\r\n"
        ),
      )
    },
  )
  inspect(log_entries(stopped.logs), content=startup_only)
}
