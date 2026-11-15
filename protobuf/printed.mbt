// JSON values checked against a field's type as `decode_json` prints it:
// smock's decoded form. A value in that form is kept, and a value that
// means the same, such as an enum number, a float that rounding changes or
// an integer written with an exponent, becomes the printed one. A value
// that ProtoJSON reads but `decode_json` never prints, such as a 64-bit
// integer written as a string, bytes in URL-safe base64 or a Duration of
// `"1.5s"`, is refused with the printed form, and any other value with
// what the field takes. smock checks its gRPC Stubs' conditions with these
// when the files load.

///|
/// Why a JSON value is not a value of a field as `decode_json` prints it.
#derive(Eq, Debug)
pub(all) suberror PrintedError {
  /// It is not a value of the field's type, or it is one that
  /// `decode_json` cannot print: `wanted` says what the field takes, such
  /// as `an integer from 0 to 4294967295`.
  NotOfType(wanted~ : String)
  /// It is a value of the field's type, which ProtoJSON reads, but
  /// `decode_json` prints that value otherwise: as `printed`, JSON text,
  /// such as `42` for `"42"`.
  NotPrinted(printed~ : String)
}

///|
/// `json`, one value of `field`, a field of a message of this set, as
/// `decode_json` prints it: the value of a singular field, or one element
/// of a repeated one. A value in that form is returned as it is, and one
/// that means the same is returned in that form:
///
/// - an integer is a number in its type's range, which may be written with
///   an exponent or a fraction of zeros, such as `1e3` or `42.0`; it is
///   returned in decimal, exact at any size;
/// - a `float` is a number within the range of a float, rounded to the
///   nearest one and returned in the shortest form that reads back as it,
///   as `decode_json` prints it, so `16777217` gives `16777216`; a
///   `double` is a number, returned as `decode_json` prints it; either may
///   be `"NaN"`, `"Infinity"` or `"-Infinity"`;
/// - a `bool` is `true` or `false`, and a `string` a string;
/// - `bytes` is a string of standard base64 with its padding;
/// - an enum is the name of one of its values, or a number from the int32
///   range, and is returned as the first name of its number, or as the
///   number when no value has it, as an open enum allows; a closed enum,
///   as a proto2 enum is, takes only the numbers it defines;
/// - a message is checked as `printed_message` checks it: an object, whose
///   members are not checked here, or a well-known type in its form.
///
/// Raises `NotPrinted` with the printed form for a value that ProtoJSON
/// reads but `decode_json` prints otherwise: an integer, a float or a
/// double written as a string, bytes in URL-safe base64, without its
/// padding or with bits after its last octet, and a Timestamp or a Duration
/// as `printed_message` says. Raises `NotOfType` for any other value, a
/// float outside the float range included.
pub fn DescriptorSet::printed_value(
  self : DescriptorSet,
  field : FieldDescriptor,
  json : Json,
) -> Json raise PrintedError {
  let unfit = NotOfType(wanted=self.printed_wanted(field))
  match field.type_ {
    Bool => if json is (True | False) { json } else { raise unfit }
    String => if json is String(_) { json } else { raise unfit }
    Bytes => {
      guard json is String(text) else { raise unfit }
      let octets = base64_octets(text) catch { _ => raise unfit }
      // The printed form, as JSON text: the string in its quotes.
      let out = @buffer.Buffer(size_hint=text.length() + 4)
      write_base64(out, octets)
      let printed = @utf8.decode(out.to_bytes()) catch { _ => raise unfit }
      if printed.length() == text.length() + 2 &&
        printed[1:printed.length() - 1] == text {
        json
      } else {
        raise NotPrinted(printed~)
      }
    }
    Message | Group =>
      match self.message_of(field) {
        Some(message) => self.printed_message(message, json)
        None => raise unfit
      }
    Float | Double => {
      if json is String("NaN" | "Infinity" | "-Infinity") {
        return json
      }
      let n = floating(json) catch { _ => raise unfit }
      let printed = if field.type_ is Float {
        let rounded = Float::from_double(n)
        if rounded.is_inf() {
          // Outside the range of a float.
          raise unfit
        }
        rounded.to_string()
      } else {
        n.to_string()
      }
      if json is String(_) {
        raise NotPrinted(printed~)
      }
      number_of(printed)
    }
    Enum => {
      guard self.enum_of(field) is Some(type_) else { raise unfit }
      let null_value = type_.full_name == "google.protobuf.NullValue"
      if null_value && json is Null {
        return json
      }
      let number = match json {
        String(name) =>
          match type_.find_value_by_name(name) {
            Some(value) => value.number
            None => raise unfit
          }
        Number(_) =>
          integer_bits(json, signed=true, wide=false)
          .reinterpret_as_int64()
          .to_int() catch {
            _ => raise unfit
          }
        _ => raise unfit
      }
      match type_.find_value_by_number(number) {
        // NullValue, whose values print as null, whatever their number.
        _ if null_value => Json::null()
        Some(value) => Json::string(value.name)
        // A closed enum, as a proto2 enum is, keeps a number it does not
        // define as an unknown field, which a message never prints.
        None if type_.syntax is Proto2 => raise unfit
        None => number_of(number.to_string())
      }
    }
    type_ => {
      guard json is (Number(_) | String(_)) else { raise unfit }
      let signed = type_
        is (Int32 | Int64 | SInt32 | SInt64 | SFixed32 | SFixed64)
      let wide = type_ is (Int64 | UInt64 | SInt64 | Fixed64 | SFixed64)
      let bits = integer_bits(json, signed~, wide~) catch { _ => raise unfit }
      let printed = decimal(bits, signed~)
      if json is String(_) {
        raise NotPrinted(printed~)
      }
      number_of(printed)
    }
  }
}

///|
/// `json`, a whole message of the type `message`, a type of this set, as
/// `decode_json` prints it. A message that it prints as an object of its
/// fields, Empty included, must be an object, which is returned as it is:
/// its members are not checked here. A well-known type with a form of its
/// own must be in that form, as ProtoJSON reads it, and is returned as it
/// is when `decode_json` prints that value so:
///
/// - a Timestamp is a string of a date and time, printed in UTC, with 0,
///   3, 6 or 9 fractional digits, such as `"1970-01-01T00:00:01.500Z"`;
/// - a Duration is a string of seconds with 0, 3, 6 or 9 fractional
///   digits, then `s`, such as `"1.500s"`;
/// - a FieldMask is a string of paths in lowerCamelCase, joined by commas;
/// - a wrapper is a value of the type it wraps, as `printed_value` checks
///   it, so a FloatValue is rounded to the nearest float.
///
/// Raises `NotPrinted` with the printed form, as JSON text, for a
/// Timestamp or a Duration that ProtoJSON reads but `decode_json` prints
/// otherwise, such as `"1.5s"` for `"1.500s"`, or a Timestamp with an
/// offset other than `Z`. Raises `NotOfType` for any value that is not one
/// of the type, or that is out of its range.
pub fn DescriptorSet::printed_message(
  self : DescriptorSet,
  message : MessageDescriptor,
  json : Json,
) -> Json raise PrintedError {
  guard well_known_form(message) is Some(form) else {
    if json is Object(_) {
      return json
    }
    raise NotOfType(wanted="an object")
  }
  let unfit = NotOfType(wanted=self.wanted_message(message))
  match (form, json) {
    (Wrapper(index), _) =>
      return self.printed_value(message.fields[index], json)
    // Their members are the caller's to check, as a message's are.
    (Struct(_) | Any, Object(_)) | (ListValue(_), Array(_)) => return json
    (Struct(_) | Any | ListValue(_), _) => raise unfit
    (Value, _) => return printed_json_value(json)
    (Timestamp | Duration | FieldMask, _) => ()
  }
  // The value as ProtoJSON reads it, encoded, then printed as
  // `decode_json` prints it.
  guard json is String(text) else { raise unfit }
  let writer = Writer()
  self.write_well_known(writer, message, form, json, 0) catch {
    _ => raise unfit
  }
  let out = @buffer.Buffer(size_hint=text.length() + 16)
  self.print_well_known(
    out,
    message,
    form,
    [writer.to_bytes()[:]],
    0,
    canonical=false,
  ) catch {
    _ => raise unfit
  }
  let printed = @utf8.decode(out.to_bytes()) catch { _ => raise unfit }
  if printed.length() == text.length() + 2 &&
    printed[1:printed.length() - 1] == text {
    json
  } else {
    raise NotPrinted(printed~)
  }
}

///|
/// `json`, a value that a google.protobuf.Value holds, as `decode_json`
/// prints it: a number is printed as a double is, and any other value is
/// returned as it is. The members of an object, a Struct, and the elements
/// of an array, a ListValue, are Values too, and the caller's to check.
///
/// Raises `NotOfType` for a number beyond the range of a double, which no
/// Value holds.
pub fn printed_json_value(json : Json) -> Json raise PrintedError {
  guard json is Number(_) else { return json }
  let n = floating(json) catch {
    _ =>
      raise NotOfType(
        wanted="a JSON value: null, a number within the range of a double, a string, true or false, an object or an array",
      )
  }
  number_of(n.to_string())
}

///|
/// Checks that `key`, a key of a map whose key field is this field, is in
/// the form `decode_json` prints it: an integer in decimal, with no `+`,
/// no leading zeros and no `-0`; `true` or `false`; or any string, for a
/// map whose keys are strings, which are data.
///
/// Raises `NotPrinted` with the printed key, as JSON text, for a key that
/// ProtoJSON reads as the same integer, such as `"007"` or `"1e3"`, and
/// `NotOfType` for any other key that is not one of the field's type.
pub fn FieldDescriptor::check_printed_key(
  self : FieldDescriptor,
  key : String,
) -> Unit raise PrintedError {
  let wanted = match self.type_ {
    Bool => "\"true\" or \"false\""
    type_ => integers_wanted(type_)
  }
  match self.type_ {
    String => ()
    Bool => if !(key is ("true" | "false")) { raise NotOfType(wanted~) }
    type_ => {
      let bits = map_key(type_, key) catch { _ => raise NotOfType(wanted~) }
      let signed = type_
        is (Int32 | Int64 | SInt32 | SInt64 | SFixed32 | SFixed64)
      let printed = decimal(bits, signed~)
      if printed != key {
        raise NotPrinted(printed="\"\{printed}\"")
      }
    }
  }
}

///|
/// What `field`'s values must be in the form `decode_json` prints them, as
/// an error says it: what ProtoJSON reads, as `wanted` says, but bytes,
/// which are printed in standard base64 with padding.
fn DescriptorSet::printed_wanted(
  self : DescriptorSet,
  field : FieldDescriptor,
) -> String {
  match field.type_ {
    Bytes => "a string of standard base64, with padding"
    Message =>
      match self.message_of(field) {
        // A BytesValue's bytes are printed so too.
        Some(message) if well_known_form(message) is Some(Wrapper(index)) =>
          self.printed_wanted(message.fields[index])
        _ => self.wanted(field)
      }
    _ => self.wanted(field)
  }
}

///|
/// What the values of the integer type `type_` must be, as an error says
/// it, such as `an integer from 0 to 4294967295`; for a type that is not
/// an integer, a map key of which no key is, what map keys may be.
fn integers_wanted(type_ : FieldType) -> String {
  match type_ {
    Int32 | SInt32 | SFixed32 => "an integer from -2147483648 to 2147483647"
    Int64 | SInt64 | SFixed64 =>
      "an integer from -9223372036854775808 to 9223372036854775807"
    UInt32 | Fixed32 => "an integer from 0 to 4294967295"
    UInt64 | Fixed64 => "an integer from 0 to 18446744073709551615"
    _ => "an integer, \"true\" or \"false\", or a string"
  }
}

///|
/// `bits`, an integer in two's complement as `integer_bits` gives it, in
/// decimal: as a signed integer when `signed`, else as an unsigned one.
fn decimal(bits : UInt64, signed~ : Bool) -> String {
  if signed {
    bits.reinterpret_as_int64().to_string()
  } else {
    bits.to_string()
  }
}

///|
/// The JSON number that `text`, a number as `decode_json` prints one,
/// reads as, with its digits kept as JSON text keeps them, so that it
/// compares with a printed message's number as the message's own does.
fn number_of(text : String) -> Json {
  @json.parse(text) catch {
    _ => abort("\{text} is not a JSON number")
  }
}
