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
