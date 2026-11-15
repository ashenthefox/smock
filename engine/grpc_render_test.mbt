// Seam 1 tests of rendering a gRPC Stub: a gRPC rendering, whatever the
// sample's method and content type, which are only conditions. The
// sample's body is the request message as JSON, checked against the input
// type and normalised, and the rendering shows the reply JSON with the
// gRPC part a call gets: its status, message, trailers and details, and no
// protobuf bytes. The set is details.binpb, gRPC's helloworld.proto with
// googleapis' error_details.proto (details_set_test.mbt); `Harness::render`
// comes from render_test.mbt.

///|
/// The Mock `greeter`, with the details set, and its Stubs: the spec's
/// `hello-tom` and `hello-unknown`.
let render_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    hosts: [greeter.svc]
  #|    grpc: { descriptorSet: details.binpb }
  #|stubs:
  #|  - id: hello-tom
  #|    mock: greeter
  #|    request:
  #|      path: /helloworld.Greeter/SayHello
  #|      headers: { x-tenant: acme }
  #|      body: { json: { name: Tom } }
  #|    response:
  #|      headers: { x-served-by: smock }
  #|      json: { message: Hello Tom }
  #|  - id: hello-unknown
  #|    mock: greeter
  #|    request:
  #|      path: /helloworld.Greeter/SayHello
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

///|
/// The sample of a call to SayHello for `name`, with the metadata
/// `x-tenant: acme`.
fn say_hello(name : String) -> Json {
  {
    "method": "POST",
    "path": "/helloworld.Greeter/SayHello",
    "headers": { "content-type": "application/grpc", "x-tenant": "acme" },
    "body": Json::string("{\"name\":\{name.escape()}}"),
  }
}

///|
test "a gRPC Stub's static reply renders as a call gets it: the reply JSON, its initial metadata, and the status OK" {
  let h = harness(
    [("greeter.yaml", render_greeter)],
    body_files=details_body_files(),
  )
  inspect(
    h.render("hello-tom", say_hello("Tom")),
    content=(
      #|{
      #|  "stub": "hello-tom",
      #|  "mock": "greeter",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "variables": {},
      #|  "dataWrites": [],
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [
      #|      {
      #|        "name": "x-served-by",
      #|        "value": "smock"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "{\"message\":\"Hello Tom\"}",
      #|      "size": 23,
      #|      "truncated": false
      #|    },
      #|    "events": null,
      #|    "grpc": {
      #|      "status": "OK",
      #|      "message": null,
      #|      "trailers": [],
      #|      "details": []
      #|    }
      #|  },
      #|  "templateError": null,
      #|  "failed": []
      #|}
    ),
  )
}
