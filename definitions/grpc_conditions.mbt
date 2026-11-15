// gRPC Stubs' `json` body conditions, checked against the input type of
// the Stub's method when the files load, and normalised to smock's decoded
// form, in which a call's message reaches the Stubs. A key must name a
// field of the type at its place, by its proto name or its JSON name, and
// becomes its JSON name; or an extension of the set that extends the type,
// by its full name in brackets, such as `[shop.priority]`, as ProtoJSON
// writes it, which stays. A group is a message. A literal must be a value
// of its field's type as smock prints it
// (`@protobuf.DescriptorSet::printed_value`): an enum number or alias
// becomes the enum's first name, and a float is rounded to 32 bits. A
// well-known type with a form of its own, such as a Duration, must be in
// its printed form, `"1.500s"`, not `"1.5s"`. Map keys are data, never
// rewritten, and must be printed keys. Patterns and operators are allowed
// in any place. So matching a call costs nothing more than matching a JSON
// body.
//
// Their exact `headers` conditions on binary metadata, whose name ends with
// `-bin`, lose their base64 padding at load, as a call's values do when it
// arrives, so that a condition written padded or not meets padded and
// unpadded clients alike.

///|
/// `request`, the conditions of a gRPC Stub, with each exact `headers`
/// condition on binary metadata, `$not`'s included, without the padding
/// that ends each comma-separated element of its value
/// (`@grpc.unpadded_elements`), as a call's values reach the Stubs.
/// Patterns are kept, and see the unpadded values. The value is not
/// checked as base64. `request` itself when no condition changes.
fn unpadded_conditions(request : Conditions) -> Conditions {
  let headers = []
  let mut changed = false
  for header in request.headers {
    let (name, condition) = header
    match unpadded_condition(name, condition) {
      Some(unpadded) => {
        headers.push((name, unpadded))
        changed = true
      }
      None => headers.push(header)
    }
  }
  guard changed else { return request }
  { ..request, headers: ReadOnlyArray::from_array(headers), }
}

///|
/// `condition`, a `headers` condition on `name`, with its exact value
/// unpadded when `name` is that of binary metadata, or `None` when that
/// changes nothing.
fn unpadded_condition(
  name : String,
  condition : ValueCondition,
) -> ValueCondition? {
  guard @grpc.is_binary_name(name) else { return None }
  match condition {
    Has(Exact(value)) => {
      let unpadded = @grpc.unpadded_elements(value)
      guard !physical_equal(unpadded, value) else { return None }
      Some(Has(Exact(unpadded)))
    }
    Not(inner) =>
      match unpadded_condition(name, inner) {
        Some(unpadded) => Some(Not(unpadded))
        None => None
      }
    Has(Pattern(_) | Any) | Exists(_) => None
  }
}

///|
/// Where a value of a gRPC Stub's `json` condition is, in the input type,
/// which says what the value is checked against.
priv enum Place {
  /// The whole message, of this type.
  Whole(@protobuf.MessageDescriptor)
  /// The message that an Any holds, of this type, a well-known type with a
  /// form of its own, given as the Any's `value`.
  Held(@protobuf.MessageDescriptor)
  /// The value of a field of a message: a map's entries, a repeated
  /// field's elements, or a singular field's value.
  Of(@protobuf.MessageDescriptor, @protobuf.FieldDescriptor)
  /// One element of a repeated field of a message.
  Element(@protobuf.MessageDescriptor, @protobuf.FieldDescriptor)
  /// One value of a map field of a message, whose values are those of the
  /// entry's field 2, the third.
  Value(
    @protobuf.MessageDescriptor,
    @protobuf.FieldDescriptor,
    @protobuf.FieldDescriptor
  )
  /// A value that a google.protobuf.Value holds, as a Struct's members
  /// and a ListValue's elements are: any JSON value, whose numbers are
  /// printed as doubles. An object's keys are data.
  Data
}

///|
/// The check of the values of one `json` condition, or of one sample
/// message, against the types of a Descriptor set. It holds what stays the
/// same from value to value, while the JSON Pointer of the value moves.
priv struct ConditionCheck {
  /// The file that each problem is reported in.
  file : File
  /// The set whose types the values are checked against: that of the
  /// Stub's Mock.
  set : @protobuf.DescriptorSet
}

///|
/// `request`, the conditions of the gRPC Stub `stub` at `pointer`, with its
/// `json` body condition checked against `input`, the input type of its
/// method, a type of `set`, and normalised, as this file's header says.
/// Each problem is reported at the JSON Pointer of the value at fault, and
/// then the conditions are returned as they were read.
fn File::grpc_conditions(
  self : File,
  pointer : String,
  stub : Map[String, Json],
  request : Conditions,
  set : @protobuf.DescriptorSet,
  input : @protobuf.MessageDescriptor,
) -> Conditions {
  // A condition that does not read is reported where it is read, and is
  // not checked again here.
  guard request.body is Some(Json(_)) &&
    stub.get("request") is Some(Object(written)) &&
    written.get("body") is Some(Object(body)) &&
    body.get("json") is Some(json) else {
    return request
  }
  let at = child_pointer(child_pointer(pointer, "body"), "json")
  let check : ConditionCheck = { file: self, set, }
  guard check.grpc_condition(at, Whole(input), json) is Some(normalised) &&
    self.read_json_condition(at, normalised) is Some(condition) else {
    return request
  }
  { ..request, body: Some(Json(condition)), }
}

///|
/// `json`, the message of a sample request that renders a gRPC Stub, a
/// message of the type `input`, a type of `set`, as JSON, checked against
/// the type and normalised as a gRPC Stub's `json` condition is when the
/// files load, as this file's header says: a key that names a field by its
/// proto name becomes its JSON name, an enum number or alias the enum's
/// first name, and a float is rounded to 32 bits, while a value that smock
/// never prints in that form, such as a Duration of `"1.5s"`, is refused.
/// A pattern or an operator is kept as a condition's is; the encoder, which
/// the caller runs next, refuses it as a value of no field.
///
/// Returns the normalised message, or every problem found, with the
/// messages a condition gets. A problem has no file (`""`), and its JSON
/// Pointer points into `json`.
pub fn sample_message(
  set : @protobuf.DescriptorSet,
  input : @protobuf.MessageDescriptor,
  json : Json,
) -> Result[Json, Array[Diagnostic]] {
  let diagnostics = []
  let file = File::{
    name: "",
    diagnostics,
    body_files: None,
    env: @template.no_env,
    buckets: Map([]),
    sets: no_declared_sets,
    header_size_limit: default_header_size_limit,
  }
  let check : ConditionCheck = { file, set, }
  match check.grpc_condition("", Whole(input), json) {
    Some(normalised) if diagnostics.is_empty() => Ok(normalised)
    _ => Err(diagnostics)
  }
}

///|
/// `json`, the value at `pointer` of a gRPC Stub's `json` condition, which
/// is at `place` in a type of the set, checked and normalised. A pattern
/// object is kept, wherever it is. An operator's operand is at the same
/// place, but that of `$includes` and `$last` on a repeated field, which is
/// one of its elements. `None` when it has a problem, each reported.
fn ConditionCheck::grpc_condition(
  self : ConditionCheck,
  pointer : String,
  place : Place,
  json : Json,
) -> Json? {
  if json is Object(members) {
    if members.length() == 1 && members.get("pattern") is Some(String(_)) {
      return Some(json)
    }
    if operator_key(members) is Some(key) {
      // The condition was read, so the operator is the only key.
      guard members.get(key) is Some(operand) && key != "$exists" else {
        return Some(json)
      }
      let operand_place = match place {
        Of(message, field) if key is ("$includes" | "$last") &&
          field.label is Repeated &&
          map_fields(self.set, field) is None => Element(message, field)
        _ => place
      }
      return self
        .grpc_condition(child_pointer(pointer, key), operand_place, operand)
        .map(operand => Json::object(Map([(key, operand)])))
    }
  }
  match place {
    // A well-known type with a form of its own is checked in that form.
    Whole(message) | Held(message) =>
      try self.set.printed_message(message, json) catch {
        error => {
          let subject = if place is Held(_) {
            "the Any holds a \{message.full_name}"
          } else {
            "the message is a \{message.full_name}"
          }
          self.file.printed_error(pointer, error, subject)
          None
        }
      } noraise {
        printed => self.form_condition(pointer, message, printed)
      }
    Of(message, field) =>
      match map_fields(self.set, field) {
        Some((key_field, value_field)) => {
          guard json is Object(entries) else {
            self.file.error(
              pointer,
              "must be an object: the field \{field.name} of \{message.full_name} is a map",
            )
            return None
          }
          self.map_condition(
            pointer, message, field, key_field, value_field, entries,
          )
        }
        None if field.label is Repeated => {
          guard json is Array(items) else {
            self.file.error(
              pointer,
              "must be an array: the \{field_text(field, message)} is repeated",
            )
            return None
          }
          let out = []
          for i, item in items {
            if self.grpc_condition(
                child_pointer(pointer, i.to_string()),
                Element(message, field),
                item,
              )
              is Some(item) {
              out.push(item)
            }
          }
          guard out.length() == items.length() else { return None }
          Some(Json::array(out))
        }
        None =>
          self.value_condition(
            pointer,
            field,
            json,
            "the \{field_text(field, message)} has the type \{type_text(field)}",
          )
      }
    Element(message, field) =>
      self.value_condition(
        pointer,
        field,
        json,
        "the elements of the \{field_text(field, message)} have the type \{type_text(field)}",
      )
    Value(message, field, value_field) =>
      self.value_condition(
        pointer,
        value_field,
        json,
        "the values of the map field \{field.name} of \{message.full_name} have the type \{type_text(value_field)}",
      )
    Data =>
      match json {
        Object(members) => self.data_object(pointer, members)
        Array(items) => self.data_array(pointer, items)
        _ =>
          try @protobuf.printed_json_value(json) catch {
            error => {
              self.file.printed_error(
                pointer, error, "it is a value of a google.protobuf.Value",
              )
              None
            }
          } noraise {
            value => Some(value)
          }
      }
  }
}

///|
/// `printed`, the value at `pointer` of a condition on a message of the
/// type `message`, a type of the set, in the form `printed_message` or
/// `printed_value` returned it, with its members checked and normalised as
/// the type's JSON form says: an object of fields as a message, a Struct's
/// members and a ListValue's elements as values that a Value holds, a
/// Value's object and array as a Struct and a ListValue, and an Any as
/// `any_condition` says. Any other value is returned as it is.
fn ConditionCheck::form_condition(
  self : ConditionCheck,
  pointer : String,
  message : @protobuf.MessageDescriptor,
  printed : Json,
) -> Json? {
  match (message.json_form(), printed) {
    (Fields, Object(members)) =>
      self.message_condition(pointer, message, members)
    (Struct | Value, Object(members)) => self.data_object(pointer, members)
    (ListValue | Value, Array(items)) => self.data_array(pointer, items)
    (Any, Object(members)) => self.any_condition(pointer, members)
    (_, value) => Some(value)
  }
}

///|
/// `members`, the object at `pointer` that is a condition on a Struct, a
/// type of the set, with each value checked and normalised as a value that a
/// Value holds. Its keys are data and are kept as written, `$$` included.
fn ConditionCheck::data_object(
  self : ConditionCheck,
  pointer : String,
  members : Map[String, Json],
) -> Json? {
  let out : Map[String, Json] = Map([])
  let mut valid = true
  for key, value in members {
    match self.grpc_condition(child_pointer(pointer, key), Data, value) {
      Some(value) => out[key] = value
      None => valid = false
    }
  }
  if valid {
    Some(Json::object(out))
  } else {
    None
  }
}

///|
/// `items`, the array at `pointer` that is a condition on a ListValue, a
/// type of the set, with each element checked and normalised as a value that
/// a Value holds.
fn ConditionCheck::data_array(
  self : ConditionCheck,
  pointer : String,
  items : Array[Json],
) -> Json? {
  let out = []
  for i, item in items {
    if self.grpc_condition(child_pointer(pointer, i.to_string()), Data, item)
      is Some(item) {
      out.push(item)
    }
  }
  guard out.length() == items.length() else { return None }
  Some(Json::array(out))
}

///|
/// `members`, the object at `pointer` that is a condition on an Any, a type
/// of the set, checked and normalised against the type that its `@type`
/// names, as smock prints an Any: `@type` is a type URL, kept as written,
/// whose type is a type of the set; the other members are the fields of a
/// message of that type, or its form as `value` when it is a well-known
/// type that has one. `{}` is kept. `@type` may be a pattern or an operator
/// only when it is the only member, since the other members are checked
/// against the type it names.
fn ConditionCheck::any_condition(
  self : ConditionCheck,
  pointer : String,
  members : Map[String, Json],
) -> Json? {
  let at_type = child_pointer(pointer, "@type")
  let a_url = "a type URL: / and the full name of a type of the set at its end, such as \"type.googleapis.com/helloworld.HelloRequest\""
  guard members.get("@type") is Some(type_url) else {
    if members.is_empty() {
      return Some(Json::object(members))
    }
    self.file.error(
      pointer, "must give \"@type\", the type URL of the message the Any holds, so that its other members can be checked against its type",
    )
    return None
  }
  guard type_url is String(url) else {
    if members.length() > 1 {
      self.file.error(
        at_type,
        "must be \{a_url}, when the Any gives other members: they are checked against the type it names",
      )
      return None
    }
    if type_url is Object(_) {
      // A pattern or an operator, which the condition reads.
      return Some(Json::object(members))
    }
    self.file.error(at_type, "must be \{a_url}")
    return None
  }
  guard @protobuf.type_name_of_url(url) is Some(name) else {
    self.file.error(at_type, "must be \{a_url}")
    return None
  }
  guard self.set.find_message(name) is Some(held) else {
    self.file.error(
      at_type,
      "names the type \{name}, which the Descriptor set does not define",
    )
    return None
  }
  let out : Map[String, Json] = Map([("@type", type_url)])
  if held.json_form() is Fields {
    let fields : Map[String, Json] = Map([])
    for key, value in members {
      if key != "@type" {
        fields[key] = value
      }
    }
    guard self.message_condition(pointer, held, fields)
      is Some(Object(normalised)) else {
      return None
    }
    for key, value in normalised {
      out[key] = value
    }
    return Some(Json::object(out))
  }
  let mut valid = true
  for key, value in members {
    match key {
      "@type" => ()
      "value" =>
        match
          self.grpc_condition(child_pointer(pointer, key), Held(held), value) {
          Some(value) => out[key] = value
          None => valid = false
        }
      _ => {
        self.file.error(
          child_pointer(pointer, key),
          "is not a member of an Any that holds a \{held.full_name}: give the \{held.full_name} as \"value\"",
        )
        valid = false
      }
    }
  }
  if valid {
    Some(Json::object(out))
  } else {
    None
  }
}

///|
/// `members`, the object at `pointer` that is a condition on a message of
/// the type `message`, a type of the set, with each key, which must name a
/// field by its proto name or its JSON name, once, as the field's JSON
/// name, and each value checked and normalised at the field's place.
fn ConditionCheck::message_condition(
  self : ConditionCheck,
  pointer : String,
  message : @protobuf.MessageDescriptor,
  members : Map[String, Json],
) -> Json? {
  let out : Map[String, Json] = Map([])
  // The key that gave each field, by its number.
  let given : Map[Int32, String] = Map([])
  let mut valid = true
  for key, value in members {
    let at = child_pointer(pointer, key)
    if is_extension_key(key) {
      // An extension has one key, its full name in brackets, which stays.
      match self.extension_condition(at, message, key, value) {
        Some(value) => out[key] = value
        None => valid = false
      }
      continue
    }
    let field = match message.find_field_by_json_name(key) {
      Some(field) => Some(field)
      None => message.find_field_by_name(key)
    }
    guard field is Some(field) else {
      self.file.error(at, "is not a field of \{message.full_name}")
      valid = false
      continue
    }
    if given.get(field.number) is Some(other) {
      self.file.error(
        at,
        "names the field \{field.name} of \{message.full_name}, as \{other.escape()} does: give a field once, by its proto name or its JSON name",
      )
      valid = false
      continue
    }
    given[field.number] = key
    match self.grpc_condition(at, Of(message, field), value) {
      Some(value) => out[field.json_name] = value
      None => valid = false
    }
  }
  if valid {
    Some(Json::object(out))
  } else {
    None
  }
}

///|
/// Whether `key`, a key of a condition on a message, names an extension, as
/// ProtoJSON writes it: its full name in brackets, such as
/// `[shop.priority]`.
fn is_extension_key(key : String) -> Bool {
  key.length() > 2 && key.has_prefix("[") && key.has_suffix("]")
}

///|
/// `value`, the value at `pointer` of the member `key` of a condition on a
/// message of the type `message`, a type of the set, where `key` is an
/// extension's full name in brackets, checked and normalised at the
/// extension's place. The set must have an extension of that name that
/// extends the type. `None` when it has a problem, each reported.
fn ConditionCheck::extension_condition(
  self : ConditionCheck,
  pointer : String,
  message : @protobuf.MessageDescriptor,
  key : String,
  value : Json,
) -> Json? {
  let name = key[1:key.length() - 1].to_owned()
  guard self.set.find_extension(name) is Some(extension) else {
    self.file.error(
      pointer,
      "is not an extension of \{message.full_name}: the Descriptor set has no extension \{name}",
    )
    return None
  }
  guard message.find_extension(extension.number) is Some(found) &&
    physical_equal(found, extension) else {
    self.file.error(
      pointer,
      "is not an extension of \{message.full_name}: \{name} extends \{without_dot(extension.extendee)}",
    )
    return None
  }
  self.grpc_condition(pointer, Of(message, extension), value)
}

///|
/// `type_name`, the full name of a type as a set gives it, without its
/// leading dot.
fn without_dot(type_name : String) -> String {
  if type_name.has_prefix(".") {
    type_name[1:].to_owned()
  } else {
    type_name
  }
}

///|
/// `field`, a field of `message` or an extension that extends it, as a
/// problem names it: `field` and its name, such as `field id of
/// shop.Order`, or `extension` and its full name, such as `extension
/// shop.priority of shop.Order`.
fn field_text(
  field : @protobuf.FieldDescriptor,
  message : @protobuf.MessageDescriptor,
) -> String {
  if field.extendee != "" {
    "extension \{field.full_name} of \{message.full_name}"
  } else {
    "field \{field.name} of \{message.full_name}"
  }
}

///|
/// `entries`, the object at `pointer` that is a condition on the map field
/// `field` of `message`, whose entries have the key field `key_field` and
/// the value field `value_field`, with each value checked and normalised.
/// Its keys are data and are kept as written, `$$` included; each must be
/// a key as smock prints it.
fn ConditionCheck::map_condition(
  self : ConditionCheck,
  pointer : String,
  message : @protobuf.MessageDescriptor,
  field : @protobuf.FieldDescriptor,
  key_field : @protobuf.FieldDescriptor,
  value_field : @protobuf.FieldDescriptor,
  entries : Map[String, Json],
) -> Json? {
  let out : Map[String, Json] = Map([])
  let mut valid = true
  let keys = "the keys of the map field \{field.name} of \{message.full_name} have the type \{type_text(key_field)}"
  for key, value in entries {
    let at = child_pointer(pointer, key)
    // `$$name` is the key `$name`.
    let data = if key.has_prefix("$$") { key[1:].to_owned() } else { key }
    let key_valid = try key_field.check_printed_key(data) catch {
      NotOfType(wanted~) => {
        self.file.error(at, "must be \{wanted}: \{keys}")
        false
      }
      NotPrinted(printed~) => {
        self.file.error(
          at,
          "must be written \{printed}, as smock prints it: \{keys}",
        )
        false
      }
    } noraise {
      _ => true
    }
    match self.grpc_condition(at, Value(message, field, value_field), value) {
      Some(value) if key_valid => out[key] = value
      _ => valid = false
    }
  }
  if valid {
    Some(Json::object(out))
  } else {
    None
  }
}

///|
/// `json`, the value at `pointer` of a condition on one value of `field`,
/// a field of a type of the set, checked and normalised: an object of a
/// message field is a condition on its message; any other value is a
/// literal, in its printed form, a well-known type's value included.
/// `subject` says what the value is a value of, as a problem says it.
fn ConditionCheck::value_condition(
  self : ConditionCheck,
  pointer : String,
  field : @protobuf.FieldDescriptor,
  json : Json,
  subject : String,
) -> Json? {
  try self.set.printed_value(field, json) catch {
    error => {
      self.file.printed_error(pointer, error, subject)
      None
    }
  } noraise {
    printed =>
      match self.set.message_of(field) {
        Some(message) => self.form_condition(pointer, message, printed)
        None => Some(printed)
      }
  }
}

///|
/// Reports at `pointer` that a value of a condition is not in the form
/// smock prints it, as `error` says, where `subject` says what the value
/// is a value of.
fn File::printed_error(
  self : File,
  pointer : String,
  error : @protobuf.PrintedError,
  subject : String,
) -> Unit {
  match error {
    NotOfType(wanted~) => self.error(pointer, "must be \{wanted}: \{subject}")
    NotPrinted(printed~) =>
      self.error(
        pointer,
        "must be written \{printed}, as smock prints it: \{subject}",
      )
  }
}

///|
/// The key field and the value field of `field`, a field of a type of
/// `set`, when it is a map.
fn map_fields(
  set : @protobuf.DescriptorSet,
  field : @protobuf.FieldDescriptor,
) -> (@protobuf.FieldDescriptor, @protobuf.FieldDescriptor)? {
  guard field.label is Repeated &&
    set.message_of(field) is Some(entry) &&
    entry.map_entry &&
    entry.find_field_by_number(1) is Some(key_field) &&
    entry.find_field_by_number(2) is Some(value_field) else {
    return None
  }
  Some((key_field, value_field))
}

///|
/// The type of `field`, as a problem names it: a scalar type as a .proto
/// file spells it, such as `uint64`, or the full name of a message or an
/// enum type, without its leading dot.
fn type_text(field : @protobuf.FieldDescriptor) -> String {
  match field.type_ {
    Message | Group | Enum =>
      if field.type_name.has_prefix(".") {
        field.type_name[1:].to_owned()
      } else {
        field.type_name
      }
    type_ => "\{type_}"
  }
}
