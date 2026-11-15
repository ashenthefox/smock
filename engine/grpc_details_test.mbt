// Seam 1 tests of a gRPC reply's error details in its plan: the gRPC
// part carries them as JSON, as written or rendered, and, for details as
// written, google.rpc.Status as it was encoded at load, which the server
// sends. A detail that fails to render is a template failure at its
// pointer. The set is details.binpb, gRPC's helloworld.proto with
// googleapis' error_details.proto (details_set_test.mbt); `Harness::call`
// and `grpc_part` come from grpc_calls_test.mbt.

///|
/// The body files of the Mock `greeter`: details.binpb.
fn details_body_files() -> Array[(String, Bytes)] raise {
  [("details.binpb", @hex.decode(details_set.replace_all(old="\n", new="")))]
}

///|
/// The details of the gRPC part of the plan of `outcome`, one line each,
/// then the value of `grpc-status-details-bin` encoded at load, if there is
/// one. `none` when the plan has no gRPC part.
fn plan_details(outcome : @engine.Outcome) -> String raise {
  guard outcome.plan.grpc is Some(part) else { return "none" }
  let lines = part.details.iter().map(detail => detail.stringify()).to_array()
  if part.encoded_status is Some(status) {
    lines.push("encoded: \{@utf8.decode(status.value)}")
  }
  lines.join("\n")
}

///|
/// The Mock `greeter`, the Default Mock, with the details set, and Stubs
/// on SayHello, told apart by `x-case`: the ticket's example, its details
/// written or templated, and a templated detail that renders a missing
/// value.
let details_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    default: true
  #|    grpc: { descriptorSet: details.binpb }
  #|stubs:
  #|  - id: written
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: written } }
  #|    response:
  #|      grpc:
  #|        status: NOT_FOUND
  #|        message: no user called Ann
  #|        details:
  #|          - "@type": type.googleapis.com/google.rpc.ErrorInfo
  #|            reason: USER_UNKNOWN
  #|            domain: greeter.svc
  #|  - id: hello-unknown
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: rendered } }
  #|    response:
  #|      template: true
  #|      grpc:
  #|        status: NOT_FOUND
  #|        message: no user called ${body.name}
  #|        trailers: { x-trace: abc }
  #|        details:
  #|          - "@type": type.googleapis.com/google.rpc.ErrorInfo
  #|            reason: USER_UNKNOWN
  #|            domain: greeter.svc
  #|            metadata: { name: "${body.name}" }
  #|          - "@type": "type.googleapis.com/${header.x-type}"
  #|            fieldViolations: [{ field: name, description: "no user called ${body.name}" }]
  #|  - id: missing
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: missing } }
  #|    response:
  #|      template: true
  #|      grpc:
  #|        status: NOT_FOUND
  #|        details: [{ "@type": type.googleapis.com/google.rpc.ErrorInfo, reason: "${body.nothing}" }]

///|
test "the ticket's example: an error's details as written are the gRPC part's, with google.rpc.Status encoded at load" {
  let h = harness(
    [("greeter.yaml", details_greeter)],
    body_files=details_body_files(),
  )
  let written = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Ann\"}",
    octets=5,
    headers=[("content-type", "application/grpc"), ("x-case", "written")],
  )
  inspect(
    grpc_part(written),
    content=(
      #|NOT_FOUND
      #|grpc-message: no user called Ann
    ),
  )
  // The value is fixtures/protobuf/details/error-info.binpb in base64.
  inspect(
    plan_details(written),
    content=(
      #|{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"USER_UNKNOWN","domain":"greeter.svc"}
      #|encoded: CAUSEm5vIHVzZXIgY2FsbGVkIEFubhpHCih0eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5ycGMuRXJyb3JJbmZvEhsKDFVTRVJfVU5LTk9XThILZ3JlZXRlci5zdmM
    ),
  )
}

///|
test "with template on, each detail renders after the trailers, as a structured template, and the server encodes it" {
  let h = harness(
    [("greeter.yaml", details_greeter)],
    body_files=details_body_files(),
  )
  let rendered = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Ann\"}",
    octets=5,
    headers=[
      ("content-type", "application/grpc"),
      ("x-case", "rendered"),
      ("x-type", "google.rpc.BadRequest"),
    ],
  )
  inspect(
    grpc_part(rendered),
    content=(
      #|NOT_FOUND
      #|grpc-message: no user called Ann
      #|x-trace: abc
    ),
  )
  inspect(
    plan_details(rendered),
    content=(
      #|{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"USER_UNKNOWN","domain":"greeter.svc","metadata":{"name":"Ann"}}
      #|{"@type":"type.googleapis.com/google.rpc.BadRequest","fieldViolations":[{"field":"name","description":"no user called Ann"}]}
    ),
  )
}

///|
test "a detail that fails to render is a template failure at its pointer" {
  let h = harness(
    [("greeter.yaml", details_greeter)],
    body_files=details_body_files(),
  )
  let outcome = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Ann\"}",
    octets=5,
    headers=[("content-type", "application/grpc"), ("x-case", "missing")],
  )
  inspect(
    match outcome.content_error {
      Some({ failure: Template(error), .. }) => "\{error.at}: \{error.message}"
      _ => "no template failure: \{grpc_part(outcome)}"
    },
    content="/response/grpc/details/0/reason: body.nothing is missing",
  )
}
