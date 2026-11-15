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
/// Stub and the gRPC status, each as JSON, `-` for an HTTP request, which
/// has no gRPC status, then each header the request sent, as
/// `name=value`, but `content-type: application/grpc` and `te: trailers`,
/// which every call sends.
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
          "request": Object({ "headers": Array(headers), .. }),
          ..
        } as members
      ) else {
      fail("not an entry: \{entry.stringify()}")
    }
    let grpc_status = members
      .get("grpcStatus")
      .map_or("-", status => status.stringify())
    let line = StringBuilder()
    line.write_string(
      "\{session.stringify()} \{stub.stringify()} \{grpc_status}",
    )
    for header in headers {
      guard header
        is Object({ "name": String(name), "value": String(value), .. }) else {
        fail("not a header: \{header.stringify()}")
      }
      if !(name == "content-type" && value == "application/grpc") &&
        !(name == "te" && value == "trailers") {
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

///|
/// The Mock `greeter`, the Default Mock, with the set, and the gRPC Stub
/// `echo` on SayHello, whose conditions read fields that gRPC sets itself
/// and a field sent twice, and whose reply echoes them in its initial
/// metadata.
let echo_example : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: echo
  #|    mock: greeter
  #|    request:
  #|      path: /helloworld.Greeter/SayHello
  #|      headers:
  #|        content-type: application/grpc
  #|        te: trailers
  #|        grpc-timeout: { pattern: "[0-9]+[HMSmun]" }
  #|        user-agent: { pattern: "grpc-go/.*" }
  #|        x-tag: b
  #|    response:
  #|      template: true
  #|      headers:
  #|        x-content-type: ${header.content-type}
  #|        x-te: ${header.te}
  #|        x-timeout: ${header.grpc-timeout}
  #|        x-user-agent: ${header.user-agent}
  #|        x-tag: ${header.x-tag}
  #|      json: { message: echoed }

///|
async test "every field of a call's metadata is a header, content-type, te, grpc-timeout and user-agent included, one value per field line, for headers conditions, header.NAME in templates and the Journal" {
  with_greeter_set([("greeter.yaml", echo_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call("/helloworld.Greeter/SayHello", headers=[
        ("grpc-timeout", "5S"),
        ("user-agent", "grpc-go/1.83.2"),
        ("x-tag", "a"),
        ("x-tag", "b"),
      ])
      // `header.x-tag` is the first value; the condition met the second.
      inspect(
        reply.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  x-content-type: application/grpc
          #|  x-te: trailers
          #|  x-timeout: 5S
          #|  x-user-agent: grpc-go/1.83.2
          #|  x-tag: a
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 00000000080a066563686f6564
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
        ),
      )
      let (_, page) = smock.journal()
      inspect(
        metadata_journaled(page),
        content=(
          #|null "echo" "OK" grpc-timeout=5S user-agent=grpc-go/1.83.2 x-tag=a x-tag=b
        ),
      )
      let (_, journal) = smock.journal()
      guard journal
        is Object(
          {
            "entries": [
              Object({ "request": Object({ "headers": headers, .. }), .. }),
            ],
            ..
          }
        ) else {
        fail("not one entry: \{journal.stringify()}")
      }
      // content-type and te are there too, in the order received.
      inspect(
        headers.stringify(),
        content=(
          #|[{"name":"content-type","value":"application/grpc"},{"name":"te","value":"trailers"},{"name":"grpc-timeout","value":"5S"},{"name":"user-agent","value":"grpc-go/1.83.2"},{"name":"x-tag","value":"a"},{"name":"x-tag","value":"b"}]
        ),
      )
    })
  })
}

///|
/// The Mock `greeter`, the Default Mock, with the set, and gRPC Stubs on
/// SayHello whose conditions are on binary metadata: `joined`, an exact
/// value of two elements written padded; `unpadded`, a pattern that only
/// a value without `=` meets; and `not`, `$not` around an exact value
/// written padded, which the call chooses with `x-case: not`.
let binary_example : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: joined
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { list-bin: "AAA=,BBB=" } }
  #|    response: { json: { message: joined } }
  #|  - id: unpadded
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { tag-bin: { pattern: "[A-Za-z0-9+/]+" } } }
  #|    response: { json: { message: unpadded } }
  #|  - id: not
  #|    mock: greeter
  #|    request:
  #|      path: /helloworld.Greeter/SayHello
  #|      headers: { x-case: not, skip-bin: { $not: "AAE=" } }
  #|    response: { json: { message: not } }

///|
async test "-bin values lose their padding in each comma-separated element, commas kept, and a gRPC Stub's exact conditions on them lose theirs at load, while a pattern sees the unpadded value" {
  with_greeter_set([("greeter.yaml", binary_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      for
        headers in [
          // A proxy joined two fields with a comma.
          [("list-bin", "AAA=,BBB=")],
          [("list-bin", "AAA,BBB")],
          [("list-bin", "AAA,BBB==")],
          // Two field lines are two values, neither of which is AAA,BBB.
          [("list-bin", "AAA="), ("list-bin", "BBB=")],
          [("tag-bin", "AA==")],
          [("tag-bin", "+/8")],
          [("x-case", "not"), ("skip-bin", "AAE=")],
          [("x-case", "not"), ("skip-bin", "AAE")],
          [("x-case", "not"), ("skip-bin", "AAAA")],
          // Not base64: smock never decodes the values.
          [("x-case", "not"), ("skip-bin", "not base64!=")],
        ] {
        let _ = client.call("/helloworld.Greeter/SayHello", headers~)
      }
      let (_, page) = smock.journal()
      inspect(
        metadata_journaled(page),
        content=(
          #|null "joined" "OK" list-bin=AAA,BBB
          #|null "joined" "OK" list-bin=AAA,BBB
          #|null "joined" "OK" list-bin=AAA,BBB
          #|null null "UNIMPLEMENTED" list-bin=AAA list-bin=BBB
          #|null "unpadded" "OK" tag-bin=AA
          #|null "unpadded" "OK" tag-bin=+/8
          #|null null "UNIMPLEMENTED" x-case=not skip-bin=AAE
          #|null null "UNIMPLEMENTED" x-case=not skip-bin=AAE
          #|null "not" "OK" x-case=not skip-bin=AAAA
          #|null "not" "OK" x-case=not skip-bin=not base64!
        ),
      )
    })
  })
}

///|
/// The Mock `greeter`, the Default Mock, with the set, the gRPC Stub
/// `traced` of the ticket's example, and the HTTP Stub `http-traced`, on
/// `/traced`, with the same condition.
let traced_beside_http : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: traced
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { trace-bin: "AAE=" } }
  #|    response: { json: { message: traced } }
  #|  - id: http-traced
  #|    mock: greeter
  #|    request: { path: /traced, headers: { trace-bin: "AAE=" } }
  #|    response: { status: 200, body: traced }

///|
async test "Journal filters see a call's -bin metadata unpadded, as stored, while HTTP requests and HTTP Stubs keep their padding, so a filter is not rewritten" {
  with_greeter_set([("greeter.yaml", traced_beside_http)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for value in ["AAE=", "AAE"] {
        let _ = client.call("/helloworld.Greeter/SayHello", headers=[
          ("trace-bin", value),
        ])
        // The HTTP Stub's condition kept its padding.
        let response = client.request(
          "POST",
          "/traced",
          authority="localhost",
          headers=[("trace-bin", value)],
        )
        out.push("POST /traced with trace-bin: \{value}: \{response.status}")
      }
      for value in ["AAE", "AAE="] {
        let (_, page) = smock.journal(
          query="{\"filter\":{\"headers\":{\"trace-bin\":\"\{value}\"}}}",
        )
        out.push("filter trace-bin: \{value}\n\{metadata_journaled(page)}")
      }
      inspect(
        out.join("\n"),
        content=(
          #|POST /traced with trace-bin: AAE=: 200
          #|POST /traced with trace-bin: AAE: 404
          #|filter trace-bin: AAE
          #|null "traced" "OK" trace-bin=AAE
          #|null "traced" "OK" trace-bin=AAE
          #|null null - trace-bin=AAE
          #|filter trace-bin: AAE=
          #|null "http-traced" - trace-bin=AAE=
        ),
      )
    })
  })
}

///|
/// The Mock `greeter`, the Default Mock, with the set, and gRPC Stubs on
/// SayHello in the Scenario `greeting`: the first call of a Session moves
/// it from `Started` to `Greeted`, and later calls get `again`.
let greeting_scenario : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: first
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    scenario: { name: greeting, requires: Started, moveTo: Greeted }
  #|    response: { json: { message: first } }
  #|  - id: again
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    scenario: { name: greeting, requires: Greeted }
  #|    response: { json: { message: again } }

///|
async test "each call's Session comes from its baggage metadata, so two Sessions on one channel keep their own Scenario state and Journal" {
  with_greeter_set([("greeter.yaml", greeting_scenario)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      for session in ["t1", "t1", "t2", "t1", "t2"] {
        let _ = client.call("/helloworld.Greeter/SayHello", headers=[
          baggage(session),
        ])
      }
      let _ = client.call("/helloworld.Greeter/SayHello")
      let out = []
      for session in [Some("t1"), Some("t2"), None] {
        let (_, page) = smock.journal(session?)
        out.push(metadata_journaled(page))
      }
      inspect(
        out.join("\n"),
        content=(
          #|"t1" "first" "OK" baggage=userId=alice,smock-session=t1;ttl=60
          #|"t1" "again" "OK" baggage=userId=alice,smock-session=t1;ttl=60
          #|"t1" "again" "OK" baggage=userId=alice,smock-session=t1;ttl=60
          #|"t2" "first" "OK" baggage=userId=alice,smock-session=t2;ttl=60
          #|"t2" "again" "OK" baggage=userId=alice,smock-session=t2;ttl=60
          #|null "first" "OK"
        ),
      )
    })
  })
}

///|
async test "--session-header and --session-member say where a call's metadata carries its Session, as for HTTP requests" {
  with_greeter_set([("greeter.yaml", greeting_scenario)], dir => {
    let _ = with_smock(
      [
        "--dir", dir, "--port", "0", "--session-header", "X-Test-Context", "--session-member",
        "run",
      ],
      smock => {
        let client = smock.h2c()
        defer client.close()
        for
          headers in [
            [("x-test-context", "run=r1")],
            [("x-test-context", "run=r1"), baggage("t1")],
          ] {
          let _ = client.call("/helloworld.Greeter/SayHello", headers~)
        }
        let response = smock.admin(
          "POST",
          "/v1/journal/query",
          headers=[("X-Test-Context", "run=r1")],
          body="{}",
        )
        inspect(
          metadata_journaled(response.json()),
          content=(
            #|"r1" "first" "OK" x-test-context=run=r1
            #|"r1" "again" "OK" x-test-context=run=r1 baggage=userId=alice,smock-session=t1;ttl=60
          ),
        )
      },
    )
  })
}
