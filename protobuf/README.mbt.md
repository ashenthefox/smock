# smock/protobuf

Protobuf for MoonBit: the wire format, a reader of Descriptor sets
(FileDescriptorSets), the compiled form of `.proto` files that
`protoc --include_imports -o` and `buf build -o` write, and messages
decoded into JSON and encoded from it with their types from a set. smock
reads a Mock's Descriptor set with it, and decodes and encodes the
messages of gRPC calls. The module does no I/O and depends only on
`moonbitlang/core`. It builds for every MoonBit target and is tested on
native and `wasm-gc`.

## The wire format

A message is a sequence of records. Each is a tag, which holds a field
number and a wire type, then a value encoded as the wire type says
([Encoding](https://protobuf.dev/programming-guides/encoding/)).

- `@protobuf.Reader(input)` reads a message in place, a record at a time:
  `tag()` reads a tag and returns its field number, and `wire_type()`
  gives its wire type. Then `varint()`, `fixed64()`, `length_delimited()`
  or `fixed32()` reads the value, `group()` the records of a group up to
  its end tag, or `skip()` skips it, groups included.
  `expect(wire_type)` checks the tag's wire type before a value is read.
  `at_end()` tells when every record is read.
- `@protobuf.Writer()` writes the same: `tag(field, wire_type)`, then the
  value, and `to_bytes()` gives what it wrote.

```mbt check
///|
test "read a message a record at a time" {
  // Field 1 holds the varint 150, and field 2 the string "Tom".
  let reader = @protobuf.Reader(b"\x08\x96\x01\x12\x03Tom"[:])
  let out = []
  while !reader.at_end() {
    match reader.tag() {
      1 => {
        reader.expect(Varint)
        out.push("1: \{reader.varint()}")
      }
      2 => {
        reader.expect(Len)
        out.push("2: \{reader.length_delimited().length()} octets")
      }
      _ => reader.skip()
    }
  }
  inspect(out.join(", "), content="1: 150, 2: 3 octets")
}

///|
test "write the same message" {
  let writer = @protobuf.Writer()
  writer.tag(1, Varint)
  writer.varint(150)
  writer.tag(2, Len)
  writer.length_delimited(b"Tom"[:])
  inspect(writer.to_bytes() == b"\x08\x96\x01\x12\x03Tom", content="true")
}
```

```mbt check
///|
test "read a group's records" {
  // Field 1 is a group, which holds field 2, the varint 7; then field 3.
  let reader = @protobuf.Reader(b"\x0b\x10\x07\x0c\x18\x01"[:])
  inspect(reader.tag(), content="1")
  let records = reader.group()
  inspect(records.length(), content="2")
  let inner = @protobuf.Reader(records)
  inspect(inner.tag(), content="2")
  inspect(inner.varint(), content="7")
  inspect(reader.tag(), content="3")
}
```

A length-delimited value is a view of the input, so reading allocates
nothing for it. Every length is checked against the octets left before
anything is read. Input that is not protobuf raises `DecodeError`, which
shows as `octet <n>: <message>`:

- a varint, a fixed value or a length that the input ends inside, and a
  varint longer than 10 octets;
- a tag longer than 5 octets, field number 0 or one over 2^29 - 1, and wire
  types 6 and 7;
- a tag whose wire type is not the one `expect` asks for;
- when reading or skipping a group, a group that the input ends inside,
  that ends with the end tag of another field, that ends where none
  started, or that nests deeper than 100.

The offset is in the bytes the reader's input is a view of, so a reader of
a nested message, made from a view, reports where the problem is in the
whole input.

```mbt check
///|
test "errors say at which octet the input breaks" {
  let message = (input : Bytes, read : (@protobuf.Reader) -> Unit raise) => {
    try read(@protobuf.Reader(input[:])) catch {
      e => e.to_string()
    } noraise {
      _ => "read"
    }
  }
  inspect(
    message(b"\x08\x96", reader => {
      reader.tag() |> ignore
      reader.varint() |> ignore
    }),
    content="octet 1: the input ends inside a varint",
  )
  inspect(
    message(b"\x12\x05Tom", reader => {
      reader.tag() |> ignore
      reader.length_delimited() |> ignore
    }),
    content="octet 1: a length of 5 runs past the end of the input, which has 3 octets left",
  )
  inspect(
    message(b"\x10\x01", reader => {
      reader.tag() |> ignore
      reader.expect(Len)
    }),
    content="octet 0: field 2 has wire type VARINT, not LEN",
  )
}
```

## Descriptor sets

`@protobuf.read_descriptor_set(input)` reads a FileDescriptorSet, as
`protoc --include_imports -o` and `buf build -o` write it, and checks
that it is self-contained. It keeps the descriptor model:

- each file's name, package, syntax (proto2, proto3 or editions) and
  dependencies;
- its messages, nested ones included, with their full names, fields,
  oneofs and extension ranges, and the options `map_entry` and
  `message_set_wire_format`;
- its enums and their values, aliases included;
- its extensions, top-level and nested, and its services and methods,
  with their streaming flags;
- of a field: its number, label, type, type name, extendee, JSON name,
  oneof, proto3 `optional` and the option `packed`.

A field's JSON name is its `json_name`, or else its name in
lowerCamelCase, as protoc computes it. The reader skips every other field
of the set, such as source info, other options and Buf's image
extensions, so a set built with `buf build`'s defaults reads as it is.

It raises `DescriptorSetError`:

- `NotDecoded(DecodeError)` when the input is not protobuf, when a field
  it keeps has another wire type than `descriptor.proto` gives it, when a
  string it keeps is not UTF-8, when a syntax, a label or a type is not
  one that `descriptor.proto` defines, and when messages nest deeper than
  100;
- `Invalid(problems)`, with every problem, when a file is in the set more
  than once or imports one that is not in it, when a full name is defined
  twice, when a message uses a field number twice or names a oneof it
  does not have, when a type that a field, a method or an extension names
  is not in the set, and when an extension's number is not one its
  message declares for extensions, or is taken by another extension.
  Types are checked once every import is in the set and every name is
  defined once, so a missing import gives no other problem. A set whose
  full names would take more than 16 MiB is refused too, as soon as they
  do.

```mbt check
///|
test "read a Descriptor set" {
  // One file, a.proto, in package demo, with syntax "proto3".
  let set = @protobuf.read_descriptor_set(
    b"\x0a\x17\x0a\x07a.proto\x12\x04demo\x62\x06proto3"[:],
  )
  let file = set.files[0]
  inspect(
    "\{file.name} \{file.package_name} \{file.syntax == Proto3}",
    content="a.proto demo true",
  )
}

///|
test "a set that lacks an import is refused" {
  // The file a.proto, which imports b.proto.
  let input = b"\x0a\x12\x0a\x07a.proto\x1a\x07b.proto"
  let problems = try @protobuf.read_descriptor_set(input[:]) catch {
    Invalid(problems) => problems.join("\n")
    NotDecoded(err) => "\{err}"
  } noraise {
    _ => "read"
  }
  inspect(
    problems,
    content="a.proto imports b.proto, which is not in the set; build the set with protoc --include_imports, or with buf build",
  )
}
```

## Lookups

Decoding, encoding and conditions share these lookups. Each reads an
index built when the set is read, so none walks the set.

- `set.find_method(path)`: a method by the path gRPC calls it by, such as
  `/helloworld.Greeter/SayHello`; `set.input_of(method)` and
  `set.output_of(method)` give its types.
- `set.find_message(full_name)`, `set.find_enum(full_name)` and
  `set.find_extension(full_name)`: by a full name without a leading dot,
  such as `helloworld.HelloRequest` or `shop.priority`.
- `set.message_of(field)` and `set.enum_of(field)`: a field's message,
  group or enum type.
- `message.find_field_by_name(name)`,
  `message.find_field_by_json_name(name)` and
  `message.find_field_by_number(number)`: a field by its proto name, its
  JSON name or its number. `message.find_extension(number)`: the extension
  of the set that extends the message with that number, and
  `message.extended_by()` all of them, in field-number order.
- `enum.find_value_by_name(name)` and `enum.find_value_by_number(number)`:
  a value by its name, or by its number, which gives its first name when
  aliases share the number.

```mbt check
///|
test "find a method, its input type and a field" {
  // greeter.proto: package g, a message Req with the field user_name, and
  // a service Greeter with the method Hi from Req to Req.
  let set = @protobuf.read_descriptor_set(
    b"\x0a\x53\x0a\x0dgreeter.proto\x12\x01g\x22\x16\x0a\x03Req\x12\x0f\x0a\x09user_name\x18\x01\x28\x09\x32\x1f\x0a\x07Greeter\x12\x14\x0a\x02Hi\x12\x06.g.Req\x1a\x06.g.Req\x62\x06proto3"[:],
  )
  guard set.find_method("/g.Greeter/Hi") is Some(hi) else { fail("no Hi") }
  let input = set.input_of(hi)
  guard input.find_field_by_json_name("userName") is Some(field) else {
    fail("no userName")
  }
  inspect(
    "\{input.full_name}: \{field.name} = \{field.number}",
    content="g.Req: user_name = 1",
  )
}
```

## Messages

`@protobuf.decode_json(set, message, input)` decodes a message of the
type `message`, a `MessageDescriptor` of `set`, into smock's decoded form:
compact JSON text in UTF-8, with one member per field, in field-number
order, under the field's JSON name, as `json_name` gives it.

- 64-bit integers are JSON numbers, exact at any size, and so are 32-bit
  integers. A double is printed as `Double::to_string` prints it, and a
  float in the shortest form that reads back as the same 32-bit float, so
  0.1f prints `0.1`. NaN and the infinities are the strings `"NaN"`,
  `"Infinity"` and `"-Infinity"`.
- bytes are standard base64 with padding. An enum value is printed by its
  name, the first one of an alias, or by its number when an open enum, as
  a proto3 enum is, does not define it. A nested message is an object.
- A repeated field is an array. A map is an object with a member per key,
  in key order: integer keys by value, bool keys `"false"` then
  `"true"`, and string keys by their octets; an integer key prints in
  decimal, as a string.
- A field without presence that the message leaves out is printed at its
  default, `[]` and `{}` included. A proto3 `optional` field, a member of
  a oneof, a message field and every singular field of a proto2 message
  are printed only when the message holds them.
- A group is printed as a message. An extension of the set that extends
  the message is printed under its full name in brackets, as ProtoJSON
  writes it, such as `"[shop.priority]":3`, among the fields in
  field-number order, and only when the message holds it.

So a message gives one text, whatever order its records come in.

It reads the message as protobuf's parsers read it: the last value of a
scalar field wins, the values of a message field are merged, a member of
a oneof replaces the one before it, repeated scalars are read packed or
not with the records of a packed field joined, and unknown fields are
skipped. A map entry without a key or a value takes the default, and when
a key repeats, the last entry wins. A number that a closed enum, as a
proto2 enum is, does not define is skipped, as protobuf's parsers keep it
as an unknown field: a list leaves it out, a map leaves its entry out, and
a field or a oneof keeps the value it had. A proto2 string that is not
UTF-8 prints with U+FFFD for each bad sequence; an extension follows the
syntax of the file that declares it. It raises `DecodeError` when the
input is not protobuf, a proto3 string is not UTF-8, a group's end tag
does not match, a message lacks a proto2 required field, or messages nest
deeper than 100, a map entry and a group counting as a message. It does
not decode types of editions files, extensions declared in one, and
MessageSets, and raises its error for a message that is or has one. The
well-known types print in their ProtoJSON forms
([below](#well-known-types)).

`set.encode_json(message, json)` encodes JSON, a message of the type
`message`, a type of `set`, as ProtoJSON writes it, the way protoc encodes
it: fields in field-number order, a field without presence left out at its
default, every singular field of a proto2 message written whenever it is
set, repeated scalars of a proto3 message packed unless the field says
`packed = false` and those of a proto2 message only when it says
`packed = true`, map entries sorted by key, extensions among the fields
and groups between their start and end tags. It reads JSON as ProtoJSON
reads it: a key may be the field's proto name or its JSON name, or an
extension's full name in brackets, `null` leaves a field
unset but for a Value or a NullValue, an enum is a name or a number, a
64-bit integer a number or a
string, exact at any size, a float `"NaN"`, `"Infinity"` or `"-Infinity"`
too, and bytes are base64, standard or URL-safe, with or without padding.
It raises `EncodeError`, which names the JSON Pointer of the value at
fault, for JSON that is not a message of the type, a message that lacks a
proto2 required field and a number that a closed enum does not define
included, a key in brackets that names no extension of the set that
extends the message, and for the types it does not encode: types and
extensions of editions files, not yet, and MessageSets.
`@protobuf.is_well_known(full_name)` tells the well-known types.

```mbt check
///|
test "decode a message, and encode one" {
  // message CountRequest { string shelf = 1; bool in_stock = 2; }
  let set = @protobuf.read_descriptor_set(
    b"\x0a\x48\x0a\x07a.proto\x12\x04demo\x22\x2f\x0a\x0cCountRequest\x12\x0d\x0a\x05shelf\x18\x01\x20\x01\x28\x09\x12\x10\x0a\x08in_stock\x18\x02\x20\x01\x28\x08\x62\x06proto3"[:],
  )
  let count = set.files[0].messages[0]
  let json = @protobuf.decode_json(set, count, b"\x0a\x02A1\x10\x01"[:])
  inspect(@utf8.decode(json), content="{\"shelf\":\"A1\",\"inStock\":true}")
  inspect(
    set.encode_json(count, { "in_stock": true, "shelf": "A1" }) ==
    b"\x0a\x02A1\x10\x01",
    content="true",
  )
}
```

## Well-known types

`decode_json` and `encode_json` give protobuf's well-known types their
ProtoJSON forms, at any place, a message's whole type included. A type is
known by its full name, such as `google.protobuf.Duration`.

- A Timestamp prints as a string of the date and time in UTC, with 0, 3,
  6 or 9 fractional digits, then `Z`, such as `"1970-01-01T00:00:01.500Z"`,
  and reads with any offset, such as `+09:00`, and 0 to 9 fractional
  digits. It is from 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z.
- A Duration prints as a string of seconds, with 0, 3, 6 or 9 fractional
  digits, then `s`, such as `"1.500s"`, and reads with 0 to 9 fractional
  digits. It is at most 315,576,000,000 seconds and 999,999,999
  nanoseconds either way, and its seconds and nanoseconds never have
  opposite signs.
- A FieldMask prints as its paths in lowerCamelCase, joined by commas,
  such as `"userName,address.city"`.
- A wrapper prints as the value it wraps, as its type prints: an
  Int64Value as a number, a FloatValue as a float.
- Empty prints as `{}`.
- A Struct, a Value and a ListValue print as the JSON values they hold: a
  Struct as an object in key order, a ListValue as an array, and a Value
  as `null`, a number, which prints as a double does, a string, a bool, an
  object or an array. A NullValue prints as `null`. In JSON, `null` sets
  `null_value` in a Value, and a NullValue, where it leaves other fields
  unset.
- An Any prints as an object of its type URL as `@type`, then the message
  it holds: the message's fields, or its form as `value` when it is a
  well-known type that has one, so an Any that holds an Empty prints
  `@type` alone. Its type is the type of the set that the URL names after
  its last `/`, as `@protobuf.type_name_of_url(url)` gives it, and an Any
  whose type the set lacks cannot be printed or read. An empty Any prints
  as `{}`.

A value that ProtoJSON cannot print, such as a Timestamp in the year
10000, is a `DecodeError`, and a value out of range in JSON an
`EncodeError`. `set.printed_message(message, json)` checks a whole message
as `printed_value` checks a field's value ([below](#printed-values)):
`"1.5s"` for a Duration gives `NotPrinted` with `"1.500s"`. A Struct, a
ListValue and an Any must be an object, an array and an object, whose
members the caller checks, as `message.json_form()` says, and
`@protobuf.printed_json_value(json)` gives a value that a Value holds in
its printed form.

```mbt check
///|
test "a Duration in its ProtoJSON form" {
  // google.protobuf.Duration { int64 seconds = 1; int32 nanos = 2; }
  let set = @protobuf.read_descriptor_set(
    b"\x0a\x55\x0a\x0eduration.proto\x12\x0fgoogle.protobuf\x22\x2a\x0a\x08Duration\x12\x0f\x0a\x07seconds\x18\x01\x20\x01\x28\x03\x12\x0d\x0a\x05nanos\x18\x02\x20\x01\x28\x05\x62\x06proto3"[:],
  )
  let duration = set.files[0].messages[0]
  let json = @protobuf.decode_json(
    set,
    duration,
    b"\x08\x01\x10\x80\xca\xb5\xee\x01"[:],
  )
  inspect(@utf8.decode(json), content="\"1.500s\"")
  inspect(
    set.encode_json(duration, "1.5s") == b"\x08\x01\x10\x80\xca\xb5\xee\x01",
    content="true",
  )
  let suggested = try set.printed_message(duration, "1.5s") catch {
    NotPrinted(printed~) => "write \{printed}"
    NotOfType(wanted~) => "must be \{wanted}"
  } noraise {
    _ => "kept"
  }
  inspect(suggested, content="write \"1.500s\"")
}
```

```mbt check
///|
test "an Any's type, and a Value's number" {
  let url = "type.googleapis.com/helloworld.HelloRequest"
  inspect(
    @protobuf.type_name_of_url(url).unwrap_or("no type"),
    content="helloworld.HelloRequest",
  )
  inspect(
    @protobuf.type_name_of_url("helloworld.HelloRequest").unwrap_or("no type"),
    content="no type",
  )
  let number = @json.parse("1e3")
  inspect(@protobuf.printed_json_value(number).stringify(), content="1000")
}
```

## google.rpc.Status

gRPC's richer error model sends `google.rpc.Status` in the
`grpc-status-details-bin` trailer: a status code, a message, and error
details, each packed in an Any. `set.encode_status(code, message,
details)` encodes it as protoc does, from details in ProtoJSON, each an Any
as `encode_json` reads one, with `@type`. It writes the Status and each Any
by field number, so the set needs neither `google/rpc/status.proto` nor
`any.proto`: only the types of the details, such as `google.rpc.ErrorInfo`
from googleapis' `error_details.proto`. A detail that is not an object,
has no `@type`, names a type the set lacks, or does not fit its type is an
`EncodeError`, at the JSON Pointer of the value at fault from the details,
such as `/0/@type`.

```mbt check
///|
test "google.rpc.Status with a Duration as its detail" {
  // google.protobuf.Duration { int64 seconds = 1; int32 nanos = 2; }
  let set = @protobuf.read_descriptor_set(
    b"\x0a\x55\x0a\x0eduration.proto\x12\x0fgoogle.protobuf\x22\x2a\x0a\x08Duration\x12\x0f\x0a\x07seconds\x18\x01\x20\x01\x28\x03\x12\x0d\x0a\x05nanos\x18\x02\x20\x01\x28\x05\x62\x06proto3"[:],
  )
  let status = set.encode_status(14, "try again", [
    { "@type": "type.googleapis.com/google.protobuf.Duration", "value": "1.5s" },
  ])
  // The code, the message, then an Any of the type URL and the Duration.
  inspect(
    status ==
    b"\x08\x0e\x12\x09try again\x1a\x38\x0a\x2ctype.googleapis.com/google.protobuf.Duration\x12\x08\x08\x01\x10\x80\xca\xb5\xee\x01",
    content="true",
  )
  let missing = try
    set.encode_status(5, "", [
      { "@type": "type.googleapis.com/google.rpc.ErrorInfo" },
    ])
  catch {
    EncodeError(pointer~, ..) => "error at \{pointer}"
  } noraise {
    _ => "encoded"
  }
  inspect(missing, content="error at /0/@type")
}
```

## Printed values

`set.printed_value(field, json)` checks a JSON value against a field's type
as `decode_json` prints it, and gives it in that form. smock checks its
gRPC Stubs' conditions with it. An enum number or alias becomes the first
name of its number, a float is rounded to 32 bits and given in its shortest
form, and an integer written with an exponent is given in its digits. It
raises `NotPrinted`, with the printed form, for a value that ProtoJSON
reads but `decode_json` never prints, such as a 64-bit integer written as
a string or bytes in URL-safe base64, and `NotOfType`, saying what the
field takes, for any other value that is not one of the type.
`key_field.check_printed_key(key)` checks a map key the same way: an
integer key such as `"007"` gives `NotPrinted` with `"7"`.

```mbt check
///|
test "check values as decode_json prints them" {
  // message Q { int64 id = 1; float ratio = 2; }
  let set = @protobuf.read_descriptor_set(
    b"\x0a\x37\x0a\x07a.proto\x12\x04demo\x22\x1e\x0a\x01Q\x12\x0a\x0a\x02id\x18\x01\x20\x01\x28\x03\x12\x0d\x0a\x05ratio\x18\x02\x20\x01\x28\x02\x62\x06proto3"[:],
  )
  let q = set.files[0].messages[0]
  guard q.find_field_by_name("id") is Some(id) &&
    q.find_field_by_name("ratio") is Some(ratio) else {
    fail("no fields")
  }
  inspect(set.printed_value(ratio, 16777217).stringify(), content="16777216")
  let suggested = try set.printed_value(id, "42") catch {
    NotPrinted(printed~) => "write \{printed}"
    NotOfType(wanted~) => "must be \{wanted}"
  } noraise {
    _ => "kept"
  }
  inspect(suggested, content="write 42")
}
```
