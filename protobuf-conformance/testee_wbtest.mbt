///|
/// The Descriptor set of protobuf's conformance messages, which the fixture
/// script builds.
let set_path = "fixtures/protobuf/conformance/conformance.binpb"

///|
/// Checks the testee's answer to the request of
/// `fixtures/protobuf/conformance/<name>.txtpb`, as protoc encodes it,
/// against the response of `<name>-response.txtpb`, as protoc encodes it.
async fn check(name : String) -> Unit {
  let dir = "fixtures/protobuf/conformance"
  let set = @protobuf.read_descriptor_set(@fs.read_file(set_path).binary()[:])
  let request = @fs.read_file("\{dir}/\{name}.binpb").binary()
  let expected = @fs.read_file("\{dir}/\{name}-response.binpb").binary()
  let got = answer(set, request[:])
  if got != expected {
    fail(
      "\{name}: the answer is \{@hex.encode(got[:])}, not \{@hex.encode(expected[:])}",
    )
  }
}

///|
async test "a binary message asked for as JSON is answered in canonical ProtoJSON" {
  check("binary-to-json")
}

///|
async test "a JSON message asked for in the binary encoding is encoded as protoc encodes it" {
  check("json-to-binary")
}

///|
async test "a JSON message asked for as JSON is answered in canonical ProtoJSON" {
  check("json-to-json")
}

///|
async test "a binary message asked for in the binary encoding is encoded again as protoc encodes it" {
  check("binary-to-binary")
}

///|
async test "a message in protobuf's text format is skipped, and so is one asked for in it" {
  check("text-format")
  check("text-format-output")
}

///|
async test "a message of a type of an editions file is skipped" {
  check("editions")
}

///|
async test "bytes that are not protobuf give smock/protobuf's error as a parse error" {
  check("not-protobuf")
}

///|
async test "a type that the Descriptor set lacks gives a runtime error" {
  check("unknown-type")
}
