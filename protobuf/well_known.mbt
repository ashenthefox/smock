// The well-known types that ProtoJSON prints in forms of their own
// (https://protobuf.dev/programming-guides/json/): Timestamp, Duration and
// FieldMask as strings, the wrappers as the values they wrap, Struct,
// Value and ListValue as the JSON values they hold, and NullValue as
// `null`. Empty is printed as the object it is, `{}`. A type is known by
// its full name, and a Timestamp, a Duration and a FieldMask are read and
// written by their field numbers, as protobuf's own code does.

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
  /// google.protobuf.Struct: an object, the map of Values that is its field
  /// `fields`, numbered 1, whose index in the message's fields this is.
  Struct(Int32)
  /// google.protobuf.ListValue: an array, the list of Values that is its
  /// field `values`, numbered 1, whose index in the message's fields this
  /// is.
  ListValue(Int32)
  /// google.protobuf.Value: the JSON value that the member of its oneof
  /// `kind` holds: `null`, a number, a string, a bool, a Struct or a
  /// ListValue.
  Value
  /// google.protobuf.Any: an object of its type URL as `@type`, then the
  /// message it holds, a type of the set: its fields, or its form as
  /// `value` when it is a well-known type that has one.
  Any
}

///|
/// How ProtoJSON writes a message of a type: what a value of it is, and so
/// what a condition on it is checked as.
#derive(Debug, Eq)
pub(all) enum JsonForm {
  /// An object of its fields, under their JSON names, Empty included.
  Fields
  /// A string or a number, as `DescriptorSet::printed_message` checks it:
  /// a Timestamp, a Duration, a FieldMask or a wrapper.
  Scalar
  /// google.protobuf.Struct: an object whose keys are data, and whose
  /// members are any JSON values, as a Value is.
  Struct
  /// google.protobuf.ListValue: an array of any JSON values, as a Value
  /// is.
  ListValue
  /// google.protobuf.Value: any JSON value. Its object is a Struct, its
  /// array a ListValue.
  Value
  /// google.protobuf.Any: an object of the type URL of the message it
  /// holds, a type of the set, as `@type`, and that message: its fields, or
  /// its form as `value` when it is a well-known type that has one, as a
  /// `json_form` other than `Fields` says.
  Any
}

///|
/// How ProtoJSON writes a message of this type.
pub fn MessageDescriptor::json_form(self : MessageDescriptor) -> JsonForm {
  match well_known_form(self) {
    None => Fields
    Some(Timestamp | Duration | FieldMask | Wrapper(_)) => Scalar
    Some(Struct(_)) => Struct
    Some(ListValue(_)) => ListValue
    Some(Value) => Value
    Some(Any) => Any
  }
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
    "google.protobuf.Struct" | "google.protobuf.ListValue" => {
      let index = message.field_index(1)
      guard index >= 0 &&
        message.fields[index].label is Repeated &&
        message.fields[index].type_ is Message else {
        return None
      }
      if name == "google.protobuf.Struct" {
        Some(Struct(index))
      } else {
        Some(ListValue(index))
      }
    }
    "google.protobuf.Value" => Some(Value)
    "google.protobuf.Any" => Some(Any)
    _ => None
  }
}

///|
/// Prints to `out` the message of the type `message`, a well-known type
/// whose form is `form`, whose records are `records`, merged in order,
/// `depth` messages deep, as ProtoJSON prints it. A Timestamp's or a
/// Duration's last seconds and nanos win, and a FieldMask's paths are
/// joined, as protobuf's parsers merge them. A Struct prints as a map is
/// printed, in key order, a ListValue as a list, a Value as the JSON value
/// of the member of its oneof that it holds, and an Any as `print_any`
/// says.
///
/// Raises `DecodeError` for a value that ProtoJSON cannot print: a
/// Timestamp or a Duration out of its range, or a Duration whose seconds
/// and nanos have opposite signs, a FieldMask path that has no
/// lowerCamelCase form, a Value that holds nothing, NaN or an infinity, at
/// any depth, and an Any that `print_any` cannot print.
fn DescriptorSet::print_well_known(
  self : DescriptorSet,
  out : Output,
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
            message="the Timestamp of seconds \{seconds} and nanos \{nanos} is outside the range from 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z that ProtoJSON prints",
          )
        }
        write_timestamp(out, seconds, nanos)
      } else {
        if !is_duration(seconds, nanos) {
          raise DecodeError(
            position~,
            message="the Duration of seconds \{seconds} and nanos \{nanos} is outside the range from -315576000000.999999999s to 315576000000.999999999s that ProtoJSON prints, or its seconds and nanos have opposite signs",
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
      let values = self.scan(message, records)
      self.print_value(out, message.fields[index], values[index], depth)
    }
    Struct(index) | ListValue(index) => {
      let values = self.scan(message, records)
      self.print_repeated(out, message.fields[index], values[index], depth)
    }
    Value => {
      let values = self.scan(message, records)
      // The member of the oneof `kind` that the Value holds: the last one
      // of its fields by number, as the oneof keeps one.
      let mut held = -1
      for index in message.by_number {
        if values[index] is Some(_) {
          held = index
        }
      }
      guard held >= 0 else {
        raise DecodeError(
          position~,
          message="the Value holds no value, which ProtoJSON cannot print: it must hold null, a number, a string, a bool, a Struct or a ListValue",
        )
      }
      let field = message.fields[held]
      if field.number == 2 && values[held] is Some(Number(bits)) {
        let number = bits.reinterpret_as_double()
        if number.is_nan() || number.is_inf() {
          raise DecodeError(
            position~,
            message="the Value holds the number \{number}, which a JSON number cannot be, and ProtoJSON does not print it as a string",
          )
        }
      }
      self.print_value(out, field, values[held], depth)
    }
    Any => self.print_any(out, records, depth)
  }
}

///|
/// The full name of the type that `url`, an Any's type URL, names: the
/// text after its last `/`, such as `helloworld.HelloRequest` for
/// `type.googleapis.com/helloworld.HelloRequest`. `None` when it has no `/`,
/// or nothing after its last one.
pub fn type_name_of_url(url : String) -> String? {
  let mut i = url.length()
  while i > 0 && url[i - 1] != '/' {
    i = i - 1
  }
  if i == 0 || i == url.length() {
    None
  } else {
    Some(url[i:].to_owned())
  }
}

///|
/// Prints to `out` the Any whose records are `records`, merged in order,
/// `depth` messages deep, as ProtoJSON prints it: `{}` when it is empty,
/// or else an object of its type URL as `@type`, then the message it holds
/// one message deeper, a type of the set that the URL names: its fields,
/// or its form as `value` when it is a well-known type that has one. Its
/// last type URL and its last value win, as protobuf's parsers keep them.
///
/// Raises `DecodeError` for an Any that ProtoJSON cannot print: one with a
/// value but no type URL, one whose type URL names no type, or a type the
/// set does not define, and one whose message does not decode.
fn DescriptorSet::print_any(
  self : DescriptorSet,
  out : Output,
  records : Array[BytesView],
  depth : Int32,
) -> Unit raise DecodeError {
  let position = records[0].start_offset()
  let mut url = records[0][0:0]
  let mut value = records[0][0:0]
  for r in 0..<records.length() {
    let reader = Reader(records[r])
    while !reader.at_end() {
      let number = reader.tag()
      match (number, reader.wire_type()) {
        (1, Len) => {
          let at = reader.pos
          url = reader.length_delimited()
          if !is_utf8(url) {
            raise reader.error(
              at, "the field type_url holds octets that are not UTF-8",
            )
          }
        }
        (2, Len) => value = reader.length_delimited()
        _ => reader.skip()
      }
    }
  }
  if url.length() == 0 {
    if value.length() > 0 {
      raise DecodeError(
        position~,
        message="the Any has a value but no type URL, so it cannot be printed",
      )
    }
    out.write_bytes(b"{}")
    return
  }
  let text = @utf8.decode_lossy(url)
  guard type_name_of_url(text) is Some(name) else {
    raise DecodeError(
      position~,
      message="the Any's type URL \{text.escape()} names no type: it must end in / and the type's full name, such as \"type.googleapis.com/helloworld.HelloRequest\"",
    )
  }
  guard self.find_message(name) is Some(held) else {
    raise DecodeError(
      position~,
      message="the Any holds the type \{name}, which the Descriptor set does not define, so it cannot be printed",
    )
  }
  if depth >= max_depth {
    raise DecodeError(
      position~,
      message="messages nest deeper than \{max_depth}",
    )
  }
  out.write_bytes(b"{\"@type\":")
  write_json_string(out, url)
  if well_known_form(held) is Some(_) {
    out.write_bytes(b",\"value\":")
    self.print_message(out, held, [value], depth + 1)
    out.write_byte(b'}')
    return
  }
  // The message's fields follow `@type` in the Any's object: the message
  // is printed as an object, which then loses its braces.
  let at = out.length
  self.print_message(out, held, [value], depth + 1)
  out.unwrap_object(at)
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
  out : Output,
  seconds : Int64,
  nanos : Int32,
) -> Unit raise DecodeError {
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
fn write_duration(
  out : Output,
  seconds : Int64,
  nanos : Int32,
) -> Unit raise DecodeError {
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
fn write_fraction(out : Output, nanos : Int32) -> Unit raise DecodeError {
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
fn write_padded(
  out : Output,
  value : Int64,
  width : Int32,
) -> Unit raise DecodeError {
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
fn write_path(out : Output, path : BytesView) -> Bool raise DecodeError {
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

///|
/// Writes `json`, a message of the type `message`, a well-known type whose
/// form is `form`, nested `depth` messages deep, as the records of its
/// fields, as protoc writes them, reading `json` as ProtoJSON reads it: a
/// Timestamp, a Duration or a FieldMask from a string, as
/// `write_timestamp_of`, `write_duration_of` and `write_field_mask_of` say,
/// a wrapper from the value it wraps, which is left out at its default, a
/// Struct from an object, a ListValue from an array and a Value from any
/// JSON value, `null` included, and an Any as `write_any` says. Raises
/// `Unfit` when `json` is not such a message, and `EncodeError` when a
/// message it holds does not fit its type.
fn DescriptorSet::write_well_known(
  self : DescriptorSet,
  writer : Writer,
  message : MessageDescriptor,
  form : WellKnown,
  json : Json,
  depth : Int32,
) -> Unit raise {
  match form {
    Timestamp => {
      guard json is String(text) else { raise Unfit }
      write_timestamp_of(writer, text)
    }
    Duration => {
      guard json is String(text) else { raise Unfit }
      write_duration_of(writer, text)
    }
    FieldMask => {
      guard json is String(text) else { raise Unfit }
      write_field_mask_of(writer, text)
    }
    Wrapper(index) =>
      self.write_value(
        writer,
        message.fields[index],
        json,
        depth,
        present=false,
      )
    Struct(index) => {
      guard json is Object(_) else { raise Unfit }
      self.write_field(writer, message, message.fields[index], json, depth)
    }
    ListValue(index) => {
      guard json is Array(_) else { raise Unfit }
      self.write_field(writer, message, message.fields[index], json, depth)
    }
    Value => {
      // The member of the oneof `kind` that holds such a JSON value.
      let number = match json {
        Null => 1
        Number(_) => 2
        String(_) => 3
        True | False => 4
        Object(_) => 5
        Array(_) => 6
      }
      let index = message.field_index(number)
      guard index >= 0 else { raise Unfit }
      self.write_value(writer, message.fields[index], json, depth, present=true)
    }
    Any => self.write_any(writer, json, depth)
  }
}

///|
/// Writes `json`, an Any nested `depth` messages deep, as the records of
/// its fields, as protoc writes them, reading `json` as ProtoJSON reads an
/// Any: an object whose `@type` is a type URL that names a type of the
/// set, and whose other members are the fields of the message it holds,
/// one message deeper, or its form as `value` when it is a well-known type
/// that has one. An Empty may give `value` as `{}`, as protobuf-go prints
/// it. `{}` is an empty Any. Raises `Unfit` when `json` is not an object,
/// and `EncodeError`, at the JSON Pointer of the value at fault, when the
/// type URL names no type of the set, or the members do not fit the type.
fn DescriptorSet::write_any(
  self : DescriptorSet,
  writer : Writer,
  json : Json,
  depth : Int32,
) -> Unit raise {
  guard json is Object(members) else { raise Unfit }
  guard members.get("@type") is Some(type_url) else {
    if members.is_empty() {
      return
    }
    raise EncodeError(
      pointer="",
      message="must give \"@type\", the type URL of the message the Any holds, such as \"type.googleapis.com/helloworld.HelloRequest\"",
    )
  }
  let not_a_url = EncodeError(
    pointer="/@type",
    message="must be a type URL: / and the full name of a type of the set at its end, such as \"type.googleapis.com/helloworld.HelloRequest\"",
  )
  guard type_url is String(url) && type_name_of_url(url) is Some(name) else {
    raise not_a_url
  }
  guard self.find_message(name) is Some(held) else {
    raise EncodeError(
      pointer="/@type",
      message="names the type \{name}, which the Descriptor set does not define",
    )
  }
  if not_encoded(held) is Some(why) {
    raise EncodeError(pointer="/@type", message=why)
  }
  if depth >= max_depth {
    raise EncodeError(
      pointer="",
      message="nests messages deeper than \{max_depth}",
    )
  }
  let inner = Writer()
  match well_known_form(held) {
    Some(form) => {
      for key, _ in members {
        if !(key is ("@type" | "value")) {
          raise EncodeError(
            pointer=pointer_of(key),
            message="is not a member of an Any that holds a \{held.full_name}: give the \{held.full_name} as \"value\"",
          )
        }
      }
      guard members.get("value") is Some(value) else {
        raise EncodeError(
          pointer="",
          message="must give \"value\", the \{held.full_name} that the Any holds",
        )
      }
      self.write_well_known(inner, held, form, value, depth + 1) catch {
        Unfit =>
          raise EncodeError(
            pointer="/value",
            message="must be \{self.wanted_message(held)}: the Any holds a \{held.full_name}",
          )
        error => raise nested(error, "/value")
      }
    }
    None => {
      let fields : Map[String, Json] = Map([])
      for key, value in members {
        if key == "@type" ||
          (
            key == "value" &&
            held.full_name == "google.protobuf.Empty" &&
            value is Object(empty) &&
            empty.is_empty()
          ) {
          continue
        }
        fields[key] = value
      }
      self.write_message(inner, held, fields, depth + 1)
    }
  }
  writer.tag(1, Len)
  writer.utf8(url) catch {
    _ => raise not_a_url
  }
  let value = inner.to_bytes()
  if value.length() > 0 {
    writer.tag(2, Len)
    writer.length_delimited(value)
  }
}

///|
/// What a message of the type `message` must be in JSON, as an error says
/// it: such as `an object`, or for a well-known type, its form.
fn DescriptorSet::wanted_message(
  self : DescriptorSet,
  message : MessageDescriptor,
) -> String {
  match well_known_form(message) {
    Some(Timestamp) =>
      "a date and time in RFC 3339 form, from \"0001-01-01T00:00:00Z\" to \"9999-12-31T23:59:59.999999999Z\", such as \"1970-01-01T00:00:01.500Z\""
    Some(Duration) =>
      "a duration from \"-315576000000.999999999s\" to \"315576000000.999999999s\": seconds, with at most 9 fractional digits, then \"s\", such as \"1.500s\""
    Some(FieldMask) =>
      "a string of field paths in lowerCamelCase, joined by commas, such as \"userName,address.city\""
    Some(Wrapper(index)) => self.wanted(message.fields[index])
    Some(Struct(_)) => "an object, whose members are any JSON values"
    Some(ListValue(_)) => "an array, whose elements are any JSON values"
    Some(Value) =>
      "a JSON value: null, a number within the range of a double, a string, true or false, an object or an array"
    Some(Any) =>
      "an object that gives the type URL of the message it holds as \"@type\""
    None => "an object"
  }
}

///|
/// Writes the Timestamp that `text` gives, as ProtoJSON reads one, as the
/// records of its `seconds` and `nanos`, each left out at 0: a date and
/// time in RFC 3339 form, `YYYY-MM-DDTHH:MM:SS`, then optionally `.` and 1
/// to 9 fractional digits, then `Z` or an offset, `+HH:MM` or `-HH:MM`. The
/// year is 1 to 9999, the date must exist, and the time, once the offset
/// is taken off, must be from 0001-01-01T00:00:00Z to
/// 9999-12-31T23:59:59.999999999Z. Raises `Unfit` for any other text.
fn write_timestamp_of(writer : Writer, text : String) -> Unit raise Unfit {
  let length = text.length()
  guard length >= 20 &&
    text[4] == '-' &&
    text[7] == '-' &&
    text[10] == 'T' &&
    text[13] == ':' &&
    text[16] == ':' else {
    raise Unfit
  }
  let year = digits_at(text, 0, 4)
  let month = digits_at(text, 5, 2)
  let day = digits_at(text, 8, 2)
  let hour = digits_at(text, 11, 2)
  let minute = digits_at(text, 14, 2)
  let second = digits_at(text, 17, 2)
  guard year >= 1 &&
    month >= 1 &&
    month <= 12 &&
    day >= 1 &&
    day <= days_in_month(year, month) &&
    hour <= 23 &&
    minute <= 59 &&
    second <= 59 else {
    raise Unfit
  }
  let mut at = 19
  let nanos = if text[at] == '.' {
    let end = digits_end(text, at + 1)
    let nanos = fraction_at(text, at + 1, end)
    at = end
    nanos
  } else {
    0
  }
  // The offset from UTC, in seconds.
  let offset = if at < length && text[at] == 'Z' {
    at = at + 1
    0L
  } else if at + 6 == length &&
    (text[at] == '+' || text[at] == '-') &&
    text[at + 3] == ':' {
    let hours = digits_at(text, at + 1, 2)
    let minutes = digits_at(text, at + 4, 2)
    guard hours <= 23 && minutes <= 59 else { raise Unfit }
    let sign = if text[at] == '-' { -1L } else { 1L }
    at = length
    sign * (hours.to_int64() * 3600 + minutes.to_int64() * 60)
  } else {
    raise Unfit
  }
  guard at == length else { raise Unfit }
  let seconds = days_from_civil(year, month, day) * 86400 +
    hour.to_int64() * 3600 +
    minute.to_int64() * 60 +
    second.to_int64() -
    offset
  guard seconds >= min_timestamp_seconds && seconds <= max_timestamp_seconds else {
    raise Unfit
  }
  write_seconds_and_nanos(writer, seconds, nanos)
}

///|
/// Writes the Duration that `text` gives, as ProtoJSON reads one, as the
/// records of its `seconds` and `nanos`, each left out at 0: an optional
/// `-`, the seconds, at least one digit, then optionally `.` and 1 to 9
/// fractional digits, then `s`, from `"-315576000000.999999999s"` to
/// `"315576000000.999999999s"`. Raises `Unfit` for any other text.
fn write_duration_of(writer : Writer, text : String) -> Unit raise Unfit {
  let length = text.length()
  let negative = length > 0 && text[0] == '-'
  let start = if negative { 1 } else { 0 }
  let end = digits_end(text, start)
  guard end > start && end < length else { raise Unfit }
  let mut seconds = 0L
  for i in start..<end {
    seconds = seconds * 10 + (text[i].to_int() - '0'.to_int()).to_int64()
    // Stops before the seconds could overflow.
    guard seconds <= max_duration_seconds else { raise Unfit }
  }
  let mut at = end
  let nanos = if text[at] == '.' {
    let fraction_end = digits_end(text, at + 1)
    let nanos = fraction_at(text, at + 1, fraction_end)
    at = fraction_end
    nanos
  } else {
    0
  }
  guard at + 1 == length && text[at] == 's' else { raise Unfit }
  if negative {
    write_seconds_and_nanos(writer, -seconds, -nanos)
  } else {
    write_seconds_and_nanos(writer, seconds, nanos)
  }
}

///|
/// Writes the paths of the FieldMask that `text` gives, as ProtoJSON reads
/// one, as records of its field `paths`: paths joined by commas, each in
/// lowerCamelCase, whose upper-case letters become an underscore and the
/// letter in lower case, as protoc names fields. `""` has no paths. A path
/// may hold letters, digits and dots, and may be empty. Raises `Unfit` for
/// any other text.
fn write_field_mask_of(writer : Writer, text : String) -> Unit raise Unfit {
  let length = text.length()
  if length == 0 {
    return
  }
  let path = @buffer.Buffer(size_hint=length + 8)
  for i in 0..<=length {
    if i == length || text[i] == ',' {
      writer.tag(1, Len)
      writer.length_delimited(path.to_bytes())
      path.reset()
      continue
    }
    let unit = text[i]
    if unit >= 'A' && unit <= 'Z' {
      path.write_byte(b'_')
      path.write_byte((unit.to_int() - 'A'.to_int() + 'a'.to_int()).to_byte())
    } else if (unit >= 'a' && unit <= 'z') ||
      (unit >= '0' && unit <= '9') ||
      unit == '.' {
      path.write_byte(unit.to_int().to_byte())
    } else {
      raise Unfit
    }
  }
}

///|
/// Writes `seconds` and `nanos`, a Timestamp's or a Duration's, as the
/// records of its fields `seconds`, numbered 1, and `nanos`, numbered 2,
/// each left out at 0, as protoc writes them.
fn write_seconds_and_nanos(
  writer : Writer,
  seconds : Int64,
  nanos : Int32,
) -> Unit {
  if seconds != 0 {
    writer.tag(1, Varint)
    writer.varint(seconds.reinterpret_as_uint64())
  }
  if nanos != 0 {
    writer.tag(2, Varint)
    writer.varint(nanos.to_int64().reinterpret_as_uint64())
  }
}

///|
/// The number that the `count` decimal digits of `text` from `start` give.
/// Raises `Unfit` when they are not all digits, or `text` ends before them.
fn digits_at(text : String, start : Int32, count : Int32) -> Int32 raise Unfit {
  guard start + count <= text.length() else { raise Unfit }
  let mut value = 0
  for i in start..<(start + count) {
    let unit = text[i]
    guard unit >= '0' && unit <= '9' else { raise Unfit }
    value = value * 10 + (unit.to_int() - '0'.to_int())
  }
  value
}

///|
/// Where the decimal digits of `text` that start at `start` end: the index
/// of the first code unit from `start` on that is not one.
fn digits_end(text : String, start : Int32) -> Int32 {
  let mut end = start
  while end < text.length() && text[end] >= '0' && text[end] <= '9' {
    end = end + 1
  }
  end
}

///|
/// The nanoseconds that the fractional digits of `text` from `start` to
/// `end` give: 1 to 9 digits. Raises `Unfit` for none, or more than 9.
fn fraction_at(text : String, start : Int32, end : Int32) -> Int32 raise Unfit {
  let count = end - start
  guard count >= 1 && count <= 9 else { raise Unfit }
  let mut nanos = digits_at(text, start, count)
  for _ in count..<9 {
    nanos = nanos * 10
  }
  nanos
}

///|
/// The number of days in `month`, from 1 to 12, of `year`, in the
/// proleptic Gregorian calendar.
fn days_in_month(year : Int32, month : Int32) -> Int32 {
  match month {
    2 =>
      if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
        29
      } else {
        28
      }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
}

///|
/// The days from 1970-01-01 to the date `year`-`month`-`day`, in the
/// proleptic Gregorian calendar: counted in eras of 400 years from
/// 0000-03-01, as `write_timestamp` counts them.
fn days_from_civil(year : Int32, month : Int32, day : Int32) -> Int64 {
  // A year from March, so that a leap day ends it.
  let y = (if month <= 2 { year - 1 } else { year }).to_int64()
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let year_of_era = y - era * 400
  let month_index = (if month > 2 { month - 3 } else { month + 9 }).to_int64()
  let day_of_year = (153L * month_index + 2) / 5 + day.to_int64() - 1
  let day_of_era = year_of_era * 365 +
    year_of_era / 4 -
    year_of_era / 100 +
    day_of_year
  era * 146097 + day_of_era - 719468
}
