// What gRPC's server reflection asks of a Descriptor set: each file as the
// set encodes it, without its source info, and the file that defines a
// symbol. Unlike the lookups of lookups.mbt, these walk the set's bytes or
// its model, since reflection asks for them once per request, and nothing
// on a call's path does.

///|
/// The files of `input`, a FileDescriptorSet in protobuf's binary encoding,
/// in the order of the set, each as the set encodes its FileDescriptorProto
/// but without its SourceCodeInfo, field 9 of FileDescriptorProto, as
/// server reflection sends files. Every other field of a file, its custom
/// options and the fields descriptor.proto does not define included, is
/// kept byte for byte, in its order; only a file's own field 9 is cut out,
/// not the field 9 of a message it holds. Fields of the set other than its
/// files are skipped.
///
/// Raises `DecodeError` when the input is not protobuf, when a file is not
/// a length-delimited value, and when a file's records do not parse.
pub fn files_without_source_info(
  input : BytesView,
) -> ReadOnlyArray[Bytes] raise DecodeError {
  let reader = Reader(input)
  let files = []
  while !reader.at_end() {
    match reader.tag() {
      1 => {
        reader.expect(Len)
        files.push(without_source_info(reader.length_delimited()))
      }
      _ => reader.skip()
    }
  }
  ReadOnlyArray::from_array(files)
}

///|
/// `file`, the encoding of a FileDescriptorProto, without its records of
/// field 9, SourceCodeInfo, copied into octets of their own.
fn without_source_info(file : BytesView) -> Bytes raise DecodeError {
  let reader = Reader(file)
  // Where each record of field 9 starts and ends in `file`.
  let cuts : Array[(Int32, Int32)] = []
  let mut cut = 0
  while !reader.at_end() {
    let start = reader.pos
    let field = reader.tag()
    reader.skip()
    if field == 9 {
      cuts.push((start, reader.pos))
      cut += reader.pos - start
    }
  }
  let out = FixedArray::make(file.length() - cut, b'\x00')
  let mut at = 0
  let mut from = 0
  for range in cuts {
    let (start, end) = range
    out.blit_from_bytesview(at, file[from:start])
    at += start - from
    from = end
  }
  out.blit_from_bytesview(at, file[from:])
  out.unsafe_reinterpret_as_bytes()
}

///|
/// The file of the set that defines `symbol`, the full name of a named
/// element without a leading dot, or `None` when no file does. A symbol is
/// a message, nested ones, map entries and groups' types included, such as
/// `shop.v1.Order.Line`; a field, such as `shop.v1.Order.order_id`; an
/// enum; an enum value, named in the scope that holds its enum, as protobuf
/// scopes enum values, such as `shop.ACTIVE` for a value of the enum
/// `shop.Status`; a service; a method, such as `shop.v1.Orders.Get`; or an
/// extension, such as `shop.priority`. Packages and oneofs are not symbols.
pub fn DescriptorSet::find_file_containing_symbol(
  self : DescriptorSet,
  symbol : String,
) -> FileDescriptor? {
  for file in self.files {
    if defines(file, symbol) {
      return Some(file)
    }
  }
  None
}

///|
/// Whether `file` defines `symbol`. Every symbol of a file with a package
/// starts with the package and a dot.
fn defines(file : FileDescriptor, symbol : String) -> Bool {
  let package_name = file.package_name
  if package_name != "" && !is_inside(symbol, package_name) {
    return false
  }
  for service in file.services {
    if service.full_name == symbol {
      return true
    }
    if is_inside(symbol, service.full_name) {
      let scope = service.full_name + "."
      for rpc in service.methods {
        if is_member(symbol, scope, rpc.name) {
          return true
        }
      }
    }
  }
  for message in file.messages {
    if message_defines(message, symbol) {
      return true
    }
  }
  let scope = if package_name == "" { "" } else { package_name + "." }
  for enum_ in file.enums {
    if enum_defines(enum_, scope, symbol) {
      return true
    }
  }
  for extension in file.extensions {
    if extension.full_name == symbol {
      return true
    }
  }
  false
}

///|
/// Whether `message` is `symbol`, or defines it: a field, a nested message,
/// an enum, a value of such an enum or an extension declared in it, at any
/// depth.
fn message_defines(message : MessageDescriptor, symbol : String) -> Bool {
  if message.full_name == symbol {
    return true
  }
  if !is_inside(symbol, message.full_name) {
    return false
  }
  for field in message.fields {
    if field.full_name == symbol {
      return true
    }
  }
  for nested in message.messages {
    if message_defines(nested, symbol) {
      return true
    }
  }
  let scope = message.full_name + "."
  for enum_ in message.enums {
    if enum_defines(enum_, scope, symbol) {
      return true
    }
  }
  for extension in message.extensions {
    if extension.full_name == symbol {
      return true
    }
  }
  false
}

///|
/// Whether `enum_`, whose values are named in `scope`, the full name of
/// the package or message that holds it and a dot, or `""` at the root, is
/// `symbol`, or has a value that is.
fn enum_defines(
  enum_ : EnumDescriptor,
  scope : String,
  symbol : String,
) -> Bool {
  if enum_.full_name == symbol {
    return true
  }
  for value in enum_.values {
    if is_member(symbol, scope, value.name) {
      return true
    }
  }
  false
}

///|
/// Whether `symbol` names something inside `name`: it starts with `name`
/// and a dot, and goes on after them.
fn is_inside(symbol : String, name : String) -> Bool {
  symbol.length() > name.length() + 1 &&
  symbol.has_prefix(name) &&
  symbol.unsafe_get(name.length()) == '.'
}

///|
/// Whether `symbol` is `scope`, a full name and a dot or `""`, followed by
/// `name`.
fn is_member(symbol : String, scope : String, name : String) -> Bool {
  symbol.length() == scope.length() + name.length() &&
  symbol.has_prefix(scope) &&
  symbol.has_suffix(name)
}
