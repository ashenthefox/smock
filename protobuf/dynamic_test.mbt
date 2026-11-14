// The well-known types whose JSON forms hold any JSON value or a message of
// another type, Struct, Value, ListValue, NullValue and Any, decoded into
// smock's decoded form and encoded from ProtoJSON through the public
// interface. The set and the messages are protoc's, built from
// fixtures/protobuf/wellknown/dynamic.proto and the files beside it
// (scripts/gen-protobuf-fixtures.sh), so the codec is never checked against
// itself; messages that protoc never writes are written by hand.

///|
/// `input` decoded as a message of the type whose full name is `name` in
/// dynamic.proto's set, as text, or the error that stops it.
fn dynamic(name : String, input : Bytes) -> String {
  decoded(dynamic_set, name, input)
}

///|
/// A Value that holds the double `number`, written by hand.
fn number_value(number : Double) -> Bytes {
  nested(w => {
    w.tag(2, I64)
    w.fixed64(number.reinterpret_as_uint64())
  })
}

///|
/// A Struct of `entries`, keys and the octets of their Values, in the
/// order given, written by hand.
fn struct_of(entries : Array[(String, Bytes)]) -> Bytes {
  nested(w => {
    for entry in entries {
      message_field(
        w,
        1,
        nested(e => {
          string_field(e, 1, entry.0)
          message_field(e, 2, entry.1)
        }),
      )
    }
  })
}

///|
/// A ListValue of the octets of `values`, written by hand.
fn list_of(values : Array[Bytes]) -> Bytes {
  nested(w => for value in values { message_field(w, 1, value) })
}

///|
test "a Value prints as the JSON value it holds, a Struct as an object in key order, the last entry of a key winning, and a ListValue as an array" {
  let null_value = nested(w => varint_field(w, 1, 0))
  let text = nested(w => string_field(w, 3, "a\"b"))
  let yes = nested(w => varint_field(w, 4, 1))
  let lines = [
    dynamic("google.protobuf.Value", null_value),
    dynamic("google.protobuf.Value", number_value(1.5)),
    dynamic("google.protobuf.Value", number_value(1.0e21)),
    dynamic("google.protobuf.Value", text),
    dynamic("google.protobuf.Value", yes),
    dynamic(
      "google.protobuf.Value",
      nested(w => message_field(w, 5, struct_of([]))),
    ),
    dynamic(
      "google.protobuf.Value",
      nested(w => message_field(w, 6, list_of([]))),
    ),
    dynamic(
      "google.protobuf.Struct",
      struct_of([
        ("b", number_value(1)),
        ("a", null_value),
        ("é", yes),
        ("b", text),
      ]),
    ),
    dynamic(
      "google.protobuf.ListValue",
      list_of([
        number_value(-0.25),
        text,
        null_value,
        nested(w => message_field(w, 6, list_of([yes]))),
        nested(w => message_field(w, 5, struct_of([("k", null_value)]))),
      ]),
    ),
    dynamic("google.protobuf.Struct", b""),
    dynamic("google.protobuf.ListValue", b""),
    // A later member of the oneof kind replaces the one before it.
    dynamic("google.protobuf.Value", text + yes),
  ]
  inspect(
    lines.join("\n"),
    content=(
      #|null
      #|1.5
      #|1e+21
      #|"a\"b"
      #|true
      #|{}
      #|[]
      #|{"a":null,"b":"a\"b","é":true}
      #|[-0.25,"a\"b",null,[true],{"k":null}]
      #|{}
      #|[]
      #|true
    ),
  )
}
