// Seam 2 tests of smock's own failures on gRPC calls: a gRPC Stub that
// cannot serve its content, since a template fails, a data write cannot be
// applied or its writes do not fit the bound on per-Session state, gets
// Trailers-Only with `:status` 200 and a fixed ASCII `grpc-message`, never
// smock's HTTP 500 or 507, and its Journal entry records the gRPC status,
// with `templateError` or `dataError` as on HTTP. The set is gRPC's
// helloworld.proto, and the messages are protoc-encoded fixtures
// (scripts/gen-protobuf-fixtures.sh). Every Admin API response is checked
// against the OpenAPI document (contract_test.mbt).

///|
/// The entries of `page`, a Journal page, one per line: the Stub, the HTTP
/// status and the gRPC status, each as JSON, `-` for a member the entry
/// does not have, then its template error and its data error, if any.
fn own_answers(page : Json) -> String raise {
  guard page is Object({ "entries": Array(entries), .. }) else {
    fail("not a Journal page: \{page.stringify()}")
  }
  let lines = []
  for entry in entries {
    guard entry is Object(members) else { fail("not an entry") }
    let shown = (name : String) => {
      members.get(name).map_or("-", value => value.stringify())
    }
    let line = StringBuilder()
    line.write_string(
      "\{shown("stub")} \{shown("status")} \{shown("grpcStatus")}",
    )
    for name in ["templateError", "dataError"] {
      match members.get(name) {
        Some(Null) | None => ()
        Some(error) => line.write_string(" \{name}=\{error.stringify()}")
      }
    }
    lines.push(line.to_string())
  }
  lines.join("\n")
}

///|
/// The Mock `greeter`, with the set, the state bound's example: the Stub
/// `greet` stores each caller it greets, by name, in the Data bucket
/// `greetings`, which the CRUD Stub `greetings` serves over HTTP.
let greetings : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|data:
  #|  - { mock: greeter, name: greetings, key: name, json: [] }
  #|stubs:
  #|  - id: greet
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    dataWrites:
  #|      - { op: append, bucket: greetings, value: { name: "${body.name}", greeted: true } }
  #|    response: { template: true, json: { message: "Hello ${body.name}" } }
  #|  - id: greetings
  #|    mock: greeter
  #|    crud: { bucket: greetings, path: /greetings }

///|
async test "the ticket's example: a gRPC Stub whose writes would pass the state bound gets Trailers-Only RESOURCE_EXHAUSTED state limit reached, never 507, and an item a gRPC Stub writes is read back by an HTTP CRUD Stub's GET" {
  with_greeter_set([("greeter.yaml", greetings)], dir => {
    // The Mock and its Session count 7 + 0 + 64 bytes; the copy of
    // greetings with Tom 9 + 64 + 95, and with Ann too 9 + 64 + 173. So Tom
    // fits, 239 bytes, and Ann does not, 317.
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--state-max-bytes", "300"],
      smock => {
        let client = smock.h2c()
        defer client.close()
        let tom = client.call("/helloworld.Greeter/SayHello")
        let ann = client.call("/helloworld.Greeter/SayHello", body=hello_ann())
        inspect(
          [tom.render(), ann.render()].join("\n---\n"),
          content=(
            #|HEADERS
            #|  :status: 200
            #|  content-type: application/grpc
            #|  smock-mock: greeter; via=default
            #|  date: <now>
            #|DATA 000000000b0a0948656c6c6f20546f6d
            #|TRAILERS
            #|  grpc-status: 0
            #|(end)
            #|---
            #|HEADERS
            #|  :status: 200
            #|  content-type: application/grpc
            #|  grpc-status: 8
            #|  grpc-message: state limit reached
            #|  smock-mock: greeter; via=default
            #|  date: <now>
            #|(end)
          ),
        )
        inspect(
          smock.send("GET", "/greetings/Tom"),
          content=(
            #|HTTP/1.1 200 OK
            #|Content-Type: application/json
            #|Smock-Mock: greeter; via=default
            #|Date: <now>
            #|Content-Length: 29
            #|
            #|{"name":"Tom","greeted":true}
          ),
        )
        inspect(
          smock.send("GET", "/greetings/Ann"),
          content=(
            #|HTTP/1.1 404 Not Found
            #|Content-Type: application/json
            #|Smock-Mock: greeter; via=default
            #|Date: <now>
            #|Content-Length: 64
            #|
            #|{"error":"no item with this key","stub":"greetings","key":"Ann"}
          ),
        )
        let (_, journal) = smock.journal()
        inspect(
          own_answers(journal),
          content=(
            #|"greet" 200 "OK"
            #|"greet" 200 "RESOURCE_EXHAUSTED"
            #|"greetings" 200 -
            #|"greetings" 404 -
          ),
        )
        // The refusal counts as any refused write does.
        inspect(
          smock.metric("smock_state_"),
          content=(
            #|smock_state_bytes 239
            #|smock_state_writes_refused_total 1
          ),
        )
      },
    )
  })
}

///|
/// The Mock `greeter`, the Default Mock, with the set and the Data buckets
/// `log`, `visits` and `orders`, keyed by `id`, and gRPC Stubs on SayHello
/// that each fail in one way, chosen by the metadata `x-case`.
let failing_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    default: true
  #|    grpc: { descriptorSet: greeter.binpb }
  #|data:
  #|  - { mock: greeter, name: log, json: [] }
  #|  - { mock: greeter, name: visits, json: 0 }
  #|  - { mock: greeter, name: orders, key: id, json: [] }
  #|stubs:
  #|  - id: variables
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: variables } }
  #|    variables: { who: "${body.missing.name}" }
  #|    response: { json: { message: Hello } }
  #|  - id: key
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: key } }
  #|    dataWrites: [{ op: set, bucket: orders, key: "${body.order}", value: { id: "1" } }]
  #|    response: { json: { message: Hello } }
  #|  - id: value
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: value } }
  #|    dataWrites: [{ op: append, bucket: log, value: "${body.missing.name}" }]
  #|    response: { json: { message: Hello } }
  #|  - id: apply
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: apply } }
  #|    dataWrites: [{ op: merge, bucket: visits, value: { count: 1 } }]
  #|    response: { json: { message: Hello } }
  #|  - id: reply
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: reply } }
  #|    response: { template: true, json: { message: "${body.missing.name}" } }

///|
async test "a template that fails in variables, in a dataWrites key or value, or in the reply gets Trailers-Only INTERNAL template failed, and a data write that cannot be applied INTERNAL data write failed; each entry has its gRPC status and HTTP status 200" {
  with_greeter_set([("greeter.yaml", failing_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let replies = []
      for case in ["variables", "key", "value", "apply", "reply"] {
        let reply = client.call("/helloworld.Greeter/SayHello", headers=[
          ("x-case", case),
        ])
        replies.push("\{case}:\n\{reply.render()}")
      }
      inspect(
        replies.join("\n"),
        content=(
          #|variables:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: template failed
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|key:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: template failed
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|value:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: template failed
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|apply:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: data write failed
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|reply:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: template failed
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
        ),
      )
      let (_, journal) = smock.journal()
      inspect(
        own_answers(journal),
        content=(
          #|"variables" 200 "INTERNAL" templateError={"at":"/variables/who","message":"body.missing.name is missing"}
          #|"key" 200 "INTERNAL" templateError={"at":"/dataWrites/0/key","message":"body.order is missing"}
          #|"value" 200 "INTERNAL" templateError={"at":"/dataWrites/0/value","message":"body.missing.name is missing"}
          #|"apply" 200 "INTERNAL" dataError={"at":"/dataWrites/0","message":"the Data bucket \"visits\" holds a number, and \"merge\" needs an object"}
          #|"reply" 200 "INTERNAL" templateError={"at":"/response/json/message","message":"body.missing.name is missing"}
        ),
      )
      // Counted under their Mock and Stub, as answers to requests that a
      // Stub matched.
      inspect(
        smock.metric("smock_requests_total"),
        content=(
          #|smock_requests_total{mock="greeter",stub="variables"} 1
          #|smock_requests_total{mock="greeter",stub="key"} 1
          #|smock_requests_total{mock="greeter",stub="value"} 1
          #|smock_requests_total{mock="greeter",stub="apply"} 1
          #|smock_requests_total{mock="greeter",stub="reply"} 1
        ),
      )
    })
  })
}

///|
async test "smock's own failure is sent as it is, never replaced by INTERNAL reply metadata too large, even to a client whose SETTINGS_MAX_HEADER_LIST_SIZE its block passes, and its entry keeps the failure's reason" {
  with_greeter_set([("greeter.yaml", failing_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      // Fewer octets than the Trailers-Only block of any answer smock
      // sends. smock does not check the size of its own answers: whether
      // the client takes the block or refuses it in its framing layer, the
      // call's entry keeps the failure's reason.
      let client = smock.h2c(
        settings=@http2.Settings::new(max_header_list_size=Some(100)),
      )
      defer client.close()
      (client.call("/helloworld.Greeter/SayHello", headers=[
        ("x-case", "variables"),
      ])
      |> ignore) catch {
        _ => ()
      }
      let (_, journal) = smock.journal()
      inspect(
        own_answers(journal),
        content=(
          #|"variables" 200 "INTERNAL" templateError={"at":"/variables/who","message":"body.missing.name is missing"}
        ),
      )
    })
  })
}
