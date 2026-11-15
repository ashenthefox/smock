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
