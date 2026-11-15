// Seam 2 tests of a gRPC call's request metadata over h2c: every field of
// it reaches `headers` conditions, `header.NAME` in templates and the
// Journal as a header, one value per field line. `-bin` values lose their
// base64 padding in each comma-separated element, on gRPC calls only, and
// a gRPC Stub's exact `headers` conditions on `-bin` fields lose theirs at
// load, so padded and unpadded clients match alike. The Session comes from
// `baggage` metadata, as from the HTTP header. The set is gRPC's
// helloworld.proto, and the messages are protoc-encoded fixtures
// (scripts/gen-protobuf-fixtures.sh). Every Admin API response is checked
// against the OpenAPI document (contract_test.mbt).

///|
/// The entries of `page`, a Journal page, one per line: the Session, the
/// Stub and the gRPC status, each as JSON, then each header the call sent,
/// as `name=value`, but `content-type` and `te`, which every call sends.
fn metadata_journaled(page : Json) -> String raise {
  guard page is Object({ "entries": Array(entries), .. }) else {
    fail("not a Journal page: \{page.stringify()}")
  }
  let lines = []
  for entry in entries {
    guard entry
      is Object(
        {
          "session": session,
          "stub": stub,
          "grpcStatus": grpc_status,
          "request": Object({ "headers": Array(headers), .. }),
          ..
        }
      ) else {
      fail("not an entry: \{entry.stringify()}")
    }
    let line = StringBuilder()
    line.write_string(
      "\{session.stringify()} \{stub.stringify()} \{grpc_status.stringify()}",
    )
    for header in headers {
      guard header
        is Object({ "name": String(name), "value": String(value), .. }) else {
        fail("not a header: \{header.stringify()}")
      }
      if name != "content-type" && name != "te" {
        line.write_string(" \{name}=\{value}")
      }
    }
    lines.push(line.to_string())
  }
  lines.join("\n")
}

///|
/// The Mock `greeter`, the Default Mock, with the set, and the gRPC Stub
/// `traced` on SayHello, which requires the binary metadata
/// `trace-bin: AAE=`, written with its padding.
let traced_example : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: traced
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { trace-bin: "AAE=" } }
  #|    response: { json: { message: traced } }

///|
async test "the ticket's example: a -bin condition written padded is met by padded and unpadded calls, the Journal stores the value unpadded, and a call with baggage is journaled under its Session" {
  with_greeter_set([("greeter.yaml", traced_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      for value in ["AAE=", "AAE"] {
        let reply = client.call("/helloworld.Greeter/SayHello", headers=[
          ("trace-bin", value),
          ("baggage", "smock-session=t1"),
        ])
        guard reply.trailers is Some(trailers) &&
          trailers.contains(("grpc-status", "0")) else {
          fail("not OK with trace-bin: \{value}: \{reply.render()}")
        }
      }
      let (_, page) = smock.journal(session="t1")
      inspect(
        metadata_journaled(page),
        content=(
          #|"t1" "traced" "OK" trace-bin=AAE baggage=smock-session=t1
          #|"t1" "traced" "OK" trace-bin=AAE baggage=smock-session=t1
        ),
      )
      // The calls are in the Session's Journal alone.
      inspect(smock.journal_count("other", "{}"), content="0")
    })
  })
}
