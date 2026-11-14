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

///|
test "a Value that holds nothing, NaN or an infinity cannot be printed" {
  let lines = [
    dynamic("google.protobuf.Value", b""),
    dynamic("google.protobuf.Value", number_value(@double.not_a_number)),
    dynamic(
      "google.protobuf.Struct",
      struct_of([("k", number_value(@double.neg_infinity))]),
    ),
  ]
  inspect(
    lines.join("\n"),
    content=(
      #|error: octet 0: the Value holds no value, which ProtoJSON cannot print: it must hold null, a number, a string, a bool, a Struct or a ListValue
      #|error: octet 0: the Value holds the number NaN, which a JSON number cannot be, and ProtoJSON does not print it as a string
      #|error: octet 7: the Value holds the number -Infinity, which a JSON number cannot be, and ProtoJSON does not print it as a string
    ),
  )
}

///|
test "the ticket's example: an Any prints its type URL as @type, then the fields of a message it holds, or its printed form as value; one that holds an Empty prints @type alone" {
  let lines = [
    dynamic("google.protobuf.Any", fixture(any_hello)),
    dynamic("google.protobuf.Any", fixture(any_duration)),
    dynamic("google.protobuf.Any", fixture(any_empty)),
  ]
  inspect(
    lines.join("\n"),
    content=(
      #|{"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Tom"}
      #|{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1.500s"}
      #|{"@type":"type.googleapis.com/google.protobuf.Empty"}
    ),
  )
}

///|
/// An Any of `type_url` and `value`, each written when it is not empty, by
/// hand.
fn any_of(type_url : String, value : Bytes) -> Bytes {
  nested(w => {
    if type_url != "" {
      string_field(w, 1, type_url)
    }
    if value.length() > 0 {
      message_field(w, 2, value)
    }
  })
}

///|
test "an Any that holds a type the set lacks, or whose type URL names no type, cannot be printed; an empty Any prints as {}" {
  let hello = nested(w => string_field(w, 1, "Tom"))
  let lines = [
    dynamic("google.protobuf.Any", fixture(any_missing)),
    dynamic("google.protobuf.Any", any_of("helloworld.HelloRequest", hello)),
    dynamic("google.protobuf.Any", any_of("type.googleapis.com/", hello)),
    dynamic("google.protobuf.Any", any_of("", hello)),
    dynamic("google.protobuf.Any", b""),
    // Any URL prefix will do: the type is named after the last /.
    dynamic(
      "google.protobuf.Any",
      any_of("example.com/types/helloworld.HelloRequest", hello),
    ),
    // The value of a message it holds must decode.
    dynamic(
      "google.protobuf.Any",
      any_of("type.googleapis.com/helloworld.HelloRequest", b"\x0a\x05Tom"),
    ),
  ]
  inspect(
    lines.join("\n"),
    content=(
      #|error: octet 0: the Any holds the type missing.Greeting, which the Descriptor set does not define, so it cannot be printed
      #|error: octet 0: the Any's type URL "helloworld.HelloRequest" names no type: it must end in / and the type's full name, such as "type.googleapis.com/helloworld.HelloRequest"
      #|error: octet 0: the Any's type URL "type.googleapis.com/" names no type: it must end in / and the type's full name, such as "type.googleapis.com/helloworld.HelloRequest"
      #|error: octet 0: the Any has a value but no type URL, so it cannot be printed
      #|{}
      #|{"@type":"example.com/types/helloworld.HelloRequest","name":"Tom"}
      #|error: octet 48: a length of 5 runs past the end of the input, which has 3 octets left

    ),
  )
}

///|
test "every type at every place: a Struct in key order with values of each kind, Values, ListValues, NullValues as null, and Anys that hold a message, a Duration, an Empty, a Value, a Struct and an Any" {
  inspect(
    dynamic("dynamic.Document", fixture(document)),
    content=(
      #|{"labels":{"count":3,"nested":{"empty":{},"sizes":[1.5,1e+21]},"none":null,"on":true,"team":"core"},"value":["x",null,[]],"list":[-0.25,false],"nothing":null,"values":["a\"b",0],"byName":{"a":null,"b":"B"},"attachment":{"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Tom"},"attachments":[{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1.500s"},{"@type":"type.googleapis.com/google.protobuf.Empty"},{"@type":"type.googleapis.com/google.protobuf.Value","value":2},{"@type":"type.googleapis.com/google.protobuf.Struct","value":{"k":true}},{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Ann"}}],"none":null,"maybe":null,"nothings":[null,null]}
    ),
  )
  // A NullValue without presence prints at its default, null; one with
  // presence, and the message fields, print only when set.
  inspect(
    dynamic("dynamic.Document", b""),
    content=(
      #|{"nothing":null,"values":[],"byName":{},"attachments":[],"nothings":[]}
    ),
  )
}
