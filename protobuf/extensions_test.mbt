// proto2 extensions and groups through the public interface, decoded and
// encoded. The set is fixtures/protobuf/extensions/shop.proto, and the
// messages are what protoc encodes from the .txtpb files beside it
// (scripts/gen-protobuf-fixtures.sh), so the codec is never checked
// against itself.

///|
test "the ticket's example: an Order with the id 7 and the extension shop.priority set to 3 decodes as {\"id\":7,\"[shop.priority]\":3}" {
  // id 7, then field 100 holding 3, as protoc encodes order.txtpb.
  inspect(
    decoded(extensions_set, "shop.Order", b"\x08\x07\xa0\x06\x03"),
    content=(
      #|{"id":7,"[shop.priority]":3}
    ),
  )
}
