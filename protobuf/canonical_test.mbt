// Messages decoded into canonical ProtoJSON through the public interface,
// beside smock's decoded form: for each field type and each well-known
// type. The messages are protoc-encoded fixtures
// (scripts/gen-protobuf-fixtures.sh), or records written by hand, so the
// codec is never checked against itself. protobuf's conformance suite
// checks the same printer against protobuf's own.

///|
/// `input` decoded as a message of the type whose full name is `name` in
/// the set the script wrote in `hex`, as canonical ProtoJSON text, or the
/// error that stops it.
fn canonical(hex : String, name : String, input : Bytes) -> String {
  let set = hex_set(hex)
  guard set.find_message(name) is Some(message) else {
    abort("no message \{name}")
  }
  @utf8.decode(@protobuf.decode_canonical_json(set, message, input[:])) catch {
    err => "error: \{err}"
  }
}

///|
/// The set of `message User { int64 id = 1; string name = 2; }`, in
/// package `demo` of a proto3 file, as protoc writes it, in hex.
let user_set : String = "0a430a07612e70726f746f120464656d6f222a0a0455736572120e0a0269641801200128035202696412120a046e616d6518022001280952046e616d65620670726f746f33"

///|
test "the ticket's example: a 64-bit integer as a string, and a field at its default left out" {
  // id: 42, and no name.
  let user = b"\x08\x2a"
  inspect(
    canonical(user_set, "demo.User", user),
    content=(
      #|{"id":"42"}
    ),
  )
  inspect(
    decoded(user_set, "demo.User", user),
    content=(
      #|{"id":42,"name":""}
    ),
  )
}
