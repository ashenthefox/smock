// The decoder's bounds, through the public interface: what `decode_json`
// prints is counted as it is printed, and a message whose JSON passes the
// limit it is given is refused as soon as it does, however small the
// message. The messages are written by hand, as hostile clients write
// them; the sets are protoc's (scripts/gen-protobuf-fixtures.sh).

///|
/// `input` decoded as a message of the type whose full name is `name` in
/// the set the script wrote in `hex`, with its JSON bounded by `limit`, as
/// text, or the error that stops it.
fn bounded(
  hex : String,
  name : String,
  input : Bytes,
  limit~ : Int32,
) -> String {
  let set = hex_set(hex)
  guard set.find_message(name) is Some(message) else {
    abort("no message \{name}")
  }
  @utf8.decode(@protobuf.decode_json(set, message, input[:], limit~)) catch {
    err => "error: \{err}"
  }
}

///|
/// `count` copies of `record`, joined.
fn repeated(record : Bytes, count : Int32) -> Bytes {
  let out = @buffer.Buffer(size_hint=record.length() * count)
  for _ in 0..<count {
    out.write_bytes(record)
  }
  out.to_bytes()
}

///|
test "the JSON is counted as it is printed: a message whose JSON passes the limit is refused, and one whose JSON is at the limit is printed" {
  // Three empty Items, each printed with every field at its default.
  let items = repeated(b"\x52\x00", 3)
  let text = bounded(collections_set, "collections.Lists", items, limit=1000)
  inspect(
    "\{text.length()} \{text}",
    content=(
      #|219 {"numbers":[],"offsets":[],"codes":[],"ratios":[],"weights":[],"flags":[],"kinds":[],"words":[],"blobs":[],"items":[{"name":"","sizes":[],"stock":{}},{"name":"","sizes":[],"stock":{}},{"name":"","sizes":[],"stock":{}}]}
    ),
  )
  inspect(
    [
      bounded(collections_set, "collections.Lists", items, limit=219),
      bounded(collections_set, "collections.Lists", items, limit=218),
    ].join("\n"),
    content=(
      #|{"numbers":[],"offsets":[],"codes":[],"ratios":[],"weights":[],"flags":[],"kinds":[],"words":[],"blobs":[],"items":[{"name":"","sizes":[],"stock":{}},{"name":"","sizes":[],"stock":{}},{"name":"","sizes":[],"stock":{}}]}
      #|error: the decoded message passes the limit of 218 octets
    ),
  )
}

///|
test "what the decoder holds to print a message is bounded by the limit too: the records of a field that do not come together, a message field sent again, and each entry of a map" {
  // 200 numbers and 200 flags, each an unpacked record of 0: together,
  // as two runs of records, or one after the other, as 400 runs.
  let together = repeated(b"\x08\x00", 200) + repeated(b"\x30\x00", 200)
  let apart = repeated(b"\x08\x00\x30\x00", 200)
  let filled = (input : Bytes, limit : Int32) => {
    let text = bounded(collections_set, "collections.Lists", input, limit~)
    if text.has_prefix("error: ") {
      text
    } else {
      "\{text.length()} octets"
    }
  }
  // A Node's child sent 100 times, merged into one.
  let children = (count : Int32, limit : Int32) => {
    bounded(scalars_set, "scalars.Node", repeated(b"\x12\x00", count), limit~)
  }
  // A map of 100 entries, from 0 to 99, each with the value 1.
  let entries = @buffer.Buffer()
  for key in 0..<100 {
    entries.write_bytes(b"\x12\x04\x08")
    entries.write_byte(key.to_byte())
    entries.write_bytes(b"\x10\x01")
  }
  let counts = (limit : Int32) => {
    let text = bounded(
      collections_set,
      "collections.Tagged",
      entries.to_bytes(),
      limit~,
    )
    if text.has_prefix("error: ") {
      text
    } else {
      "\{text.length()} octets"
    }
  }
  inspect(
    [
      filled(together, 2000),
      filled(apart, 2000),
      filled(apart, 100000),
      children(1, 1000),
      children(100, 1000),
      counts(2000),
      counts(100000),
    ].join("\n"),
    content=(
      #|1716 octets
      #|error: the decoded message passes the limit of 2000 octets
      #|1716 octets
      #|{"name":"","child":{"name":""}}
      #|error: the decoded message passes the limit of 1000 octets
      #|error: the decoded message passes the limit of 2000 octets
      #|712 octets
    ),
  )
}

///|
/// What decoding `input` as the type `name` of the set in `hex` gives:
/// `decoded`, or the error's message, without its position.
fn depth_outcome(hex : String, name : String, input : Bytes) -> String {
  let set = hex_set(hex)
  guard set.find_message(name) is Some(message) else {
    abort("no message \{name}")
  }
  let _ = @protobuf.decode_json(set, message, input[:], limit=no_limit) catch {
    DecodeError(message~, ..) => return message
    error => return error.to_string()
  }
  "decoded"
}

///|
/// A Burrow that holds `levels` more, each in the one before, through
/// `field`: 2, a message field, 3, a group, whose field 1 holds the next,
/// or 4, a map's values. The last holds `last`.
fn burrows(levels : Int32, field : Int32, last : Bytes) -> Bytes {
  let mut message = last
  for _ in 0..<levels {
    let inner = message
    message = nested(w => {
      match field {
        3 => {
          w.tag(3, StartGroup)
          message_field(w, 1, inner)
          w.tag(3, EndGroup)
        }
        4 => message_field(w, 4, nested(e => message_field(e, 2, inner)))
        _ => message_field(w, field, inner)
      }
    })
  }
  message
}

///|
test "messages nest 100 deep and no deeper through each path: a message field, a group and a map's values, each group and map entry counting as a message" {
  let dig = (levels : Int32, field : Int32, last : Bytes) => {
    depth_outcome(limits_set, "limits.Burrow", burrows(levels, field, last))
  }
  // A group with nothing in it, and a map entry with nothing in it, at the
  // depth after the last Burrow.
  let empty_group = b"\x1b\x1c"
  let empty_entry = b"\x22\x00"
  inspect(
    [
      // The last Burrow at depth 100, then one deeper.
      dig(100, 2, b""),
      dig(101, 2, b""),
      // A group and its Burrow are two levels: the last Burrow at depth
      // 100, then its empty group at 101.
      dig(50, 3, b""),
      dig(50, 3, empty_group),
      // A map entry and its Burrow are two levels, too.
      dig(50, 4, b""),
      dig(50, 4, empty_entry),
      // protoc's Burrow, with each path, nested in each path.
      dig(1, 3, fixture(burrow)),
    ].join("\n"),
    content=(
      #|decoded
      #|messages nest deeper than 100
      #|decoded
      #|messages nest deeper than 100
      #|decoded
      #|messages nest deeper than 100
      #|decoded
    ),
  )
  inspect(
    bounded(limits_set, "limits.Burrow", fixture(burrow), limit=no_limit),
    content=(
      #|{"name":"top","inner":{"name":"inner","rooms":{}},"layer":{"inner":{"name":"layer","rooms":{}}},"rooms":{"room":{"name":"room","rooms":{}}}}
    ),
  )
}

///|
/// An Any of the Any `inner`, `levels` times.
fn anys(levels : Int32, inner : Bytes) -> Bytes {
  let mut message = inner
  for _ in 0..<levels {
    message = any_of("type.googleapis.com/google.protobuf.Any", message)
  }
  message
}

///|
/// A Struct of one member, `x`, whose Value holds a Struct of the same,
/// `levels` times, the last holding the Value `last`.
fn structs(levels : Int32, last : Bytes) -> Bytes {
  let mut message = struct_of([("x", last)])
  for _ in 1..<levels {
    let inner = message
    message = struct_of([("x", nested(w => message_field(w, 5, inner)))])
  }
  message
}

///|
/// A Value that holds a ListValue of one Value, `levels` times, the last
/// being `last`.
fn listed_values(levels : Int32, last : Bytes) -> Bytes {
  let mut message = last
  for _ in 0..<levels {
    let inner = message
    message = nested(w => message_field(w, 6, list_of([inner])))
  }
  message
}

///|
test "messages nest 100 deep and no deeper through an Any, a Struct and its Values, and a ListValue, as protobuf's parsers count their messages" {
  let hello = any_of(
    "type.googleapis.com/helloworld.HelloRequest",
    nested(w => string_field(w, 1, "Tom")),
  )
  let empty_list = nested(w => message_field(w, 6, b""))
  inspect(
    [
      // An Any is one level: the HelloRequest at depth 100, then 101.
      dynamic_depth("google.protobuf.Any", anys(99, hello)),
      dynamic_depth("google.protobuf.Any", anys(100, hello)),
      // A Struct, its entry and its Value are three levels: the last
      // Struct at depth 96 and its Value at 98, then the Struct at 99 and
      // its Value at 101.
      dynamic_depth("google.protobuf.Struct", structs(33, number_value(1.0))),
      dynamic_depth("google.protobuf.Struct", structs(34, number_value(1.0))),
      // A Value and its ListValue are two levels: the last Value at depth
      // 100, then its ListValue at 101.
      dynamic_depth(
        "google.protobuf.Value",
        listed_values(50, number_value(1.0)),
      ),
      dynamic_depth("google.protobuf.Value", listed_values(50, empty_list)),
    ].join("\n"),
    content=(
      #|decoded
      #|messages nest deeper than 100
      #|decoded
      #|messages nest deeper than 100
      #|decoded
      #|messages nest deeper than 100
    ),
  )
}

///|
/// What decoding `input` as the type `name` of dynamic.proto's set gives,
/// as `depth_outcome` says.
fn dynamic_depth(name : String, input : Bytes) -> String {
  depth_outcome(dynamic_set, name, input)
}

///|
/// Octets that are UTF-8 or not, at the start, the middle and the end of a
/// string: each kind of bad sequence, a sequence cut short, and good ones
/// of every length, a byte order mark included.
let utf8_cases : Array[Bytes] = [
  b"plain", b"\xef\xbb\xbfbom", b"\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x88", b"\x80",
  b"a\xbfb", b"\xc0\x80", b"\xc1\xbf", b"\xe0\x80\x80", b"\xe0\x9f\xbf", b"\xed\xa0\x80",
  b"\xed\xbf\xbf", b"\xf0\x80\x80\x80", b"\xf0\x8f\xbf\xbf", b"\xf4\x90\x80\x80",
  b"\xf5\x80\x80\x80", b"\xff", b"\xfe\xfe", b"\xc3", b"\xe2\x82", b"\xf0\x9f\x98",
  b"x\xe2\x82", b"\xe2\x82x", b"\xf0\x9f\x98x", b"\xc3\xc3\xa9", b"\xe2\x28\xa1",
]

///|
test "a proto2 string that is not UTF-8 prints as UTF-8 decoders repair it, U+FFFD for each maximal subpart, and a proto3 one is refused, whatever its bad sequence" {
  for octets in utf8_cases {
    // A proto2 Burrow's name, printed with no copy of the repaired text.
    let printed = bounded(
      limits_set,
      "limits.Burrow",
      nested(w => {
        w.tag(1, Len)
        w.length_delimited(octets)
      }),
      limit=no_limit,
    )
    let lossy = @utf8.decode_lossy(octets)
    assert_eq(printed, "{\"name\":\"\{lossy}\",\"rooms\":{}}")
    // A proto3 Every's string.
    let strict = bounded(
      scalars_set,
      "scalars.Every",
      nested(w => {
        w.tag(9, Len)
        w.length_delimited(octets)
      }),
      limit=no_limit,
    )
    let good = try @utf8.decode(octets, ignore_bom=false) catch {
      _ => false
    } noraise {
      _ => true
    }
    assert_eq(
      strict.has_prefix("error: ") && strict.contains("not UTF-8"),
      !good,
    )
  }
}

///|
test "the JSON counts wherever it is printed: through a message field, a list, a map, a group, an Any's message, a Struct and a ListValue, a message is printed at its JSON's length and refused one octet short" {
  let hello = any_of(
    "type.googleapis.com/helloworld.HelloRequest",
    nested(w => string_field(w, 1, "Tom")),
  )
  let cases : Array[(String, String, Bytes)] = [
    (limits_set, "limits.Burrow", fixture(burrow)),
    (collections_set, "collections.Lists", repeated(b"\x52\x00", 2)),
    // Maps whose JSON is longer than what is held to print them.
    (
      collections_set,
      "collections.Tagged",
      fixture(tagged) + nested(w => string_field(w, 1, "x".repeat(400))),
    ),
    (dynamic_set, "google.protobuf.Any", anys(2, hello)),
    (
      dynamic_set,
      "google.protobuf.Struct",
      structs(3, nested(w => string_field(w, 3, "x".repeat(400)))),
    ),
    (dynamic_set, "google.protobuf.Value", listed_values(3, number_value(1.5))),
  ]
  let out = []
  for case in cases {
    let (hex, name, input) = case
    let text = bounded(hex, name, input, limit=no_limit)
    let at = bounded(hex, name, input, limit=text.length())
    let short = bounded(hex, name, input, limit=text.length() - 1)
    out.push(
      "\{name}: \{at == text}, \{short.has_prefix("error: the decoded message passes")}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|limits.Burrow: true, true
      #|collections.Lists: true, true
      #|collections.Tagged: true, true
      #|google.protobuf.Any: true, true
      #|google.protobuf.Struct: true, true
      #|google.protobuf.Value: true, true
    ),
  )
}

///|
test "an Any's message is printed in place, after its @type: one with no field to print leaves @type alone" {
  // google.protobuf.Any, and e.E, a message with no fields.
  let any = file_proto(
    "google/protobuf/any.proto",
    package_name="google.protobuf",
    body=w => {
      message_field(
        w,
        4,
        message_proto("Any", body=w => {
          message_field(w, 2, field_proto("type_url", 1, 9))
          message_field(w, 2, field_proto("value", 2, 12))
        }),
      )
    },
  )
  let e = file_proto("e.proto", package_name="e", body=w => {
    message_field(w, 4, message_proto("E"))
  })
  let set = @protobuf.read_descriptor_set(set_of([any, e])) catch {
    err => abort("not a set: \{err}")
  }
  guard set.find_message("google.protobuf.Any") is Some(message) else {
    abort("no Any")
  }
  let printed = (input : Bytes, limit : Int32) => {
    @utf8.decode(@protobuf.decode_json(set, message, input[:], limit~)) catch {
      err => "error: \{err}"
    }
  }
  let empty = any_of("type.googleapis.com/e.E", b"")
  inspect(
    [printed(empty, 100), printed(empty, 35), printed(empty, 34)].join("\n"),
    content=(
      #|{"@type":"type.googleapis.com/e.E"}
      #|{"@type":"type.googleapis.com/e.E"}
      #|error: the decoded message passes the limit of 34 octets
    ),
  )
}
