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
