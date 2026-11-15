// Seam 2 tests of a gRPC Stub's error details over h2c: an error's reply
// carries google.rpc.Status, built from its status, its message and its
// details packed as Any, in `grpc-status-details-bin`, in base64 without
// padding. The client decodes the value, and the tests compare it with
// protoc's encoding of the status they expect, which
// scripts/gen-protobuf-fixtures.sh writes from
// fixtures/protobuf/details/, so the encoder is never checked against
// itself. The set holds gRPC's helloworld.proto and googleapis'
// error_details.proto, not status.proto.

///|
/// The set of fixtures/protobuf/details/: helloworld.proto and
/// error_details.proto.
let details_set_path : String = "fixtures/protobuf/details/details.binpb"

///|
/// The framed HelloRequest `{name: "Ann"}`, as protoc encodes it.
async fn hello_ann() -> Bytes {
  framed(@fs.read_file("fixtures/protobuf/details/hello-ann.binpb").binary())
}

///|
/// The google.rpc.Status that protoc encodes from
/// fixtures/protobuf/details/<name>.txtpb.
async fn protoc_status(name : String) -> Bytes {
  @fs.read_file("fixtures/protobuf/details/\{name}.binpb").binary()
}

///|
/// The status the client decodes from the reply's `grpc-status-details-bin`,
/// which gRPC sends in base64 with or without padding: `None` without one.
fn GrpcReply::status_details(self : GrpcReply) -> Bytes? raise {
  guard self.status_field("grpc-status-details-bin") is Some(value) else {
    return None
  }
  Some(@base64.decode(value + "=".repeat((4 - value.length() % 4) % 4)))
}

///|
/// Runs `f` with a definitions directory holding `details.yaml`, which
/// declares the Mock `greeter`, the Default Mock, whose set is
/// details.binpb, then holds `stubs`, the lines of its `stubs` array; and
/// with the set at `files/details.binpb`.
async fn with_details(stubs : String, f : async (String) -> Unit) -> Unit {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    default: true
    #|    grpc: { descriptorSet: details.binpb }
    #|stubs:
    #|
  with_definitions([("details.yaml", yaml + stubs)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/details.binpb",
      @fs.read_file(details_set_path).binary(),
    )
    f(dir)
  })
}

///|
async test "the ticket's example: hello-unknown answers a call for Ann with NOT_FOUND, and the client decodes google.rpc.Status with code 5, the message and the ErrorInfo" {
  let stubs =
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
  with_details(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call("/helloworld.Greeter/SayHello", body=hello_ann())
      inspect(
        reply.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 5
          #|  grpc-message: no user called Ann
          #|  grpc-status-details-bin: CAUSEm5vIHVzZXIgY2FsbGVkIEFubhpHCih0eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5ycGMuRXJyb3JJbmZvEhsKDFVTRVJfVU5LTk9XThILZ3JlZXRlci5zdmM
          #|  smock-mock: greeter; via=default
          #|  x-trace: abc
          #|  date: <now>
          #|(end)
        ),
      )
      assert_eq(reply.status_details(), Some(protoc_status("error-info")))
      inspect(
        smock.calls_of(),
        content=(
          #|"hello-unknown" 200 "NOT_FOUND"
        ),
      )
    })
  })
}

///|
async test "details as written: a RetryInfo's Duration, a BadRequest, and three details with a map and a type that is not one of googleapis', each decoded back into protoc's google.rpc.Status, in the trailers after initial metadata" {
  let stubs =
    #|  - id: retry
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: retry } }
    #|    response:
    #|      grpc:
    #|        status: UNAVAILABLE
    #|        message: try again
    #|        details: [{ "@type": type.googleapis.com/google.rpc.RetryInfo, retryDelay: 1.5s }]
    #|  - id: bad-request
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: bad-request } }
    #|    response:
    #|      headers: { x-served-by: smock }
    #|      grpc:
    #|        status: INVALID_ARGUMENT
    #|        message: the request is not valid
    #|        details:
    #|          - "@type": type.googleapis.com/google.rpc.BadRequest
    #|            field_violations:
    #|              - { field: name, description: must not be empty }
    #|              - { field: version, description: must be a number, reason: NOT_A_NUMBER }
    #|  - id: several
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: several } }
    #|    response:
    #|      grpc:
    #|        status: RESOURCE_EXHAUSTED
    #|        message: "try again ☺"
    #|        details:
    #|          - "@type": type.googleapis.com/google.rpc.ErrorInfo
    #|            reason: QUOTA
    #|            domain: greeter.svc
    #|            metadata: { limit: "10", burst: "2" }
    #|          - { "@type": type.googleapis.com/google.rpc.RetryInfo, retryDelay: 30s }
    #|          - { "@type": type.googleapis.com/helloworld.HelloReply, message: later }
  with_details(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let lines = []
      for case in ["retry", "bad-request", "several"] {
        let reply = client.call("/helloworld.Greeter/SayHello", headers=[
          ("x-case", case),
        ])
        let expected = if case == "retry" { "retry-info" } else { case }
        let decoded = reply.status_details() == Some(protoc_status(expected))
        lines.push("\{case}: \{reply.status_line()}, as protoc: \{decoded}")
        if case == "bad-request" {
          lines.push(reply.render())
        }
      }
      inspect(
        lines.join("\n"),
        content=(
          #|retry: grpc-status 14, trailers-only
          #|  sent: try again
          #|  decoded: "try again", as protoc: true
          #|bad-request: grpc-status 3, message, then trailers
          #|  sent: the request is not valid
          #|  decoded: "the request is not valid", as protoc: true
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  x-served-by: smock
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|TRAILERS
          #|  grpc-status: 3
          #|  grpc-message: the request is not valid
          #|  grpc-status-details-bin: CAMSGHRoZSByZXF1ZXN0IGlzIG5vdCB2YWxpZBpzCil0eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5ycGMuQmFkUmVxdWVzdBJGChkKBG5hbWUSEW11c3Qgbm90IGJlIGVtcHR5CikKB3ZlcnNpb24SEG11c3QgYmUgYSBudW1iZXIaDE5PVF9BX05VTUJFUg
          #|(end)
          #|several: grpc-status 8, trailers-only
          #|  sent: try again %E2%98%BA
          #|  decoded: "try again ☺", as protoc: true
        ),
      )
    })
  })
}

///|
async test "templated details render from the call, then are encoded; one that does not fit its type gets Trailers-Only INTERNAL template failed, with templateError" {
  let stubs =
    #|  - id: templated
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: templated } }
    #|    response:
    #|      template: true
    #|      grpc:
    #|        status: NOT_FOUND
    #|        message: no user called ${body.name}
    #|        details:
    #|          - "@type": type.googleapis.com/google.rpc.ErrorInfo
    #|            reason: USER_UNKNOWN
    #|            domain: greeter.svc
    #|            metadata: { name: "${body.name}" }
    #|          - "@type": "type.googleapis.com/${header.x-type}"
    #|            fieldViolations: [{ field: name, description: "no user called ${body.name}" }]
    #|  - id: misfit
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: misfit } }
    #|    responses:
    #|      - template: true
    #|        grpc:
    #|          status: NOT_FOUND
    #|          details:
    #|            - { "@type": type.googleapis.com/google.rpc.RetryInfo, retryDelay: "${body.name}" }
  with_details(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let templated = client.call(
        "/helloworld.Greeter/SayHello",
        headers=[("x-case", "templated"), ("x-type", "google.rpc.BadRequest")],
        body=hello_ann(),
      )
      assert_eq(templated.status_details(), Some(protoc_status("templated")))
      // A rendered @type that names no type of the set, and a rendered
      // value that does not fit its field.
      let missing = client.call(
        "/helloworld.Greeter/SayHello",
        headers=[("x-case", "templated"), ("x-type", "google.rpc.Status")],
        body=hello_ann(),
      )
      inspect(
        missing.render(),
        content=(
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
      let _ = client.call(
        "/helloworld.Greeter/SayHello",
        headers=[("x-case", "misfit")],
        body=hello_ann(),
      )
      inspect(
        smock.calls_of(),
        content=(
          #|"templated" 200 "NOT_FOUND"
          #|"templated" 200 "INTERNAL" templateError={"at":"/response/grpc/details/1/@type","message":"names the type google.rpc.Status, which the Descriptor set does not define"}
          #|"misfit" 200 "INTERNAL" templateError={"at":"/responses/0/grpc/details/0/retryDelay","message":"must be a duration from \"-315576000000.999999999s\" to \"315576000000.999999999s\": seconds, with at most 9 fractional digits, then \"s\", such as \"1.500s\": the field retry_delay of google.rpc.RetryInfo has the type google.protobuf.Duration"}
        ),
      )
    })
  })
}

///|
async test "rendered details count toward the trailers' size: a Trailers-Only block over --header-size-limit gets INTERNAL reply metadata too large" {
  let stubs =
    #|  - id: long
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response:
    #|      template: true
    #|      grpc:
    #|        status: NOT_FOUND
    #|        details:
    #|          - "@type": type.googleapis.com/google.rpc.ErrorInfo
    #|            reason: "${body.name}"
    #|
  // A 600-character reason gives an ErrorInfo of 603 octets, an Any of
  // 648 and a status of 653, 871 in base64 without padding. The block:
  // :status and content-type, 102; grpc-status 5, 44;
  // grpc-status-details-bin, 23 + 871 + 32 = 926; smock-mock, 10 + 20 + 32
  // = 62; date, 65. So 1199 in all.
  let reason = "R".repeat(600)
  let stubs = stubs.replace(old="${body.name}", new=reason)
  with_details(stubs, dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--header-size-limit", "1024"],
      smock => {
        let client = smock.h2c()
        defer client.close()
        let reply = client.call("/helloworld.Greeter/SayHello")
        inspect(
          reply.status_line(),
          content=(
            #|grpc-status 13, trailers-only
            #|  sent: reply metadata too large
            #|  decoded: "reply metadata too large"
          ),
        )
        inspect(
          smock.calls_of(),
          content=(
            #|"long" 200 "INTERNAL" templateError={"at":"/response","message":"the reply's Trailers-Only block would take 1199 bytes, over --header-size-limit, 1024"}
          ),
        )
      },
    )
  })
}

///|
async test "an error with details that a delay holds back sends them once the delay ends" {
  let stubs =
    #|  - id: slow-unknown
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response:
    #|      template: true
    #|      grpc:
    #|        status: NOT_FOUND
    #|        message: no user called ${body.name}
    #|        details:
    #|          - "@type": type.googleapis.com/google.rpc.ErrorInfo
    #|            reason: USER_UNKNOWN
    #|            domain: greeter.svc
    #|    fault: { delay: { fixed: 200 } }
  with_details(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call("/helloworld.Greeter/SayHello", body=hello_ann())
      assert_eq(reply.status_details(), Some(protoc_status("error-info")))
      inspect(
        smock.calls_of(),
        content=(
          #|"slow-unknown" 200 "NOT_FOUND"
        ),
      )
    })
  })
}

///|
async test "smock check reports a detail type the set lacks and details with OK" {
  let stubs =
    #|  - id: missing
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response:
    #|      grpc:
    #|        status: NOT_FOUND
    #|        details: [{ "@type": type.googleapis.com/google.rpc.Status, code: 5 }]
    #|  - id: ok
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response:
    #|      json: { message: Hello }
    #|      grpc:
    #|        details: [{ "@type": type.googleapis.com/google.rpc.ErrorInfo, reason: FINE }]
  with_details(stubs, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|details.yaml: /stubs/0/response/grpc/details/0/@type: names the type google.rpc.Status, which the Descriptor set does not define
        #|details.yaml: /stubs/1/response/grpc/details: is not allowed with the gRPC status OK: gRPC sends error details only with an error
        #|
      ),
    )
  })
}

///|
async test "an Ephemeral gRPC Stub's details as written are encoded again once a reload swaps its Mock's set, and a type the new set lacks gets INTERNAL with its templateError" {
  with_details("  []\n", dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let added = smock.call(
        "POST",
        "/v1/mocks/greeter/stubs",
        body=(
          #|{"request":{"path":"/helloworld.Greeter/SayHello"},"response":{"grpc":{"status":"NOT_FOUND","message":"no user called Ann","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"USER_UNKNOWN","domain":"greeter.svc"}]}}}
        ),
      )
      let client = smock.h2c()
      defer client.close()
      let first = client.call("/helloworld.Greeter/SayHello")
      // The same Mock with gRPC's helloworld.proto alone, without
      // error_details.proto.
      let before = smock.status()
      write_bytes(
        dir,
        "files/greeter.binpb",
        @fs.read_file(greeter_set_path).binary(),
      )
      @fs.write_file(
        "\{dir}/details.yaml",
        (
          #|mocks:
          #|  - name: greeter
          #|    default: true
          #|    grpc: { descriptorSet: greeter.binpb }
        ),
      )
      let _ = smock.swapped(before)
      let second = client.call("/helloworld.Greeter/SayHello")
      inspect(
        [
          "added: \{added.split(" ").next().unwrap_or("")}",
          "before: \{first.status_details() == Some(protoc_status("error-info"))}",
          "after: \{second.status_line()}",
          smock.calls_of(),
        ].join("\n"),
        content=(
          #|added: 201
          #|before: true
          #|after: grpc-status 13, trailers-only
          #|  sent: template failed
          #|  decoded: "template failed"
          #|"eph-1" 200 "NOT_FOUND"
          #|"eph-1" 200 "INTERNAL" templateError={"at":"/response/grpc/details/0/@type","message":"names the type google.rpc.ErrorInfo, which the Descriptor set does not define"}
        ),
      )
    })
  })
}
