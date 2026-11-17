// The reader and builder of a Mock's built-in reflection service, gRPC's
// `grpc.reflection.v1.ServerReflection` and its older name in
// `grpc.reflection.v1alpha`, whose messages are the same on the wire: the
// reply to the first request message of a call. server finds the call,
// reads its framing and sends the reply (server/grpc_reflection.mbt).
// Its messages are read and written by hand, with smock/protobuf's wire
// codec: reflection.proto is not embedded.
//
// It answers from the Mock's set, whose files the Mock keeps as the set
// encodes them, without their SourceCodeInfo, when reflection is on
// (`@definitions.Mock::reflection`): `list_services` with the set's
// services; `file_by_filename`, `file_containing_symbol` and
// `file_containing_extension` with the file and the files it imports, at
// any depth, each once, the file first; and `all_extension_numbers_of_type`
// with the numbers of the extensions of the type. A name it lacks gets the
// reflection `error_response` with NOT_FOUND. On a Mock with health on,
// the health service is listed, and its file is answered from the
// descriptor of gRPC's health.proto that smock embeds, unless the Mock's
// set defines the package `grpc.health.v1` itself, which then answers.
// Each response echoes the request as received in `original_request`, and
// gives the call's Host in `valid_host`.

///|
/// Where the reflection service of a Mock finds files: a Descriptor set and
/// its files as reflection sends them, as the set encodes them without
/// their SourceCodeInfo, in the order of the set's `files`.
pub(all) struct ReflectionSource {
  set : @protobuf.DescriptorSet
  files : ReadOnlyArray[Bytes]
}

///|
/// The ServerReflectionResponse that the reflection service of a Mock
/// sends to `message`, the first request message of a call, a
/// ServerReflectionRequest, for a call whose Host is `host`, or `""` when it
/// has none. It answers from `set`, the Mock's set with its files, if it
/// has one, then, when `health` is given (the Mock turns health on) and
/// the set does not define the package `grpc.health.v1`, from the source
/// `health` gives: the embedded descriptor of health.proto, which it asks
/// for only then. Raises when `message` does not read as a
/// ServerReflectionRequest (`read_reflection_request`), before it asks for
/// anything.
pub fn reflection_reply(
  message : BytesView,
  host~ : String,
  set~ : ReflectionSource?,
  health~ : (() -> ReflectionSource)?,
) -> Bytes raise {
  let asked = read_reflection_request(message)
  let (field, answer) = reflection_answer(
    asked,
    reflection_sources(set, health),
  )
  let writer = @protobuf.Writer()
  if host != "" {
    writer.tag(1, Len)
    writer.length_delimited(@utf8.encode(host))
  }
  writer.tag(2, Len)
  writer.length_delimited(message)
  writer.tag(field, Len)
  writer.length_delimited(answer)
  writer.to_bytes()
}

///|
/// What a reflection request asks for.
priv enum Asked {
  /// `file_by_filename`: a file, by its name.
  File(String)
  /// `file_containing_symbol`: the file that defines a symbol.
  Symbol(String)
  /// `file_containing_extension`: the file that defines the extension of a
  /// message type, by the type's full name, with a field number.
  Extension(String, Int32)
  /// `all_extension_numbers_of_type`: the numbers of the extensions of a
  /// message type.
  ExtensionNumbers(String)
  /// `list_services`, whose text is not read.
  Services
  /// Nothing: the request sets no member of `message_request`.
  Nothing
}

///|
/// Reads `message`, a ServerReflectionRequest of reflection.proto, as
/// protobuf's parsers read a proto3 message: unknown fields, and known
/// fields sent with another wire type than their type's, are skipped, of
/// the members of the oneof `message_request` the last one wins, records of
/// `file_containing_extension` in a row merge, as the records of an
/// embedded message do, and a string that is not UTF-8 is an error. Its
/// `host` is read, and not used.
fn read_reflection_request(message : BytesView) -> Asked raise {
  let reader = @protobuf.Reader(message)
  let mut asked = Nothing
  while !reader.at_end() {
    let number = reader.tag()
    match (number, reader.wire_type()) {
      (1, Len) => ignore(reflection_text(reader))
      (3, Len) => asked = File(reflection_text(reader))
      (4, Len) => asked = Symbol(reflection_text(reader))
      (5, Len) => {
        let extension = @protobuf.Reader(reader.length_delimited())
        let mut containing_type = ""
        let mut number = 0
        // A record right after one of the same member merges into it: its
        // fields replace those that it holds, and the others stay.
        if asked is Extension(type_name, value) {
          containing_type = type_name
          number = value
        }
        while !extension.at_end() {
          let field = extension.tag()
          match (field, extension.wire_type()) {
            (1, Len) => containing_type = reflection_text(extension)
            (2, Varint) => number = extension.varint().to_int()
            _ => extension.skip()
          }
        }
        asked = Extension(containing_type, number)
      }
      (6, Len) => asked = ExtensionNumbers(reflection_text(reader))
      (7, Len) => {
        ignore(reflection_text(reader))
        asked = Services
      }
      _ => reader.skip()
    }
  }
  asked
}

///|
/// Reads the value of a `string` field of reflection.proto, the last tag
/// `reader` read, whose wire type is LEN: a length-delimited value in
/// UTF-8.
fn reflection_text(reader : @protobuf.Reader) -> String raise {
  @utf8.decode(reader.length_delimited())
}

///|
/// The sources of the reflection service of a Mock: `set`, the Mock's set
/// with its files, if it has one, then, when the Mock turns health on and
/// its set does not define the package `grpc.health.v1`, the source that
/// `health` gives, the embedded descriptor of health.proto.
fn reflection_sources(
  set : ReflectionSource?,
  health : (() -> ReflectionSource)?,
) -> Array[ReflectionSource] {
  let sources = []
  let mut defines_health = false
  if set is Some(source) {
    sources.push(source)
    for file in source.set.files {
      if file.package_name == "grpc.health.v1" {
        defines_health = true
      }
    }
  }
  if health is Some(embedded) && !defines_health {
    sources.push(embedded())
  }
  sources
}

///|
/// The index in `source`'s files of the file named `name`, or -1.
fn ReflectionSource::index_of(self : ReflectionSource, name : String) -> Int32 {
  for i, file in self.set.files {
    if file.name == name {
      return i
    }
  }
  -1
}

///|
/// The FileDescriptorResponse of the file at `index` in `source`, as
/// reflection sends it, and of the files it imports, at any depth, each
/// once, the file first, then its imports breadth first, as gRPC's
/// reflection servers order them.
fn ReflectionSource::with_imports(
  self : ReflectionSource,
  index : Int32,
) -> Bytes {
  let writer = @protobuf.Writer()
  let queue = [index]
  let sent : Map[Int32, Bool] = Map::from_array([(index, true)])
  let mut next = 0
  while next < queue.length() {
    let at = queue[next]
    next += 1
    writer.tag(1, Len)
    writer.length_delimited(self.files[at])
    for name in self.set.files[at].dependencies {
      let imported = self.index_of(name)
      if imported >= 0 && !sent.contains(imported) {
        sent[imported] = true
        queue.push(imported)
      }
    }
  }
  writer.to_bytes()
}

///|
/// The number of a field of a ServerReflectionResponse: which answer it
/// holds.
let file_descriptor_response : Int32 = 4

///|
let all_extension_numbers_response : Int32 = 5

///|
let list_services_response : Int32 = 6

///|
let error_response : Int32 = 7

///|
/// What the reflection service answers `asked` with, from `sources`: the
/// number of the field of the ServerReflectionResponse that holds the
/// answer, and the answer, encoded.
fn reflection_answer(
  asked : Asked,
  sources : Array[ReflectionSource],
) -> (Int32, Bytes) {
  match asked {
    Services => {
      let writer = @protobuf.Writer()
      for source in sources {
        for file in source.set.files {
          for service in file.services {
            let entry = @protobuf.Writer()
            entry.tag(1, Len)
            entry.length_delimited(@utf8.encode(service.full_name))
            writer.tag(1, Len)
            writer.length_delimited(entry.to_bytes())
          }
        }
      }
      (list_services_response, writer.to_bytes())
    }
    File(name) => {
      for source in sources {
        let index = source.index_of(name)
        if index >= 0 {
          return (file_descriptor_response, source.with_imports(index))
        }
      }
      not_found("file not found: \{name}")
    }
    Symbol(symbol) => {
      for source in sources {
        if source.set.find_file_containing_symbol(symbol) is Some(file) {
          return (
            file_descriptor_response,
            source.with_imports(source.index_of(file.name)),
          )
        }
      }
      not_found("symbol not found: \{symbol}")
    }
    Extension(containing_type, number) => {
      for source in sources {
        if source.set.find_message(containing_type) is Some(message) &&
          message.find_extension(number) is Some(extension) {
          return (
            file_descriptor_response,
            source.with_imports(source.index_of(extension.file_name)),
          )
        }
      }
      not_found("extension not found: \{containing_type}, number \{number}")
    }
    ExtensionNumbers(type_name) => {
      for source in sources {
        if source.set.find_message(type_name) is Some(message) {
          let writer = @protobuf.Writer()
          writer.tag(1, Len)
          writer.length_delimited(@utf8.encode(message.full_name))
          let extensions = message.extended_by()
          if extensions.length() > 0 {
            // Packed, as proto3 encodes a repeated int32.
            let numbers = @protobuf.Writer()
            for extension in extensions {
              numbers.varint(
                extension.number.to_int64().reinterpret_as_uint64(),
              )
            }
            writer.tag(2, Len)
            writer.length_delimited(numbers.to_bytes())
          }
          return (all_extension_numbers_response, writer.to_bytes())
        }
      }
      not_found("type not found: \{type_name}")
    }
    Nothing => error_answer(3, "the request asks for nothing")
  }
}

///|
/// The reflection error NOT_FOUND, with `message`.
fn not_found(message : String) -> (Int32, Bytes) {
  error_answer(@grpc.NotFound.code(), message)
}

///|
/// An `error_response` with the gRPC status code `code` and `message`.
fn error_answer(code : Int32, message : String) -> (Int32, Bytes) {
  let writer = @protobuf.Writer()
  writer.tag(1, Varint)
  writer.varint(code.to_int64().reinterpret_as_uint64())
  writer.tag(2, Len)
  writer.length_delimited(@utf8.encode(message))
  (error_response, writer.to_bytes())
}
