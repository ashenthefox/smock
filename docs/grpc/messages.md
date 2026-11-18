# Messages as JSON

smock decodes a gRPC call's message into JSON with its method's input
type, and encodes a gRPC Stub's reply from JSON with the output type. This
document gives the JSON form of a request message, the well-known types,
Struct and Value, and Any. It says how a `json` condition is checked and
rewritten into that form, how a reply's `json` is read, encoded and sent,
and how the types of proto2 files are served. It is part of the [gRPC
guide](../grpc.md), whose [How smock serves a
call](../grpc.md#how-smock-serves-a-call) gives the steps of a call. It
assumes a Mock that names a Descriptor set, the set ([Building a
set](../grpc.md#building-a-set)), and [gRPC Stubs](../grpc.md#grpc-stubs)
on its methods. Its examples use gRPC's helloworld.proto, as the guide's
[quick start](../grpc.md#quick-start) does.

## Contents

- [The request message as JSON](#the-request-message-as-json)
- [Well-known types](#well-known-types)
- [JSON values: Struct, Value, ListValue and NullValue](#json-values-struct-value-listvalue-and-nullvalue)
- [Any](#any)
- [Conditions on the message](#conditions-on-the-message)
- [Printed forms](#printed-forms)
- [The reply](#the-reply)
- [proto2 types](#proto2-types)
  - [Extensions](#extensions)
  - [What is not served](#what-is-not-served)

## The request message as JSON

smock prints a request message in one form, the same for every client
that sends it. The fields come in field-number order, each under its JSON
name: its name in lowerCamelCase, such as `inStock` for `in_stock`, unless
the `.proto` file gives it a `json_name`. Each type prints as follows:

| Protobuf | JSON | Example |
|---|---|---|
| `int64`, `uint64`, `sint64`, `fixed64`, `sfixed64` | a number, exact at any size | `9223372036854775807` |
| `int32`, `uint32`, `sint32`, `fixed32`, `sfixed32` | a number | `-5` |
| `double` | a number, as smock's `json` replies write one | `0.1`, `1e+21` |
| `float` | a number, in the shortest form that reads back as the same 32-bit float | `9.99`, not `9.989999771118164` |
| `double` and `float` that are not numbers | the strings `"NaN"`, `"Infinity"` and `"-Infinity"` | `"NaN"` |
| `bool` | `true` or `false` | `true` |
| `string` | a string | `"Kyoto"` |
| `bytes` | a string of standard base64, with padding | `"AAH7/w=="` |
| an enum | the name of its value, the first name when aliases share the number, or the number of a value the enum does not define, for an open enum, as a proto3 enum is ([proto2 types](#proto2-types)) | `"ACTIVE"`, `7` |
| a message | an object in the same form | `{"city":"Kyoto"}` |
| a repeated field | an array of its values, in order | `["a","b"]` |
| a map | an object with a member per key, in key order; integer keys in decimal and bool keys as `"true"` and `"false"`, as strings | `{"1":3,"2":5,"10":1}` |
| a oneof | the member the message holds, under its own JSON name, and no other | `"word":"w"` |
| a proto2 group | an object, as a message | `"stop":[{"city":"Paris"}]` |
| a proto2 extension | its value, under its full name in brackets, among the fields in field-number order, only when the message holds it ([proto2 types](#proto2-types)) | `"[shop.priority]":3` |
| `google.protobuf.Timestamp` | a string of the date and time in UTC, with 0, 3, 6 or 9 fractional digits, then `Z` | `"1970-01-01T00:00:01.500Z"` |
| `google.protobuf.Duration` | a string of seconds, with 0, 3, 6 or 9 fractional digits, then `s` | `"1.500s"`, `"-0.250s"` |
| `google.protobuf.FieldMask` | a string of its paths in lowerCamelCase, joined by commas | `"userName,address.city"` |
| a wrapper, such as `google.protobuf.Int32Value` | the value it wraps, printed as its type is: `Int64Value` and `UInt64Value` as numbers, `FloatValue` as a `float`, `BytesValue` in base64 | `5`, `9.99`, `"Tom"` |
| `google.protobuf.Empty` | an empty object | `{}` |
| `google.protobuf.Struct` | an object of any JSON values, its members in key order | `{"age":42,"name":"Tom"}` |
| `google.protobuf.Value` | the JSON value it holds: `null`, a number, which prints as a `double` does, a string, `true` or `false`, an object or an array | `null`, `1.5`, `["x"]` |
| `google.protobuf.ListValue` | an array of any JSON values | `["Tom",null,7]` |
| `google.protobuf.NullValue` | `null` | `null` |
| `google.protobuf.Any` | an object of its type URL as `"@type"`, then the message it holds: its fields, or, for a well-known type with a form of its own, that form as `"value"` ([Any](#any)) | `{"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Tom"}` |

So the message `id: 9223372036854775807 price: 9.99 status: ACTIVE
address { city: "Kyoto" }` is:

```json
{"id":9223372036854775807,"price":9.99,"status":"ACTIVE","note":"","address":{"city":"Kyoto"}}
```

A condition matches it as written: `{price: 9.99, status: ACTIVE}` meets
it, and so does `{id: 9223372036854775807}`, since numbers are compared
exactly.

Which fields print depends on whether a field has presence:

- A field without presence, such as a plain proto3 `string` or `int32`,
  prints even when the message leaves it out. It prints at its default:
  `0`, `false`, `""`, or an enum's value numbered 0. A repeated field
  prints `[]` and a map `{}`. So `{count: 0}`, `{name: ""}` and
  `{tags: []}` match a message that leaves `count`, `name` or `tags` out.
- A proto3 `optional` field, a member of a oneof, a message field and
  every singular field of a proto2 message print only when the message
  holds them, even at their default. So the condition
  `{maybeCount: {$exists: false}}` tells a message that leaves
  `maybe_count` out from one that holds 0.

smock reads a message as protobuf's parsers read it:

- The last value of a field wins.
- The values of a message field are merged: the last value of each of
  its fields wins, its repeated fields are joined, and its maps are
  merged.
- A member of a oneof replaces the member that came before it, so the
  JSON never holds two.
- A repeated number, bool or enum may come packed or not, and the records
  of a packed field are joined.
- A map entry without a key or a value takes the default. When a key
  comes twice, the last entry wins.
- Fields the type does not have, such as those a newer client sends, are
  skipped.

Each message gives one text. Its fields come in field-number order, and
its map entries in key order: integer keys by their value, bool keys
`false` then `true`, and string keys by their text, in the order of
Unicode code points. Neither depends on the order in which a client
encodes them. So a message reads the same in `bodyText`, the Journal and
the Near miss, whichever client sent it. The message
`tags: ["a", "b"] counts: {10: 1, 1: 3, 2: 5}` is always:

```json
{"tags":["a","b"],"counts":{"1":3,"2":5,"10":1}}
```

smock decodes requests, and answers with replies, of every type of a
proto3 or a proto2 file ([The reply](#the-reply),
[proto2 types](#proto2-types)). The types of editions files and
MessageSets are not served ([What is not served](#what-is-not-served)).

## Well-known types

protobuf's well-known types print in their ProtoJSON forms, as grpcurl
shows them, not as objects of their fields
([the table above](#the-request-message-as-json)). This section shows
Timestamp, Duration, FieldMask, the wrappers and Empty; the next two show
the types that hold any JSON value, and Any. With this message:

```proto
message Lease {
  google.protobuf.Timestamp created_at = 1;
  google.protobuf.Duration ttl = 2;
}
```

a call with a Timestamp 1.5 s after the epoch and a Duration of 1.5 s is
journaled as:

```json
{"createdAt":"1970-01-01T00:00:01.500Z","ttl":"1.500s"}
```

A Timestamp and a Duration print the fewest fractional digits of 0, 3, 6
and 9 that hold their nanoseconds: `"1s"`, `"1.500s"`, `"0.000120s"`,
`"0.000000001s"`. A negative Duration starts with `-`, such as `"-0.500s"`.

A field of a well-known type is a message field. It prints only when the
message holds it, and then even at its default: a Timestamp of the epoch
prints `"1970-01-01T00:00:00Z"`, a Duration of 0 `"0s"`, a FieldMask
without paths `""`, and an `Int32Value` that holds 0 prints `0`. So, on an
`Int32Value` field `count`, the condition `{count: {$exists: false}}`
tells a message that leaves `count` out from one that holds 0.

A condition on one of these types is written in its printed form
([Printed forms](#printed-forms)): `{ttl: "1.5s"}` is a problem that names
`"1.500s"`. A reply reads every form that ProtoJSON reads, offsets and
other fraction lengths included ([The reply](#the-reply)). A reply value
out of its type's range is a problem, or INTERNAL `template failed` when
the reply is templated.

A method's whole input or output may be a well-known type, too. A call
that sends `google.protobuf.Empty` is `{}`, and one that sends a
`google.protobuf.Duration` is the string, such as `"1.500s"`. A Stub's
`json` condition, and its reply, are then that value:

```yaml
- id: wait
  mock: leases
  request:
    path: /wellknown.Leases/Wait            # takes a google.protobuf.Duration
    body: { json: "1.500s" }
  response: {}                              # returns google.protobuf.Empty
```

A message that holds one of these values cannot be printed, so it does
not decode:

- A Timestamp outside the range from 0001-01-01T00:00:00Z to
  9999-12-31T23:59:59.999999999Z.
- A Duration longer than 315,576,000,000 seconds either way, or one whose
  seconds and nanoseconds have opposite signs.
- A FieldMask with a path that has no lowerCamelCase form, such as
  `user__name`.

The call gets INTERNAL, as a message that does not parse does.

## JSON values: Struct, Value, ListValue and NullValue

`google.protobuf.Struct`, `Value` and `ListValue` hold any JSON value, and
print as that value. A Struct is an object, its members in key order, as
a map's are. A ListValue is an array. A Value is `null`, a number, a
string, `true` or `false`, an object, which is a Struct, or an array,
which is a ListValue. A number prints as a `double` does: `3`, `1.5`,
`1e+21`. `google.protobuf.NullValue`, the enum of a Value's `null`, prints
as `null`. With this message:

```proto
message Document {
  google.protobuf.Struct labels = 1;
  google.protobuf.Value value = 2;
  google.protobuf.NullValue nothing = 4;
}
```

a call is journaled as:

```json
{"labels":{"count":3,"team":"core"},"value":["x",null],"nothing":null}
```

A NullValue field without presence prints `null` even when the message
leaves it out, as any field at its default does.

A condition on one of these types may hold any JSON value, with patterns
and operators in any place. A Struct's keys are data, as a map's are:
smock never rewrites them, and a key that starts with `$` is written
`$$`. A number is rewritten into the form a `double` prints, such as
`3` for `3.0`, and a NullValue's name, `NULL_VALUE`, or its number into
`null`.

In a reply, `null` sets a Value, a Struct's members and a ListValue's
elements included, to `null_value`, and a NullValue field to its one
value. It leaves any other field unset:

```yaml
response:
  json: { labels: { gone: null }, value: null, nothing: null }
```

A Value that holds no value cannot be printed. Neither can one that holds
a number that JSON has none for, NaN or an infinity, as protobuf's JSON
printers refuse them. So a call whose message holds one does not decode
and gets INTERNAL.

## Any

A `google.protobuf.Any` holds a message of any type, with the type's URL,
such as `type.googleapis.com/helloworld.HelloRequest`. smock looks the
type up in the Mock's Descriptor set, by the full name after the URL's
last `/`. So the set must hold the file that defines it, as
`protoc --include_imports` puts it there when a file of the set imports
it. An Any prints as an object of the URL as `"@type"`, then the message
it holds: its fields, as any message prints, or, for a well-known type
with a form of its own, that form as `"value"`. An Any that holds an
Empty prints `"@type"` alone, and an empty Any prints `{}`.

So an Any that holds a `helloworld.HelloRequest` is journaled as:

```json
{"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Tom"}
```

and one that holds a Duration of 1.5 s as:

```json
{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1.500s"}
```

A condition on an Any is written in the same form. smock checks its
other members against the type that `"@type"` names, and rewrites them as
in any condition. `"@type"` may be a pattern or an operator only when it
is the Any's only member. A reply is read in the same form, field names
in either spelling, and an Empty may also be given `"value": {}`, as
grpcurl prints it.

An Any whose type the set lacks cannot be printed. A call whose message
holds one gets INTERNAL, as a message that does not parse does. A
templated reply that names one gets INTERNAL `template failed`. In a
condition or a static reply, it is a problem when the files load:

```text
documents.yaml: /stubs/0/request/body/json/@type: names the type missing.Greeting, which the Descriptor set does not define
```

## Conditions on the message

When the files load, smock checks each gRPC Stub's `json` condition
against the input type of its method. It rewrites the condition into the
form in which it prints a call's message. Matching a call then costs no
more than matching a JSON body. With this input type:

```proto
message Query {
  int64 user_id = 1;
  Status status = 2;
  float ratio = 3;
  map<int32, string> labels = 5;
  Profile profile = 7;
}

enum Status {
  option allow_alias = true;
  STATUS_UNSPECIFIED = 0;
  ACTIVE = 1;
  ENABLED = 1;
  SUSPENDED = 2;
}

message Profile {
  string display_name = 1;
  map<string, int32> scores = 2;
}
```

the condition `{user_id: 42, status: 1}` is matched as
`{"userId":42,"status":"ACTIVE"}`, so the call `user_id: 42 status: ACTIVE`
meets it. A Near miss in the Journal shows the condition in that form.

smock rewrites:

- A field's name in the `.proto` file into its JSON name: `user_id` into
  `userId`, at every depth.
- An enum's number, or an alias, into the first name of its number:
  `status: 1` and `status: ENABLED` into `status: ACTIVE`. A number that no
  value has stays a number, as smock prints it for an open enum. It is a
  problem for a closed enum, which never prints it
  ([proto2 types](#proto2-types)).
- A `float`, or the value of a `google.protobuf.FloatValue`, into the
  nearest 32-bit float, in the form smock prints it:

  | Written | Matched as | Meets a call of |
  |---|---|---|
  | `ratio: 0.1` | `0.1` | `0.1` |
  | `ratio: 9.99` | `9.99` | `9.99` |
  | `ratio: 16777217` | `16777216` | `16777217`, which a float holds as 16777216 |

- An integer written with an exponent or a fraction of zeros, such as
  `1e3`, into its digits, `1000`.
- A NullValue's name or number into `null`, and a number that a Value
  holds into the form a `double` prints
  ([JSON values](#json-values-struct-value-listvalue-and-nullvalue)).

Map keys are data, never rewritten: `profile: {scores: {math_score: 90}}`
matches the key `math_score` as written, while `profile` and its field
`display_name` become `profile` and `displayName`. A key that starts with
`$` is written `$$`, as in any `json` condition. A Struct's keys are data
too, and an Any's members are checked against the type its `"@type"`
names ([Any](#any)).

An extension is written by its full name in brackets, as ProtoJSON writes
it, such as `"[shop.priority]": 3`, and the key stays as written
([proto2 types](#proto2-types)).

smock refuses the following, each as a problem at the JSON Pointer of the
value at fault.

- A key that names no field of the type at its place, a key in brackets
  that names no extension of the set that extends the type, and a field
  given by both its names in one object.
- A literal that is not a value of its field's type as smock prints it,
  and so can never match. Such a literal is an integer out of its type's
  range or with a fraction, an enum name the enum lacks, a `float` outside
  the float range, or a string for a number or a number for a string. So
  is an array for a field that is not repeated, a map or a message that
  is not an object, and `null`, which smock prints only for a Value and a
  NullValue.
- A literal that ProtoJSON reads but smock never prints
  ([Printed forms](#printed-forms)).

Patterns and operators are allowed in any place. An operator's condition
is checked as the value in its place, and that of `$includes` and `$last`
on a repeated field as one of its elements, so
`history: {$includes: ENABLED}` becomes `history: {$includes: ACTIVE}`.

```text
users.yaml: /stubs/0/request/body/json/usr_id: is not a field of users.Query
users.yaml: /stubs/1/request/body/json/history/1: must be the name of a value of users.Status, or an integer from -2147483648 to 2147483647: the elements of the field history of users.Query have the type users.Status
```

Templates, `find`, `$each`, Variables and data writes read the call's
message as smock prints it, so they see JSON names only: `${body.userId}`
reads 42, and `${body.user_id}` is missing.

Two gRPC Stubs are compared once rewritten for the [warning about a Stub
that can never match](../definition-files.md#a-stub-that-can-never-match).
So a gRPC Stub whose conditions include all of an earlier one's gets the
warning, however each spells them:

```text
users.yaml: /stubs/1: warning: the Stub "by-json-name" can never match: the Stub "by-proto-name" at users.yaml: /stubs/0 is tried first and matches every request this one would
```

## Printed forms

ProtoJSON reads some values in several forms, as smock reads a
[reply](#the-reply). smock prints each value in one form, so a condition
written in another form could never match. Rather than rewrite these, smock
refuses them when the files load, with the form to write:

| Field | Written | The problem suggests |
|---|---|---|
| An integer of any size, such as `int64` | `user_id: "42"` | `42` |
| `float` or `double` | `ratio: "0.1"` | `0.1` |
| `bytes`, in base64 without its padding | `token: "+/8"` | `"+/8="` |
| `bytes`, in URL-safe base64 | `token: "-_8="` | `"+/8="` |
| An integer map key not in decimal | `labels: {"007": seven}` | `"7"` |
| `google.protobuf.Duration` | `ttl: "1.5s"` | `"1.500s"` |
| `google.protobuf.Timestamp`, with an offset other than `Z` | `createdAt: "1970-01-01T09:00:01.500+09:00"` | `"1970-01-01T00:00:01.500Z"` |
| `google.protobuf.Timestamp`, with other fractional digits | `createdAt: "1970-01-01T00:00:01.5Z"` | `"1970-01-01T00:00:01.500Z"` |

```text
users.yaml: /stubs/0/request/body/json/user_id: must be written 42, as smock prints it: the field user_id of users.Query has the type int64
users.yaml: /stubs/1/request/body/json/labels/007: must be written "7", as smock prints it: the keys of the map field labels of users.Query have the type int32
leases.yaml: /stubs/0/request/body/json/ttl: must be written "1.500s", as smock prints it: the field ttl of wellknown.Lease has the type google.protobuf.Duration
```

The same holds for bytes whose base64 has bits after its last octet, such
as `"QR=="`, which smock prints `"QQ=="`, and for an integer key such as
`"-0"` or `"1e3"`. It holds for a wrapper's value as for its type's: an
`Int64Value` written `"42"` names `42`. A FieldMask's paths are data,
which smock does not check against any type, so its printed form is the
one ProtoJSON reads: lowerCamelCase paths, joined by commas.

## The reply

A gRPC Stub's reply is `json`, the reply message, read as ProtoJSON reads
JSON. So a reply that grpcurl or another tool printed can be pasted as it
is:

| Field | In `json` |
|---|---|
| Any field | Its name as the `.proto` file spells it, such as `user_id`, or its JSON name, such as `userId`. Giving both in one object is a problem. |
| `int32`, `sint32`, `sfixed32`, `uint32`, `fixed32` | A number or a string, in its type's range: `7` or `"7"`. An exponent or a fraction of zeros is fine, such as `1e3` or `"100.0"`. |
| `int64`, `sint64`, `sfixed64`, `uint64`, `fixed64` | The same, exact at any size: `"9223372036854775807"`, or the number, whose digits smock keeps. |
| `float`, `double` | A number or a string, or `"NaN"`, `"Infinity"` or `"-Infinity"`. A `float` is rounded to the nearest 32-bit float, and one beyond its range is a problem. |
| `bool` | `true` or `false`. |
| `string` | A string. |
| `bytes` | A string in base64, standard or URL-safe, with or without its padding. |
| An enum | The name of a value, such as `ACTIVE`, or a number, which may name no value, as an open enum allows. A closed enum, as a proto2 enum is, takes only the numbers it defines. |
| A message | An object. |
| A repeated field | An array. `null` in it is a problem, but in a list of Values or NullValues. |
| A map | An object whose keys are the map's keys as strings: integers in decimal, such as `"-1"`, and `"true"` and `"false"`. A `null` value is a problem, but in a map of Values or NullValues. |
| A oneof | One of its members. Two members in one object are a problem, but a member that is `null` does not count. |
| A proto2 group | An object, as for a message. |
| A proto2 extension | Its full name in brackets, such as `"[shop.priority]": 3`. It must name an extension of the set that extends the type. |
| `google.protobuf.Timestamp` | A string in RFC 3339 form, with 0 to 9 fractional digits, then `Z` or an offset such as `+09:00`: `"1970-01-01T09:00:01.5+09:00"`. From 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z, once the offset is taken off. |
| `google.protobuf.Duration` | A string of seconds, with 0 to 9 fractional digits, then `s`: `"1.5s"`, `"-0.25s"`. At most `315576000000.999999999s` either way. |
| `google.protobuf.FieldMask` | A string of paths in lowerCamelCase, joined by commas: `"userName,address.city"`. An underscore in it is a problem. |
| A wrapper | The value it wraps, as its type reads it: `5` or `"5"` for an `Int64Value`. |
| `google.protobuf.Empty` | `{}`. |
| `google.protobuf.Struct` | An object of any JSON values. |
| `google.protobuf.Value` | Any JSON value, `null` included. |
| `google.protobuf.ListValue` | An array of any JSON values, `null` included. |
| `google.protobuf.NullValue` | `null`, or its name `NULL_VALUE`, or its number. |
| `google.protobuf.Any` | An object of `"@type"`, a type URL that names a type of the set, and the message it holds ([Any](#any)). |

`null` leaves a field unset, but sets a Value or a NullValue field
([JSON values](#json-values-struct-value-listvalue-and-nullvalue)). A key
that names no field is a problem. A Stub without `json` answers an empty
message, with every field at its default.

The reply's output type may be any message of a proto3 or a proto2 file,
with any of these fields. It may be a well-known type such as
`google.protobuf.Timestamp`, whose value is then the whole `json`, such
as `json: "1970-01-01T00:00:01.5Z"`. A Stub on a method whose
output type reaches a type of an editions file or a MessageSet, through
its fields or its extensions, is a problem at its `path`
([proto2 types](#proto2-types)).

A reply without `template` is read and encoded once, when the files load.
A reply that is not a message of the output type is a problem at the JSON
Pointer of its first value at fault, which `smock check` reports:

```text
replies.yaml: /stubs/0/response/json/tags/1: cannot be null: it is an element of the repeated field tags of replies.User
```

A reply with `template: true` is rendered as JSON, its values escaped as
in any `json` template, then read and encoded on each call. One that is
not a message of the output type gets
[Trailers-Only](metadata-and-status.md#trailers-only) INTERNAL with the
message `template failed`. The call's Journal entry says why in
`templateError`, at the JSON Pointer of the value at fault within the
Stub:

```json
{
  "at": "/response/json/userId",
  "message": "must be an integer from -9223372036854775808 to 9223372036854775807: the field user_id of replies.User has the type int64"
}
```

smock encodes the reply as protoc encodes it:

- Fields go in field-number order, and extensions among them.
- A field without presence is left out at its default. A message field,
  a member of a oneof, a proto3 `optional` field and every singular field
  of a proto2 message are written whenever they are set.
- Repeated scalars of a proto3 message are packed, unless the field says
  `packed = false`. Those of a proto2 message are packed only when the
  field says `packed = true`.
- Map entries are sorted by key, each with its key and its value.
- A group goes between its start and end tags.

It sends what a gRPC server sends:

- HEADERS with `:status` 200, `content-type: application/grpc`, the Stub's
  `headers`, its initial metadata ([Reply
  metadata](metadata-and-status.md#reply-metadata)), `smock-mock` when the
  Default Mock answered, and `date`.
- One DATA frame with the reply message, framed.
- Trailers with `grpc-status: 0`, `grpc-message` when the Stub gives a
  message ([Status and message](metadata-and-status.md#status-and-message)),
  and its `grpc.trailers`, its trailing metadata. They end the stream.

A reply larger than the client's flow-control windows goes out as the
client widens them, and the trailers follow it. It waits for window as a
response body does, in the same order as the connection's other streams
([Streams that wait](../http2.md#streams-that-wait)).

## proto2 types

gRPC Stubs serve the types of proto2 files as they serve those of proto3
files, with proto2's own rules. With this file:

```proto
syntax = "proto2";

package shipping;

message Order {
  required int64 id = 1;
  optional string note = 2;
}
```

a call to a method that takes an `Order`, with `id` 7 and no `note`, is
journaled as `{"id":7}`, and a call without `id` gets INTERNAL.

- **Presence.** Every singular field of a proto2 message has presence. It
  prints only when the message holds it, even at its default, and a reply
  writes it whenever the reply gives it, `0`, `false` and `""` included.
  Repeated fields and maps still print `[]` and `{}`. So
  `{note: {$exists: false}}` tells a call without a note from one with an
  empty note. A field's `default` option never shows, since a field the
  message leaves out does not print.
- **Required fields.** A request message that lacks a required field, at any
  depth, does not parse, as protobuf's parsers refuse it. The call gets
  Trailers-Only INTERNAL `the request message cannot be decoded`, never
  reaches the Stubs, and counts as a rejected request ([Protocol checks and
  limits](unmatched-and-refused-calls.md#protocol-checks-and-limits)). A
  static reply that lacks one is a problem at the JSON Pointer of the
  message that lacks it:

  ```text
  shipping.yaml: /stubs/0/response/json: lacks the required field id of shipping.Order
  ```

  A templated reply that lacks one gets INTERNAL `template failed`. Its
  Journal entry's `templateError` says the same.
- **Closed enums.** An enum of a proto2 file is closed: a number it does
  not define is kept as an unknown field, as protobuf keeps it, so it
  never prints. A singular field keeps the value it had, a repeated field
  leaves the number out, a map leaves the entry out, and a oneof keeps the
  member it had. Matching never sees such a number, so a condition that
  names one is a problem, and so is a reply that gives one:

  ```text
  shipping.yaml: /stubs/0/request/body/json/state: must be the name or the number of a value of shipping.State: the field state of shipping.Parcel has the type shipping.State
  ```

- **Packing.** A reply packs the repeated numbers, bools and enums of a
  proto2 message only when the field says `packed = true`, as protoc
  does. A request may send them packed or not, as for proto3.
- **Text.** A proto2 string need not be UTF-8. One that is not prints
  with U+FFFD for each bad sequence, as smock reads header values: the
  octets `61 c3 28 62` print as `"a�(b"`. Two map keys that print alike
  are one key, and the last entry wins.
- **Groups.** A group is a message field that protobuf delimits with a
  start tag and an end tag instead of a length. smock prints, matches and
  writes it as a message, under the JSON name of its field, groups nested
  in groups included. So
  `repeated group Stop = 2 { optional string city = 3; }` prints as
  `"stop":[{"city":"Paris"}]`. A group whose end tag names another field,
  or that the message ends inside, does not parse, as protobuf's parsers
  refuse it: the call gets INTERNAL
  `the request message cannot be decoded`.

### Extensions

An extension that the set declares, at the top level of a file or in a
message, is found by the type it extends and its field number, within the
Mock's set. It prints under its full name in brackets, as ProtoJSON
writes it, among the message's fields in field-number order, and only when
the message holds it, a repeated one too. A number in an extension range
that no extension of the set has is an unknown field, and is skipped.
With this file:

```proto
syntax = "proto2";

package shop;

message Order {
  optional int64 id = 1;
  extensions 100 to 199;
}

extend Order {
  optional int32 priority = 100;
}
```

a call whose `Order` has `id` 7 and `priority` 3 is journaled as
`{"id":7,"[shop.priority]":3}`, and meets the condition
`{"[shop.priority]": 3}`. A reply may set the same key,
`json: {id: 7, "[shop.priority]": 3}`, and is encoded as protoc encodes
it. An extension declared in a message is named by its full name too,
such as `[shop.Gift.gift]` for an extension `gift` declared in
`shop.Gift`. Templates read one with brackets:
`${body['[shop.priority]']}`.

A key in brackets, in a condition or a reply, must name an extension of
the set that extends the type at its place:

```text
shop.yaml: /stubs/0/request/body/json/[shop.urgency]: is not an extension of shop.Order: the Descriptor set has no extension shop.urgency
shop.yaml: /stubs/1/request/body/json/[shop.priority]: is not an extension of shop.Itinerary: shop.priority extends shop.Order
```

An extension follows the syntax of the file that declares it. One that a
proto3 file declares, as a custom option is, holds UTF-8 strings and
packs its repeated numbers, though the message it extends is proto2.

### What is not served

Three kinds of type are not served:

- A type of an editions file, such as a file with `edition = "2023"`, an
  enum included. Editions come in a later spec.
- A type that an extension declared in an editions file extends, since
  what such an extension is depends on features that smock does not read.
- A MessageSet, a message with the option `message_set_wire_format`,
  whose extensions use another wire form.

Each is a problem at the `path` of a Stub whose method's input or output
type is one, or reaches one through its fields or its extensions:

```text
shipping.yaml: /stubs/0/request/path: the input type labels.Label is not served yet: labels.proto, which defines it, is an editions file, and editions come in a later spec
shipping.yaml: /stubs/1/request/path: the input type shipping.Crate is not served: shipping.Bag, a type it reaches, is a MessageSet, whose extensions use another wire form, and smock serves no MessageSet types
```

The check is per method, so a set whose editions files and MessageSets no
Stub's method reaches loads quietly. A call to such a method never reaches a
Stub: it gets UNIMPLEMENTED ([Unmatched
calls](unmatched-and-refused-calls.md#unmatched-calls)), or INTERNAL when
its message is, or holds, a value of such a type, which smock does not
decode.
