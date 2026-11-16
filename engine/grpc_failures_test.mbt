// Seam 1 tests of smock's own failures on gRPC calls: a gRPC Stub that
// cannot serve its content, since a template fails, a data write cannot be
// applied or its writes do not fit the bound on per-Session state, gets a
// plan in gRPC's form, never smock's HTTP 500 or 507: HTTP status 200, no
// body, and a gRPC part with smock's own status and fixed message, which
// the Journal entry records. The set is gRPC's helloworld.proto
// (greeter_set_test.mbt).

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
  #|  - id: bounded
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: bounded } }
  #|    variables: { last: "${body}" }
  #|    response: { json: { message: Hello } }
  #|  - id: reply
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: reply } }
  #|    response: { template: true, json: { message: "${body.missing.name}" } }

///|
/// The plan of `outcome` and how its Journal entry records the answer: the
/// plan's HTTP status, headers and body, its gRPC part (`grpc_part`) and
/// whether it is smock's own, then the entry's `status`, `grpcStatus`,
/// `templateError` and `dataError`.
fn own_failure(outcome : @engine.Outcome) -> String {
  let plan = outcome.plan
  let lines = ["plan: \{plan.status}"]
  for header in plan.headers {
    lines.push("header: \{header.0}: \{header.1}")
  }
  guard plan.body is Bytes(body) else { abort("a body of bytes") }
  lines.push("body: \{text(body)}")
  lines.push(grpc_part(outcome))
  if outcome.plan.grpc is Some({ own: true, .. }) {
    lines.push("smock's own")
  }
  guard outcome.journal is Some(entry) else { abort("no entry") }
  lines.push(
    "entry: \{entry.status.map_or("none", status => status.to_string())} \{entry.grpc_status.map_or("none", status => status.name())}",
  )
  if entry.template_error is Some(error) {
    lines.push("templateError: \{error.at}: \{error.message}")
  }
  if entry.data_error is Some(error) {
    lines.push("dataError: \{error.at}: \{error.message}")
  }
  lines.join("\n")
}

///|
test "a gRPC Stub that cannot serve its content gets HTTP status 200, no body, and a gRPC part with smock's own status and fixed message, which its entry records" {
  // Small enough that any Variable passes it.
  let h = harness(
    [("greeter.yaml", failing_greeter)],
    body_files=greeter_body_files(),
    state_max_bytes=100,
  )
  let call = (case : String) => {
    own_failure(
      h.call("/helloworld.Greeter/SayHello", "{\"name\":\"Tom\"}", octets=5, headers=[
        ("x-case", case),
      ]),
    )
  }
  inspect(
    call("variables"),
    content=(
      #|plan: 200
      #|header: Smock-Mock: greeter; via=default
      #|body: ""
      #|INTERNAL
      #|grpc-message: template failed
      #|smock's own
      #|entry: 200 INTERNAL
      #|templateError: /variables/who: body.missing.name is missing
    ),
  )
  inspect(
    call("key"),
    content=(
      #|plan: 200
      #|header: Smock-Mock: greeter; via=default
      #|body: ""
      #|INTERNAL
      #|grpc-message: template failed
      #|smock's own
      #|entry: 200 INTERNAL
      #|templateError: /dataWrites/0/key: body.order is missing
    ),
  )
  inspect(
    call("value"),
    content=(
      #|plan: 200
      #|header: Smock-Mock: greeter; via=default
      #|body: ""
      #|INTERNAL
      #|grpc-message: template failed
      #|smock's own
      #|entry: 200 INTERNAL
      #|templateError: /dataWrites/0/value: body.missing.name is missing
    ),
  )
  inspect(
    call("apply"),
    content=(
      #|plan: 200
      #|header: Smock-Mock: greeter; via=default
      #|body: ""
      #|INTERNAL
      #|grpc-message: data write failed
      #|smock's own
      #|entry: 200 INTERNAL
      #|dataError: /dataWrites/0: the Data bucket "visits" holds a number, and "merge" needs an object
    ),
  )
  inspect(
    call("bounded"),
    content=(
      #|plan: 200
      #|header: Smock-Mock: greeter; via=default
      #|body: ""
      #|RESOURCE_EXHAUSTED
      #|grpc-message: state limit reached
      #|smock's own
      #|entry: 200 RESOURCE_EXHAUSTED
    ),
  )
  inspect(
    call("reply"),
    content=(
      #|plan: 200
      #|header: Smock-Mock: greeter; via=default
      #|body: ""
      #|INTERNAL
      #|grpc-message: template failed
      #|smock's own
      #|entry: 200 INTERNAL
      #|templateError: /response/json/message: body.missing.name is missing
    ),
  )
  // Nothing was written.
  inspect(h.engine.state_stats().bytes, content="0")
}
