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

///|
test "a message without a required field does not parse, nested ones and a map's values included, as protobuf's parsers refuse it" {
  // An Order without its id, as protoc encodes draft.txtpb.
  inspect(
    decoded(shipping_set, "shipping.Order", b"\x12\x05no id"),
    content="error: octet 0: the message shipping.Order lacks its required field id",
  )
  // A Parcel whose order lacks its id, as protoc encodes
  // parcel-without-ids.txtpb: the error is at the nested message.
  inspect(
    decoded(shipping_set, "shipping.Parcel", b"\x2a\x08\x12\x06nested"),
    content="error: octet 2: the message shipping.Order lacks its required field id",
  )
  // The same in an element of orders, and in a value of by_id.
  inspect(
    decoded(shipping_set, "shipping.Parcel", b"\x32\x02\x08\x01\x32\x00"),
    content="error: octet 6: the message shipping.Order lacks its required field id",
  )
  inspect(
    decoded(shipping_set, "shipping.Parcel", b"\x7a\x04\x08\x01\x12\x00"),
    content="error: octet 6: the message shipping.Order lacks its required field id",
  )
  // An entry of by_id without a value holds an Order without an id too.
  inspect(
    decoded(shipping_set, "shipping.Parcel", b"\x7a\x02\x08\x01"),
    content="error: octet 2: the message shipping.Order lacks its required field id",
  )
  // Each one with its id parses.
  inspect(
    decoded(
      shipping_set, "shipping.Parcel", b"\x2a\x02\x08\x01\x32\x02\x08\x02\x7a\x06\x08\x01\x12\x02\x08\x03",
    ),
    content=(
      #|{"history":[],"weights":[],"sizes":[],"order":{"id":1},"orders":[{"id":2}],"states":{},"tags":[],"notes":{},"byId":{"1":{"id":3}}}
    ),
  )
}
