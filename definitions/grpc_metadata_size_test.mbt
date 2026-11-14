// The size of a static gRPC reply's metadata at load: its header block and
// its trailers, or its one Trailers-Only block, each count against
// `--header-size-limit` as RFC 7541 counts a header list, each field's name
// and value plus 32 octets, smock's own fields included. The sizes the
// tests expect are worked out by hand from that rule, field by field:
//
// - `:status: 200`, 7 + 3 + 32 = 42;
// - `content-type: application/grpc`, 12 + 16 + 32 = 60;
// - `date`, 4 + 29 + 32 = 65;
// - `grpc-status: 5` or `grpc-status: 0`, 11 + 1 + 32 = 44;
// - a metadata field, its name, its value and 32.
//
// The set is gRPC's helloworld.proto (greeter_set_test.mbt).

///|
/// Loads `a.yaml`, which declares the Mock `greeter`, whose set is gRPC's
/// helloworld.proto, then `stubs`, the lines of its `stubs` array, with the
/// header size limit `header_size_limit`. Renders every problem, one per
/// line, or, for a valid set, `loaded` and then each warning.
fn sized_replies(
  stubs : String,
  header_size_limit~ : Int32 = 16384,
) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: greeter, grpc: { descriptorSet: greeter.binpb } }
    #|stubs:
    #|
  match
    @definitions.load(
      {
        files: [("a.yaml", @utf8.encode(yaml + stubs))],
        body_files: [("greeter.binpb", set_bytes(greeter_set))],
      },
      header_size_limit~,
    ) {
    Ok(snapshot) =>
      ["loaded", ..snapshot.warnings().map(warning => warning.to_string())].join(
        "\n",
      )
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
/// A gRPC Stub `id` on SayHello whose reply is `response`, as a line of
/// `stubs`.
fn sized_stub(id : String, response : String) -> String {
  (
    $|  - id: \{id}
    $|    mock: greeter
    $|    request: { path: /helloworld.Greeter/SayHello }
    $|    response: \{response}
    $|
  )
}

///|
test "a static reply's Trailers-Only block that takes more than --header-size-limit is a problem at the reply, and one that takes it exactly loads" {
  // :status, content-type, grpc-status, date: 42 + 60 + 44 + 65 = 211;
  // x-trace with a value of n octets: 7 + n + 32. So 250 + n in all.
  let error = (n : Int32) => {
    "{ grpc: { status: NOT_FOUND, trailers: { x-trace: \{"a".repeat(n)} } } }"
  }
  inspect(
    sized_replies(sized_stub("at-limit", error(50)), header_size_limit=300),
    content="loaded",
  )
  inspect(
    sized_replies(sized_stub("over", error(51)), header_size_limit=300),
    content="a.yaml: /stubs/0/response: the reply's Trailers-Only block would take 301 bytes, over --header-size-limit, 300: each block of a gRPC reply's metadata counts as RFC 7541 counts a header list, each field's name and value plus 32, smock's own fields included",
  )
}

///|
test "an OK reply's header block, and the trailers of an error with initial metadata, each count on their own, the message percent-encoded" {
  // :status, content-type, date: 42 + 60 + 65 = 167; x-a with a value of n
  // octets: 3 + n + 32. So 202 + n in all.
  let ok = (n : Int32) => {
    "{ headers: { x-a: \{"a".repeat(n)} }, json: { message: Hi } }"
  }
  inspect(
    sized_replies(sized_stub("at-limit", ok(98)), header_size_limit=300),
    content="loaded",
  )
  inspect(
    sized_replies(sized_stub("over", ok(99)), header_size_limit=300),
    content="a.yaml: /stubs/0/response: the reply's header block would take 301 bytes, over --header-size-limit, 300: each block of a gRPC reply's metadata counts as RFC 7541 counts a header list, each field's name and value plus 32, smock's own fields included",
  )
  // The header block: 167 + x-a: b, 3 + 1 + 32, so 203. The trailers:
  // grpc-status, 44; grpc-message, "☺" sent as %E2%98%BA, 12 + 9 + 32 =
  // 53; x-trace with a value of n octets, 7 + n + 32. So 136 + n.
  let error = (n : Int32) => {
    (
      $|    responses:
      $|      - { json: { message: Hi } }
      $|      - headers: { x-a: b }
      $|        grpc: { status: NOT_FOUND, message: "☺", trailers: { x-trace: \{"a".repeat(n)} } }
      $|
    )
  }
  let stub = (id : String, n : Int32) => {
    (
      $|  - id: \{id}
      $|    mock: greeter
      $|    request: { path: /helloworld.Greeter/SayHello }
      $|\{error(n)}
    )
  }
  inspect(
    sized_replies(stub("at-limit", 164), header_size_limit=300),
    content="loaded",
  )
  inspect(
    sized_replies(stub("over", 165), header_size_limit=300),
    content="a.yaml: /stubs/0/responses/1: the reply's trailers would take 301 bytes, over --header-size-limit, 300: each block of a gRPC reply's metadata counts as RFC 7541 counts a header list, each field's name and value plus 32, smock's own fields included",
  )
}

///|
test "a date the metadata gives goes out in place of smock's, and values count once trimmed of spaces at either end" {
  // :status, content-type, grpc-status: 42 + 60 + 44 = 146; date with a
  // value of n octets once trimmed, 4 + n + 32, and no date of smock's. So
  // 182 + n.
  let error = (n : Int32) => {
    "{ grpc: { status: NOT_FOUND, trailers: { date: \"  \{"a".repeat(n)}  \" } } }"
  }
  inspect(
    sized_replies(sized_stub("at-limit", error(118)), header_size_limit=300),
    content="loaded",
  )
  inspect(
    sized_replies(sized_stub("over", error(119)), header_size_limit=300),
    content="a.yaml: /stubs/0/response: the reply's Trailers-Only block would take 301 bytes, over --header-size-limit, 300: each block of a gRPC reply's metadata counts as RFC 7541 counts a header list, each field's name and value plus 32, smock's own fields included",
  )
}
