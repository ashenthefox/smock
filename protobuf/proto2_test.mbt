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

///|
test "proto2 fields print only when set, at their defaults too, and repeated fields and maps print [] and {}" {
  inspect(
    decoded(shipping_set, "shipping.Parcel", fixture(shipping_parcel)),
    content=(
      #|{"state":"SHIPPED","history":["NEW","DELIVERED"],"weights":[1,300],"sizes":[3,4],"order":{"id":7},"orders":[{"id":8,"note":""},{"id":-1}],"states":{"a":"NEW","b":"DELIVERED"},"label":"","tags":["x",""],"notes":{"k":"v"},"fragile":false,"count":0,"carrierName":"post","byId":{"2":{"id":2}}}
    ),
  )
  inspect(
    decoded(shipping_set, "shipping.Parcel", b""),
    content=(
      #|{"history":[],"weights":[],"sizes":[],"orders":[],"states":{},"tags":[],"notes":{},"byId":{}}
    ),
  )
}

///|
test "an unknown value of a closed enum is kept as an unknown field: the field keeps its value, a list drops it, a map drops its entry, and a oneof keeps its member" {
  // parcel-unknown.txtpb, then carrier-unknown.txtpb, which protobuf's
  // parsers read as one message: state 1 then 9, a packed history of 0,
  // 9, 2 and -1, entries a: 1, a: 9 and b: 9, carrier_name, then
  // carrier_state 7.
  inspect(
    decoded(
      shipping_set,
      "shipping.Parcel",
      fixture(shipping_unknown) + b"\x68\x07",
    ),
    content=(
      #|{"state":"SHIPPED","history":["NEW","DELIVERED"],"weights":[],"sizes":[],"orders":[],"states":{"a":"SHIPPED"},"tags":[],"notes":{},"carrierName":"post","byId":{}}
    ),
  )
  // An unpacked history, 9 then 1; a state that is unknown alone; an entry
  // of 9 alone; carrier_state 7 alone.
  inspect(
    decoded(
      shipping_set, "shipping.Parcel", b"\x10\x09\x10\x01\x08\x09\x3a\x05\x0a\x01c\x10\x09\x68\x07",
    ),
    content=(
      #|{"history":["SHIPPED"],"weights":[],"sizes":[],"orders":[],"states":{},"tags":[],"notes":{},"byId":{}}
    ),
  )
}
