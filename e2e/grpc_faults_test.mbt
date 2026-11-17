// Seam 2 tests of connection Faults on gRPC calls, over h2c: each takes
// spec E's per-stream form, with no `content-length`. `reset` resets the
// call's stream alone with RST_STREAM INTERNAL_ERROR; `partial` sends the
// reply's HEADERS and the first half of its framed message, then that
// reset; `close` sends GOAWAY and closes the connection, which ends every
// call on it. Each test shows the frames a client gets and the status a
// gRPC client derives from them (`derived_status`). The set is gRPC's
// helloworld.proto, and the request message a protoc-encoded fixture
// (scripts/gen-protobuf-fixtures.sh).

///|
/// The Mock `greeter`, the Default Mock, with the set, and two gRPC Stubs
/// on SayHello: `broken`, for calls with `x-fault: reset`, with a reset
/// Fault, and `hello`, for any other call: the ticket's example.
let reset_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: broken
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: reset } }
  #|    response: { json: { message: never sent } }
  #|    fault: { connection: { kind: reset } }
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello Tom } }

///|
/// The status a gRPC client derives from `reply`, as gRPC's HTTP/2
/// protocol says (PROTOCOL-HTTP2.md, "Errors"): the name of the code its
/// `grpc-status` gives, in its trailers or in Trailers-Only; INTERNAL for a
/// stream reset with NO_ERROR, PROTOCOL_ERROR or INTERNAL_ERROR, or that
/// ends without a status; UNAVAILABLE for one reset with REFUSED_STREAM,
/// or whose connection closes first; CANCELLED for one reset with CANCEL,
/// and RESOURCE_EXHAUSTED for one reset with ENHANCE_YOUR_CALM.
fn derived_status(reply : GrpcReply) -> String {
  let last = match reply.trailers {
    Some(trailers) => trailers
    None => if reply.ended == "end" { reply.head } else { [] }
  }
  for field in last {
    if field.0 == "grpc-status" {
      return match field.1 {
        "0" => "OK"
        "4" => "DEADLINE_EXCEEDED"
        "5" => "NOT_FOUND"
        "13" => "INTERNAL"
        "14" => "UNAVAILABLE"
        code => "code \{code}"
      }
    }
  }
  match reply.ended {
    "reset REFUSED_STREAM" | "closed" => "UNAVAILABLE"
    "reset CANCEL" => "CANCELLED"
    "reset ENHANCE_YOUR_CALM" => "RESOURCE_EXHAUSTED"
    _ => "INTERNAL"
  }
}

///|
/// The Journal's entries, one per line: each call's Stub, its HTTP status,
/// its gRPC status and its Fault, each as JSON, `-` for a member the entry
/// does not have.
async fn fault_answers(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let lines = []
  for entry in entries {
    guard entry is Object(members) else { fail("not an entry") }
    let shown = []
    for name in ["stub", "status", "grpcStatus", "fault"] {
      shown.push(
        match members.get(name) {
          Some(value) => value.stringify()
          None => "-"
        },
      )
    }
    lines.push(shown.join(" "))
  }
  lines.join("\n")
}

///|
async test "the ticket's example: a gRPC Stub with a reset Fault makes the client see INTERNAL, while a second call on the same channel, to another Stub, succeeds; the reset call's entry has no status and no gRPC status" {
  with_greeter_set([("greeter.yaml", reset_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let broken = client.call("/helloworld.Greeter/SayHello", headers=[
        ("x-fault", "reset"),
      ])
      let hello = client.call("/helloworld.Greeter/SayHello")
      inspect(
        [
          "x-fault: reset:",
          broken.render(),
          "the client sees \{derived_status(broken)}",
          "then, on the same connection:",
          hello.render(),
          "the client sees \{derived_status(hello)}",
          "Journal:",
          fault_answers(smock),
        ].join("\n"),
        content=(
          #|x-fault: reset:
          #|HEADERS
          #|(reset INTERNAL_ERROR)
          #|the client sees INTERNAL
          #|then, on the same connection:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 000000000b0a0948656c6c6f20546f6d
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|the client sees OK
          #|Journal:
          #|"broken" null - "reset"
          #|"hello" 200 "OK" null
        ),
      )
    })
  })
}

///|
async test "a reset Fault reads the whole call, its message split over DATA frames included, then resets its stream alone with RST_STREAM INTERNAL_ERROR, while another call on the connection is answered" {
  with_greeter_set([("greeter.yaml", reset_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let hello = framed(@fs.read_file(hello_request_path).binary())
      let out = []
      // Half the message: smock waits for the rest, and answers another
      // call meanwhile.
      raw.send(
        [
          headers_frame(
            1,
            raw.block(checked_call("POST", more=[("x-fault", "reset")])),
            end_stream=false,
          ),
          Data(
            stream_id=1,
            data=hello[0:5].to_owned(),
            end_stream=false,
            padding=0,
          ),
          ..raw.hello_call(3),
          fence,
        ],
      )
      out.push(raw.frames_until_ping_ack())
      out.push("--- the rest of the message")
      raw.send([
        Data(stream_id=1, data=hello[5:].to_owned(), end_stream=true, padding=0),
      ])
      out.push(raw.frames_until_stream_ends(1))
      inspect(
        [..out, "Journal:", fault_answers(smock)].join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 3 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
          #|DATA 3 16 octets
          #|HEADERS 3 END_STREAM END_HEADERS [grpc-status: 0]
          #|--- the rest of the message
          #|RST_STREAM 1 INTERNAL_ERROR
          #|Journal:
          #|"hello" 200 "OK" null
          #|"broken" null - "reset"
        ),
      )
    })
  })
}

///|
/// The Mock `greeter`, the Default Mock, with the set, and gRPC Stubs on
/// SayHello with a partial Fault, one for each value of the call's
/// `x-fault`: an OK reply (`partial`), an OK reply with an empty message
/// (`partial-empty`), an error, sent as Trailers-Only without the Fault
/// (`partial-error`), an error with initial metadata, sent as HEADERS then
/// trailers without the Fault (`partial-error-metadata`), and a templated
/// reply that does not fit the output type, which gets smock's own INTERNAL
/// (`partial-failed`).
let partial_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: partial
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: partial } }
  #|    response: { headers: { x-served-by: smock }, json: { message: Hello Tom }, grpc: { trailers: { x-trailer: t } } }
  #|    fault: { connection: { kind: partial } }
  #|  - id: partial-empty
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: partial-empty } }
  #|    response: { json: {} }
  #|    fault: { connection: { kind: partial } }
  #|  - id: partial-error
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: partial-error } }
  #|    response: { grpc: { status: NOT_FOUND, message: no such greeting, trailers: { x-trailer: t } } }
  #|    fault: { connection: { kind: partial } }
  #|  - id: partial-error-metadata
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: partial-error-metadata } }
  #|    response: { headers: { x-served-by: smock }, grpc: { status: NOT_FOUND, message: no such greeting } }
  #|    fault: { connection: { kind: partial } }
  #|  - id: partial-failed
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: partial-failed } }
  #|    response: { template: true, headers: { x-served-by: smock }, json: { mesage: "${body.name}" } }
  #|    fault: { connection: { kind: partial } }

///|
async test "a partial Fault sends the reply's HEADERS, with no content-length, and the first half of its framed message, rounded down, then RST_STREAM INTERNAL_ERROR; an answer with no message sends the HEADERS it would send before its trailers, without ending the stream, then the reset; the client sees INTERNAL, and the entry keeps its status and gRPC status" {
  with_greeter_set([("greeter.yaml", partial_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for
        fault in [
          "partial", "partial-empty", "partial-error", "partial-error-metadata",
          "partial-failed",
        ] {
        let reply = client.call("/helloworld.Greeter/SayHello", headers=[
          ("x-fault", fault),
        ])
        out.push("x-fault: \{fault}:")
        out.push(reply.render())
        out.push("the client sees \{derived_status(reply)}")
      }
      inspect(
        [..out, "Journal:", fault_answers(smock)].join("\n"),
        content=(
          #|x-fault: partial:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  x-served-by: smock
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 000000000b0a0948
          #|(reset INTERNAL_ERROR)
          #|the client sees INTERNAL
          #|x-fault: partial-empty:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 0000
          #|(reset INTERNAL_ERROR)
          #|the client sees INTERNAL
          #|x-fault: partial-error:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(reset INTERNAL_ERROR)
          #|the client sees INTERNAL
          #|x-fault: partial-error-metadata:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  x-served-by: smock
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(reset INTERNAL_ERROR)
          #|the client sees INTERNAL
          #|x-fault: partial-failed:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(reset INTERNAL_ERROR)
          #|the client sees INTERNAL
          #|Journal:
          #|"partial" 200 "OK" "partial"
          #|"partial-empty" 200 "OK" "partial"
          #|"partial-error" 200 "NOT_FOUND" "partial"
          #|"partial-error-metadata" 200 "NOT_FOUND" "partial"
          #|"partial-failed" 200 "INTERNAL" "partial"
        ),
      )
    })
  })
}

///|
/// The Mock `greeter`, the Default Mock, with the set, and two gRPC Stubs
/// on SayHello: `closing`, for calls with `x-fault: close`, with a close
/// Fault, and `slow`, for any other call, whose reply waits 3000 ms.
let close_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: closing
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: close } }
  #|    response: { json: { message: never sent } }
  #|    fault: { connection: { kind: close } }
  #|  - id: slow
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello Tom } }
  #|    fault: { delay: { fixed: 3000 } }

///|
/// The frames of a gRPC call to SayHello on `stream`, with the framed
/// HelloRequest `{name: "Tom"}`, then `more` among its fields.
async fn RawH2::hello_call(
  self : RawH2,
  stream : Int32,
  more~ : Array[(String, String)] = [],
) -> Array[@http2.Frame] {
  [
    headers_frame(
      stream,
      self.block(checked_call("POST", more~)),
      end_stream=false,
    ),
    Data(
      stream_id=stream,
      data=framed(@fs.read_file(hello_request_path).binary()),
      end_stream=true,
      padding=0,
    ),
  ]
}

///|
async test "a close Fault sends GOAWAY NO_ERROR, then closes the connection, which ends every call in flight on it: the client sees UNAVAILABLE for the call and for a second call that waits for its delay; the closed call's entry has no status and no gRPC status" {
  with_greeter_set([("greeter.yaml", close_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      // The frames: a call that waits for its delay, then the Fault's.
      let raw = smock.raw_h2()
      defer raw.close()
      let start = @async.now()
      raw.send(
        [..raw.hello_call(1), ..raw.hello_call(3, more=[("x-fault", "close")])],
      )
      let frames = raw.frames_until(start, _ => false)
      // The status a client derives, on a connection of its own.
      let client = smock.h2c()
      defer client.close()
      let slow = client.start_call()
      let closing = client.start_call(headers=[("x-fault", "close")])
      let closed = client.reply(closing)
      let waiting = client.reply(slow)
      let ended_ms = @async.now() - start
      inspect(
        [
          ..frames.shown,
          "then \{frames.how}",
          "x-fault: close:",
          closed.render(),
          "the client sees \{derived_status(closed)}",
          "the call that waits:",
          waiting.render(),
          "the client sees \{derived_status(waiting)}",
          "both before the delay is over: \{ended_ms < 3000}",
          "Journal:",
          fault_answers(smock),
        ].join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|GOAWAY last=3 NO_ERROR
          #|then a FIN
          #|x-fault: close:
          #|HEADERS
          #|(closed)
          #|the client sees UNAVAILABLE
          #|the call that waits:
          #|HEADERS
          #|(closed)
          #|the client sees UNAVAILABLE
          #|both before the delay is over: true
          #|Journal:
          #|"closing" null - "close"
          #|"slow" 200 "OK" null
          #|"closing" null - "close"
          #|"slow" 200 "OK" null
        ),
      )
    })
  })
}

///|
/// The Mock `greeter`, the Default Mock, with the set, and gRPC Stubs on
/// SayHello whose Faults come after a delay, one for each value of the
/// call's `x-fault`: `late-reset` (300 ms), `late-partial` (450 ms) and
/// `late-close` (700 ms); `fast` answers any other call at once.
let late_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: late-reset
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: late-reset } }
  #|    response: { json: { message: never sent } }
  #|    fault: { delay: { fixed: 300 }, connection: { kind: reset } }
  #|  - id: late-partial
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: late-partial } }
  #|    response: { json: { message: Hello Tom } }
  #|    fault: { delay: { fixed: 450 }, connection: { kind: partial } }
  #|  - id: late-close
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: late-close } }
  #|    response: { json: { message: never sent } }
  #|    fault: { delay: { fixed: 700 }, connection: { kind: close } }
  #|  - id: fast
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello Tom } }

///|
async test "a Fault with a delay comes in its call's task once the delay is over, while the connection's other calls are answered: a reset one, a partial one and a close one" {
  with_greeter_set([("greeter.yaml", late_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let faults = ["late-reset", "late-partial", "late-close"]
      // The calls with Faults, then the one without, in one write: smock
      // reads them together, so their replies come in the order smock gives
      // them, however late the test sends the calls or reads the replies.
      // While a call's delay runs, "the other calls of the connection are
      // answered meanwhile" (docs/grpc/state-and-faults.md, Faults), so the
      // call without a Fault is answered before the first delay, 300 ms, is
      // over, and nothing of the other calls comes before its reply.
      let start = @async.now()
      let streams = client.start_calls(
        [..faults.map(fault => [("x-fault", fault)]), []],
      )
      let fast = client.reply(streams[faults.length()])
      // Whatever came of the other calls while the client read this reply
      // was kept for later.
      let first = faults
        .mapi((i, _) => client.kept_for(streams[i]))
        .iter()
        .all(kept => kept == 0)
      let out = [
        "fast, at once: \{derived_status(fast)}, before anything of the calls with Faults: \{first}",
      ]
      let delays = [300L, 450, 700]
      for i, fault in faults {
        let reply = client.reply(streams[i])
        out.push("x-fault: \{fault}:")
        out.push(reply.render())
        out.push(
          "the client sees \{derived_status(reply)}, after its delay: \{@async.now() - start >= delays[i]}",
        )
      }
      inspect(
        [..out, "Journal:", fault_answers(smock)].join("\n"),
        content=(
          #|fast, at once: OK, before anything of the calls with Faults: true
          #|x-fault: late-reset:
          #|HEADERS
          #|(reset INTERNAL_ERROR)
          #|the client sees INTERNAL, after its delay: true
          #|x-fault: late-partial:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 000000000b0a0948
          #|(reset INTERNAL_ERROR)
          #|the client sees INTERNAL, after its delay: true
          #|x-fault: late-close:
          #|HEADERS
          #|(closed)
          #|the client sees UNAVAILABLE, after its delay: true
          #|Journal:
          #|"fast" 200 "OK" null
          #|"late-reset" null - "reset"
          #|"late-partial" 200 "OK" "partial"
          #|"late-close" null - "close"
        ),
      )
    })
  })
}

///|
/// The Mock `greeter`, the Default Mock, with the set, and gRPC Stubs on
/// SayHello whose Faults come after a delay of 3000 ms, one for each value
/// of the call's `x-fault`: `cut-reset`, `cut-partial` and `cut-close`.
let cut_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: cut-reset
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: cut-reset } }
  #|    response: { json: { message: never sent } }
  #|    fault: { delay: { fixed: 3000 }, connection: { kind: reset } }
  #|  - id: cut-partial
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: cut-partial } }
  #|    response: { json: { message: never sent } }
  #|    fault: { delay: { fixed: 3000 }, connection: { kind: partial } }
  #|  - id: cut-close
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: cut-close } }
  #|    response: { json: { message: never sent } }
  #|    fault: { delay: { fixed: 3000 }, connection: { kind: close } }

///|
async test "a deadline that cuts a delay short comes before the Fault, which would come after the delay and never comes: the call gets DEADLINE_EXCEEDED, the connection stays open, and the entry has the HTTP status 200 and no Fault" {
  with_greeter_set([("greeter.yaml", cut_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let start = @async.now()
      let streams = []
      for fault in ["cut-reset", "cut-partial", "cut-close"] {
        streams.push(
          client.start_call(timeout="500m", headers=[("x-fault", fault)]),
        )
      }
      let out = []
      for stream in streams {
        let reply = client.reply(stream)
        out.push(reply.render())
        out.push("the client sees \{derived_status(reply)}")
      }
      inspect(
        [
          ..out,
          "before the delay is over: \{@async.now() - start < 3000}",
          "Journal:",
          fault_answers(smock),
        ].join("\n"),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 4
          #|  grpc-message: deadline exceeded
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|the client sees DEADLINE_EXCEEDED
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 4
          #|  grpc-message: deadline exceeded
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|the client sees DEADLINE_EXCEEDED
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 4
          #|  grpc-message: deadline exceeded
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|the client sees DEADLINE_EXCEEDED
          #|before the delay is over: true
          #|Journal:
          #|"cut-reset" 200 "DEADLINE_EXCEEDED" null
          #|"cut-partial" 200 "DEADLINE_EXCEEDED" null
          #|"cut-close" 200 "DEADLINE_EXCEEDED" null
        ),
      )
    })
  })
}

///|
/// The Mock `greeter`, the Default Mock, with the set, and two gRPC Stubs
/// on SayHello with a partial Fault on a reply whose message is 150,000
/// octets of `x`, a framed message of 150,009 octets: `big`, for calls with
/// `x-fault: big`, at once, and `late-big`, for any other call, after a
/// delay of 200 ms.
fn big_partial() -> String {
  let message = "x".repeat(150000)
  (
    $|mocks:
    $|  - name: greeter
    $|    grpc: { descriptorSet: greeter.binpb }
    $|stubs:
    $|  - id: big
    $|    mock: greeter
    $|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: big } }
    $|    response: { json: { message: \{message} } }
    $|    fault: { connection: { kind: partial } }
    $|  - id: late-big
    $|    mock: greeter
    $|    request: { path: /helloworld.Greeter/SayHello }
    $|    response: { json: { message: \{message} } }
    $|    fault: { delay: { fixed: 200 }, connection: { kind: partial } }
    $|
  )
}

///|
async test "the half of a framed message that a partial Fault sends, larger than the client's windows, goes out as the client widens them, at once or after a delay, then the reset" {
  with_greeter_set([("greeter.yaml", big_partial())], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for case in [("at once", [("x-fault", "big")]), ("after its delay", [])] {
        let (when, headers) = case
        let reply = client.call("/helloworld.Greeter/SayHello", headers~)
        let mut octets = 0
        for data in reply.data {
          octets += data.length()
        }
        // The prefix, flag 0 and the length 150,004, then the message's
        // field 1, its tag and its length, 150,000, as a varint.
        let first = hex(reply.data[0][0:9].to_owned())
        out.push(
          "\{when}: \{octets} octets, from \{first}, more than the initial window: \{reply.data.length() > 1}, then (\{reply.ended}): the client sees \{derived_status(reply)}",
        )
      }
      inspect(
        [..out, "Journal:", fault_answers(smock)].join("\n"),
        content=(
          #|at once: 75004 octets, from 00000249f40af09309, more than the initial window: true, then (reset INTERNAL_ERROR): the client sees INTERNAL
          #|after its delay: 75004 octets, from 00000249f40af09309, more than the initial window: true, then (reset INTERNAL_ERROR): the client sees INTERNAL
          #|Journal:
          #|"big" 200 "OK" "partial"
          #|"late-big" 200 "OK" "partial"
        ),
      )
    })
  })
}

///|
/// The Mock `greeter`, the Default Mock, with the set, and two gRPC Stubs
/// on SayHello with a partial Fault on a reply with the initial metadata
/// `x-pad`: `padded`, for calls with `x-fault: padded`, with 2,000 octets
/// of it, and `small`, for any other call, with 3.
fn padded_partial() -> String {
  (
    $|mocks:
    $|  - name: greeter
    $|    grpc: { descriptorSet: greeter.binpb }
    $|stubs:
    $|  - id: padded
    $|    mock: greeter
    $|    request: { path: /helloworld.Greeter/SayHello, headers: { x-fault: padded } }
    $|    response: { headers: { x-pad: \{"a".repeat(2000)} }, json: { message: Hello Tom } }
    $|    fault: { connection: { kind: partial } }
    $|  - id: small
    $|    mock: greeter
    $|    request: { path: /helloworld.Greeter/SayHello }
    $|    response: { headers: { x-pad: aaa }, json: { message: Hello Tom } }
    $|    fault: { connection: { kind: partial } }
    $|
  )
}

///|
async test "a partial Fault's HEADERS too large for the SETTINGS_MAX_HEADER_LIST_SIZE the client advertised go out as smock's own, without the Stub's metadata or message, then the reset, and the entry records INTERNAL and why" {
  with_greeter_set([("greeter.yaml", padded_partial())], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c(
        settings=@http2.Settings::new(max_header_list_size=Some(1024)),
      )
      defer client.close()
      let padded = client.call("/helloworld.Greeter/SayHello", headers=[
        ("x-fault", "padded"),
      ])
      let small = client.call("/helloworld.Greeter/SayHello")
      let (_, page) = smock.journal()
      inspect(
        [
          "x-pad of 2000:",
          padded.render(),
          "the client sees \{derived_status(padded)}",
          "x-pad of 3:",
          small.render(),
          "the client sees \{derived_status(small)}",
          "Journal:",
          answers(page),
        ].join("\n"),
        content=(
          #|x-pad of 2000:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(reset INTERNAL_ERROR)
          #|the client sees INTERNAL
          #|x-pad of 3:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  x-pad: aaa
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 000000000b0a0948
          #|(reset INTERNAL_ERROR)
          #|the client sees INTERNAL
          #|Journal:
          #|"padded" 200 "INTERNAL" templateError={"at":"/response","message":"the reply's header block would take 2266 bytes, over the 1024 that the client allows in its SETTINGS_MAX_HEADER_LIST_SIZE"}
          #|"small" 200 "OK"
        ),
      )
    })
  })
}
