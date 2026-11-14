// A gRPC Stub's reply metadata at load: its `headers`, the initial
// metadata, and its `grpc.trailers`, the trailing metadata, with the names
// and values gRPC's grammar allows, `-bin` values in base64 without their
// padding, and several values of one name as an array. The set is gRPC's
// helloworld.proto (greeter_set_test.mbt), and `check_stubs`
// (grpc_stubs_test.mbt) renders the problems.

///|
/// One field of reply metadata as `reply_metadata` shows it: its name, then
/// its value as written, or its template's source after `template`.
fn shown_metadata(fields : @definitions.ResponseHeaders) -> String {
  let shown = match fields {
    Written(fields) =>
      fields.iter().map(field => "\{field.0}: \{field.1.escape()}").collect()
    Templated(fields) =>
      fields
      .iter()
      .map(field => "\{field.0}: template \{field.1.source.escape()}")
      .collect()
  }
  "[\{shown.join(", ")}]"
}

///|
/// Loads `a.yaml`, which declares the Mock `greeter`, whose set is gRPC's
/// helloworld.proto, then `stubs`, the lines of its `stubs` array. Shows
/// the metadata of each response of each Stub, one response per line: its
/// initial metadata, then its trailing metadata. Or every problem, one per
/// line.
fn reply_metadata(stubs : String) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: greeter, grpc: { descriptorSet: greeter.binpb } }
    #|stubs:
    #|
  match
    @definitions.load({
      files: [("a.yaml", @utf8.encode(yaml + stubs))],
      body_files: [("greeter.binpb", set_bytes(greeter_set))],
    }) {
    Ok(snapshot) => {
      let lines = []
      for stub in snapshot.mocks[0].stubs {
        guard stub.serves is Ordinary(ordinary) else { continue }
        for weighted in ordinary.responses {
          let response = weighted.response
          let trailers = match response.grpc {
            Some(reply) => shown_metadata(reply.trailers)
            None => "-"
          }
          lines.push(
            "\{stub.id}: headers \{shown_metadata(response.headers)} trailers \{trailers}",
          )
        }
      }
      lines.join("\n")
    }
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
test "a gRPC Stub's headers are its initial metadata and grpc.trailers its trailing metadata, with names in lower case, an array for several values, and -bin values without their padding" {
  inspect(
    reply_metadata(
      (
        #|  - id: missing
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response:
        #|      headers: { X-Served-By: smock }
        #|      grpc:
        #|        status: NOT_FOUND
        #|        trailers: { x-trace: abc, x-tag: [a, b], trace-bin: "AAE=", Tag-Bin: [AA==, AAAA] }
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    responses:
        #|      - { headers: { x-empty: "", x.dotted_name: " spaced " }, json: { message: Hi } }
        #|      - { grpc: { trailers: {} } }
        #|      - { json: { message: Hi } }
      ),
    ),
    content=(
      #|missing: headers [x-served-by: "smock"] trailers [x-trace: "abc", x-tag: "a", x-tag: "b", trace-bin: "AAE", tag-bin: "AA", tag-bin: "AAAA"]
      #|hello: headers [x-empty: "", x.dotted_name: " spaced "] trailers -
      #|hello: headers [] trailers []
      #|hello: headers [] trailers -
    ),
  )
}

///|
test "with template on, trailer values are text templates, as header values are, and their values are checked once rendered" {
  inspect(
    reply_metadata(
      (
        #|  - id: templated
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response:
        #|      template: true
        #|      headers: { x-name: "${body.name}" }
        #|      grpc:
        #|        status: NOT_FOUND
        #|        trailers: { x-trace: "trace ${body.name}", x-tag: [a, "${body.name}"], trace-bin: "${body.name}", x-note: "café" }
      ),
    ),
    content=(
      #|templated: headers [x-name: template "${body.name}"] trailers [x-trace: template "trace ${body.name}", x-tag: template "a", x-tag: template "${body.name}", trace-bin: template "${body.name}", x-note: template "café"]
    ),
  )
  // A trailer whose template does not parse is reported at its pointer.
  inspect(
    check_stubs(
      (
        #|  - id: broken
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response: { template: true, grpc: { status: INTERNAL, trailers: { x-trace: "${body.name" } } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/response/grpc/trailers/x-trace: template: column 1: the ${ is not closed
    ),
  )
}

///|
test "names that gRPC reserves, that HTTP/2 forbids or that smock sets are load errors in both, so a gRPC Stub that gives a Content-Type is refused" {
  inspect(
    check_stubs(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response:
        #|      headers: { grpc-foo: x, Content-Type: application/grpc, te: trailers, keep-alive: x, proxy-connection: x, upgrade: x }
        #|      grpc:
        #|        trailers: { Grpc-Status: "0", grpc-: x, content-type: x, TE: x, Keep-Alive: x, Proxy-Connection: x, Upgrade: x, content-length: "1", connection: x, transfer-encoding: x, smock-mock: x }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/response/headers/grpc-foo: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
      #|a.yaml: /stubs/0/response/headers/Content-Type: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
      #|a.yaml: /stubs/0/response/headers/te: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
      #|a.yaml: /stubs/0/response/headers/keep-alive: is specific to an HTTP/1.1 connection, which HTTP/2 forbids
      #|a.yaml: /stubs/0/response/headers/proxy-connection: is specific to an HTTP/1.1 connection, which HTTP/2 forbids
      #|a.yaml: /stubs/0/response/headers/upgrade: is specific to an HTTP/1.1 connection, which HTTP/2 forbids
      #|a.yaml: /stubs/0/response/grpc/trailers/Grpc-Status: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
      #|a.yaml: /stubs/0/response/grpc/trailers/grpc-: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
      #|a.yaml: /stubs/0/response/grpc/trailers/content-type: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
      #|a.yaml: /stubs/0/response/grpc/trailers/TE: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
      #|a.yaml: /stubs/0/response/grpc/trailers/Keep-Alive: is specific to an HTTP/1.1 connection, which HTTP/2 forbids
      #|a.yaml: /stubs/0/response/grpc/trailers/Proxy-Connection: is specific to an HTTP/1.1 connection, which HTTP/2 forbids
      #|a.yaml: /stubs/0/response/grpc/trailers/Upgrade: is specific to an HTTP/1.1 connection, which HTTP/2 forbids
      #|a.yaml: /stubs/0/response/grpc/trailers/content-length: is set by smock and cannot be given
      #|a.yaml: /stubs/0/response/grpc/trailers/connection: is set by smock and cannot be given
      #|a.yaml: /stubs/0/response/grpc/trailers/transfer-encoding: is set by smock and cannot be given
      #|a.yaml: /stubs/0/response/grpc/trailers/smock-mock: is set by smock and cannot be given
    ),
  )
}

///|
test "names and values outside gRPC's grammar and -bin values that are not base64 are load errors; with template on, values are checked once rendered" {
  inspect(
    check_stubs(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    responses:
        #|      - headers: { "x!y": a, "x y": b, "x/y": c, "é": d, "": e, x-tab: "a\tb", x-cafe: "café", x-smile: "☺" }
        #|        grpc: { trailers: { "x:y": a, x-tag: [ok, "a\tb"], x-line: "a\nb", trace-bin: "AA=", tag-bin: [AAE, "-_8", "A"] } }
        #|      - template: true
        #|        headers: { x-cafe: "café ${body.name}", x-line: "a\nb" }
        #|        grpc: { trailers: { trace-bin: "${body.name}", x-tab: "a\tb", x-line: "a\nb" } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/responses/0/headers/x!y: is not a gRPC metadata name: in lower case, it may hold only 0-9, a-z, _, - and .
      #|a.yaml: /stubs/0/responses/0/headers/x y: is not a gRPC metadata name: in lower case, it may hold only 0-9, a-z, _, - and .
      #|a.yaml: /stubs/0/responses/0/headers/x~1y: is not a gRPC metadata name: in lower case, it may hold only 0-9, a-z, _, - and .
      #|a.yaml: /stubs/0/responses/0/headers/é: is not a gRPC metadata name: in lower case, it may hold only 0-9, a-z, _, - and .
      #|a.yaml: /stubs/0/responses/0/headers/: is not a gRPC metadata name: in lower case, it may hold only 0-9, a-z, _, - and .
      #|a.yaml: /stubs/0/responses/0/headers/x-tab: must hold only characters from 0x20 to 0x7E: other values go in a field whose name ends with -bin, in base64
      #|a.yaml: /stubs/0/responses/0/headers/x-cafe: must hold only characters from 0x20 to 0x7E: other values go in a field whose name ends with -bin, in base64
      #|a.yaml: /stubs/0/responses/0/headers/x-smile: must hold only characters from 0x20 to 0x7E: other values go in a field whose name ends with -bin, in base64
      #|a.yaml: /stubs/0/responses/0/grpc/trailers/x:y: is not a gRPC metadata name: in lower case, it may hold only 0-9, a-z, _, - and .
      #|a.yaml: /stubs/0/responses/0/grpc/trailers/x-tag/1: must hold only characters from 0x20 to 0x7E: other values go in a field whose name ends with -bin, in base64
      #|a.yaml: /stubs/0/responses/0/grpc/trailers/x-line: must hold only characters from 0x20 to 0x7E: other values go in a field whose name ends with -bin, in base64
      #|a.yaml: /stubs/0/responses/0/grpc/trailers/trace-bin: must be standard base64, padded or not: a field whose name ends with -bin is binary
      #|a.yaml: /stubs/0/responses/0/grpc/trailers/tag-bin/1: must be standard base64, padded or not: a field whose name ends with -bin is binary
      #|a.yaml: /stubs/0/responses/0/grpc/trailers/tag-bin/2: must be standard base64, padded or not: a field whose name ends with -bin is binary
      #|a.yaml: /stubs/0/responses/1/headers/x-line: must not contain control characters other than tab
      #|a.yaml: /stubs/0/responses/1/grpc/trailers/x-line: must not contain control characters other than tab
    ),
  )
}

///|
test "trailers take the shape of headers, and two names that differ only in case are a load error" {
  inspect(
    check_stubs(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    responses:
        #|      - grpc: { trailers: [x-trace] }
        #|      - grpc: { trailers: { x-trace: 5, x-tag: [], x-list: [a, 5] } }
        #|      - headers: { x-trace: a, X-Trace: b }
        #|        grpc: { trailers: { x-trace: a, X-TRACE: b } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/responses/0/grpc/trailers: must be an object
      #|a.yaml: /stubs/0/responses/1/grpc/trailers/x-trace: must be a string or an array of strings
      #|a.yaml: /stubs/0/responses/1/grpc/trailers/x-tag: must not be an empty array
      #|a.yaml: /stubs/0/responses/1/grpc/trailers/x-list/1: must be a string
      #|a.yaml: /stubs/0/responses/2/headers/X-Trace: the header name "x-trace" is already given: header names are case-insensitive
      #|a.yaml: /stubs/0/responses/2/grpc/trailers/X-TRACE: the header name "x-trace" is already given: header names are case-insensitive
    ),
  )
}

///|
test "an HTTP Stub's headers keep HTTP's rules: names that gRPC reserves and values outside 0x20 to 0x7E are not refused there" {
  inspect(
    check_stubs(
      (
        #|  - id: http
        #|    mock: plain
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response: { status: 200, headers: { grpc-foo: x, X-Tab: "a\tb", X-Cafe: "café" } }
      ),
    ),
    content="plain: http: HTTP Stub",
  )
}
