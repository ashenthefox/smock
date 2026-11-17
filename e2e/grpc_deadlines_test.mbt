// Seam 2 tests of delays and deadlines on gRPC calls, over h2c: a gRPC
// Stub's delay waits before the reply's HEADERS, in the stream's task, as
// on HTTP/2, and a call the client cancels during it ends there. The
// deadline comes from the call's `grpc-timeout` and counts from the arrival
// of its HEADERS. A delay that outlasts it ends the call at the deadline
// with Trailers-Only DEADLINE_EXCEEDED `deadline exceeded`, which the
// Journal records, and so does a client reset that arrives in the last
// 100 ms before it. The set is gRPC's helloworld.proto, and the messages
// are protoc-encoded fixtures (scripts/gen-protobuf-fixtures.sh).

///|
/// The Mock `greeter`, the Default Mock, with the set, and the gRPC Stub
/// `slow` on SayHello, whose reply waits 3000 ms: the ticket's example.
let slow_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: slow
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello Tom } }
  #|    fault: { delay: { fixed: 3000 } }

///|
async test "the ticket's example: a Stub with a delay of 3000 ms answers a call with grpc-timeout 5S after 3 s, and a call with grpc-timeout 1S gets Trailers-Only DEADLINE_EXCEEDED about 1 s after its HEADERS, journaled with status 200 and grpcStatus DEADLINE_EXCEEDED" {
  with_greeter_set([("greeter.yaml", slow_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      // The deadline cuts the delay short: the call ends "about 1 s after
      // its HEADERS" (docs/grpc/state-and-faults.md, Deadlines), before the
      // delay, the competing event, is over.
      let delay = 3000L
      let start = @async.now()
      let five = client.start_call(timeout="5S")
      let one = client.start_call(timeout="1S")
      let cut = client.reply(one)
      let cut_ms = @async.now() - start
      let served = client.reply(five)
      let served_ms = @async.now() - start
      let (_, page) = smock.journal()
      inspect(
        [
          "grpc-timeout 1S:",
          cut.render(),
          "after 1 s, before the delay is over: \{cut_ms >= 1000 && cut_ms < delay}",
          "grpc-timeout 5S:",
          served.render(),
          "after 3 s: \{served_ms >= delay}",
          "Journal:",
          answers(page),
        ].join("\n"),
        content=(
          #|grpc-timeout 1S:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 4
          #|  grpc-message: deadline exceeded
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|after 1 s, before the delay is over: true
          #|grpc-timeout 5S:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 000000000b0a0948656c6c6f20546f6d
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|after 3 s: true
          #|Journal:
          #|"slow" 200 "DEADLINE_EXCEEDED"
          #|"slow" 200 "OK"
        ),
      )
    })
  })
}

///|
/// The Journal's entries, one per line, sorted, so that entries committed
/// at about the same time show in one order: the `grpc-timeout` of each
/// call, `-` for none, its Stub, its HTTP status and its gRPC status.
async fn by_timeout(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let lines = []
  for entry in entries {
    guard entry
      is Object(
        {
          "request": Object({ "headers": Array(headers), .. }),
          "stub": stub,
          "status": status,
          "grpcStatus": grpc_status,
          ..
        }
      ) else {
      fail("not a gRPC call's entry: \{entry.stringify()}")
    }
    let mut timeout = "-"
    for header in headers {
      if header
        is Object(
          { "name": String("grpc-timeout"), "value": String(value), .. }
        ) {
        timeout = value
      }
    }
    lines.push(
      "grpc-timeout \{timeout}: \{stub.stringify()} \{status.stringify()} \{grpc_status.stringify()}",
    )
  }
  lines.sort()
  lines.join("\n")
}

///|
async test "a call the client cancels during a delay ends there with its entry as planned, unless the reset arrives in the last 100 ms before its deadline: that entry records DEADLINE_EXCEEDED, as does a reset after smock ended the call at its deadline; each entry is committed when its call ends, before the delay is over" {
  with_greeter_set([("greeter.yaml", slow_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let hello = framed(@fs.read_file(hello_request_path).binary())
      let call = (stream : Int32, timeout : String?) => {
        let more = match timeout {
          Some(timeout) => [("grpc-timeout", timeout)]
          None => []
        }
        [
          headers_frame(
            stream,
            raw.block(checked_call("POST", more~)),
            end_stream=false,
          ),
          @http2.Frame::Data(
            stream_id=stream,
            data=hello,
            end_stream=true,
            padding=0,
          ),
        ]
      }
      let cancel = (stream : Int32) => {
        @http2.Frame::RstStream(
          stream_id=stream,
          error_code=@http2.error_cancel,
        )
      }
      let delay = 3000L
      let start = @async.now()
      // Each delay of 3000 ms outlasts every deadline but the first.
      raw.send(
        [
          ..call(1, None),
          ..call(3, Some("2S")),
          ..call(5, Some("1S")),
          ..call(7, Some("500m")),
        ],
      )
      // Well before the deadline of 3, which has 2 s.
      @async.sleep(300)
      raw.send([cancel(1), cancel(3)])
      // 50 ms before the deadline of 5, as a client resets at its own.
      @async.sleep((950L - (@async.now() - start)).to_int())
      raw.send([cancel(5)])
      // After smock ended 7 at its deadline.
      @async.sleep((1100L - (@async.now() - start)).to_int())
      raw.send([cancel(7), fence])
      let frames = raw.frames_until(start, frame => frame is Ping(ack=true, ..))
      // Every entry is in the Journal by the time it is read.
      let journaled = by_timeout(smock)
      let committed_ms = @async.now() - start
      // Smock's deadline for 5 comes 50 ms after the reset: a reset late on
      // a loaded machine meets the deadline's answer, which records the
      // same entry, so that stream's frames are not shown.
      let shown = frames.shown.filter(frame => !frame.has_prefix("HEADERS 5 "))
      inspect(
        [
          ..shown,
          "every entry committed before the delay was over: \{committed_ms < delay}",
          journaled,
        ].join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 7 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 4, grpc-message: deadline exceeded, smock-mock: greeter; via=default, date: <now>]
          #|PING ACK
          #|every entry committed before the delay was over: true
          #|grpc-timeout -: "slow" 200 "OK"
          #|grpc-timeout 2S: "slow" 200 "OK"
          #|grpc-timeout 1S: "slow" 200 "DEADLINE_EXCEEDED"
          #|grpc-timeout 500m: "slow" 200 "DEADLINE_EXCEEDED"
        ),
      )
    })
  })
}

///|
async test "a delay shorter than the call's deadline is served, and so is a delay under 99999999H, which acts as no deadline; under a timeout of 0, a delayed call gets DEADLINE_EXCEEDED at once and frees its stream, and a call without a delay is served" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: at-once
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-delay: none } }
    #|    response: { json: { message: Hello Tom } }
    #|  - id: slow
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { json: { message: Hello Tom } }
    #|    fault: { delay: { fixed: 1000 } }
  // Under a timeout of 0, "a call with a delay gets DEADLINE_EXCEEDED at
  // once" (docs/grpc/state-and-faults.md, Deadlines): before its delay of
  // 1000 ms, the competing event, is over.
  let delay = 1000L
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    // One stream at a time: each call needs the one before to have freed
    // its stream.
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--http2-max-concurrent-streams", "1"],
      smock => {
        let client = smock.h2c()
        defer client.close()
        let out = []
        let cases = [
          ("5S", []),
          ("99999999H", []),
          ("0m", []),
          ("0m", [("x-delay", "none")]),
        ]
        for timed in cases {
          let (timeout, headers) = timed
          let start = @async.now()
          let reply = client.call(
            "/helloworld.Greeter/SayHello",
            headers=[("grpc-timeout", timeout), ..headers],
          )
          let ms = @async.now() - start
          // A Trailers-Only answer carries its status in its HEADERS.
          let last = match reply.trailers {
            Some(trailers) => trailers
            None => reply.head
          }
          let status = last
            .filter(field => field.0.has_prefix("grpc-"))
            .map(field => "\{field.0}: \{field.1}")
            .join(", ")
          // A call without a delay has no competing event: its status shows
          // that it was served, and how fast is the runner's speed.
          let (at_once, when) = if headers.is_empty() {
            (" ", ", after the delay of 1000 ms: \{ms >= delay}")
          } else {
            (" x-delay: none, ", "")
          }
          out.push(
            "grpc-timeout \{timeout},\{at_once}\{reply.data.length()} message: \{status}\{when}",
          )
        }
        let (_, page) = smock.journal()
        inspect(
          [..out, "Journal:", answers(page)].join("\n"),
          content=(
            #|grpc-timeout 5S, 1 message: grpc-status: 0, after the delay of 1000 ms: true
            #|grpc-timeout 99999999H, 1 message: grpc-status: 0, after the delay of 1000 ms: true
            #|grpc-timeout 0m, 0 message: grpc-status: 4, grpc-message: deadline exceeded, after the delay of 1000 ms: false
            #|grpc-timeout 0m, x-delay: none, 1 message: grpc-status: 0
            #|Journal:
            #|"slow" 200 "OK"
            #|"slow" 200 "OK"
            #|"slow" 200 "DEADLINE_EXCEEDED"
            #|"at-once" 200 "OK"
          ),
        )
      },
    )
  })
}
