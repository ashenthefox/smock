// Seam 1 tests of a gRPC reply's metadata in its plan: the initial
// metadata is the plan's headers, and the trailing metadata the gRPC
// part's trailers, as written or rendered. With template on, a rendered
// value outside 0x20 to 0x7E, or a rendered `-bin` value that is not
// base64, is a template failure at the value's pointer. The set is gRPC's
// helloworld.proto (greeter_set_test.mbt); `Harness::call` and `grpc_part`
// come from grpc_calls_test.mbt.

///|
/// The header fields of the plan of `outcome`, one per line.
fn plan_headers(outcome : @engine.Outcome) -> String {
  outcome.plan.headers.map(field => "\{field.0}: \{field.1}").join("\n")
}

///|
/// The Mock `greeter`, the Default Mock, with the set, and three Stubs on
/// SayHello, told apart by `x-case`: an error with the ticket's metadata
/// as written, and an OK reply and an error whose metadata are templates.
let metadata_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    default: true
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: written
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: written } }
  #|    response:
  #|      headers: { x-served-by: smock }
  #|      grpc:
  #|        status: NOT_FOUND
  #|        trailers: { x-trace: abc, x-tag: [a, b], trace-bin: "AAE=" }
  #|  - id: rendered
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: rendered } }
  #|    response:
  #|      template: true
  #|      headers: { x-name: "${body.name}" }
  #|      json: { message: "Hello ${body.name}" }
  #|      grpc:
  #|        message: "fine"
  #|        trailers: { x-greeted: "${body.name}", name-bin: "${header.x-name-bin}", x-tag: [a, "${method}"] }
  #|  - id: rendered-error
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: rendered-error } }
  #|    response:
  #|      template: true
  #|      grpc:
  #|        status: UNAVAILABLE
  #|        trailers: { x-name: "${body.name}", name-bin: "${header.x-name-bin}" }

///|
test "a gRPC reply's headers are the plan's headers, the initial metadata, and its trailers the gRPC part's, after its status and message" {
  let h = harness(
    [("greeter.yaml", metadata_greeter)],
    body_files=greeter_body_files(),
  )
  let written = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
    headers=[("content-type", "application/grpc"), ("x-case", "written")],
  )
  inspect(
    plan_headers(written),
    content=(
      #|x-served-by: smock
      #|Smock-Mock: greeter; via=default
    ),
  )
  inspect(
    grpc_part(written),
    content=(
      #|NOT_FOUND
      #|x-trace: abc
      #|x-tag: a
      #|x-tag: b
      #|trace-bin: AAE
    ),
  )
}

///|
test "with template on, metadata values render as header values do, control characters becoming spaces, and a rendered -bin value loses its padding" {
  let h = harness(
    [("greeter.yaml", metadata_greeter)],
    body_files=greeter_body_files(),
  )
  let rendered = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Ann\\r\\nBob\"}",
    octets=12,
    headers=[
      ("content-type", "application/grpc"),
      ("x-case", "rendered"),
      ("x-name-bin", "AAE="),
    ],
  )
  inspect(
    plan_headers(rendered),
    content=(
      #|x-name: Ann  Bob
      #|Smock-Mock: greeter; via=default
    ),
  )
  inspect(
    grpc_part(rendered),
    content=(
      #|OK
      #|grpc-message: fine
      #|x-greeted: Ann  Bob
      #|name-bin: AAE
      #|x-tag: a
      #|x-tag: POST
    ),
  )
  let error = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Ann\"}",
    octets=5,
    headers=[
      ("content-type", "application/grpc"),
      ("x-case", "rendered-error"),
      ("x-name-bin", "AAAA"),
    ],
  )
  inspect(
    grpc_part(error),
    content=(
      #|UNAVAILABLE
      #|x-name: Ann
      #|name-bin: AAAA
    ),
  )
}

///|
test "a rendered metadata value outside 0x20 to 0x7E, or a rendered -bin value that is not base64, is a template failure at its pointer" {
  let h = harness(
    [("greeter.yaml", metadata_greeter)],
    body_files=greeter_body_files(),
  )
  let failure = (case : String, name : String, bin : String) => {
    let outcome = h.call(
      "/helloworld.Greeter/SayHello",
      "{\"name\":\"\{name}\"}",
      octets=10,
      headers=[
        ("content-type", "application/grpc"),
        ("x-case", case),
        ("x-name-bin", bin),
      ],
    )
    match outcome.content_error {
      Some({ failure: Template(error), .. }) =>
        "\{outcome.plan.status} \{error.at}: \{error.message}"
      _ => "no template failure: \{grpc_part(outcome)}"
    }
  }
  inspect(
    failure("rendered", "Zoë", "AAE="),
    content="200 /response/headers/x-name: the rendered value holds U+00EB, and gRPC metadata values hold only characters from 0x20 to 0x7E",
  )
  inspect(
    failure("rendered", "Ann\\tBob", "AAE="),
    content="200 /response/headers/x-name: the rendered value holds U+0009, and gRPC metadata values hold only characters from 0x20 to 0x7E",
  )
  inspect(
    failure("rendered", "Ann", "AA="),
    content="200 /response/grpc/trailers/name-bin: the rendered value is not standard base64, which a field whose name ends with -bin holds",
  )
  inspect(
    failure("rendered-error", "☺", "AAE="),
    content="200 /response/grpc/trailers/x-name: the rendered value holds U+263A, and gRPC metadata values hold only characters from 0x20 to 0x7E",
  )
  inspect(
    failure("rendered-error", "Ann", "AAE=,AAE="),
    content="200 /response/grpc/trailers/name-bin: the rendered value is not standard base64, which a field whose name ends with -bin holds",
  )
}
