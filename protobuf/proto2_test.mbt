// proto2 types through the public interface: presence, required fields,
// closed enums, packing and strings that are not UTF-8, decoded and
// encoded. The set is fixtures/protobuf/shipping/shipping.proto, and the
// messages are what protoc encodes from the .txtpb files beside it
// (scripts/gen-protobuf-fixtures.sh), so the codec is never checked
// against itself.

///|
test "the ticket's example: an Order with the id 7 and no note decodes as {\"id\":7}" {
  // id 7, as protoc encodes order.txtpb.
  inspect(
    decoded(shipping_set, "shipping.Order", b"\x08\x07"),
    content=(
      #|{"id":7}
    ),
  )
}
