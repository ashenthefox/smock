// Seam 2 tests of the defences of an HTTP/2 connection, over h2c, sent as
// raw frames with moonhttp's frame encoder: a client that sends more than
// 100 frames that do no work in one second gets GOAWAY ENHANCE_YOUR_CALM,
// the connection closes, and smock logs one line that names the pattern.
// A fresh connection is served right after.

///|
/// Sends `n` PINGs on `raw` in one write, and reads smock's answers until
/// it has acknowledged them all, or sent a GOAWAY.
async fn RawH2::pings(self : RawH2, n : Int32) -> Frames {
  self.send(times(ping, n))
  let mut acks = 0
  self.frames_until(@async.now(), frame => {
    if frame is Ping(ack=true, ..) {
      acks += 1
    }
    acks == n || is_goaway(frame)
  })
}

///|
async test "h2c: 100 frames that do no work in one second, the client's SETTINGS and 99 PINGs, are answered, and one more PING gets GOAWAY ENHANCE_YOUR_CALM, after which the connection closes, smock logs one line, and a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let answered = raw.pings(99)
      raw.send([ping])
      inspect(
        [
          runs(answered.shown),
          "one more PING:",
          raw.runs_until_closed(),
          smock.fresh(),
        ].join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|PING ACK x99
          #|one more PING:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING"}
      ),
    )
  })
}

///|
async test "h2c: frames that do no work, no more than 100 in any one second, are never cut, however many come in all: three rounds of 60 PINGs, 1.1 seconds apart, are answered, and so is a request after them" {
  with_definitions([("faults.json", faults)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = []
      for round in 1..<=3 {
        if round > 1 {
          @async.sleep(1100)
        }
        out.push("round \{round}:")
        out.push(runs(raw.pings(60).shown))
      }
      raw.send([raw.get(1, "/fast")])
      out.push(raw.frames_until_stream_ends(1))
      inspect(
        out.join("\n"),
        content=(
          #|round 1:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|PING ACK x60
          #|round 2:
          #|PING ACK x60
          #|round 3:
          #|PING ACK x60
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
        ),
      )
    })
  })
}

///|
async test "h2c: a client that sends a PING after each DATA frame it receives is not cut, at over 100 PINGs a second, while a body streams to it, since smock sent DATA since its last PING; the same PINGs with no traffic are cut" {
  with_definitions(flow_definitions(), dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      // Windows of 1,000 octets on each stream, and a connection window
      // wide enough for the whole body: one DATA frame for each grant.
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 1000)],
          ack=false,
        ),
        WindowUpdate(stream_id=0, increment=1_000_000),
        raw.get(1, "/big"),
      ])
      // When each PING went out.
      let sent_at = []
      let shown = []
      // The DATA frames of stream 1 so far, and their octets.
      let mut frames = 0
      let mut octets = 0
      for ;; {
        guard raw.read_frame() is Some(frame) else {
          shown.push("closed")
          break
        }
        match frame {
          Data(stream_id=1, data~, end_stream~, ..) => {
            frames += 1
            octets += data.length()
            if end_stream {
              shown.push(
                "DATA 1 END_STREAM: \{frames} frames, \{octets} octets",
              )
              break
            }
            sent_at.push(@async.now())
            raw.send([ping, WindowUpdate(stream_id=1, increment=data.length())])
          }
          Ping(ack=true, ..) => ()
          _ => shown.push(raw.render_frame(frame))
        }
      }
      // Whether 101 PINGs went out within one second.
      let mut fast = false
      for i = 0; i + 100 < sent_at.length(); i = i + 1 {
        if sent_at[i + 100] - sent_at[i] < 1000 {
          fast = true
        }
      }
      raw.send([raw.get(3, "/item")])
      shown.push(raw.frames_until_stream_ends(3))
      shown.push(
        "\{sent_at.length()} PINGs, over 100 within one second: \{fast}",
      )
      // One PING at a time, each after the acknowledgement of the last,
      // with nothing else.
      let idle = smock.raw_h2()
      defer idle.close()
      let mut pings = 0
      let alone = for ;; {
        idle.send([ping])
        pings += 1
        let frames = idle.frames_until(@async.now(), frame => {
          frame is Ping(ack=true, ..)
        })
        if frames.how != "open" || pings == 150 {
          break frames
        }
      }
      shown.push("with no traffic, after \{pings} PINGs:")
      shown.push(runs(alone.shown))
      shown.push("then \{alone.how}")
      inspect(
        shown.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|DATA 1 END_STREAM: 150 frames, 150000 octets
          #|HEADERS 3 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|DATA 3 END_STREAM 5 octets
          #|149 PINGs, over 100 within one second: true
          #|with no traffic, after 100 PINGs:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING"}
      ),
    )
  })
}

///|
/// The body of `GET /pinged`: 200,000 octets, more than three times the
/// windows a client starts with (65,535 octets each).
let pinged_body : String = numbered(25_000)

///|
/// Mock `m`, for `localhost`, with a Stub that answers `GET /pinged` with
/// `pinged_body`.
fn pinged_definitions() -> Array[(String, String)] {
  [
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
        #|  "stubs": [
        #|    { "id": "pinged", "mock": "m", "request": { "path": "/pinged" },
        #|      "response": { "status": 200, "bodyFile": "pinged.txt" } } ] }
      ),
    ),
    ("files/pinged.txt", pinged_body),
  ]
}

///|
async test "h2c: with the default windows, a client that sends a PING after each DATA frame it receives is not cut, though several DATA frames come between its PINGs, since each HEADERS or DATA frame smock sends lets one PING pass" {
  with_definitions(pinged_definitions(), dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      // When each PING went out.
      let sent_at = []
      let shown = []
      let requests = 15
      let mut whole = 0
      for i in 0..<requests {
        let stream = 2 * i + 1
        raw.send([raw.get(stream, "/pinged")])
        let mut octets = 0
        // The octets of the stream since the client last widened the
        // windows: it widens both once the stream's window is used up, so
        // that up to four DATA frames come between its grants.
        let mut used = 0
        let ended = for ;; {
          guard raw.read_frame() is Some(frame) else {
            shown.push("closed")
            break false
          }
          match frame {
            Data(stream_id~, data~, end_stream~, ..) if stream_id == stream => {
              octets += data.length()
              used += data.length()
              sent_at.push(@async.now())
              raw.send([ping])
              if end_stream {
                // What the stream used of the connection window, given
                // back for the next stream.
                raw.send([WindowUpdate(stream_id=0, increment=used)])
                break true
              }
              if used == 65535 {
                raw.send([
                  WindowUpdate(stream_id=0, increment=used),
                  WindowUpdate(stream_id=stream, increment=used),
                ])
                used = 0
              }
            }
            Ping(ack=true, ..) | Headers(..) | Settings(..) => ()
            _ => shown.push(raw.render_frame(frame))
          }
        }
        guard ended else { break }
        if octets == pinged_body.length() {
          whole += 1
        }
      }
      // Whether 101 PINGs went out within one second.
      let mut fast = false
      for i = 0; i + 100 < sent_at.length(); i = i + 1 {
        if sent_at[i + 100] - sent_at[i] < 1000 {
          fast = true
        }
      }
      inspect(
        [
          ..shown,
          "responses in full: \{whole} of \{requests}",
          // How many DATA frames carry a body depends on how the slow
          // write splits it, so the count is not shown.
          "a PING after each DATA frame, over 100 within one second: \{fast}",
        ].join("\n"),
        content=(
          #|responses in full: 15 of 15
          #|a PING after each DATA frame, over 100 within one second: true
        ),
      )
    })
    inspect(defence_entries(stopped.logs), content="")
  })
}

///|
async test "h2c: smock saves up at most 100 PING passes: after it has sent 120 HEADERS and DATA frames, and over a second after the client's SETTINGS, 200 PINGs at once are answered, 100 that pass and the 100 that the bound then allows, and one more gets GOAWAY ENHANCE_YOUR_CALM" {
  // docs/http2.md, Frames that do no work: a PING counts "beyond one for
  // each HEADERS or DATA frame smock has sent on the connection. smock
  // saves up at most 100 of these", and more than 100 counted frames in any
  // one second get GOAWAY ENHANCE_YOUR_CALM.
  with_definitions([("faults.json", faults)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      // Sixty answers of a HEADERS and a DATA frame each: 120 passes
      // earned, more than the 100 that smock saves up.
      let gets = []
      for i in 0..<60 {
        gets.push(raw.get(2 * i + 1, "/fast"))
      }
      raw.send(gets)
      let mut ended = 0
      let answers = raw.frames_until(@async.now(), frame => {
        if frame is Data(end_stream=true, ..) {
          ended += 1
        }
        ended == 60
      })
      // The client's SETTINGS counted when the connection opened. Once a
      // second has passed since, it is no longer among the frames of any
      // one second that the PINGs to come fall in, however long the
      // answers took.
      @async.sleep(1100)
      let answered = raw.pings(200)
      raw.send([ping])
      inspect(
        [
          "60 streams answered:",
          tally(answers.shown),
          "200 PINGs:",
          runs(answered.shown),
          "one more PING:",
          raw.runs_until_closed(),
          smock.fresh(),
        ].join("\n"),
        content=(
          #|60 streams answered:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS n END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4] x60
          #|DATA n END_STREAM 4 octets x60
          #|200 PINGs:
          #|PING ACK x200
          #|one more PING:
          #|GOAWAY last=119 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING"}
      ),
    )
  })
}

///|
async test "h2c: floods of PRIORITY frames, frames of unknown types, PING acknowledgements and SETTINGS acknowledgements past those smock is owed each get GOAWAY ENHANCE_YOUR_CALM and one log line, and a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      out.push(
        smock.flood("PRIORITY on a stream not yet used", _ => {
          times(
            Priority(stream_id=3, priority={
              exclusive: false,
              stream_dependency: 0,
              weight: 16,
            }),
            100,
          )
        }),
      )
      out.push(
        smock.flood("frames of an unknown type", _ => {
          times(Unknown(ftype=0xfa, flags=0, stream_id=0, payload=b"x"), 100)
        }),
      )
      out.push(
        smock.flood("PING acknowledgements, while smock sent no PING", _ => {
          times(
            Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x07", ack=true),
            100,
          )
        }),
      )
      out.push(
        smock.flood("SETTINGS acknowledgements, while smock is owed one", _ => {
          times(Settings(params=[], ack=true), 101)
        }),
      )
      inspect(
        out.join("\n"),
        content=(
          #|PRIORITY on a stream not yet used:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|frames of an unknown type:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|PING acknowledgements, while smock sent no PING:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|SETTINGS acknowledgements, while smock is owed one:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PRIORITY"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"unknown type"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING acknowledgement"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"SETTINGS acknowledgement"}
      ),
    )
  })
}

///|
async test "h2c: floods of empty DATA frames, padded or not, of WINDOW_UPDATE, RST_STREAM and DATA frames on a closed stream, and of HEADERS on a stream smock reset each get GOAWAY ENHANCE_YOUR_CALM and one log line, and a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      // A request whose body is still to come keeps stream 1 open.
      out.push(
        smock.flood(
          "DATA frames that carry no data and end no stream",
          setup=raw => {
            [
              headers_frame(
                1,
                raw.block(request_fields("POST", "/fast", "localhost")),
                end_stream=false,
              ),
            ]
          },
          _ => {
            let frames = []
            for i in 0..<100 {
              frames.push(
                @http2.Frame::Data(
                  stream_id=1,
                  data=b"",
                  end_stream=false,
                  padding=i % 2 * 4,
                ),
              )
            }
            frames
          },
        ),
      )
      // Stream 1 is closed once its response has ended it.
      let closed = (label, frame) => {
        smock.flood(
          label,
          setup=raw => [raw.get(1, "/fast")],
          ready=frame => ends_stream(frame, 1),
          _ => times(frame, 100),
        )
      }
      out.push(
        closed(
          "WINDOW_UPDATE on a closed stream",
          WindowUpdate(stream_id=1, increment=1),
        ),
      )
      out.push(
        closed(
          "RST_STREAM on a closed stream",
          RstStream(stream_id=1, error_code=@http2.error_cancel),
        ),
      )
      out.push(
        closed(
          "DATA on a closed stream",
          Data(stream_id=1, data=b"x", end_stream=false, padding=0),
        ),
      )
      // A reset Fault ends stream 1 with RST_STREAM.
      out.push(
        smock.flood(
          "HEADERS on a stream smock reset",
          setup=raw => [raw.get(1, "/reset")],
          ready=frame => ends_stream(frame, 1),
          raw => {
            let frames = []
            for _ in 0..<100 {
              frames.push(raw.get(1, "/fast"))
            }
            frames
          },
        ),
      )
      inspect(
        out.join("\n"),
        content=(
          #|DATA frames that carry no data and end no stream:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|WINDOW_UPDATE on a closed stream:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|RST_STREAM on a closed stream:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|DATA on a closed stream:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|flood:
          #|RST_STREAM 1 STREAM_CLOSED x99
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|HEADERS on a stream smock reset:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|RST_STREAM 1 INTERNAL_ERROR
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"empty DATA"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"WINDOW_UPDATE on a closed stream"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"RST_STREAM on a closed stream"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"DATA on a closed stream"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"HEADERS on a stream smock reset"}
      ),
    )
  })
}

///|
async test "h2c: when a defence closes the connection, its streams in progress end with it: a delayed stream's task is cancelled at once, and its entry's duration, by smock's own clock, ends before its delay was over" {
  with_definitions([("faults.json", faults)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      // `GET /slow` waits 1,500 ms before its response.
      let flooded = smock.flood(
        "a PING flood while a delayed stream waits",
        setup=raw => [raw.get(1, "/slow")],
        _ => times(ping, 100),
      )
      // "Every stream of a connection that closes" stops waiting at once
      // (docs/http2.md, Streams that wait), so the delayed entry's
      // duration, by smock's own clock, ends before the delay of 1,500 ms.
      let entries = smock.journal_durations(2, below=1500, within=patience_ms)
      inspect(
        [flooded, "both committed: \{entries.length() == 2}", ..entries].join(
          "\n",
        ),
        content=(
          #|a PING flood while a delayed stream waits:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|PING ACK x99
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|both committed: true
          #|/slow: stub "slow", status 200, durationMs below 1500: true
          #|/fast: stub "fast", status 200, durationMs below 1500: true
        ),
      )
    })
  })
}

///|
async test "h2 over TLS: a PING flood gets GOAWAY ENHANCE_YOUR_CALM and one log line, and a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    with_certificates(certs => {
      let stopped = with_smock(["--dir", dir, "--port", "0", ..certs.args()], smock => {
        inspect(
          smock.flood("PING over TLS", tls=true, _ => times(ping, 100)),
          content=(
            #|PING over TLS:
            #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|flood:
            #|PING ACK x99
            #|GOAWAY last=0 ENHANCE_YOUR_CALM
            #|then a FIN
            #|then a fresh connection: 200 fast
          ),
        )
      })
      inspect(
        defence_entries(stopped.logs),
        content=(
          #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING"}
        ),
      )
    })
  })
}
