// The well-known types that ProtoJSON prints in forms of their own,
// Timestamp, Duration, FieldMask, the wrappers and Empty, decoded into
// smock's decoded form through the public interface. The set and the
// messages are protoc's, built from fixtures/protobuf/wellknown/ and
// protobuf's files beside it (scripts/gen-protobuf-fixtures.sh), so the
// codec is never checked against itself.

///|
test "the ticket's example: a Timestamp 1.5 s after the epoch and a Duration of 1.5 s" {
  inspect(
    decoded(wellknown_set, "wellknown.Lease", fixture(lease)),
    content=(
      #|{"createdAt":"1970-01-01T00:00:01.500Z","ttl":"1.500s"}
    ),
  )
}

///|
test "every type in its printed form: Timestamp, Duration, FieldMask, each wrapper as its value, Empty as {}, and Timestamps and Durations in a list and a map, at the ends of their ranges" {
  inspect(
    decoded(wellknown_set, "wellknown.Known", fixture(known)),
    content=(
      #|{"at":"2025-11-14T09:30:00.123456Z","ttl":"-3.250s","mask":"userName,address.cityName","aDouble":1.5,"aFloat":9.99,"anInt64":9223372036854775807,"aUint64":18446744073709551615,"anInt32":-2147483648,"aUint32":4294967295,"aBool":true,"aString":"Tom","aBytes":"+/8=","nothing":{},"history":["0001-01-01T00:00:00Z","9999-12-31T23:59:59.999999999Z"],"limits":{"read":"315576000000.999999999s","write":"0.000001s"},"ids":[1,0]}
    ),
  )
}

///|
test "a message of a well-known type is printed when it is set, even at its default; one left out is not" {
  inspect(
    decoded(wellknown_set, "wellknown.Known", fixture(known_defaults)),
    content=(
      #|{"at":"1970-01-01T00:00:00Z","ttl":"0s","mask":"","aDouble":0,"aFloat":0,"anInt64":0,"aUint64":0,"anInt32":0,"aUint32":0,"aBool":false,"aString":"","aBytes":"","nothing":{},"history":[],"limits":{},"ids":[]}
    ),
  )
  inspect(
    decoded(wellknown_set, "wellknown.Known", b""),
    content=(
      #|{"history":[],"limits":{},"ids":[]}
    ),
  )
}

///|
/// A Timestamp or a Duration of `seconds` and `nanos`, in protobuf's binary
/// encoding, written by hand: each field that is not 0.
fn seconds_and_nanos(seconds : Int64, nanos : Int32) -> Bytes {
  nested(w => {
    if seconds != 0 {
      varint_field(w, 1, seconds.reinterpret_as_uint64())
    }
    if nanos != 0 {
      varint_field(w, 2, nanos.to_int64().reinterpret_as_uint64())
    }
  })
}

///|
test "a well-known type is printed in its form as a method's whole input too" {
  let decode = (name, input) => {
    decoded(wellknown_set, "google.protobuf.\{name}", input)
  }
  let lines = [
    decode("Timestamp", seconds_and_nanos(1, 500_000_000)),
    decode("Timestamp", b""),
    decode("Duration", seconds_and_nanos(0, -500_000_000)),
    decode("Duration", seconds_and_nanos(-1, 0)),
    decode(
      "FieldMask",
      nested(w => {
        string_field(w, 1, "a")
        string_field(w, 1, "b_c.d_e")
      }),
    ),
    decode(
      "FloatValue",
      nested(w => {
        w.tag(1, I32)
        w.fixed32(Float::from_double(0.1).reinterpret_as_uint())
      }),
    ),
    decode("StringValue", nested(w => string_field(w, 1, "Tom"))),
    decode("BytesValue", b""),
    decode("Empty", b""),
  ]
  inspect(
    lines.join("\n"),
    content=(
      #|"1970-01-01T00:00:01.500Z"
      #|"1970-01-01T00:00:00Z"
      #|"-0.500s"
      #|"-1s"
      #|"a,bC.dE"
      #|0.1
      #|"Tom"
      #|""
      #|{}
    ),
  )
}

///|
test "a Timestamp and a Duration print 0, 3, 6 or 9 fractional digits, the fewest that hold their nanos, and dates before the epoch and in leap years print in UTC" {
  let lines = []
  for
    case in [
      (0L, 1),
      (0L, 10_000_000),
      (0L, 120_000),
      (0L, 999_999_999),
      (-1L, 0),
      (-1L, 999_000_000),
      (951782400L, 0),
      (951868799L, 0),
      (1709251199L, 0),
      (-2208988800L, 0),
      (4107542400L, 0),
    ] {
    let (seconds, nanos) = case
    let input = seconds_and_nanos(seconds, nanos)
    lines.push(
      "\{seconds} \{nanos}: \{decoded(wellknown_set, "google.protobuf.Timestamp", input)} \{decoded(wellknown_set, "google.protobuf.Duration", input)}",
    )
  }
  inspect(
    lines.join("\n"),
    content=(
      #|0 1: "1970-01-01T00:00:00.000000001Z" "0.000000001s"
      #|0 10000000: "1970-01-01T00:00:00.010Z" "0.010s"
      #|0 120000: "1970-01-01T00:00:00.000120Z" "0.000120s"
      #|0 999999999: "1970-01-01T00:00:00.999999999Z" "0.999999999s"
      #|-1 0: "1969-12-31T23:59:59Z" "-1s"
      #|-1 999000000: "1969-12-31T23:59:59.999Z" error: octet 0: the Duration of seconds -1 and nanos 999000000 is outside the range from -315576000000.999999999s to 315576000000.999999999s that ProtoJSON prints, or its seconds and nanos have opposite signs
      #|951782400 0: "2000-02-29T00:00:00Z" "951782400s"
      #|951868799 0: "2000-02-29T23:59:59Z" "951868799s"
      #|1709251199 0: "2024-02-29T23:59:59Z" "1709251199s"
      #|-2208988800 0: "1900-01-01T00:00:00Z" "-2208988800s"
      #|4107542400 0: "2100-03-01T00:00:00Z" "4107542400s"
    ),
  )
}

///|
test "a Timestamp or a Duration out of its range, and a FieldMask path with no lowerCamelCase form, cannot be printed; a Duration at the end of its range can" {
  let timestamp = input => {
    decoded(wellknown_set, "google.protobuf.Timestamp", input)
  }
  let duration = input => {
    decoded(wellknown_set, "google.protobuf.Duration", input)
  }
  let mask = path => {
    decoded(
      wellknown_set,
      "google.protobuf.FieldMask",
      nested(w => string_field(w, 1, path)),
    )
  }
  let lines = [
    timestamp(seconds_and_nanos(-62135596801, 0)),
    timestamp(seconds_and_nanos(253402300800, 0)),
    timestamp(seconds_and_nanos(0, -1)),
    timestamp(seconds_and_nanos(0, 1_000_000_000)),
    duration(seconds_and_nanos(315576000001, 0)),
    duration(seconds_and_nanos(-315576000001, 0)),
    duration(seconds_and_nanos(0, 1_000_000_000)),
    duration(seconds_and_nanos(1, -1)),
    duration(seconds_and_nanos(-315576000000, -999_999_999)),
    mask("fooBar"),
    mask("foo__bar"),
    mask("foo_3"),
    mask("foo_"),
    mask("été"),
    mask("a-b"),
  ]
  inspect(
    lines.join("\n"),
    content=(
      #|error: octet 0: the Timestamp of seconds -62135596801 and nanos 0 is outside the range from 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z that ProtoJSON prints
      #|error: octet 0: the Timestamp of seconds 253402300800 and nanos 0 is outside the range from 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z that ProtoJSON prints
      #|error: octet 0: the Timestamp of seconds 0 and nanos -1 is outside the range from 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z that ProtoJSON prints
      #|error: octet 0: the Timestamp of seconds 0 and nanos 1000000000 is outside the range from 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z that ProtoJSON prints
      #|error: octet 0: the Duration of seconds 315576000001 and nanos 0 is outside the range from -315576000000.999999999s to 315576000000.999999999s that ProtoJSON prints, or its seconds and nanos have opposite signs
      #|error: octet 0: the Duration of seconds -315576000001 and nanos 0 is outside the range from -315576000000.999999999s to 315576000000.999999999s that ProtoJSON prints, or its seconds and nanos have opposite signs
      #|error: octet 0: the Duration of seconds 0 and nanos 1000000000 is outside the range from -315576000000.999999999s to 315576000000.999999999s that ProtoJSON prints, or its seconds and nanos have opposite signs
      #|error: octet 0: the Duration of seconds 1 and nanos -1 is outside the range from -315576000000.999999999s to 315576000000.999999999s that ProtoJSON prints, or its seconds and nanos have opposite signs
      #|"-315576000000.999999999s"
      #|error: octet 1: a path of the FieldMask has no lowerCamelCase form, which ProtoJSON prints: a path may hold lower-case letters, digits, dots, and underscores each followed by a lower-case letter
      #|error: octet 1: a path of the FieldMask has no lowerCamelCase form, which ProtoJSON prints: a path may hold lower-case letters, digits, dots, and underscores each followed by a lower-case letter
      #|error: octet 1: a path of the FieldMask has no lowerCamelCase form, which ProtoJSON prints: a path may hold lower-case letters, digits, dots, and underscores each followed by a lower-case letter
      #|error: octet 1: a path of the FieldMask has no lowerCamelCase form, which ProtoJSON prints: a path may hold lower-case letters, digits, dots, and underscores each followed by a lower-case letter
      #|error: octet 1: a path of the FieldMask has no lowerCamelCase form, which ProtoJSON prints: a path may hold lower-case letters, digits, dots, and underscores each followed by a lower-case letter
      #|error: octet 1: a path of the FieldMask has no lowerCamelCase form, which ProtoJSON prints: a path may hold lower-case letters, digits, dots, and underscores each followed by a lower-case letter
    ),
  )
}

///|
test "the last seconds and nanos of a Timestamp win, and the paths of a FieldMask sent in two records are joined, as protobuf's parsers merge them" {
  let lease = nested(w => {
    message_field(w, 1, seconds_and_nanos(5, 0))
    message_field(w, 1, nested(w => varint_field(w, 2, 1_000_000)))
    message_field(w, 1, nested(w => varint_field(w, 1, 1)))
  })
  inspect(
    decoded(wellknown_set, "wellknown.Lease", lease),
    content=(
      #|{"createdAt":"1970-01-01T00:00:01.001Z"}
    ),
  )
  let known = nested(w => {
    message_field(w, 3, nested(w => string_field(w, 1, "a")))
    message_field(w, 3, nested(w => string_field(w, 1, "b")))
  })
  inspect(
    member_text(decoded(wellknown_set, "wellknown.Known", known), "mask"),
    content=(
      #|"a,b"
    ),
  )
}

///|
/// `text`, JSON text, encoded as a message of `name`, a type of
/// fixtures/protobuf/wellknown/, protobuf's types included, in hex, or the
/// error that stops it. JSON text keeps the digits of an integer that a
/// double does not hold.
fn known_reply(name : String, text : String) -> String {
  let json = @json.parse(text) catch { err => abort("not JSON: \{err}") }
  encoded(wellknown_set, name, json)
}

///|
test "replies in the printed forms have protoc's bytes, and so do replies in every other form ProtoJSON reads: offsets, other fraction lengths, numbers as strings, URL-safe base64 and proto names" {
  let expected = @hex.encode(fixture(known))
  assert_eq(
    known_reply(
      "wellknown.Known",
      (
        #|{"at":"2025-11-14T09:30:00.123456Z","ttl":"-3.250s","mask":"userName,address.cityName","aDouble":1.5,"aFloat":9.99,"anInt64":9223372036854775807,"aUint64":18446744073709551615,"anInt32":-2147483648,"aUint32":4294967295,"aBool":true,"aString":"Tom","aBytes":"+/8=","nothing":{},"history":["0001-01-01T00:00:00Z","9999-12-31T23:59:59.999999999Z"],"limits":{"read":"315576000000.999999999s","write":"0.000001s"},"ids":[1,0]}
      ),
    ),
    expected,
  )
  assert_eq(
    known_reply(
      "wellknown.Known",
      (
        #|{"at":"2025-11-14T18:30:00.123456+09:00","ttl":"-3.25s","mask":"userName,address.cityName",
        #| "a_double":"1.5","a_float":"9.99","an_int64":"9223372036854775807","a_uint64":"18446744073709551615",
        #| "an_int32":"-2147483648","a_uint32":4.294967295e9,"a_bool":true,"a_string":"Tom","a_bytes":"-_8",
        #| "nothing":{},"history":["0001-01-01T01:00:00+01:00","9999-12-31T22:59:59.999999999-01:00"],
        #| "limits":{"write":"0.000001000s","read":"315576000000.999999999s"},"ids":["1",0]}
      ),
    ),
    expected,
  )
  // Each message present, at its default, and Empty.
  assert_eq(
    known_reply(
      "wellknown.Known",
      (
        #|{"at":"1970-01-01T00:00:00Z","ttl":"0s","mask":"","aDouble":0,"aFloat":0,"anInt64":0,"aUint64":0,
        #| "anInt32":0,"aUint32":0,"aBool":false,"aString":"","aBytes":"","nothing":{}}
      ),
    ),
    @hex.encode(fixture(known_defaults)),
  )
  assert_eq(
    known_reply(
      "wellknown.Known",
      (
        #|{"at":"1970-01-01T01:00:00+01:00","ttl":"-0.000s","mask":"","aDouble":"0","aFloat":"0","anInt64":"0",
        #| "aUint64":"0","anInt32":0,"aUint32":0,"aBool":false,"aString":"","aBytes":"","nothing":{}}
      ),
    ),
    @hex.encode(fixture(known_defaults)),
  )
}

///|
test "null leaves a field of a well-known type unset, and the ticket's example has protoc's bytes" {
  assert_eq(
    known_reply(
      "wellknown.Lease",
      (
        #|{"createdAt":"1970-01-01T00:00:01.500Z","ttl":"1.500s"}
      ),
    ),
    @hex.encode(fixture(lease)),
  )
  assert_eq(
    known_reply(
      "wellknown.Lease",
      (
        #|{"created_at":"1970-01-01T00:00:01.5Z","ttl":"1.5s"}
      ),
    ),
    @hex.encode(fixture(lease)),
  )
  inspect(
    known_reply(
      "wellknown.Known",
      (
        #|{"at":null,"ttl":null,"mask":null,"aFloat":null,"nothing":null}
      ),
    ),
    content="",
  )
}

///|
test "a well-known type as a method's whole reply is read in its form too" {
  let reply = (name, text) => known_reply("google.protobuf.\{name}", text)
  let lines = [
    reply("Timestamp", "\"1970-01-01T00:00:01.5Z\"") ==
    @hex.encode(seconds_and_nanos(1, 500_000_000)),
    reply("Duration", "\"-0.5s\"") ==
    @hex.encode(seconds_and_nanos(0, -500_000_000)),
    reply("Duration", "\"-1s\"") == @hex.encode(seconds_and_nanos(-1, 0)),
    reply("FieldMask", "\"a,bC.dE\"") ==
    @hex.encode(
      nested(w => {
        string_field(w, 1, "a")
        string_field(w, 1, "b_c.d_e")
      }),
    ),
    reply("FloatValue", "0.1") ==
    @hex.encode(
      nested(w => {
        w.tag(1, I32)
        w.fixed32(Float::from_double(0.1).reinterpret_as_uint())
      }),
    ),
    reply("StringValue", "\"Tom\"") ==
    @hex.encode(nested(w => string_field(w, 1, "Tom"))),
    reply("BoolValue", "false") == "",
    reply("Empty", "{}") == "",
  ]
  inspect(lines, content="[true, true, true, true, true, true, true, true]")
}

///|
test "a value that ProtoJSON does not read as its type, or that is out of its range, is not a message of the type" {
  let lines = []
  for
    case in [
      ("at", "\"0000-01-01T00:00:00Z\""),
      ("at", "\"10000-01-01T00:00:00Z\""),
      ("at", "\"9999-12-31T23:59:59-01:00\""),
      ("at", "\"0001-01-01T00:00:00+00:01\""),
      ("at", "\"1970-01-01T00:00:00z\""),
      ("at", "\"1970-01-01t00:00:00Z\""),
      ("at", "\"1970-01-01 00:00:00Z\""),
      ("at", "\"1970-01-01T00:00:00\""),
      ("at", "\"1970-01-01T00:00:00.Z\""),
      ("at", "\"1970-01-01T00:00:00.0000000001Z\""),
      ("at", "\"1970-02-29T00:00:00Z\""),
      ("at", "\"1970-13-01T00:00:00Z\""),
      ("at", "\"1970-01-01T24:00:00Z\""),
      ("at", "\"1970-01-01T00:00:60Z\""),
      ("at", "\"1970-01-01T00:00:00+24:00\""),
      ("at", "\"1970-01-01T00:00:00+0900\""),
      ("at", "0"),
      ("at", "{\"seconds\":1}"),
      ("ttl", "\"1\""),
      ("ttl", "\"1.5\""),
      ("ttl", "\"315576000001s\""),
      ("ttl", "\"-315576000001s\""),
      ("ttl", "\"1.0000000001s\""),
      ("ttl", "\"+1s\""),
      ("ttl", "\".5s\""),
      ("ttl", "\"1.s\""),
      ("ttl", "\"1 s\""),
      ("ttl", "1.5"),
      ("mask", "\"user_name\""),
      ("mask", "\"a b\""),
      ("mask", "[\"a\"]"),
      ("anInt32", "2147483648"),
      ("aFloat", "1e39"),
      ("aBool", "\"true\""),
      ("aBytes", "\"*\""),
      ("nothing", "{\"x\":1}"),
      ("history", "[null]"),
      ("limits", "{\"a\":\"1\"}"),
      ("ids", "[\"x\"]"),
    ] {
    let (key, value) = case
    lines.push(
      "\{key} \{value} -> \{known_reply("wellknown.Known", "{\"\{key}\":\{value}}")}",
    )
  }
  lines.push(
    "Timestamp null -> \{known_reply("google.protobuf.Timestamp", "null")}",
  )
  lines.push(
    "Int64Value null -> \{known_reply("google.protobuf.Int64Value", "null")}",
  )
  inspect(
    lines.join("\n"),
    content=(
      #|at "0000-01-01T00:00:00Z" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "10000-01-01T00:00:00Z" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "9999-12-31T23:59:59-01:00" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "0001-01-01T00:00:00+00:01" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-01-01T00:00:00z" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-01-01t00:00:00Z" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-01-01 00:00:00Z" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-01-01T00:00:00" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-01-01T00:00:00.Z" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-01-01T00:00:00.0000000001Z" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-02-29T00:00:00Z" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-13-01T00:00:00Z" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-01-01T24:00:00Z" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-01-01T00:00:60Z" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-01-01T00:00:00+24:00" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at "1970-01-01T00:00:00+0900" -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at 0 -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|at {"seconds":1} -> error: /at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|ttl "1" -> error: /ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Known has the type google.protobuf.Duration
      #|ttl "1.5" -> error: /ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Known has the type google.protobuf.Duration
      #|ttl "315576000001s" -> error: /ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Known has the type google.protobuf.Duration
      #|ttl "-315576000001s" -> error: /ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Known has the type google.protobuf.Duration
      #|ttl "1.0000000001s" -> error: /ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Known has the type google.protobuf.Duration
      #|ttl "+1s" -> error: /ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Known has the type google.protobuf.Duration
      #|ttl ".5s" -> error: /ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Known has the type google.protobuf.Duration
      #|ttl "1.s" -> error: /ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Known has the type google.protobuf.Duration
      #|ttl "1 s" -> error: /ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Known has the type google.protobuf.Duration
      #|ttl 1.5 -> error: /ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Known has the type google.protobuf.Duration
      #|mask "user_name" -> error: /mask: must be a string of field paths in lowerCamelCase, joined by commas, such as "userName,address.city": the field mask of wellknown.Known has the type google.protobuf.FieldMask
      #|mask "a b" -> error: /mask: must be a string of field paths in lowerCamelCase, joined by commas, such as "userName,address.city": the field mask of wellknown.Known has the type google.protobuf.FieldMask
      #|mask ["a"] -> error: /mask: must be a string of field paths in lowerCamelCase, joined by commas, such as "userName,address.city": the field mask of wellknown.Known has the type google.protobuf.FieldMask
      #|anInt32 2147483648 -> error: /anInt32: must be an integer from -2147483648 to 2147483647: the field an_int32 of wellknown.Known has the type google.protobuf.Int32Value
      #|aFloat 1e39 -> error: /aFloat: must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity": the field a_float of wellknown.Known has the type google.protobuf.FloatValue
      #|aBool "true" -> error: /aBool: must be true or false: the field a_bool of wellknown.Known has the type google.protobuf.BoolValue
      #|aBytes "*" -> error: /aBytes: must be a string in base64, standard or URL-safe, with or without padding: the field a_bytes of wellknown.Known has the type google.protobuf.BytesValue
      #|nothing {"x":1} -> error: /nothing/x: is not a field of google.protobuf.Empty
      #|history [null] -> error: /history/0: cannot be null: it is an element of the repeated field history of wellknown.Known
      #|limits {"a":"1"} -> error: /limits/a: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the values of the map field limits of wellknown.Known have the type google.protobuf.Duration
      #|ids ["x"] -> error: /ids/0: must be an integer from -9223372036854775808 to 9223372036854775807: the elements of the field ids of wellknown.Known have the type google.protobuf.Int64Value
      #|Timestamp null -> error: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the message is a google.protobuf.Timestamp
      #|Int64Value null -> error: must be an integer from -9223372036854775808 to 9223372036854775807: the message is a google.protobuf.Int64Value
    ),
  )
}
