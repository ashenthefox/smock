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

///|
test "extensions print in field-number order among the fields, once set: a repeated one, a group and one declared in a message under its full name" {
  // order-full.txtpb: id 8, note, shop.priority -2, shop.codes a and "",
  // the group shop.label, shop.Gift.gift, then urgent, field 200.
  inspect(
    decoded(extensions_set, "shop.Order", fixture(order_full)),
    content=(
      #|{"id":8,"note":"gift","[shop.priority]":-2,"[shop.codes]":["a",""],"[shop.label]":{"text":"fragile"},"[shop.Gift.gift]":{"wrap":"red"},"urgent":true}
    ),
  )
  // An Order that holds none prints none, a repeated one included.
  inspect(
    decoded(extensions_set, "shop.Order", b""),
    content=(
      #|{}
    ),
  )
  // Field 150, a number in the extensions' range that no extension of the
  // set has, is an unknown field, skipped, as is shop.codes sent as a
  // varint; the records of one extension are merged as a field's are, the
  // last value winning and a message's values merged.
  inspect(
    decoded(
      extensions_set, "shop.Order", b"\xb0\x09\x01\xa8\x06\x01\xa0\x06\x05\xf2\x06\x02\x0a\x00\xa0\x06\x06\xf2\x06\x05\x0a\x03red",
    ),
    content=(
      #|{"[shop.priority]":6,"[shop.Gift.gift]":{"wrap":"red"}}
    ),
  )
}

///|
test "groups decode as messages, repeated and nested in one another" {
  // itinerary.txtpb: two Stops, the first with a Window, then a Note.
  inspect(
    decoded(extensions_set, "shop.Itinerary", fixture(itinerary)),
    content=(
      #|{"name":"tour","stop":[{"city":"Paris","window":{"opens":9,"closes":17}},{"city":"Lyon"}],"note":{"text":"by train"}}
    ),
  )
  // Two Notes are merged, as two values of a message field are.
  inspect(
    decoded(
      extensions_set, "shop.Itinerary", b"\x3b\x42\x01a\x3c\x0a\x01x\x3b\x3c\x3b\x42\x01b\x3c",
    ),
    content=(
      #|{"name":"x","stop":[],"note":{"text":"b"}}
    ),
  )
  // A Stop sent as a length-delimited message is not a group: it is
  // skipped, as a field sent with another wire type is.
  inspect(
    decoded(extensions_set, "shop.Itinerary", b"\x12\x02\x1a\x00"),
    content=(
      #|{"stop":[]}
    ),
  )
}

///|
test "a group whose end does not match, or that the message ends inside, does not parse" {
  // itinerary.txtpb with the end of the first Window, 0x24, made the end
  // of field 5, 0x2c.
  let input = fixture(itinerary)
  let broken = Bytes::makei(input.length(), i => {
    if input[i] == b'\x24' {
      b'\x2c'
    } else {
      input[i]
    }
  })
  inspect(
    decoded(extensions_set, "shop.Itinerary", broken),
    content="error: octet 19: the group of field 4 ends with the tag of field 5",
  )
  // A Note whose end tag is missing.
  inspect(
    decoded(extensions_set, "shop.Itinerary", b"\x3b\x42\x01a"),
    content="error: octet 0: the input ends inside the group of field 7",
  )
  // The end of a group that never started.
  inspect(
    decoded(extensions_set, "shop.Itinerary", b"\x0a\x01x\x3c"),
    content="error: octet 3: the group of field 7 ends where none started",
  )
}

///|
/// `text`, JSON text, encoded as a message of `name`, a type of
/// fixtures/protobuf/extensions/shop.proto, in hex, or the error that stops
/// it.
fn shop_encoded(name : String, text : String) -> String {
  let set = hex_set(extensions_set)
  guard set.find_message(name) is Some(message) else {
    abort("no message \{name}")
  }
  let json = @json.parse(text) catch { err => abort("not JSON: \{err}") }
  @hex.encode(set.encode_json(message, json)) catch {
    err => "error: \{err}"
  }
}

///|
test "a reply that sets extensions under their [full.name] keys has protoc's bytes, extensions in field-number order among the fields" {
  // The ticket's example, as protoc encodes order.txtpb.
  inspect(
    shop_encoded("shop.Order", "{\"id\": 7, \"[shop.priority]\": 3}"),
    content="0807a00603",
  )
  // order-full.txtpb, its keys in another order.
  assert_eq(
    shop_encoded(
      "shop.Order",
      (
        #|{"urgent": true, "[shop.Gift.gift]": {"wrap": "red"},
        #| "[shop.label]": {"text": "fragile"}, "[shop.codes]": ["a", ""],
        #| "[shop.priority]": "-2", "note": "gift", "id": 8}
      ),
    ),
    @hex.encode(fixture(order_full)),
  )
  // null leaves an extension unset; an empty list writes nothing.
  inspect(
    shop_encoded(
      "shop.Order", "{\"[shop.priority]\": null, \"[shop.codes]\": [], \"[shop.label]\": {}}",
    ),
    content="b306b406",
  )
}

///|
test "a reply with groups, repeated and nested, has protoc's bytes" {
  assert_eq(
    shop_encoded(
      "shop.Itinerary",
      (
        #|{"name": "tour", "stop": [{"city": "Paris", "window": {"opens": 9, "closes": 17}},
        #| {"city": "Lyon"}], "note": {"text": "by train"}}
      ),
    ),
    @hex.encode(fixture(itinerary)),
  )
  // A group is a message: its value must be an object.
  inspect(
    shop_encoded("shop.Itinerary", "{\"stop\": [{\"window\": 9}]}"),
    content="error: /stop/0/window: must be an object: the field window of shop.Itinerary.Stop has the type shop.Itinerary.Stop.Window",
  )
}

///|
test "a [full.name] key that names no extension of the set, or one that extends another type, is not an extension of the message" {
  inspect(
    shop_encoded("shop.Order", "{\"[shop.urgency]\": 1}"),
    content="error: /[shop.urgency]: is not an extension of shop.Order: the Descriptor set has no extension shop.urgency",
  )
  inspect(
    shop_encoded("shop.Itinerary", "{\"[shop.priority]\": 1}"),
    content="error: /[shop.priority]: is not an extension of shop.Itinerary: shop.priority extends shop.Order",
  )
  // An extension's value is checked against its type, at its key.
  inspect(
    shop_encoded("shop.Order", "{\"[shop.Gift.gift]\": {\"wrap\": 1}}"),
    content="error: /[shop.Gift.gift]/wrap: must be a string of Unicode text: the field wrap of shop.Gift has the type string",
  )
  inspect(
    shop_encoded("shop.Order", "{\"[shop.priority]\": \"high\"}"),
    content="error: /[shop.priority]: must be an integer from -2147483648 to 2147483647: the extension shop.priority of shop.Order has the type int32",
  )
  inspect(
    shop_encoded("shop.Order", "{\"[shop.codes]\": \"a\"}"),
    content="error: /[shop.codes]: must be an array: the extension shop.codes of shop.Order is repeated",
  )
  inspect(
    shop_encoded("shop.Order", "{\"[shop.codes]\": [\"a\", 1]}"),
    content="error: /[shop.codes]/1: must be a string of Unicode text: the elements of the extension shop.codes of shop.Order have the type string",
  )
  inspect(
    shop_encoded("shop.Order", "{\"[shop.codes]\": [null]}"),
    content="error: /[shop.codes]/0: cannot be null: it is an element of the repeated extension shop.codes of shop.Order",
  )
  // An extension is found by its full name only.
  inspect(
    shop_encoded("shop.Order", "{\"priority\": 1}"),
    content="error: /priority: is not a field of shop.Order",
  )
}
