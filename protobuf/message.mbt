// Messages decoded from their descriptors into smock's decoded form, the
// JSON text the engine, the Journal and templates see. For now the decoder
// serves every field of the types of proto3 and proto2 files but groups;
// well_known.mbt prints the well-known types. encode.mbt encodes messages
// from JSON.

///|
/// The index in `fields` of the message's field numbered `number`, or -1,
/// found by binary search in the index of its fields by number.
fn MessageDescriptor::field_index(
  self : MessageDescriptor,
  number : Int32,
) -> Int32 {
  let order = self.by_number
  let mut low = 0
  let mut high = order.length()
  while low < high {
    let middle = (low + high) / 2
    if self.fields[order[middle]].number < number {
      low = middle + 1
    } else {
      high = middle
    }
  }
  if low < order.length() && self.fields[order[low]].number == number {
    order[low]
  } else {
    -1
  }
}

///|
/// The value of a field of a message being decoded, as its records give
/// it.
priv enum Value {
  /// The last value of a scalar or an enum field: a varint, or a fixed
  /// 32-bit or 64-bit value, as its bits.
  Number(UInt64)
  /// The octets of the last value of a string or bytes field.
  Octets(BytesView)
  /// The octets of each value of a message field, in order. protobuf's
  /// parsers merge them into one message.
  Messages(Array[BytesView])
  /// The records of a repeated field, tags included, in order, as runs:
  /// each view holds one or more records of the field that follow each
  /// other in the message, so a field whose records come together costs
  /// one view. A record holds a value, a packed record of values of a
  /// scalar or an enum, or an entry of a map.
  Elements(Array[BytesView])
}

///|
/// The runs of records of a repeated field that a message leaves out.
let no_runs : Array[BytesView] = []

///|
/// Decodes `input`, a message of the type `message` of `set` in protobuf's
/// binary encoding, into smock's decoded form: compact JSON text in UTF-8,
/// an object with one member per field, in field-number order, under the
/// field's JSON name. A message gives one text, whatever order its records
/// come in.
///
/// - 64-bit integers are numbers, exact at any size; 32-bit integers are
///   numbers too.
/// - A double is printed as `Double::to_string` prints it, and a float in
///   the shortest form that reads back as the same 32-bit float, so 0.1f
///   prints `0.1`. NaN and the infinities are the strings `"NaN"`,
///   `"Infinity"` and `"-Infinity"`.
/// - A bool is `true` or `false`, a string is a JSON string, and bytes are
///   a string of standard base64 with padding.
/// - An enum value is printed by its name, the first one of an alias, or
///   by its number when an open enum, as a proto3 enum is, does not define
///   it. A closed enum, as a proto2 enum is, keeps such a number as an
///   unknown field, as protobuf's parsers keep it: a field or a oneof keeps
///   the value it had, a list leaves the number out, and a map its entry.
/// - A nested message is an object in the same form.
/// - A repeated field is an array of its values, in order, and a map an
///   object with a member per key, in key order: integer keys by value,
///   bool keys `"false"` then `"true"`, and string keys by their octets.
///   An integer key prints in decimal, as a string.
/// - A field without presence that the message leaves out is printed at
///   its default: `0`, `false`, `""`, an enum's value 0, `[]` or `{}`. A
///   proto3 `optional` field, a member of a oneof, a message field and
///   every singular field of a proto2 message are printed only when the
///   message holds them.
/// - A proto2 string need not be UTF-8: one that is not is printed with
///   U+FFFD for each bad sequence.
///
/// It reads the message as protobuf's parsers read it: the last value of a
/// scalar or an enum field wins, the values of a message field are merged,
/// a member of a oneof replaces the one before it, repeated scalars are
/// read packed or not, and the records of a packed field are joined. A map
/// entry without a key or a value takes the default, and when a key
/// repeats, the last entry wins. Unknown fields, and fields sent with
/// another wire type than their type's, are skipped.
///
/// The well-known types are printed in their ProtoJSON forms, at any
/// place, the whole message included: a Timestamp as a string of the date
/// and time in UTC, such as `"1970-01-01T00:00:01.500Z"`, a Duration as a
/// string of seconds, such as `"1.500s"`, each with 0, 3, 6 or 9 fractional
/// digits; a FieldMask as its paths in lowerCamelCase, joined by commas; a
/// wrapper as the value it wraps, an Int64Value or a UInt64Value as a
/// number, a FloatValue as a float; Empty as `{}`; a Struct, a Value and a
/// ListValue as the JSON values they hold, a Struct's keys in order, and a
/// NullValue as `null`; and an Any as an object of its type URL as
/// `@type`, then the fields of the message it holds, a type of the set
/// that the URL names, or its form as `value` when it is a well-known type
/// that has one, an Empty's object of no fields included.
///
/// The JSON is bounded by `limit`: it is counted as it is printed, and
/// printing stops as soon as it passes `limit` octets, so a small message
/// whose JSON would be far larger, such as a list of empty messages each
/// printed with every field at its default, costs no more than `limit`.
/// What it holds meanwhile to print a message is bounded by `limit` too:
/// views of the input, beyond one a field, of the records of a repeated
/// field that do not come together, of a message field sent again, and of
/// the entries of a map, each counted as about the memory it takes. It
/// allocates nothing for a length before it has checked it against the
/// octets left, and checks and repairs UTF-8 with no copy.
///
/// Raises `DecodeError` when the input is not protobuf, when a proto3
/// string is not UTF-8, when a message lacks a proto2 required field, as
/// protobuf's parsers refuse it, when messages nest deeper than 100, a map
/// entry counting as a message, when a well-known type has a value that
/// ProtoJSON cannot print, such as a Timestamp out of range, a Value that
/// holds nothing or NaN, or an Any whose type the set lacks, when a message
/// it prints is a type of an editions file or a MessageSet, and when a
/// message it prints is or has a field that it does not decode yet: one
/// declared in an editions file. Raises `TooLarge` when the JSON, or what
/// it holds to print it, passes `limit`.
pub fn decode_json(
  set : DescriptorSet,
  message : MessageDescriptor,
  input : BytesView,
  limit~ : Int32,
) -> Bytes raise DecodeError {
  // Twice the input, as a guess, but never more than the limit.
  let guess = if input.length() > (limit - 16) / 2 {
    limit
  } else {
    2 * input.length() + 16
  }
  let out = Output::new(size_hint=guess, limit~)
  set.print_message(out, message, [input], 0)
  out.to_bytes()
}

///|
/// The values of the fields of the message of the type `message` whose
/// records are `records`, merged in order, by the index of each field in
/// `message.fields`; `None` for a field the message leaves out. A number
/// that a closed enum does not define is skipped, as protobuf's parsers
/// keep it as an unknown field: the field keeps the value it had, and a
/// oneof the member it had. Each view a field's value holds beyond its
/// first is held in `out`, which the caller lets go once it has printed
/// the message.
fn DescriptorSet::scan(
  self : DescriptorSet,
  out : Output,
  message : MessageDescriptor,
  records : Array[BytesView],
) -> FixedArray[Value?] raise DecodeError {
  // A field's value at its index in `fields`, and an extension's after
  // them, as `field_or_extension` says.
  let values : FixedArray[Value?] = FixedArray::make(
    message.fields.length() + message.extended_by.length(),
    None,
  )
  // The index of the member of each oneof that the message holds, by the
  // oneof's index, or -1.
  let chosen = if message.oneofs.length() == 0 {
    no_oneofs
  } else {
    FixedArray::make(message.oneofs.length(), -1)
  }
  for r in 0..<records.length() {
    let record = records[r]
    let reader = Reader(record)
    while !reader.at_end() {
      let index = message.field_or_extension_index(reader.tag())
      guard index >= 0 else {
        reader.skip()
        continue
      }
      let field = message.field_or_extension(index)
      // A string of a proto3 file must be UTF-8. One of a proto2 file need
      // not be, and is printed with U+FFFD for each bad sequence.
      let checked = field.syntax is Proto3
      if field.label is Repeated {
        let start = reader.tag_at
        let at = reader.pos
        match (field.type_, reader.wire_type()) {
          (String, Len) => {
            let value = reader.length_delimited()
            if checked && !is_utf8(value) {
              raise reader.error(
                at,
                "the field \{field.name} holds octets that are not UTF-8",
              )
            }
          }
          // A string, bytes, a message or a map entry; or a packed record
          // of values.
          (
            Bytes
            | Message
            | Int32
            | Int64
            | UInt32
            | UInt64
            | SInt32
            | SInt64
            | Bool
            | Enum
            | Fixed64
            | SFixed64
            | Double
            | Fixed32
            | SFixed32
            | Float,
            Len,
          ) => ignore(reader.length_delimited())
          (
            Int32
            | Int64
            | UInt32
            | UInt64
            | SInt32
            | SInt64
            | Bool
            | Enum,
            Varint,
          ) => ignore(reader.varint())
          (Fixed64 | SFixed64 | Double, I64) => ignore(reader.fixed64())
          (Fixed32 | SFixed32 | Float, I32) => ignore(reader.fixed32())
          (Group, StartGroup) => ignore(reader.group())
          _ => {
            reader.skip()
            continue
          }
        }
        // The record joins the field's last run when it follows it.
        match values[index] {
          Some(Elements(runs)) => {
            let last = runs[runs.length() - 1]
            let from = last.start_offset() - record.start_offset()
            if from >= 0 && from + last.length() == start {
              runs[runs.length() - 1] = record[from:reader.pos]
            } else {
              out.hold(held_view)
              runs.push(record[start:reader.pos])
            }
          }
          _ => values[index] = Some(Elements([record[start:reader.pos]]))
        }
        continue
      }
      match (field.type_, reader.wire_type()) {
        (Int32 | Int64 | UInt32 | UInt64 | SInt32 | SInt64 | Bool, Varint) =>
          values[index] = Some(Number(reader.varint()))
        (Enum, Varint) => {
          let bits = reader.varint()
          if self.closed_enum_of(field) is Some(type_) && !type_.defines(bits) {
            continue
          }
          values[index] = Some(Number(bits))
        }
        (Fixed64 | SFixed64 | Double, I64) =>
          values[index] = Some(Number(reader.fixed64()))
        (Fixed32 | SFixed32 | Float, I32) =>
          values[index] = Some(Number(reader.fixed32().to_uint64()))
        (String, Len) => {
          let at = reader.pos
          let value = reader.length_delimited()
          // One of a proto2 file is repaired as it is printed.
          if checked && !is_utf8(value) {
            raise reader.error(
              at,
              "the field \{field.name} holds octets that are not UTF-8",
            )
          }
          values[index] = Some(Octets(value))
        }
        (Bytes, Len) => values[index] = Some(Octets(reader.length_delimited()))
        (Message, Len) | (Group, StartGroup) => {
          let value = if field.type_ is Group {
            reader.group()
          } else {
            reader.length_delimited()
          }
          match values[index] {
            Some(Messages(list)) => {
              out.hold(held_view)
              list.push(value)
            }
            _ => values[index] = Some(Messages([value]))
          }
        }
        _ => {
          reader.skip()
          continue
        }
      }
      // A member of a oneof replaces the member the message held before.
      if field.oneof_index is Some(oneof) && chosen[oneof] != index {
        if chosen[oneof] >= 0 {
          values[chosen[oneof]] = None
        }
        chosen[oneof] = index
      }
    }
  }
  values
}

///|
/// Prints to `out` the message of the type `message` whose values are
/// `records`, merged in order, `depth` messages deep in the message that
/// `decode_json` decodes, as `decode_json` prints it.
fn DescriptorSet::print_message(
  self : DescriptorSet,
  out : Output,
  message : MessageDescriptor,
  records : Array[BytesView],
  depth : Int32,
) -> Unit raise DecodeError {
  if message.syntax is Editions {
    raise DecodeError(
      position=records[0].start_offset(),
      message="the message \{message.full_name} is a type of an editions file, which smock does not decode",
    )
  }
  if message.message_set_wire_format {
    raise DecodeError(
      position=records[0].start_offset(),
      message="the message \{message.full_name} is a MessageSet, which smock does not decode",
    )
  }
  // What the message's scan holds is let go once it is printed.
  let held = out.held
  if well_known_form(message) is Some(form) {
    self.print_well_known(out, message, form, records, depth)
    out.release_to(held)
    return
  }
  let fields = message.fields
  let values = self.scan(out, message, records)
  out.write_byte(b'{')
  // The fields, and the extensions that extend the message, in
  // field-number order.
  let order = message.numbered
  // Every singular field of a proto2 message has presence.
  let proto2 = message.syntax is Proto2
  let mut first = true
  for n in 0..<order.length() {
    let index = order[n]
    let field = message.field_or_extension(index)
    let extension = index >= fields.length()
    if self.not_decoded(field) is Some(why) {
      let what = if extension {
        "extension \{field.full_name}"
      } else {
        "field \{field.name}"
      }
      raise DecodeError(
        position=records[0].start_offset(),
        message="the \{what} \{why}, which smock does not decode yet",
      )
    }
    let value = values[index]
    if value is None && field.label is Required && !extension {
      raise DecodeError(
        position=records[0].start_offset(),
        message="the message \{message.full_name} lacks its required field \{field.name}",
      )
    }
    // An extension is printed only when the message holds it, as
    // ProtoJSON prints it, a repeated one too.
    if value is None &&
      (
        extension ||
        (
          !(field.label is Repeated) &&
          (
            proto2 ||
            field.oneof_index is Some(_) ||
            field.type_ is (Message | Group)
          )
        )
      ) {
      continue
    }
    if !first {
      out.write_byte(b',')
    }
    first = false
    if extension {
      write_extension_name(out, field.full_name)
    } else {
      write_json_name(out, field.json_name)
    }
    out.write_byte(b':')
    if field.label is Repeated {
      self.print_repeated(out, field, value, depth)
    } else {
      self.print_value(out, field, value, depth)
    }
  }
  out.write_byte(b'}')
  out.release_to(held)
}

///|
/// Prints to `out` the value `value` of `field`, a repeated field of a
/// message `depth` messages deep: a map as an object, or else a list as an
/// array.
fn DescriptorSet::print_repeated(
  self : DescriptorSet,
  out : Output,
  field : FieldDescriptor,
  value : Value?,
  depth : Int32,
) -> Unit raise DecodeError {
  let runs = match value {
    Some(Elements(runs)) => runs
    _ => no_runs
  }
  match self.message_of(field) {
    Some(entry) if entry.map_entry && is_map_entry(entry) =>
      self.print_map(out, entry, runs, depth)
    _ => self.print_list(out, field, runs, depth)
  }
}

///|
/// Prints to `out` the value `value` of `field`, a singular field of a
/// message `depth` messages deep, or its default when it is `None`.
fn DescriptorSet::print_value(
  self : DescriptorSet,
  out : Output,
  field : FieldDescriptor,
  value : Value?,
  depth : Int32,
) -> Unit raise DecodeError {
  match value {
    Some(Messages(list)) => {
      if depth >= max_depth {
        raise DecodeError(
          position=list[0].start_offset(),
          message="messages nest deeper than \{max_depth}",
        )
      }
      match self.message_of(field) {
        Some(type_) => self.print_message(out, type_, list, depth + 1)
        // Never: a message field's type is a message of its set.
        None => out.write_bytes(b"{}")
      }
    }
    Some(Octets(octets)) =>
      if field.type_ is Bytes {
        write_base64(out, octets)
      } else {
        // A string of a proto2 file need not be UTF-8: those of a proto3
        // file were checked when the message was scanned.
        write_json_string(out, octets, repair=field.syntax is Proto2)
      }
    Some(Number(bits)) => self.print_number(out, field, bits)
    None | Some(Elements(_)) =>
      match field.type_ {
        String | Bytes => out.write_bytes(b"\"\"")
        // Never: a message field the message leaves out is not printed,
        // and a map value is given.
        Message | Group => out.write_bytes(b"{}")
        _ => self.print_number(out, field, 0)
      }
  }
}

///|
/// Prints to `out` the values of `field`, a repeated field other than a
/// map of a message `depth` messages deep, whose records are in `runs`,
/// as an array.
fn DescriptorSet::print_list(
  self : DescriptorSet,
  out : Output,
  field : FieldDescriptor,
  runs : Array[BytesView],
  depth : Int32,
) -> Unit raise DecodeError {
  out.write_byte(b'[')
  // The strings of a proto3 file were checked when the message was
  // scanned. Those of a proto2 file may not be UTF-8.
  let checked = field.syntax is Proto3
  // A number that a closed enum does not define is skipped, as protobuf's
  // parsers keep it as an unknown field.
  let closed = self.closed_enum_of(field)
  let mut first = true
  for r in 0..<runs.length() {
    let reader = Reader(runs[r])
    while !reader.at_end() {
      ignore(reader.tag())
      match (field.type_, reader.wire_type()) {
        (String | Bytes | Message | Group, _) => {
          let element = if field.type_ is Group {
            reader.group()
          } else {
            reader.length_delimited()
          }
          if !first {
            out.write_byte(b',')
          }
          first = false
          match self.message_of(field) {
            Some(type_) => {
              if depth >= max_depth {
                raise DecodeError(
                  position=element.start_offset(),
                  message="messages nest deeper than \{max_depth}",
                )
              }
              self.print_message(out, type_, [element], depth + 1)
            }
            None if field.type_ is Bytes => write_base64(out, element)
            None => write_json_string(out, element, repair=!checked)
          }
        }
        // A packed record of values.
        (_, Len) => {
          let values = Reader(reader.length_delimited())
          while !values.at_end() {
            let bits = values.number(field.type_)
            if closed is Some(type_) && !type_.defines(bits) {
              continue
            }
            if !first {
              out.write_byte(b',')
            }
            first = false
            self.print_number(out, field, bits)
          }
        }
        _ => {
          let bits = reader.number(field.type_)
          if closed is Some(type_) && !type_.defines(bits) {
            continue
          }
          if !first {
            out.write_byte(b',')
          }
          first = false
          self.print_number(out, field, bits)
        }
      }
    }
  }
  out.write_byte(b']')
}

///|
/// Reads a value of the scalar or enum type `type_`, other than a string
/// or bytes, as its type is encoded: a fixed 64-bit or 32-bit value, or a
/// varint, as its bits.
fn Reader::number(self : Reader, type_ : FieldType) -> UInt64 raise DecodeError {
  match type_ {
    Fixed64 | SFixed64 | Double => self.fixed64()
    Fixed32 | SFixed32 | Float => self.fixed32().to_uint64()
    _ => self.varint()
  }
}

///|
/// Whether `entry`, a message with the option `map_entry`, is a map entry
/// that ProtoJSON prints as an object: its key, field 1, is an integer, a
/// bool or a string, and its value is field 2. protoc writes no other.
fn is_map_entry(entry : MessageDescriptor) -> Bool {
  let key = entry.field_index(1)
  key >= 0 &&
  entry.field_index(2) >= 0 &&
  entry.fields[key].label is (Optional | Required) &&
  entry.fields[key].type_
  is (Int32
  | Int64
  | UInt32
  | UInt64
  | SInt32
  | SInt64
  | Fixed32
  | Fixed64
  | SFixed32
  | SFixed64
  | Bool
  | String)
}

///|
/// Prints to `out` the map whose entries, of the type `entry`, are the
/// records in `runs`, a field of a message `depth` messages deep, as an
/// object with a member per key, in key order. An entry without a key or a
/// value takes the default, and of the entries with one key, the last
/// wins. An entry whose value is a number that a closed enum does not
/// define is skipped, as protobuf's parsers keep it as an unknown field.
fn DescriptorSet::print_map(
  self : DescriptorSet,
  out : Output,
  entry : MessageDescriptor,
  runs : Array[BytesView],
  depth : Int32,
) -> Unit raise DecodeError {
  // Each entry is held, with its key and its place in the map's order,
  // until the map is printed.
  let held = out.held
  let key_type = entry.fields[entry.field_index(1)].type_
  let each = held_view +
    held_entry +
    (if key_type is String { held_view } else { 0 })
  let entries : Array[BytesView] = []
  for r in 0..<runs.length() {
    let reader = Reader(runs[r])
    while !reader.at_end() {
      ignore(reader.tag())
      let value = reader.length_delimited()
      out.hold(each)
      entries.push(value)
    }
  }
  if entries.length() == 0 {
    out.write_bytes(b"{}")
    return
  }
  // An entry is a message nested in the map's.
  if depth >= max_depth {
    raise DecodeError(
      position=entries[0].start_offset(),
      message="messages nest deeper than \{max_depth}",
    )
  }
  let key_index = entry.field_index(1)
  let value_index = entry.field_index(2)
  let key_field = entry.fields[key_index]
  let value_field = entry.fields[value_index]
  let textual = key_field.type_ is String
  let checked = entry.syntax is Proto3
  let closed = self.closed_enum_of(value_field)
  // Each entry's key: its text for a string key, or else a number whose
  // unsigned order is the key's order, the default's until the entry
  // gives one.
  let no_key = key_order(key_field.type_, 0)
  let keys : FixedArray[UInt64] = FixedArray::make(entries.length(), no_key)
  let texts : FixedArray[BytesView] = FixedArray::make(
    if textual {
      entries.length()
    } else {
      0
    },
    b""[:],
  )
  // The entries kept, at the start of `entries`, `keys` and `texts`.
  let mut count = 0
  for i in 0..<entries.length() {
    let reader = Reader(entries[i])
    // Whether the entry's last value is a number its closed enum does not
    // define.
    let mut unknown = false
    while !reader.at_end() {
      let number = reader.tag()
      let at = reader.pos
      match (number, key_field.type_, reader.wire_type()) {
        (1, String, Len) => {
          let text = reader.length_delimited()
          texts[count] = if is_utf8(text) {
            text
          } else if checked {
            raise reader.error(
              at,
              "the field \{key_field.name} holds octets that are not UTF-8",
            )
          } else {
            // Keys that print alike are one key. The key repaired is held
            // until the map is printed.
            out.hold(repaired_length(text))
            repaired(text)
          }
        }
        (1, Int32 | Int64 | UInt32 | UInt64 | SInt32 | SInt64 | Bool, Varint)
        | (1, Fixed64 | SFixed64, I64)
        | (1, Fixed32 | SFixed32, I32) =>
          keys[count] = key_order(
            key_field.type_,
            match reader.wire_type() {
              I64 => reader.fixed64()
              I32 => reader.fixed32().to_uint64()
              _ => reader.varint()
            },
          )
        (2, _, Len) if checked && value_field.type_ is String => {
          // Checked here, since only the last entry of a key is printed.
          let text = reader.length_delimited()
          if !is_utf8(text) {
            raise reader.error(
              at,
              "the field \{value_field.name} holds octets that are not UTF-8",
            )
          }
        }
        (2, _, Varint) if closed is Some(type_) =>
          unknown = !type_.defines(reader.varint())
        _ => reader.skip()
      }
    }
    if unknown {
      keys[count] = no_key
      if textual {
        texts[count] = b""[:]
      }
      continue
    }
    entries[count] = entries[i]
    count += 1
  }
  if count == 0 {
    out.release_to(held)
    out.write_bytes(b"{}")
    return
  }
  let order = sorted_entries(keys, texts, count)
  out.write_byte(b'{')
  let mut first = true
  for n in 0..<count {
    let i = order[n]
    // Of the entries with one key, the last wins.
    if n + 1 < count && same_key(keys, texts, i, order[n + 1]) {
      continue
    }
    if !first {
      out.write_byte(b',')
    }
    first = false
    let before = out.held
    let values = self.scan(out, entry, [entries[i]])
    match values[key_index] {
      Some(Octets(text)) => write_json_string(out, text, repair=!checked)
      Some(Number(bits)) => {
        out.write_byte(b'"')
        self.print_number(out, key_field, bits)
        out.write_byte(b'"')
      }
      _ =>
        if textual {
          out.write_bytes(b"\"\"")
        } else {
          out.write_byte(b'"')
          self.print_number(out, key_field, 0)
          out.write_byte(b'"')
        }
    }
    out.write_byte(b':')
    let value = match values[value_index] {
      // A message value that the entry leaves out is an empty message.
      None if value_field.type_ is (Message | Group) =>
        Some(Messages([entries[i][0:0]]))
      value => value
    }
    self.print_value(out, value_field, value, depth + 1)
    out.release_to(before)
  }
  out.write_byte(b'}')
  out.release_to(held)
}

///|
/// A number whose unsigned order is the order of the map key of the type
/// `type_`, an integer or a bool, whose bits are `bits`.
fn key_order(type_ : FieldType, bits : UInt64) -> UInt64 {
  // A signed key with its sign bit flipped orders as an unsigned number.
  let sign = 0x8000_0000_0000_0000UL
  match type_ {
    Int32 | SFixed32 =>
      bits.to_uint().reinterpret_as_int().to_int64().reinterpret_as_uint64() ^
      sign
    SInt32 => {
      let n = bits.to_uint()
      let value = (n >> 1).reinterpret_as_int() ^ -(n & 1).reinterpret_as_int()
      value.to_int64().reinterpret_as_uint64() ^ sign
    }
    Int64 | SFixed64 => bits ^ sign
    SInt64 =>
      ((bits >> 1).reinterpret_as_int64() ^ -(bits & 1).reinterpret_as_int64()).reinterpret_as_uint64() ^
      sign
    UInt32 | Fixed32 => bits & 0xFFFF_FFFFUL
    Bool => if bits != 0 { 1 } else { 0 }
    _ => bits
  }
}

///|
/// How the keys of the entries `a` and `b` of a map compare: by `texts`
/// when it holds the keys, or else by `keys`. Negative when `a`'s comes
/// first, 0 when they are one key.
fn compare_keys(
  keys : FixedArray[UInt64],
  texts : FixedArray[BytesView],
  a : Int32,
  b : Int32,
) -> Int32 {
  if texts.length() == 0 {
    return if keys[a] < keys[b] {
      -1
    } else if keys[a] > keys[b] {
      1
    } else {
      0
    }
  }
  let x = texts[a]
  let y = texts[b]
  let length = if x.length() < y.length() { x.length() } else { y.length() }
  for i in 0..<length {
    if x[i] != y[i] {
      return if x[i] < y[i] { -1 } else { 1 }
    }
  }
  x.length() - y.length()
}

///|
/// Whether the entries `a` and `b` of a map have one key.
fn same_key(
  keys : FixedArray[UInt64],
  texts : FixedArray[BytesView],
  a : Int32,
  b : Int32,
) -> Bool {
  compare_keys(keys, texts, a, b) == 0
}

///|
/// The indexes of the first `count` entries of a map, whose keys are `keys`
/// or `texts`, as `compare_keys` says, in key order, entries with one key
/// in their order: a merge sort, a run at a time, with plain loops.
fn sorted_entries(
  keys : FixedArray[UInt64],
  texts : FixedArray[BytesView],
  count : Int32,
) -> FixedArray[Int32] {
  let mut from : FixedArray[Int32] = FixedArray::make(count, 0)
  for i in 0..<count {
    from[i] = i
  }
  let mut into : FixedArray[Int32] = FixedArray::make(count, 0)
  let mut width = 1
  while width < count {
    let mut low = 0
    while low < count {
      let middle = if low + width < count { low + width } else { count }
      let high = if middle + width < count { middle + width } else { count }
      let mut left = low
      let mut right = middle
      for k in low..<high {
        // Ties take the left run's entry first, so the order is stable.
        if left < middle &&
          (
            right >= high ||
            compare_keys(keys, texts, from[left], from[right]) <= 0
          ) {
          into[k] = from[left]
          left = left + 1
        } else {
          into[k] = from[right]
          right = right + 1
        }
      }
      low = high
    }
    let swap = from
    from = into
    into = swap
    width = width * 2
  }
  from
}

///|
/// Prints to `out` the value of `field`, a scalar or an enum field other
/// than a string or bytes, whose bits are `bits`: a varint, or a fixed
/// 32-bit or 64-bit value.
fn DescriptorSet::print_number(
  self : DescriptorSet,
  out : Output,
  field : FieldDescriptor,
  bits : UInt64,
) -> Unit raise DecodeError {
  match field.type_ {
    Bool => out.write_bytes(if bits != 0 { b"true" } else { b"false" })
    Int64 | SFixed64 => write_signed(out, bits.reinterpret_as_int64())
    UInt64 | Fixed64 => write_unsigned(out, bits)
    Int32 | SFixed32 =>
      write_signed(out, bits.to_uint().reinterpret_as_int().to_int64())
    UInt32 | Fixed32 => write_unsigned(out, bits & 0xFFFF_FFFFUL)
    SInt32 => {
      let n = bits.to_uint()
      let value = (n >> 1).reinterpret_as_int() ^ -(n & 1).reinterpret_as_int()
      write_signed(out, value.to_int64())
    }
    SInt64 =>
      write_signed(
        out,
        (bits >> 1).reinterpret_as_int64() ^ -(bits & 1).reinterpret_as_int64(),
      )
    Double => write_double(out, bits.reinterpret_as_double())
    Float => {
      let value = Float::reinterpret_from_uint(bits.to_uint())
      if value.is_nan() || value.is_inf() {
        write_double(out, value.to_double())
      } else {
        out.write_ascii(value.to_string())
      }
    }
    Enum => {
      let number = bits.to_uint().reinterpret_as_int()
      match self.enum_of(field) {
        // NullValue, whose one value ProtoJSON prints as `null`, whatever
        // its number.
        Some(type_) if type_.full_name == "google.protobuf.NullValue" =>
          out.write_bytes(b"null")
        Some(type_) =>
          match type_.find_value_by_number(number) {
            Some(value) => write_json_name(out, value.name)
            None => write_signed(out, number.to_int64())
          }
        None => write_signed(out, number.to_int64())
      }
    }
    _ => ()
  }
}

///|
/// The enum type of `field`, a field of a message of this set, when it is
/// a closed enum, as the enums of proto2 files are: protobuf's parsers keep
/// a number it does not define as an unknown field. `None` for an open
/// enum and for any other type.
fn DescriptorSet::closed_enum_of(
  self : DescriptorSet,
  field : FieldDescriptor,
) -> EnumDescriptor? {
  match self.enum_of(field) {
    Some(type_) if type_.syntax is Proto2 => Some(type_)
    _ => None
  }
}

///|
/// Whether the enum defines the number whose bits, as a varint gives them,
/// are `bits`: their low 32 bits, as protobuf's parsers read an enum.
fn EnumDescriptor::defines(self : EnumDescriptor, bits : UInt64) -> Bool {
  self.find_value_by_number(bits.to_uint().reinterpret_as_int()) is Some(_)
}

///|
/// Why `decode_json` does not decode `field` yet, a field of a message of
/// this set or an extension that extends one, or `None` when it does: it
/// is declared in an editions file, as an extension may be.
fn DescriptorSet::not_decoded(
  self : DescriptorSet,
  field : FieldDescriptor,
) -> String? {
  ignore(self)
  if field.syntax is Editions {
    Some("is declared in an editions file")
  } else {
    None
  }
}

///|
/// Whether `full_name`, a full name without a leading dot, is the name of
/// one of protobuf's well-known types that ProtoJSON prints in a form of
/// its own: Any, Duration, Timestamp, FieldMask, Struct, Value, ListValue,
/// NullValue, Empty and the wrappers, such as
/// `google.protobuf.Timestamp`.
pub fn is_well_known(full_name : String) -> Bool {
  full_name.has_prefix("google.protobuf.") &&
  full_name
  is ("google.protobuf.Any"
  | "google.protobuf.Duration"
  | "google.protobuf.Timestamp"
  | "google.protobuf.FieldMask"
  | "google.protobuf.Struct"
  | "google.protobuf.Value"
  | "google.protobuf.ListValue"
  | "google.protobuf.NullValue"
  | "google.protobuf.Empty"
  | "google.protobuf.DoubleValue"
  | "google.protobuf.FloatValue"
  | "google.protobuf.Int64Value"
  | "google.protobuf.UInt64Value"
  | "google.protobuf.Int32Value"
  | "google.protobuf.UInt32Value"
  | "google.protobuf.BoolValue"
  | "google.protobuf.StringValue"
  | "google.protobuf.BytesValue")
}

///|
/// Writes `value` as a JSON number, or as the string `"NaN"`, `"Infinity"`
/// or `"-Infinity"`, which JSON has no number for.
fn write_double(out : Output, value : Double) -> Unit raise DecodeError {
  if value.is_nan() {
    out.write_bytes(b"\"NaN\"")
  } else if value.is_pos_inf() {
    out.write_bytes(b"\"Infinity\"")
  } else if value.is_neg_inf() {
    out.write_bytes(b"\"-Infinity\"")
  } else {
    out.write_ascii(value.to_string())
  }
}

///|
/// Writes `value` in decimal, with a `-` when it is negative.
fn write_signed(out : Output, value : Int64) -> Unit raise DecodeError {
  if value < 0 {
    out.write_byte(b'-')
    // In two's complement, so that the smallest Int64 has its magnitude.
    write_unsigned(out, 0UL - value.reinterpret_as_uint64())
  } else {
    write_unsigned(out, value.reinterpret_as_uint64())
  }
}

///|
/// Writes `value` in decimal.
fn write_unsigned(out : Output, value : UInt64) -> Unit raise DecodeError {
  // The power of ten of the first digit. It never passes `value`, so it
  // never overflows.
  let mut unit = 1UL
  while value / unit >= 10 {
    unit = unit * 10
  }
  while unit > 0 {
    out.write_byte((0x30UL + value / unit % 10).to_byte())
    unit = unit / 10
  }
}

///|
/// The digits of standard base64, in order.
let base64_digits : Bytes = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// Writes `octets` as a JSON string of standard base64, with padding.
fn write_base64(out : Output, octets : BytesView) -> Unit raise DecodeError {
  out.write_byte(b'"')
  let length = octets.length()
  let mut i = 0
  while i + 3 <= length {
    let bits = (octets[i].to_int() << 16) |
      (octets[i + 1].to_int() << 8) |
      octets[i + 2].to_int()
    out.write_byte(base64_digits[bits >> 18])
    out.write_byte(base64_digits[(bits >> 12) & 63])
    out.write_byte(base64_digits[(bits >> 6) & 63])
    out.write_byte(base64_digits[bits & 63])
    i = i + 3
  }
  if length - i == 1 {
    let bits = octets[i].to_int() << 16
    out.write_byte(base64_digits[bits >> 18])
    out.write_byte(base64_digits[(bits >> 12) & 63])
    out.write_bytes(b"==")
  } else if length - i == 2 {
    let bits = (octets[i].to_int() << 16) | (octets[i + 1].to_int() << 8)
    out.write_byte(base64_digits[bits >> 18])
    out.write_byte(base64_digits[(bits >> 12) & 63])
    out.write_byte(base64_digits[(bits >> 6) & 63])
    out.write_byte(b'=')
  }
  out.write_byte(b'"')
}

///|
/// Writes `name`, a field's JSON name or an enum value's name, as a JSON
/// string. Such a name is ASCII without quotes or controls, unless a
/// `json_name` makes it otherwise, so it is written one code unit at a time
/// until a code unit needs more.
fn write_json_name(out : Output, name : String) -> Unit raise DecodeError {
  for i in 0..<name.length() {
    let unit = name[i]
    if unit < 0x20 || unit >= 0x7F || unit == '"' || unit == '\\' {
      write_json_string(out, @utf8.encode(name))
      return
    }
  }
  out.write_byte(b'"')
  for i in 0..<name.length() {
    out.write_byte(name[i].to_byte())
  }
  out.write_byte(b'"')
}

///|
/// Writes the key of an extension whose full name is `full_name`, as
/// ProtoJSON writes it: the full name in brackets, as a JSON string, such
/// as `"[shop.priority]"`.
fn write_extension_name(
  out : Output,
  full_name : String,
) -> Unit raise DecodeError {
  // A full name is ASCII without quotes or controls, as protoc writes it,
  // but a set may hold any, so it is written as `write_json_name` writes a
  // name.
  for i in 0..<full_name.length() {
    let unit = full_name[i]
    if unit < 0x20 || unit >= 0x7F || unit == '"' || unit == '\\' {
      write_json_string(out, @utf8.encode("[" + full_name + "]"))
      return
    }
  }
  out.write_bytes(b"\"[")
  for i in 0..<full_name.length() {
    out.write_byte(full_name[i].to_byte())
  }
  out.write_bytes(b"]\"")
}

///|
/// The length of the UTF-8 sequence that starts at `at` in `octets`, from
/// 1 to 4, when it is well formed, or else minus the length of its maximal
/// subpart: the longest start of a well-formed sequence there, or its first
/// octet, which a decoder replaces with one U+FFFD (Unicode, section 3.9),
/// as `@utf8.decode_lossy` does. It reads no octet past the sequence.
fn utf8_sequence(octets : BytesView, at : Int32) -> Int32 {
  let first = octets[at].to_int()
  if first < 0x80 {
    return 1
  }
  // The sequence's length, and the range of its second octet: the others
  // are from 0x80 to 0xBF.
  let mut length = 0
  let mut low = 0x80
  let mut high = 0xBF
  if first >= 0xC2 && first <= 0xDF {
    length = 2
  } else if first == 0xE0 {
    length = 3
    low = 0xA0
  } else if first == 0xED {
    length = 3
    high = 0x9F
  } else if first >= 0xE1 && first <= 0xEF {
    length = 3
  } else if first == 0xF0 {
    length = 4
    low = 0x90
  } else if first == 0xF4 {
    length = 4
    high = 0x8F
  } else if first >= 0xF1 && first <= 0xF3 {
    length = 4
  } else {
    return -1
  }
  for k in 1..<length {
    if at + k >= octets.length() {
      return -k
    }
    let octet = octets[at + k].to_int()
    if octet < low || octet > high {
      return -k
    }
    low = 0x80
    high = 0xBF
  }
  length
}

///|
/// The length of `octets` repaired: each maximal subpart that is not UTF-8
/// replaced with U+FFFD, 3 octets, as `repaired` repairs it.
fn repaired_length(octets : BytesView) -> Int32 {
  let mut length = 0
  let mut i = 0
  while i < octets.length() {
    let sequence = utf8_sequence(octets, i)
    if sequence > 0 {
      length += sequence
      i += sequence
    } else {
      length += 3
      i -= sequence
    }
  }
  length
}

///|
/// `octets`, which are not UTF-8, as UTF-8, with U+FFFD for each maximal
/// subpart that is not, as smock reads header values.
fn repaired(octets : BytesView) -> BytesView {
  let out = @buffer.Buffer(size_hint=repaired_length(octets))
  let mut i = 0
  while i < octets.length() {
    let sequence = utf8_sequence(octets, i)
    if sequence > 0 {
      out.write_bytes(octets[i:i + sequence])
      i += sequence
    } else {
      out.write_bytes(b"\xef\xbf\xbd")
      i -= sequence
    }
  }
  out.to_bytes()
}

///|
/// Whether `octets` are UTF-8. It allocates nothing.
fn is_utf8(octets : BytesView) -> Bool {
  let mut i = 0
  while i < octets.length() {
    if octets[i] < b'\x80' {
      i += 1
      continue
    }
    let sequence = utf8_sequence(octets, i)
    if sequence < 0 {
      return false
    }
    i += sequence
  }
  true
}

///|
/// Writes `octets`, UTF-8 text, as a JSON string: in quotes, with `"`, `\`
/// and the control characters escaped as `@json` escapes them. With
/// `repair`, `octets` need not be UTF-8: each maximal subpart that is not
/// is written as U+FFFD, as `repaired` repairs it, with no copy made.
fn write_json_string(
  out : Output,
  octets : BytesView,
  repair~ : Bool = false,
) -> Unit raise DecodeError {
  out.write_byte(b'"')
  let mut i = 0
  while i < octets.length() {
    let octet = octets[i]
    i += 1
    match octet {
      _ if octet >= b'\x80' && repair => {
        let sequence = utf8_sequence(octets, i - 1)
        if sequence > 0 {
          out.write_bytes(octets[i - 1:i - 1 + sequence])
          i = i - 1 + sequence
        } else {
          out.write_bytes(b"\xef\xbf\xbd")
          i = i - 1 - sequence
        }
      }
      b'"' => out.write_bytes(b"\\\"")
      b'\\' => out.write_bytes(b"\\\\")
      b'\n' => out.write_bytes(b"\\n")
      b'\r' => out.write_bytes(b"\\r")
      b'\t' => out.write_bytes(b"\\t")
      b'\x08' => out.write_bytes(b"\\b")
      b'\x0c' => out.write_bytes(b"\\f")
      _ if octet < b'\x20' => {
        out.write_bytes(b"\\u00")
        out.write_byte(hex_digit(octet.to_int() >> 4))
        out.write_byte(hex_digit(octet.to_int() & 15))
      }
      _ => out.write_byte(octet)
    }
  }
  out.write_byte(b'"')
}

///|
/// The lower-case hex digit of `n`, from 0 to 15.
fn hex_digit(n : Int32) -> Byte {
  if n < 10 {
    (0x30 + n).to_byte()
  } else {
    (0x61 + n - 10).to_byte()
  }
}
