// A gRPC Stub's `response.grpc.details` at load: error details in ProtoJSON
// with `@type`, whose types are looked up in the Mock's set, and which go
// out in google.rpc.Status, encoded from a static reply when the files are
// loaded. The sets are details.binpb (gRPC's helloworld.proto and
// googleapis' error_details.proto, details_set_test.mbt) and shipping.proto
// (shipping_set_test.mbt), whose types reach an editions file and a
// MessageSet.

///|
/// Loads `a.yaml`, which declares the Mock `greeter`, whose set is
/// details.binpb, and the Mock `shipping`, whose set is shipping.proto,
/// then `stubs`, the lines of its `stubs` array, with the header size limit
/// `header_size_limit`. Shows the details of each response of each Stub,
/// one Stub per line: how many it has, and the value of
/// `grpc-status-details-bin` encoded at load, or `template` for templated
/// ones; `-` for a response without any. Or every problem, one per line.
fn grpc_details(
  stubs : String,
  header_size_limit~ : Int32 = 16384,
) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: greeter, grpc: { descriptorSet: details.binpb } }
    #|  - { name: shipping, grpc: { descriptorSet: shipping.binpb } }
    #|stubs:
    #|
  match
    @definitions.load(
      {
        files: [("a.yaml", @utf8.encode(yaml + stubs))],
        body_files: [
          ("details.binpb", set_bytes(details_set)),
          ("shipping.binpb", set_bytes(shipping_set)),
        ],
      },
      header_size_limit~,
    ) {
    Ok(snapshot) => {
      let lines = []
      for mock in snapshot.mocks {
        for stub in mock.stubs {
          guard stub.serves is Ordinary(ordinary) else { continue }
          let replies = []
          for weighted in ordinary.responses {
            replies.push(
              match weighted.response.grpc {
                None | Some({ details: Written(_, None), .. }) => "-"
                Some({ details: Written(details, Some(status)), .. }) =>
                  "\{details.length()} \{@utf8.decode(status.value)}"
                Some({ details: Templated(details), .. }) =>
                  "\{details.length()} template"
              },
            )
          }
          lines.push("\{stub.id}: \{replies.join(" | ")}")
        }
      }
      lines.join("\n")
    }
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
test "the ticket's example: an error's details as written go out in google.rpc.Status, encoded at load, in base64 without padding; templated ones are kept to render" {
  inspect(
    grpc_details(
      (
        #|  - id: hello-unknown
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
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
        #|  - id: hello-ann
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    responses:
        #|      - grpc:
        #|          status: NOT_FOUND
        #|          message: no user called Ann
        #|          details:
        #|            - "@type": type.googleapis.com/google.rpc.ErrorInfo
        #|              reason: USER_UNKNOWN
        #|              domain: greeter.svc
        #|      - grpc: { status: UNAVAILABLE, details: [] }
        #|      - json: { message: Hello }
      ),
    ),
    // The value is fixtures/protobuf/details/error-info.binpb, protoc's
    // encoding of the same status, in base64 without padding.
    content=(
      #|hello-unknown: 1 template
      #|hello-ann: 1 CAUSEm5vIHVzZXIgY2FsbGVkIEFubhpHCih0eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5ycGMuRXJyb3JJbmZvEhsKDFVTRVJfVU5LTk9XThILZ3JlZXRlci5zdmM | - | -
    ),
  )
}

///|
test "details with OK are a load error, since gRPC sends them only with an error, and so are details that are not Anys of the set's types" {
  inspect(
    grpc_details(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    responses:
        #|      - grpc: { details: [{ "@type": type.googleapis.com/google.rpc.ErrorInfo }] }
        #|      - grpc: { status: OK, message: fine, details: [{ "@type": type.googleapis.com/google.rpc.ErrorInfo }] }
        #|      - grpc: { status: NOT_FOUND, details: { "@type": type.googleapis.com/google.rpc.ErrorInfo } }
        #|      - grpc: { status: NOT_FOUND, details: [ErrorInfo] }
        #|      - grpc: { status: NOT_FOUND, details: [{ reason: USER_UNKNOWN }] }
        #|      - grpc: { status: NOT_FOUND, details: [{ "@type": 5 }] }
        #|      - grpc: { status: NOT_FOUND, details: [{ "@type": type.googleapis.com/google.rpc.Status }] }
        #|      - grpc: { status: NOT_FOUND, details: [{ "@type": type.googleapis.com/google.rpc.ErrorInfo, reasons: USER_UNKNOWN }] }
        #|      - grpc: { status: UNAVAILABLE, details: [{ "@type": type.googleapis.com/google.rpc.RetryInfo }, { "@type": type.googleapis.com/google.rpc.RetryInfo, retryDelay: 1.5 }] }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/responses/0/grpc/details: is not allowed with the gRPC status OK: gRPC sends error details only with an error
      #|a.yaml: /stubs/0/responses/1/grpc/details: is not allowed with the gRPC status OK: gRPC sends error details only with an error
      #|a.yaml: /stubs/0/responses/2/grpc/details: must be an array
      #|a.yaml: /stubs/0/responses/3/grpc/details/0: must be an object: a detail is an Any, the fields of its message beside "@type"
      #|a.yaml: /stubs/0/responses/4/grpc/details/0: must give "@type", the type URL of the detail's message, such as "type.googleapis.com/google.rpc.ErrorInfo"
      #|a.yaml: /stubs/0/responses/5/grpc/details/0/@type: must be a type URL: / and the full name of a type of the set at its end, such as "type.googleapis.com/helloworld.HelloRequest"
      #|a.yaml: /stubs/0/responses/6/grpc/details/0/@type: names the type google.rpc.Status, which the Descriptor set does not define
      #|a.yaml: /stubs/0/responses/7/grpc/details/0/reasons: is not a field of google.rpc.ErrorInfo
      #|a.yaml: /stubs/0/responses/8/grpc/details/1/retryDelay: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field retry_delay of google.rpc.RetryInfo has the type google.protobuf.Duration
    ),
  )
}

///|
test "a templated detail is a structured template, whose @type is looked up at load when it is written without an expression" {
  inspect(
    grpc_details(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    responses:
        #|      - template: true
        #|        grpc:
        #|          status: NOT_FOUND
        #|          details:
        #|            - { "@type": type.googleapis.com/google.rpc.ErrorInfo, reason: "${body.name}" }
        #|            - { "@type": "type.googleapis.com/${body.name}", reason: "${body.name}" }
        #|      - template: true
        #|        grpc:
        #|          status: NOT_FOUND
        #|          details: [{ "@type": type.googleapis.com/google.rpc.Status, reason: "${body.name}" }]
        #|      - template: true
        #|        grpc:
        #|          status: NOT_FOUND
        #|          details: [{ "@type": type.googleapis.com/google.rpc.ErrorInfo, reason: "${body.name" }]
        #|      - template: true
        #|        grpc:
        #|          status: NOT_FOUND
        #|          details: [{ reason: "${body.name}" }]
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/responses/1/grpc/details/0/@type: names the type google.rpc.Status, which the Descriptor set does not define
      #|a.yaml: /stubs/0/responses/2/grpc/details/0/reason: template: column 1: the ${ is not closed
      #|a.yaml: /stubs/0/responses/3/grpc/details/0: must give "@type", the type URL of the detail's message, such as "type.googleapis.com/google.rpc.ErrorInfo"
    ),
  )
}

///|
test "a detail type goes through a method's type checks: a type of an editions file, or one that reaches one, and a MessageSet are load errors" {
  inspect(
    grpc_details(
      (
        #|  - id: place
        #|    mock: shipping
        #|    request: { path: /shipping.Orders/Place }
        #|    responses:
        #|      - grpc: { status: NOT_FOUND, details: [{ "@type": type.googleapis.com/labels.Label }] }
        #|      - grpc: { status: NOT_FOUND, details: [{ "@type": type.googleapis.com/shipping.Sheet }] }
        #|      - grpc: { status: NOT_FOUND, details: [{ "@type": type.googleapis.com/shipping.Bag }] }
        #|      - template: true
        #|        grpc: { status: NOT_FOUND, details: [{ "@type": type.googleapis.com/shipping.Bag }] }
        #|      - grpc: { status: NOT_FOUND, details: [{ "@type": type.googleapis.com/shipping.Draft, note: lost }] }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/responses/0/grpc/details/0/@type: the detail type labels.Label is not served yet: labels.proto, which defines it, is an editions file, and editions come in a later spec
      #|a.yaml: /stubs/0/responses/1/grpc/details/0/@type: the detail type shipping.Sheet is not served yet: labels.proto, which defines labels.Color, a type it reaches, is an editions file, and editions come in a later spec
      #|a.yaml: /stubs/0/responses/1/grpc/details/0/@type: the detail type shipping.Sheet is not served yet: labels.proto, which defines labels.Label, a type it reaches, is an editions file, and editions come in a later spec
      #|a.yaml: /stubs/0/responses/2/grpc/details/0/@type: the detail type shipping.Bag is not served: it is a MessageSet, whose extensions use another wire form, and smock serves no MessageSet types
      #|a.yaml: /stubs/0/responses/3/grpc/details/0/@type: the detail type shipping.Bag is not served: it is a MessageSet, whose extensions use another wire form, and smock serves no MessageSet types
    ),
  )
}

///|
test "static details count toward the trailers' size: google.rpc.Status in base64 without padding, beside the other fields" {
  // :status, content-type, grpc-status 5, date: 42 + 60 + 44 + 65 = 211;
  // grpc-message "no user called Ann": 12 + 18 + 32 = 62; the status of
  // error-info.binpb, 95 octets, in base64 without padding, 127 octets:
  // 23 + 127 + 32 = 182. So 455 in all.
  let stubs =
    #|  - id: hello-ann
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response:
    #|      grpc:
    #|        status: NOT_FOUND
    #|        message: no user called Ann
    #|        details:
    #|          - "@type": type.googleapis.com/google.rpc.ErrorInfo
    #|            reason: USER_UNKNOWN
    #|            domain: greeter.svc
  inspect(
    grpc_details(stubs, header_size_limit=455).has_prefix("hello-ann: 1 "),
    content="true",
  )
  inspect(
    grpc_details(stubs, header_size_limit=454),
    content="a.yaml: /stubs/0/response: the reply's Trailers-Only block would take 455 bytes, over --header-size-limit, 454: each block of a gRPC reply's metadata counts as RFC 7541 counts a header list, each field's name and value plus 32, smock's own fields included",
  )
}
