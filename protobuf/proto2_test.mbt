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

///|
test "a proto2 string that is not UTF-8 is valid protobuf, and prints with U+FFFD for each bad sequence, as smock reads header values" {
  // parcel-not-utf8.txtpb: label a, C3 28, b; tags FF FE and ok; notes
  // FF: F0 9F 98, the first three octets of a four-octet sequence.
  inspect(
    decoded(shipping_set, "shipping.Parcel", fixture(shipping_not_utf8)),
    content=(
      #|{"history":[],"weights":[],"sizes":[],"orders":[],"states":{},"label":"a�(b","tags":["��","ok"],"notes":{"�":"�"},"byId":{}}
    ),
  )
  // Two keys that print alike are one key, and the last entry wins.
  inspect(
    decoded(
      shipping_set, "shipping.Parcel", b"\x52\x06\x0a\x01\xff\x12\x011\x52\x06\x0a\x01\xfe\x12\x012\x52\x05\x0a\x01a\x12\x00",
    ),
    content=(
      #|{"history":[],"weights":[],"sizes":[],"orders":[],"states":{},"tags":[],"notes":{"a":"","�":"2"},"byId":{}}
    ),
  )
}

///|
test "a message of an editions file, and a MessageSet, are not decoded" {
  inspect(
    decoded(shipping_set, "labels.Label", b"\x0a\x01a"),
    content="error: octet 0: the message labels.Label is a type of an editions file, which smock does not decode",
  )
  // A Crate whose bag, a MessageSet, is set; and one without it.
  inspect(
    decoded(shipping_set, "shipping.Crate", b"\x0a\x00"),
    content="error: octet 2: the message shipping.Bag is a MessageSet, which smock does not decode",
  )
  inspect(
    decoded(shipping_set, "shipping.Crate", b""),
    content=(
      #|{}
    ),
  )
}

///|
/// `text`, JSON text, encoded as a message of `name`, a type of
/// fixtures/protobuf/shipping/shipping.proto, in hex, or the error that
/// stops it.
fn shipped(name : String, text : String) -> String {
  let set = hex_set(shipping_set)
  guard set.find_message(name) is Some(message) else {
    abort("no message \{name}")
  }
  let json = @json.parse(text) catch { err => abort("not JSON: \{err}") }
  @hex.encode(set.encode_json(message, json)) catch {
    err => "error: \{err}"
  }
}

///|
test "a Parcel has protoc's bytes: proto2 fields written whenever set, at their defaults too, and repeated scalars packed only with packed = true" {
  assert_eq(
    shipped(
      "shipping.Parcel",
      (
        #|{"state": "SHIPPED", "history": ["NEW", 2], "weights": [1, 300],
        #| "sizes": [3, 4], "order": {"id": 7}, "orders": [{"id": "8", "note": ""}, {"id": -1}],
        #| "states": {"b": "DELIVERED", "a": "NEW"}, "label": "", "tags": ["x", ""],
        #| "notes": {"k": "v"}, "fragile": false, "count": 0, "carrier_name": "post",
        #| "byId": {"2": {"id": 2}}}
      ),
    ),
    @hex.encode(fixture(shipping_parcel)),
  )
  // null leaves a field unset.
  inspect(
    shipped("shipping.Order", "{\"id\": 7, \"note\": null}"),
    content="0807",
  )
}

///|
test "a type of an editions file, and a MessageSet, are not encoded" {
  inspect(
    shipped("labels.Label", "{\"text\": \"a\"}"),
    content="error: smock does not encode labels.Label yet: it is a type of an editions file",
  )
  inspect(
    shipped("shipping.Crate", "{\"bag\": {}}"),
    content="error: /bag: smock does not encode shipping.Bag: it is a MessageSet, whose extensions use another wire form",
  )
}

///|
test "a reply without a required field is not a message of its type, nested ones, list elements and map values included" {
  inspect(
    shipped("shipping.Order", "{\"note\": \"x\"}"),
    content="error: lacks the required field id of shipping.Order",
  )
  inspect(
    shipped("shipping.Order", "{\"id\": null}"),
    content="error: lacks the required field id of shipping.Order",
  )
  inspect(
    shipped("shipping.Parcel", "{\"order\": {}}"),
    content="error: /order: lacks the required field id of shipping.Order",
  )
  inspect(
    shipped("shipping.Parcel", "{\"orders\": [{\"id\": 1}, {}]}"),
    content="error: /orders/1: lacks the required field id of shipping.Order",
  )
  inspect(
    shipped("shipping.Parcel", "{\"by_id\": {\"2\": {\"note\": \"\"}}}"),
    content="error: /by_id/2: lacks the required field id of shipping.Order",
  )
}

///|
test "a number that a closed enum does not define is not a value of it, singular, in a list, as a map's value or in a oneof" {
  inspect(shipped("shipping.Parcel", "{\"state\": 1}"), content="0801")
  inspect(
    shipped("shipping.Parcel", "{\"state\": 9}"),
    content="error: /state: must be the name or the number of a value of shipping.State: the field state of shipping.Parcel has the type shipping.State",
  )
  inspect(
    shipped("shipping.Parcel", "{\"history\": [0, -1]}"),
    content="error: /history/1: must be the name or the number of a value of shipping.State: the elements of the field history of shipping.Parcel have the type shipping.State",
  )
  inspect(
    shipped("shipping.Parcel", "{\"states\": {\"a\": 3}}"),
    content="error: /states/a: must be the name or the number of a value of shipping.State: the values of the map field states of shipping.Parcel have the type shipping.State",
  )
  inspect(
    shipped("shipping.Parcel", "{\"carrierState\": 7}"),
    content="error: /carrierState: must be the name or the number of a value of shipping.State: the field carrier_state of shipping.Parcel has the type shipping.State",
  )
}

///|
test "a condition on a closed enum takes the names and numbers it defines, as smock prints them, and no other number, which a call's message never shows" {
  let texts = ["\"SHIPPED\"", "1", "0", "9", "-1", "\"9\""]
  inspect(
    texts
    .map(text => {
      "\{text} -> \{printed_form(shipping_set, "shipping.Parcel", "state", text)}"
    })
    .join("\n"),
    content=(
      #|"SHIPPED" -> "SHIPPED"
      #|1 -> "SHIPPED"
      #|0 -> "NEW"
      #|9 -> must be the name or the number of a value of shipping.State
      #|-1 -> must be the name or the number of a value of shipping.State
      #|"9" -> must be the name or the number of a value of shipping.State
    ),
  )
}
