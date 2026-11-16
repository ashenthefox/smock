// Seam 2 tests of a gRPC reply's metadata over h2c: a gRPC Stub's
// `headers` go out in the reply's HEADERS, its initial metadata, and its
// `grpc.trailers` in its trailers, its trailing metadata. An error whose
// reply has initial metadata sends HEADERS, then the trailers; one without
// is Trailers-Only, and `smock-mock` alone does not count as initial
// metadata. Names go out in lower case, values trimmed, `-bin` values
// without their base64 padding, and several values of one name as several
// fields. The set is gRPC's helloworld.proto, and the request is its
// protoc-encoded HelloRequest `{name: "Tom"}`
// (scripts/gen-protobuf-fixtures.sh).

///|
/// The Stubs of the ticket's example and its variants on SayHello, told
/// apart by `x-case`, for a Mock `greeter` on the Host `localhost` and for
/// `default`, the Default Mock, each with the set.
let metadata_stubs : String =
  #|mocks:
  #|  - name: greeter
  #|    hosts: [localhost]
  #|    grpc: { descriptorSet: greeter.binpb }
  #|  - name: default
  #|    default: true
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: example
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: example } }
  #|    response:
  #|      headers: { x-served-by: smock }
  #|      grpc:
  #|        status: NOT_FOUND
  #|        trailers: { x-trace: abc, x-tag: [a, b], trace-bin: "AAE=" }
  #|  - id: ok
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: ok } }
  #|    response:
  #|      headers: { X-Served-By: "  smock  ", x-tag: [a, b], served-bin: "AAAA" }
  #|      json: { message: Hello Tom }
  #|      grpc: { message: fine, trailers: { X-Trace: abc, tag-bin: [AA==, AAE] } }
  #|  - id: trailers-only
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: trailers-only } }
  #|    response:
  #|      grpc:
  #|        status: UNAVAILABLE
  #|        message: try again
  #|        trailers: { x-retry-after: "5", x-tag: [a, b], trace-bin: "AAE=" }
  #|  - id: default-error
  #|    mock: default
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: default-error } }
  #|    response: { grpc: { status: NOT_FOUND, trailers: { x-trace: abc } } }
  #|  - id: default-headers
  #|    mock: default
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: default-headers } }
  #|    response:
  #|      headers: { x-served-by: smock }
  #|      grpc: { status: NOT_FOUND, trailers: { x-trace: abc } }

///|
/// Makes the call of `case` on `client`, to `authority`, and renders its
/// reply as the client got it.
async fn H2Client::metadata_case(
  self : H2Client,
  case : String,
  authority~ : String = "localhost",
) -> String {
  let reply = self.call("/helloworld.Greeter/SayHello", authority~, headers=[
    ("x-case", case),
  ])
  "\{case}:\n\{reply.render()}"
}

///|
async test "the ticket's example: an error with initial metadata sends HEADERS with it, then trailers with the status and the trailing metadata, -bin values unpadded and an array as several fields" {
  with_greeter_set([("greeter.yaml", metadata_stubs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      inspect(
        client.metadata_case("example"),
        content=(
          #|example:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  x-served-by: smock
          #|  date: <now>
          #|TRAILERS
          #|  grpc-status: 5
          #|  x-trace: abc
          #|  x-tag: a
          #|  x-tag: b
          #|  trace-bin: AAE
          #|(end)
        ),
      )
      // The call is journaled with its gRPC status, and the HTTP status 200.
      let (_, page) = smock.journal()
      inspect(answers(page), content="\"example\" 200 \"NOT_FOUND\"")
    })
  })
  // A name that gRPC reserves fails smock check.
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: example
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { headers: { grpc-foo: x } }
  with_greeter(yaml, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|greeter.yaml: /stubs/0/response/headers/grpc-foo: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
        #|
      ),
    )
  })
}

///|
async test "an OK reply sends its initial metadata in its HEADERS and its trailing metadata after the status and the message, names in lower case and values trimmed" {
  with_greeter_set([("greeter.yaml", metadata_stubs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      inspect(
        client.metadata_case("ok"),
        content=(
          #|ok:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  x-served-by: smock
          #|  x-tag: a
          #|  x-tag: b
          #|  served-bin: AAAA
          #|  date: <now>
          #|DATA 000000000b0a0948656c6c6f20546f6d
          #|TRAILERS
          #|  grpc-status: 0
          #|  grpc-message: fine
          #|  x-trace: abc
          #|  tag-bin: AA
          #|  tag-bin: AAE
          #|(end)
        ),
      )
    })
  })
}

///|
async test "an error without initial metadata is Trailers-Only, with the trailing metadata in its one block, and smock-mock alone does not count as initial metadata" {
  with_greeter_set([("greeter.yaml", metadata_stubs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let replies = [
        client.metadata_case("trailers-only"),
        client.metadata_case("default-error", authority="other.svc"),
        client.metadata_case("default-headers", authority="other.svc"),
      ]
      inspect(
        replies.join("\n"),
        content=(
          #|trailers-only:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 14
          #|  grpc-message: try again
          #|  x-retry-after: 5
          #|  x-tag: a
          #|  x-tag: b
          #|  trace-bin: AAE
          #|  date: <now>
          #|(end)
          #|default-error:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 5
          #|  smock-mock: default; via=default
          #|  x-trace: abc
          #|  date: <now>
          #|(end)
          #|default-headers:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  x-served-by: smock
          #|  smock-mock: default; via=default
          #|  date: <now>
          #|TRAILERS
          #|  grpc-status: 5
          #|  x-trace: abc
          #|(end)
        ),
      )
      let (_, page) = smock.journal()
      inspect(
        answers(page),
        content=(
          #|"trailers-only" 200 "UNAVAILABLE"
          #|"default-error" 200 "NOT_FOUND"
          #|"default-headers" 200 "NOT_FOUND"
        ),
      )
    })
  })
}

///|
async test "with template on, metadata values render as header values do, a -bin value loses its padding, and a value outside 0x20 to 0x7E gives Trailers-Only INTERNAL template failed, with the reason in templateError" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    hosts: [localhost]
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: templated
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response:
    #|      template: true
    #|      headers: { x-greeted: "${body.name}" }
    #|      json: { message: "Hello ${body.name}" }
    #|      grpc:
    #|        trailers: { x-trace: "${header.x-trace}", trace-bin: "${header.x-trace-bin}", x-tag: [a, "${method}"] }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let call = (trace : String) => {
        client
        .call("/helloworld.Greeter/SayHello", headers=[
          ("x-trace", trace),
          ("x-trace-bin", "AAE="),
        ])
        .render()
      }
      inspect(
        call("abc"),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  x-greeted: Tom
          #|  date: <now>
          #|DATA 000000000b0a0948656c6c6f20546f6d
          #|TRAILERS
          #|  grpc-status: 0
          #|  x-trace: abc
          #|  trace-bin: AAE
          #|  x-tag: a
          #|  x-tag: POST
          #|(end)
        ),
      )
      // A request header value may hold octets above 0x7E, which a
      // trailer of the reply cannot.
      inspect(
        call("café"),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: template failed
          #|  date: <now>
          #|(end)
        ),
      )
      let (_, page) = smock.journal()
      inspect(
        answers(page),
        content=(
          #|"templated" 200 "OK"
          #|"templated" 200 "INTERNAL" templateError={"at":"/response/grpc/trailers/x-trace","message":"the rendered value holds U+00E9, and gRPC metadata values hold only characters from 0x20 to 0x7E"}
        ),
      )
    })
  })
}

///|
async test "smock check reports reserved names, names and values outside gRPC's grammar and -bin values that are not base64, in headers and trailers alike" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: reserved
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response:
    #|      headers: { Content-Type: application/grpc, grpc-status: "0", te: trailers, upgrade: h2c }
    #|      grpc: { status: NOT_FOUND, trailers: { grpc-message: x, smock-mock: x, keep-alive: x } }
    #|  - id: grammar
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response:
    #|      headers: { "x(trace)": a, "x-cafe": "café" }
    #|      grpc: { status: NOT_FOUND, trailers: { "x trace": a, x-tab: "a\tb", x-smile: "☺" } }
    #|  - id: binary
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response:
    #|      headers: { served-bin: "AA=" }
    #|      grpc: { status: NOT_FOUND, trailers: { trace-bin: [AAE, "-_8", "AAAAA", "AA AA"] } }
  with_greeter(yaml, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|greeter.yaml: /stubs/0/response/headers/Content-Type: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
        #|greeter.yaml: /stubs/0/response/headers/grpc-status: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
        #|greeter.yaml: /stubs/0/response/headers/te: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
        #|greeter.yaml: /stubs/0/response/headers/upgrade: is specific to an HTTP/1.1 connection, which HTTP/2 forbids
        #|greeter.yaml: /stubs/0/response/grpc/trailers/grpc-message: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
        #|greeter.yaml: /stubs/0/response/grpc/trailers/smock-mock: is set by smock and cannot be given
        #|greeter.yaml: /stubs/0/response/grpc/trailers/keep-alive: is specific to an HTTP/1.1 connection, which HTTP/2 forbids
        #|greeter.yaml: /stubs/1/response/headers/x(trace): is not a gRPC metadata name: in lower case, it may hold only 0-9, a-z, _, - and .
        #|greeter.yaml: /stubs/1/response/headers/x-cafe: must hold only characters from 0x20 to 0x7E: other values go in a field whose name ends with -bin, in base64
        #|greeter.yaml: /stubs/1/response/grpc/trailers/x trace: is not a gRPC metadata name: in lower case, it may hold only 0-9, a-z, _, - and .
        #|greeter.yaml: /stubs/1/response/grpc/trailers/x-tab: must hold only characters from 0x20 to 0x7E: other values go in a field whose name ends with -bin, in base64
        #|greeter.yaml: /stubs/1/response/grpc/trailers/x-smile: must hold only characters from 0x20 to 0x7E: other values go in a field whose name ends with -bin, in base64
        #|greeter.yaml: /stubs/2/response/headers/served-bin: must be standard base64, padded or not: a field whose name ends with -bin is binary
        #|greeter.yaml: /stubs/2/response/grpc/trailers/trace-bin/1: must be standard base64, padded or not: a field whose name ends with -bin is binary
        #|greeter.yaml: /stubs/2/response/grpc/trailers/trace-bin/2: must be standard base64, padded or not: a field whose name ends with -bin is binary
        #|greeter.yaml: /stubs/2/response/grpc/trailers/trace-bin/3: must be standard base64, padded or not: a field whose name ends with -bin is binary
        #|
      ),
    )
  })
}
