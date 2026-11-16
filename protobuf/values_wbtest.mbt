// The count of the JSON values a message prints, which bounds what a
// message of a given size may print (`values_bound`): each path of the
// printer counts each value once. A whitebox test, since `decode_json`
// takes no bound on the values: it sets the bound from the size of its
// input. Each message is printed with no bound, and its values are counted
// in the text as `@json.parse` reads it; printed into an output that may
// hold as many, it must print the same text, and into one that may hold
// one fewer, it must be refused. The messages are written by hand; the
// sets are protoc's (scripts/gen-protobuf-fixtures.sh).

///|
/// The set the script wrote in `hex`.
fn values_set(hex : String) -> DescriptorSet {
  let octets = @hex.decode(hex.replace_all(old="\n", new="")) catch {
    _ => abort("not hex")
  }
  read_descriptor_set(octets) catch {
    err => abort("not a set: \{err}")
  }
}

///|
/// The JSON values of `json`: itself, and those of its members or of its
/// elements.
fn json_values(json : Json) -> Int32 {
  match json {
    Object(members) => {
      let mut count = 1
      for _, value in members {
        count += json_values(value)
      }
      count
    }
    Array(elements) => {
      let mut count = 1
      for element in elements {
        count += json_values(element)
      }
      count
    }
    _ => 1
  }
}

///|
/// What printing `input`, a message of the type `message` of `set`, gives
/// in an output that may hold at most `most_values` values: its text, or
/// the error that stops it.
fn printed_within(
  set : DescriptorSet,
  message : MessageDescriptor,
  input : Bytes,
  most_values : Int32,
) -> String {
  let out = Output::new(size_hint=0, limit=unbounded, most_values~)
  set.print_message(out, message, [input[:]], 0, canonical=false) catch {
    err => return "error: \{err}"
  }
  @utf8.decode(out.to_bytes()) catch {
    _ => abort("the text is not UTF-8")
  }
}

///|
/// The values of `input`, a message of the type `name` of the set in
/// `hex`, with its text: `<values> <text>`, when the printer counts as
/// many as the text holds. Then an output that may hold that many prints
/// the same text, and one that may hold one fewer refuses the message,
/// unless the message is one value, which any output may hold. Otherwise
/// what differs.
fn counted(hex : String, name : String, input : Bytes) -> String {
  let set = values_set(hex)
  guard set.find_message(name) is Some(message) else {
    abort("no message \{name}")
  }
  let text = printed_within(set, message, input, unbounded)
  let values = json_values(@json.parse(text)) catch {
    _ => return "not JSON: \{text}"
  }
  let within = printed_within(set, message, input, values)
  if within != text {
    return "\{values} \{text}, but in an output that may hold \{values}: \{within}"
  }
  let fewer = printed_within(set, message, input, values - 1)
  let refused = "error: the decoded message holds more than \{values - 1} values, the most for a message of its size"
  if values > 1 && fewer != refused {
    return "\{values} \{text}, but in an output that may hold \{values - 1}: \{fewer}"
  }
  "\{values} \{text}"
}

///|
/// A length-delimited record of field `field` that holds `value`.
fn record(field : Int32, value : Bytes) -> Bytes {
  let writer = Writer()
  writer.tag(field, Len)
  writer.length_delimited(value[:])
  writer.to_bytes()
}

///|
test "a message may print 32,768 values and 4 more for each of its octets, or any number once that passes the largest Int32" {
  inspect(
    [0, 1024, 19004, 65536, 1048576, 536862719, 536862720, 0x7FFF_FFFF]
    .map(octets => "\{octets}: \{values_bound(octets)}")
    .join("\n"),
    content=(
      #|0: 32768
      #|1024: 36864
      #|19004: 108784
      #|65536: 294912
      #|1048576: 4227072
      #|536862719: 2147483644
      #|536862720: 2147483647
      #|2147483647: 2147483647
    ),
  )
}

///|
test "each member and each element is one value: a message field, a member of a oneof, and lists of messages, of strings and of numbers, packed or not" {
  inspect(
    [
      // Three numbers packed and two not, two words, and two Items.
      counted(
        collections_set, "collections.Lists", b"\x0a\x03\x01\x02\x03\x08\x04\x08\x05\x42\x01x\x42\x00\x52\x00\x52\x03\x0a\x01a",
      ),
      // The member `word` of a oneof, and a message field, `box`.
      counted(collections_set, "collections.Choice", b"\x12\x01w\x2a\x00"),
    ].join("\n"),
    content=(
      #|26 {"numbers":[1,2,3,4,5],"offsets":[],"codes":[],"ratios":[],"weights":[],"flags":[],"kinds":[],"words":["x",""],"blobs":[],"items":[{"name":"","sizes":[],"stock":{}},{"name":"a","sizes":[],"stock":{}}]}
      #|7 {"label":"","word":"w","box":{"name":"","sizes":[],"stock":{}}}
    ),
  )
}

///|
test "each entry of a map is one value, and a key that is sent again is one entry" {
  inspect(
    // The keys 1, 2, then 1 again.
    counted(
      collections_set, "collections.Tagged", b"\x12\x04\x08\x01\x10\x01\x12\x04\x08\x02\x10\x02\x12\x04\x08\x01\x10\x03",
    ),
    content=(
      #|5 {"tags":[],"counts":{"1":3,"2":2}}
    ),
  )
}

///|
test "what a proto2 message prints is counted the same: a number that a closed enum does not define is no value, in a list, packed or not, and as a map's value; a group and an extension are one each" {
  inspect(
    [
      // A history of NEW, 9 and DELIVERED, unpacked, then of SHIPPED, 9 and
      // NEW, packed; and the states a, which is 9, and b, which is SHIPPED.
      counted(
        shipping_set, "shipping.Parcel", b"\x10\x00\x10\x09\x10\x02\x12\x03\x01\x09\x00\x3a\x05\x0a\x01a\x10\x09\x3a\x05\x0a\x01b\x10\x01",
      ),
      // Two groups, one with a city and one with nothing.
      counted(shipping_set, "shipping.Itinerary", b"\x0b\x12\x01a\x0c\x0b\x0c"),
      // A field and the extension shipping.stamp, field 100.
      counted(shipping_set, "shipping.Stamped", b"\x0a\x01b\xa2\x06\x01s"),
    ].join("\n"),
    content=(
      #|14 {"history":["NEW","DELIVERED","SHIPPED","NEW"],"weights":[],"sizes":[],"orders":[],"states":{"b":"SHIPPED"},"tags":[],"notes":{},"byId":{}}
      #|5 {"stop":[{"city":"a"},{}]}
      #|3 {"by":"b","[shipping.stamp]":"s"}
    ),
  )
}

///|
test "the well-known types are counted as the JSON they print: a Struct's members, a ListValue's elements, a Value as what it holds, an Any's `@type` and then its message's members or its `value`, and a Timestamp, a Duration, a FieldMask and a wrapper as one each" {
  // A Value of the string v, of an empty Struct, of the number 1.5, of
  // null and of true.
  let text = b"\x1a\x01v"
  let empty = b"\x2a\x00"
  let number = b"\x11\x00\x00\x00\x00\x00\x00\xf8\x3f"
  let null = b"\x08\x00"
  let yes = b"\x20\x01"
  let entry = (key : Bytes, value : Bytes) => {
    record(1, record(1, key) + record(2, value))
  }
  let any = (url : String, value : Bytes) => {
    record(1, @utf8.encode(url)) + record(2, value)
  }
  let document = record(1, entry(b"k", text) + entry(b"n", empty)) +
    record(2, record(6, record(1, number) + record(1, null))) +
    record(3, record(1, yes)) +
    record(
      7,
      any("type.googleapis.com/helloworld.HelloRequest", record(1, b"Tom")),
    ) +
    record(
      8,
      any(
        "type.googleapis.com/google.protobuf.Duration", b"\x08\x01\x10\x80\xca\xb5\xee\x01",
      ),
    )
  // A Timestamp, a Duration, a FieldMask of two paths and an Int64Value;
  // two Timestamps, a map of one Duration, and two Int64Values.
  let known = record(1, b"\x08\x01") +
    record(2, b"\x08\x02") +
    record(3, record(1, b"a") + record(1, b"b_c")) +
    record(6, b"\x08\x07") +
    record(14, b"") +
    record(14, b"\x08\x01") +
    record(15, record(1, b"r") + record(2, b"")) +
    record(16, b"") +
    record(16, b"\x08\x05")
  inspect(
    [
      counted(dynamic_set, "dynamic.Document", document),
      counted(wellknown_set, "wellknown.Known", known),
      // A message that is one value, whatever it holds: an output that may
      // hold one value prints it.
      counted(wellknown_set, "google.protobuf.Timestamp", b"\x08\x01"),
      counted(dynamic_set, "google.protobuf.Any", b""),
    ].join("\n"),
    content=(
      #|20 {"labels":{"k":"v","n":{}},"value":[1.5,null],"list":[true],"nothing":null,"values":[],"byName":{},"attachment":{"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Tom"},"attachments":[{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1.500s"}],"nothings":[]}
      #|13 {"at":"1970-01-01T00:00:01Z","ttl":"2s","mask":"a,bC","anInt64":7,"history":["1970-01-01T00:00:00Z","1970-01-01T00:00:01Z"],"limits":{"r":"0s"},"ids":[0,5]}
      #|1 "1970-01-01T00:00:01Z"
      #|1 {}
    ),
  )
}
