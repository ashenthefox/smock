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
  nested(w => {
    for value in values {
      message_field(w, 1, value)
    }
  })
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

///|
test "replies of every type have protoc's bytes, Struct entries sorted by key, in either spelling of a field and with NullValue by name or number" {
  assert_eq(
    encoded(dynamic_set, "dynamic.Document", {
      "nothings": [null, "NULL_VALUE"],
      "maybe": 0,
      "none": null,
      "attachments": [
        {
          "@type": "type.googleapis.com/google.protobuf.Duration",
          "value": "1.5s",
        },
        { "@type": "type.googleapis.com/google.protobuf.Empty" },
        { "@type": "type.googleapis.com/google.protobuf.Value", "value": 2 },
        {
          "@type": "type.googleapis.com/google.protobuf.Struct",
          "value": { "k": true },
        },
        {
          "@type": "type.googleapis.com/google.protobuf.Any",
          "value": {
            "name": "Ann",
            "@type": "type.googleapis.com/helloworld.HelloRequest",
          },
        },
      ],
      "attachment": {
        "@type": "type.googleapis.com/helloworld.HelloRequest",
        "name": "Tom",
      },
      "by_name": { "b": "B", "a": null },
      "values": ["a\"b", 0],
      "nothing": "NULL_VALUE",
      "list": [-0.25, false],
      "value": ["x", null, []],
      "labels": {
        "team": "core",
        "on": true,
        "none": null,
        "nested": { "sizes": [1.5, 1.0e21], "empty": {} },
        "count": 3,
      },
    }),
    @hex.encode(fixture(document)),
  )
}

///|
test "a reply's null sets null_value in a Value, in a Struct's and a ListValue's values and in a NullValue field, and leaves other fields unset" {
  assert_eq(
    encoded(dynamic_set, "dynamic.Document", {
      "labels": { "gone": null },
      "value": null,
      "list": [null],
      "nothing": null,
      "values": [null],
      "byName": { "gone": null },
      "attachment": null,
      "attachments": null,
      "none": null,
      "maybe": null,
      "nothings": [null],
    }),
    @hex.encode(fixture(document_nulls)),
  )
}

///|
test "the ticket's example: an Any is read with its type from the set, a message's fields beside @type, and a well-known type's form as value; an Empty may give value {} or no value" {
  let any = json => encoded(dynamic_set, "google.protobuf.Any", json)
  assert_eq(
    any({
      "@type": "type.googleapis.com/helloworld.HelloRequest",
      "name": "Tom",
    }),
    @hex.encode(fixture(any_hello)),
  )
  assert_eq(
    any({
      "@type": "type.googleapis.com/google.protobuf.Duration",
      "value": "1.500s",
    }),
    @hex.encode(fixture(any_duration)),
  )
  assert_eq(
    any({ "@type": "type.googleapis.com/google.protobuf.Empty" }),
    @hex.encode(fixture(any_empty)),
  )
  assert_eq(
    any({ "@type": "type.googleapis.com/google.protobuf.Empty", "value": {} }),
    @hex.encode(fixture(any_empty)),
  )
  // An empty Any.
  inspect(any({}), content="")
}

///|
test "an Any whose type the set lacks, or whose members do not fit the type it names, is not encoded, with the JSON Pointer of the value at fault" {
  let any = json => encoded(dynamic_set, "google.protobuf.Any", json)
  let document = json => encoded(dynamic_set, "dynamic.Document", json)
  let lines = [
    any({ "@type": "type.googleapis.com/missing.Greeting", "name": "Tom" }),
    any({ "@type": "helloworld.HelloRequest" }),
    any({ "@type": 42 }),
    any({ "name": "Tom" }),
    any({
      "@type": "type.googleapis.com/helloworld.HelloRequest",
      "nmae": "Tom",
    }),
    any({
      "@type": "type.googleapis.com/helloworld.HelloRequest",
      "value": { "name": "Tom" },
    }),
    any({ "@type": "type.googleapis.com/google.protobuf.Duration" }),
    any({
      "@type": "type.googleapis.com/google.protobuf.Duration",
      "value": "1.5",
    }),
    any({
      "@type": "type.googleapis.com/google.protobuf.Duration",
      "value": "1s",
      "seconds": 1,
    }),
    any("type.googleapis.com/helloworld.HelloRequest"),
    document({ "attachments": [{ "@type": "type.googleapis.com/x.Y" }] }),
    document({ "labels": [] }),
    document({ "list": {} }),
    document({ "nothing": "NOTHING" }),
  ]
  inspect(
    lines.join("\n"),
    content=(
      #|error: /@type: names the type missing.Greeting, which the Descriptor set does not define
      #|error: /@type: must be a type URL: / and the full name of a type of the set at its end, such as "type.googleapis.com/helloworld.HelloRequest"
      #|error: /@type: must be a type URL: / and the full name of a type of the set at its end, such as "type.googleapis.com/helloworld.HelloRequest"
      #|error: must give "@type", the type URL of the message the Any holds, such as "type.googleapis.com/helloworld.HelloRequest"
      #|error: /nmae: is not a field of helloworld.HelloRequest
      #|error: /value: is not a field of helloworld.HelloRequest
      #|error: must give "value", the google.protobuf.Duration that the Any holds
      #|error: /value: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the Any holds a google.protobuf.Duration
      #|error: /seconds: is not a member of an Any that holds a google.protobuf.Duration: give the google.protobuf.Duration as "value"
      #|error: must be an object that gives the type URL of the message it holds as "@type": the message is a google.protobuf.Any
      #|error: /attachments/0/@type: names the type x.Y, which the Descriptor set does not define
      #|error: /labels: must be an object, whose members are any JSON values: the field labels of dynamic.Document has the type google.protobuf.Struct
      #|error: /list: must be an array, whose elements are any JSON values: the field list of dynamic.Document has the type google.protobuf.ListValue
      #|error: /nothing: must be null: the field nothing of dynamic.Document has the type google.protobuf.NullValue
    ),
  )
  // A Struct's keys are data, `@type` included: a Struct is no Any.
  let labels = encoded(dynamic_set, "dynamic.Document", {
    "labels": { "a": { "b": [1, { "@type": 5 }] } },
  })
  inspect(
    dynamic("dynamic.Document", @hex.decode(labels)),
    content=(
      #|{"labels":{"a":{"b":[1,{"@type":5}]}},"nothing":null,"values":[],"byName":{},"attachments":[],"nothings":[]}
    ),
  )
}
