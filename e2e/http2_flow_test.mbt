// Seam 2 tests of flow control over h2c: a response body larger than the
// client's windows goes out as the windows allow, from a task of its own (a
// slow write), which resumes when the client widens a window, while the
// connection's other streams go on.

///|
/// A response as a test shows it, with its body replaced by whether it is
/// `expected`, and its length.
fn H2Response::checked(self : H2Response, expected : String) -> String {
  let body = @utf8.decode_lossy(self.body)
  let shown : H2Response = { ..self, body: b"", }
  let gap = if self.ended == "end" { "" } else { "\n" }
  "\{shown.render()}\{gap}body: \{self.body.length()} octets, as the Stub gives it: \{body == expected}"
}

///|
async test "h2c: a response body larger than both of the client's windows goes out within them, as the client widens them, and arrives in full" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let response = client.request("GET", "/big", authority="localhost")
      let entries = smock.journal_once(1, within=patience_ms)
      inspect(
        [response.checked(big_body), ..entries].join("\n"),
        content=(
          #|200
          #|accept-ranges: bytes
          #|date: <now>
          #|content-length: 150000
          #|
          #|body: 150000 octets, as the Stub gives it: true
          #|/big: stub "big", status 200
        ),
      )
    })
  })
}

///|
async test "h2c: a client SETTINGS frame that raises the initial window resumes a stream waiting for window, as h2spec's http2/6.9.2/1 checks" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      let out = []
      // A window of 0: the HEADERS go out, and the body waits.
      raw.send([
        Settings(params=[(@http2.settings_initial_window_size, 0)], ack=false),
        raw.get(1, "/item"),
        fence,
      ])
      out.push(raw.frames_until_ping_ack())
      out.push("--- the initial window raised to 3")
      raw.send([
        Settings(params=[(@http2.settings_initial_window_size, 3)], ack=false),
      ])
      out.push(raw.runs_until(frame => frame is Data(..)))
      out.push("--- the initial window raised to 100")
      raw.send([
        Settings(params=[(@http2.settings_initial_window_size, 100)], ack=false),
      ])
      out.push(raw.runs_until(frame => ends_stream(frame, 1)))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|--- the initial window raised to 3
          #|SETTINGS ACK
          #|DATA 1: 1 frames, 3 octets
          #|--- the initial window raised to 100
          #|SETTINGS ACK
          #|DATA 1 END_STREAM: 1 frames, 2 octets
        ),
      )
    })
  })
}

///|
async test "h2c: a client that grants window one octet at a time, on the stream or on the connection, gets one small DATA frame for each grant, and its whole response" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      let out = []
      // On the stream: a window of 1 for "hello".
      raw.send([
        Settings(params=[(@http2.settings_initial_window_size, 1)], ack=false),
        raw.get(1, "/item"),
      ])
      let body = @buffer.Buffer()
      let mut frames = 0
      while raw.read_frame() is Some(frame) {
        if frame is Data(data~, end_stream~, ..) {
          frames += 1
          body.write_bytes(data)
          out.push(raw.render_frame(frame))
          if end_stream {
            break
          }
          raw.send([WindowUpdate(stream_id=1, increment=1)])
        }
      }
      out.push(
        "on the stream: \{frames} DATA frames, body \{@utf8.decode_lossy(body.to_bytes())}",
      )
      // On the connection: the stream's window wide open, and a body nine
      // octets larger than the connection window.
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 0x7fffffff)],
          ack=false,
        ),
        raw.get(1, "/medium"),
      ])
      let body = @buffer.Buffer()
      let granted = []
      while raw.read_frame() is Some(frame) {
        if frame is Data(data~, end_stream~, ..) {
          body.write_bytes(data)
          if body.length() > 65535 {
            granted.push(raw.render_frame(frame))
          }
          if end_stream {
            break
          }
          if body.length() >= 65535 {
            raw.send([WindowUpdate(stream_id=0, increment=1)])
          }
        }
      }
      out.push("---")
      out.append(granted)
      out.push(
        "on the connection: \{granted.length()} DATA frames after the first 65535 octets, body as the Stub gives it: \{@utf8.decode_lossy(body.to_bytes()) == medium_body}",
      )
      inspect(
        out.join("\n"),
        content=(
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 END_STREAM 1 octets
          #|on the stream: 5 DATA frames, body hello
          #|---
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 END_STREAM 1 octets
          #|on the connection: 9 DATA frames after the first 65535 octets, body as the Stub gives it: true
        ),
      )
    })
  })
}

///|
async test "h2c: two bodies larger than the windows, on one connection, both arrive in full" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let first = client.send("GET", "/big", authority="localhost")
      let second = client.send("GET", "/big", authority="localhost")
      let second_response = client.response(second)
      let first_response = client.response(first)
      inspect(
        [
          first_response.checked(big_body),
          "---",
          second_response.checked(big_body),
          "---",
          ..smock.journal_once(2, within=patience_ms),
        ].join("\n"),
        content=(
          #|200
          #|accept-ranges: bytes
          #|date: <now>
          #|content-length: 150000
          #|
          #|body: 150000 octets, as the Stub gives it: true
          #|---
          #|200
          #|accept-ranges: bytes
          #|date: <now>
          #|content-length: 150000
          #|
          #|body: 150000 octets, as the Stub gives it: true
          #|---
          #|/big: stub "big", status 200
          #|/big: stub "big", status 200
        ),
      )
    })
  })
}

///|
/// A predicate on frames that holds once `octets` of DATA have come, on
/// any of the streams, counting from when it is made: all that a widening
/// of the connection window by `octets` lets smock send. A share of the
/// window that goes to the wrong stream then shows in what was read, where
/// waiting for a stream to end would wait in vain.
fn data_total(octets : Int32) -> (@http2.Frame) -> Bool {
  let mut seen = 0
  frame => {
    if frame is Data(data~, ..) {
      seen += data.length()
    }
    seen >= octets
  }
}

///|
async test "h2c: streams waiting on the connection window get it in the order they became ready: after a connection WINDOW_UPDATE, the stream that waited first sends its DATA first, one that has sent waits behind the others, and a new response waits behind them all" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      let out = []
      // Wide stream windows, so that only the connection window of 65,535
      // octets holds the bodies back. Stream 3 takes all of it at once and
      // waits for more; stream 1, after its delay, finds none, and waits
      // behind it.
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 1_000_000)],
          ack=false,
        ),
        raw.get(1, "/slow-big"),
        raw.get(3, "/big"),
      ])
      out.push(raw.runs_until(frame => frame is Headers(stream_id=1, ..)))
      out.push("--- the connection window widened by 500")
      raw.send([WindowUpdate(stream_id=0, increment=500)])
      out.push(raw.runs_until(data_seen(3, 500)))
      // Stream 3 now waits behind stream 1, which gets the next 500 octets,
      // though stream 5's short body, which comes with them, would fit.
      out.push("--- the connection window widened by 500, and stream 5 opened")
      raw.send([WindowUpdate(stream_id=0, increment=500), raw.get(5, "/item")])
      out.push(raw.runs_until(data_seen(1, 500)))
      // Stream 3 has waited longest: "When several streams wait for the
      // connection window, they get it in the order they began to wait, and
      // a stream that has sent what it was given waits behind the others"
      // (docs/http2.md, Streams that wait). So a widening of the 83,965
      // octets left of its body goes to it alone. A wider one would give
      // streams 5 and 1 their shares too, and their tasks could send them
      // between stream 3's DATA frames.
      out.push("--- the connection window widened by 83965")
      raw.send([WindowUpdate(stream_id=0, increment=83_965)])
      out.push(raw.runs_until(data_total(83_965)))
      // Then the 149,505 octets left of the bodies of streams 1 and 5, which
      // one widening gives to both: their tasks may send in either order,
      // which is not checked here. The next test checks which of the two
      // waits first, as the maintainer decided on 2026-11-18: a stream
      // begins to wait as soon as the windows hold back part of its body
      // (#381, #391).
      out.push("--- the connection window widened by 149505")
      raw.send([WindowUpdate(stream_id=0, increment=149_505)])
      let rest = raw.runs_until(data_total(149_505)).split("\n").collect()
      let rest = rest.iter().map(line => line.to_owned()).collect()
      rest.sort()
      out.append(rest)
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 3 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|DATA 3: 4 frames, 65535 octets
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|--- the connection window widened by 500
          #|DATA 3: 1 frames, 500 octets
          #|--- the connection window widened by 500, and stream 5 opened
          #|HEADERS 5 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|DATA 1: 1 frames, 500 octets
          #|--- the connection window widened by 83965
          #|DATA 3 END_STREAM: 6 frames, 83965 octets
          #|--- the connection window widened by 149505
          #|DATA 5 END_STREAM: 1 frames, 5 octets
          #|DATA 1 END_STREAM: 10 frames, 149500 octets
        ),
      )
    })
  })
}

///|
async test "h2c: a response queued without all of its body waits for the connection window from then, so a stream that has just sent what it was given waits behind it (#381)" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      let out = []
      // Wide stream windows, so that only the connection window of 65,535
      // octets holds the bodies back. Stream 3 takes all of it at once and
      // waits for more; stream 1, after its delay, finds none, and waits
      // behind it.
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 1_000_000)],
          ack=false,
        ),
        raw.get(1, "/slow-big"),
        raw.get(3, "/big"),
      ])
      out.push(raw.runs_until(frame => frame is Headers(stream_id=1, ..)))
      out.push("--- the connection window widened by 500")
      raw.send([WindowUpdate(stream_id=0, increment=500)])
      out.push(raw.runs_until(data_seen(3, 500)))
      // In one write: the next 500 octets, which go to stream 1, and stream
      // 5, whose response smock queues before stream 1 has sent them, with
      // no room for its body.
      out.push(
        "--- the connection window widened by 500, and stream 5 opened, in one write",
      )
      raw.send([WindowUpdate(stream_id=0, increment=500), raw.get(5, "/item")])
      out.push(raw.runs_until(data_seen(1, 500)))
      // "When several streams wait for the connection window, they get it in
      // the order they began to wait, and a stream that has sent what it was
      // given waits behind the others" (docs/http2.md, Streams that wait).
      // Stream 3 has waited longest, so the 83,965 octets left of its body
      // go to it. "A stream begins to wait as soon as the windows hold back
      // part of its body" (the same section, #381, #391): stream 5 began to
      // wait as its response was queued, with no room for its body, before
      // stream 1 sent its 500 octets, so the next 5 octets go to stream 5,
      // and stream 1 gets the rest after it.
      out.push("--- the connection window widened by 83965")
      raw.send([WindowUpdate(stream_id=0, increment=83_965)])
      out.push(raw.runs_until(data_total(83_965)))
      out.push("--- the connection window widened by 5")
      raw.send([WindowUpdate(stream_id=0, increment=5)])
      out.push(raw.runs_until(data_total(5)))
      out.push("--- the connection window widened by 149500")
      raw.send([WindowUpdate(stream_id=0, increment=149_500)])
      out.push(raw.runs_until(data_total(149_500)))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 3 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|DATA 3: 4 frames, 65535 octets
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|--- the connection window widened by 500
          #|DATA 3: 1 frames, 500 octets
          #|--- the connection window widened by 500, and stream 5 opened, in one write
          #|HEADERS 5 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|DATA 1: 1 frames, 500 octets
          #|--- the connection window widened by 83965
          #|DATA 3 END_STREAM: 6 frames, 83965 octets
          #|--- the connection window widened by 5
          #|DATA 5 END_STREAM: 1 frames, 5 octets
          #|--- the connection window widened by 149500
          #|DATA 1 END_STREAM: 10 frames, 149500 octets
        ),
      )
    })
  })
}

///|
async test "h2c: a fast stream is answered at once while a large body on the same connection waits for window" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      let out = []
      // Stream windows of 1,000 octets: stream 1's body waits for its own
      // window, while stream 3's short body fits at once.
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 1000)],
          ack=false,
        ),
        raw.get(1, "/big"),
        raw.get(3, "/item"),
        fence,
      ])
      out.push(raw.frames_until_ping_ack())
      out.push("--- both windows widened")
      raw.send([
        WindowUpdate(stream_id=0, increment=100_000),
        WindowUpdate(stream_id=1, increment=149_000),
      ])
      out.push(raw.runs_until(frame => ends_stream(frame, 1)))
      out.push("---")
      out.append(smock.journal_once(2, within=patience_ms))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|DATA 1 1000 octets
          #|HEADERS 3 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|DATA 3 END_STREAM 5 octets
          #|--- both windows widened
          #|DATA 1 END_STREAM: 10 frames, 149000 octets
          #|---
          #|/item: stub "item", status 200
          #|/big: stub "big", status 200
        ),
      )
    })
  })
}

///|
async test "h2c: a stream reset while its body waits for window ends its slow write at once: its entry is committed, no more of its body is sent, and the window it was woken for goes to the stream waiting after it" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      let out = []
      // Stream 1 takes the connection window and waits for more; stream 3,
      // with a short body, waits behind it.
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 1_000_000)],
          ack=false,
        ),
        raw.get(1, "/big"),
        raw.get(3, "/item"),
      ])
      out.push(raw.runs_until(frame => frame is Headers(stream_id=3, ..)))
      // The window wakes stream 1, and the reset in the same read ends it
      // before it sends: stream 3 gets the window instead.
      out.push("--- the connection window widened by 10, and stream 1 reset")
      raw.send([
        WindowUpdate(stream_id=0, increment=10),
        RstStream(stream_id=1, error_code=@http2.error_cancel),
      ])
      out.push(raw.runs_until(frame => ends_stream(frame, 3)))
      out.push("--- nothing more on stream 1")
      raw.send([WindowUpdate(stream_id=0, increment=200_000), fence])
      let more = raw.frames_until_ping_ack()
      out.push(if more == "" { "(no frame)" } else { more })
      out.push("---")
      out.append(smock.journal_once(2, within=patience_ms))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|DATA 1: 4 frames, 65535 octets
          #|HEADERS 3 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|--- the connection window widened by 10, and stream 1 reset
          #|DATA 3 END_STREAM: 1 frames, 5 octets
          #|--- nothing more on stream 1
          #|(no frame)
          #|---
          #|/big: stub "big", status 200
          #|/item: stub "item", status 200
        ),
      )
    })
  })
}

///|
/// `line`, a line of `RawH2::runs_until` that shows a run of DATA frames on
/// stream 1 without its end, shown as part of the `granted` octets when it
/// carries more than none and fewer than all of them, since how many it
/// carries depends on the socket's buffers; any other line as it is.
fn granted_part(line : String, granted : Int32) -> String {
  guard line.strip_prefix("DATA 1: ") is Some(run) &&
    run.split(", ").collect() is [_, octets] &&
    octets.strip_suffix(" octets") is Some(octets) else {
    return line
  }
  let octets = @string.parse_int(octets) catch { _ => return line }
  if octets > 0 && octets < granted {
    "DATA 1: whole frames, some of the \{granted} octets granted"
  } else {
    line
  }
}

///|
async test "h2c: a stream reset while its task writes part of its body to a client that does not read leaves every frame whole: what it was writing goes out in full, then the next stream's response, no more of its body, and the task ends with its entry committed" {
  // A body of 9,000,000 octets, of which the client grants about 8,000,000
  // at once: more than the socket takes while the client does not read, so
  // the stream's task is still writing when the reset comes. It sends at
  // most 16 KiB at a time, each once the last is written, so how much of
  // the body goes out before the reset depends on the socket's buffers.
  let definitions = [
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
        #|  "stubs": [
        #|    { "id": "huge", "mock": "m", "request": { "path": "/huge" },
        #|      "response": { "status": 200, "bodyFile": "huge.txt" } },
        #|    { "id": "item", "mock": "m", "request": { "path": "/item" },
        #|      "response": { "status": 200, "body": "hello" } } ] }
      ),
    ),
    ("files/huge.txt", String::make(9_000_000, 'x')),
  ]
  with_definitions(definitions, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      // A wide stream window: the connection window of 65,535 octets goes
      // at once, and the task waits for more.
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 8_000_000)],
          ack=false,
        ),
        raw.get(1, "/huge"),
      ])
      let out = [raw.runs_until(data_seen(1, 65535))]
      // A WINDOW_UPDATE owes no reply, so the reader has nothing to write,
      // and the woken task writes its DATA itself.
      raw.send([WindowUpdate(stream_id=0, increment=8_000_000)])
      @async.sleep(300)
      raw.send([
        RstStream(stream_id=1, error_code=@http2.error_cancel),
        raw.get(3, "/item"),
      ])
      out.push(
        "--- the connection window widened by 8000000, then stream 1 reset and stream 3 sent",
      )
      for line in raw.runs_until(frame => ends_stream(frame, 3)).split("\n") {
        out.push(granted_part(line.to_owned(), 7_934_465))
      }
      // Stream 1's task ended once its write was done, and committed its
      // entry then; nothing more of its body was sent.
      out.push("--- nothing more on stream 1")
      raw.send([fence])
      let more = raw.frames_until_ping_ack()
      out.push(if more == "" { "(no frame)" } else { more })
      out.push("---")
      out.append(smock.journal_once(2, within=patience_ms))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 9000000]
          #|DATA 1: 4 frames, 65535 octets
          #|--- the connection window widened by 8000000, then stream 1 reset and stream 3 sent
          #|DATA 1: whole frames, some of the 7934465 octets granted
          #|HEADERS 3 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|DATA 3 END_STREAM: 1 frames, 5 octets
          #|--- nothing more on stream 1
          #|(no frame)
          #|---
          #|/item: stub "item", status 200
          #|/huge: stub "huge", status 200
        ),
      )
    })
  })
}
