// The well-known types that ProtoJSON prints in forms of their own
// (https://protobuf.dev/programming-guides/json/): Timestamp, Duration and
// FieldMask as strings, and the wrappers as the values they wrap. Empty is
// printed as the object it is, `{}`. Any, Struct, Value, ListValue and
// NullValue are not served yet. A type is known by its full name, and a
// Timestamp, a Duration and a FieldMask are read and written by their field
// numbers, as protobuf's own code does.

///|
/// A well-known type that ProtoJSON prints in a form of its own, not as an
/// object of its fields.
priv enum WellKnown {
  /// google.protobuf.Timestamp: a date and time in UTC, as a string such as
  /// `"1970-01-01T00:00:01.500Z"`.
  Timestamp
  /// google.protobuf.Duration: a string of seconds, then `s`, such as
  /// `"1.500s"`.
  Duration
  /// google.protobuf.FieldMask: a string of paths in lowerCamelCase, joined
  /// by commas, such as `"userName,address.city"`.
  FieldMask
  /// A wrapper, such as google.protobuf.Int32Value: the value of its field
  /// `value`, numbered 1, whose index in the message's fields this is.
  Wrapper(Int32)
}

///|
/// The earliest Timestamp, 0001-01-01T00:00:00Z, in seconds since the epoch.
let min_timestamp_seconds : Int64 = -62135596800L

///|
/// The latest second of a Timestamp, 9999-12-31T23:59:59Z, in seconds since
/// the epoch.
let max_timestamp_seconds : Int64 = 253402300799L

///|
/// The largest number of seconds of a Duration, either way: about 10,000
/// years.
let max_duration_seconds : Int64 = 315576000000L

///|
/// The form of its own in which ProtoJSON prints `message`, or `None` for a
/// message that it prints as an object of its fields, Empty included. A
/// wrapper that has no field numbered 1 is printed as an object.
fn well_known_form(message : MessageDescriptor) -> WellKnown? {
  let name = message.full_name
  if !name.has_prefix("google.protobuf.") {
    return None
  }
  match name {
    "google.protobuf.Timestamp" => Some(Timestamp)
    "google.protobuf.Duration" => Some(Duration)
    "google.protobuf.FieldMask" => Some(FieldMask)
    "google.protobuf.DoubleValue"
    | "google.protobuf.FloatValue"
    | "google.protobuf.Int64Value"
    | "google.protobuf.UInt64Value"
    | "google.protobuf.Int32Value"
    | "google.protobuf.UInt32Value"
    | "google.protobuf.BoolValue"
    | "google.protobuf.StringValue"
    | "google.protobuf.BytesValue" => {
      let index = message.field_index(1)
      if index >= 0 {
        Some(Wrapper(index))
      } else {
        None
      }
    }
    _ => None
  }
}

///|
/// Whether `full_name`, a full name without a leading dot, is one of the
/// well-known types that `decode_json` and `DescriptorSet::encode_json` do
/// not serve yet: Any, Struct, Value, ListValue and NullValue, whose JSON
/// forms hold any JSON value or a message of another type.
pub fn is_unserved_well_known(full_name : String) -> Bool {
  full_name.has_prefix("google.protobuf.") &&
  full_name
  is ("google.protobuf.Any"
  | "google.protobuf.Struct"
  | "google.protobuf.Value"
  | "google.protobuf.ListValue"
  | "google.protobuf.NullValue")
}

///|
/// Prints to `out` the message of the type `message`, a well-known type
/// whose form is `form`, whose records are `records`, merged in order,
/// `depth` messages deep, as ProtoJSON prints it. A Timestamp's or a
/// Duration's last seconds and nanos win, and a FieldMask's paths are
/// joined, as protobuf's parsers merge them.
///
/// Raises `DecodeError` for a value that ProtoJSON cannot print: a
/// Timestamp or a Duration out of its range, or a Duration whose seconds
/// and nanos have opposite signs, and a FieldMask path that has no
/// lowerCamelCase form.
fn DescriptorSet::print_well_known(
  self : DescriptorSet,
  out : @buffer.Buffer,
  message : MessageDescriptor,
  form : WellKnown,
  records : Array[BytesView],
  depth : Int32,
) -> Unit raise DecodeError {
  let position = records[0].start_offset()
  match form {
    Timestamp | Duration => {
      let mut seconds = 0L
      let mut nanos = 0
      for r in 0..<records.length() {
        let reader = Reader(records[r])
        while !reader.at_end() {
          let number = reader.tag()
          match (number, reader.wire_type()) {
            (1, Varint) => seconds = reader.varint().reinterpret_as_int64()
            (2, Varint) =>
              nanos = reader.varint().to_uint().reinterpret_as_int()
            _ => reader.skip()
          }
        }
      }
      if form is Timestamp {
        if !is_timestamp(seconds, nanos) {
          raise DecodeError(
            position~,
            message="the Timestamp of \{seconds} seconds and \{nanos} nanoseconds is outside the range from 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z that ProtoJSON prints",
          )
        }
        write_timestamp(out, seconds, nanos)
      } else {
        if !is_duration(seconds, nanos) {
          raise DecodeError(
            position~,
            message="the Duration of \{seconds} seconds and \{nanos} nanoseconds is outside the range from -315576000000.999999999s to 315576000000.999999999s that ProtoJSON prints, or its seconds and nanoseconds have opposite signs",
          )
        }
        write_duration(out, seconds, nanos)
      }
    }
    FieldMask => {
      out.write_byte(b'"')
      let mut first = true
      for r in 0..<records.length() {
        let reader = Reader(records[r])
        while !reader.at_end() {
          let number = reader.tag()
          guard number == 1 && reader.wire_type() is Len else {
            reader.skip()
            continue
          }
          let at = reader.pos
          let path = reader.length_delimited()
          if !first {
            out.write_byte(b',')
          }
          first = false
          if !write_path(out, path) {
            raise reader.error(
              at, "a path of the FieldMask has no lowerCamelCase form, which ProtoJSON prints: a path may hold lower-case letters, digits, dots, and underscores each followed by a lower-case letter",
            )
          }
        }
      }
      out.write_byte(b'"')
    }
    Wrapper(index) => {
      let values = scan(message, records)
      self.print_value(out, message.fields[index], values[index], depth)
    }
  }
}

///|
/// Whether `seconds` and `nanos` are a Timestamp that ProtoJSON prints:
/// from 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z.
fn is_timestamp(seconds : Int64, nanos : Int32) -> Bool {
  seconds >= min_timestamp_seconds &&
  seconds <= max_timestamp_seconds &&
  nanos >= 0 &&
  nanos <= 999_999_999
}

///|
/// Whether `seconds` and `nanos` are a Duration that ProtoJSON prints: at
/// most 315,576,000,000 seconds and 999,999,999 nanoseconds either way,
/// and not of opposite signs.
fn is_duration(seconds : Int64, nanos : Int32) -> Bool {
  seconds >= -max_duration_seconds &&
  seconds <= max_duration_seconds &&
  nanos >= -999_999_999 &&
  nanos <= 999_999_999 &&
  !(seconds > 0 && nanos < 0) &&
  !(seconds < 0 && nanos > 0)
}

///|
/// Writes the Timestamp `seconds` and `nanos` after the epoch, one that
/// `is_timestamp` accepts, as a JSON string, as ProtoJSON prints it: the
/// date and time in UTC, with 0, 3, 6 or 9 fractional digits, then `Z`,
/// such as `"1970-01-01T00:00:01.500Z"`.
fn write_timestamp(
  out : @buffer.Buffer,
  seconds : Int64,
  nanos : Int32,
) -> Unit {
  // The days since 1970-01-01, and the seconds into the day.
  let mut days = seconds / 86400
  let mut time = seconds % 86400
  if time < 0 {
    time = time + 86400
    days = days - 1
  }
  // The civil date of the day, in the proleptic Gregorian calendar: counted
  // in eras of 400 years from 0000-03-01, so that a leap day ends a year.
  let from_era_start = days + 719468
  let era = (if from_era_start >= 0 {
      from_era_start
    } else {
      from_era_start - 146096
    }) /
    146097
  let day_of_era = from_era_start - era * 146097
  let year_of_era = (
      day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096
    ) /
    365
  let day_of_year = day_of_era -
    (365 * year_of_era + year_of_era / 4 - year_of_era / 100)
  // Months from March, 0 to 11.
  let month_index = (5L * day_of_year + 2) / 153
  let day = day_of_year - (153L * month_index + 2) / 5 + 1
  let month = if month_index < 10L { month_index + 3 } else { month_index - 9 }
  let year = year_of_era + era * 400 + (if month <= 2 { 1L } else { 0L })
  out.write_byte(b'"')
  write_padded(out, year, 4)
  out.write_byte(b'-')
  write_padded(out, month, 2)
  out.write_byte(b'-')
  write_padded(out, day, 2)
  out.write_byte(b'T')
  write_padded(out, time / 3600, 2)
  out.write_byte(b':')
  write_padded(out, time / 60 % 60, 2)
  out.write_byte(b':')
  write_padded(out, time % 60, 2)
  write_fraction(out, nanos)
  out.write_bytes(b"Z\"")
}

///|
/// Writes the Duration `seconds` and `nanos`, one that `is_duration`
/// accepts, as a JSON string, as ProtoJSON prints it: a `-` when it is
/// negative, the seconds, 0, 3, 6 or 9 fractional digits, then `s`, such as
/// `"-1.500s"`.
fn write_duration(out : @buffer.Buffer, seconds : Int64, nanos : Int32) -> Unit {
  out.write_byte(b'"')
  if seconds < 0 || nanos < 0 {
    out.write_byte(b'-')
  }
  write_unsigned(
    out,
    (if seconds < 0 { -seconds } else { seconds }).reinterpret_as_uint64(),
  )
  write_fraction(out, if nanos < 0 { -nanos } else { nanos })
  out.write_bytes(b"s\"")
}

///|
/// Writes `nanos`, from 0 to 999,999,999 nanoseconds, as ProtoJSON prints
/// a fraction of a second: nothing for 0, or else `.` and 3, 6 or 9
/// digits, the fewest that hold it.
fn write_fraction(out : @buffer.Buffer, nanos : Int32) -> Unit {
  if nanos == 0 {
    return
  }
  out.write_byte(b'.')
  let value = nanos.to_int64()
  if nanos % 1_000_000 == 0 {
    write_padded(out, value / 1_000_000, 3)
  } else if nanos % 1000 == 0 {
    write_padded(out, value / 1000, 6)
  } else {
    write_padded(out, value, 9)
  }
}

///|
/// Writes `value`, 0 or more, in decimal, with zeros before it to make
/// `width` digits at least.
fn write_padded(out : @buffer.Buffer, value : Int64, width : Int32) -> Unit {
  let mut unit = 1L
  for _ in 1..<width {
    unit = unit * 10
  }
  while value / unit >= 10 {
    unit = unit * 10
  }
  while unit > 0 {
    out.write_byte((0x30L + value / unit % 10).to_byte())
    unit = unit / 10
  }
}

///|
/// Writes `path`, a path of a FieldMask, in lowerCamelCase, as ProtoJSON
/// prints it: an underscore and the lower-case letter after it become that
/// letter in upper case. Returns false, with part of it written, when it
/// has no such form that reads back as it: it holds an octet other than a
/// lower-case letter, a digit, a dot or an underscore, or an underscore
/// that a lower-case letter does not follow.
fn write_path(out : @buffer.Buffer, path : BytesView) -> Bool {
  let length = path.length()
  let mut i = 0
  while i < length {
    let octet = path[i]
    if octet == b'_' {
      guard i + 1 < length && path[i + 1] >= b'a' && path[i + 1] <= b'z' else {
        return false
      }
      out.write_byte(path[i + 1] - b'a' + b'A')
      i = i + 2
      continue
    }
    guard (octet >= b'a' && octet <= b'z') ||
      (octet >= b'0' && octet <= b'9') ||
      octet == b'.' else {
      return false
    }
    out.write_byte(octet)
    i = i + 1
  }
  true
}
