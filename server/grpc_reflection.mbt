// The built-in reflection service of a Mock, gRPC's
// `grpc.reflection.v1.ServerReflection` and its older name in
// `grpc.reflection.v1alpha`, whose messages are the same on the wire, which
// a Mock turns on with `grpc.reflection`. It lets tools such as grpcurl and
// Postman list and describe the Mock's services without a local copy of
// its Descriptor set.
//
// Its one method, `ServerReflectionInfo`, is bidirectional streaming, and
// smock serves no streaming method, so it answers one request per call: it
// reads the first request message as soon as it is whole, sends one
// response message and the OK trailers, then RST_STREAM NO_ERROR if the
// client still sends (`end_early`); a client opens a new call for its next
// request. Its messages are read and written by hand, with smock/protobuf's
// wire codec: reflection.proto is not embedded.
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
//
// A call goes to the service when its Mock turns reflection on, its
// `:path` is the method's, and no Stub is on that path, as for the health
// service. The protocol checks apply to it as to any call. Its answer does
// not reach the engine: it is not in the Journal, gets no Mockoon line, and
// counts in the request metrics under its Mock with `stub=""`.

///|
/// Whether `path` is the path of reflection's method, in either version.
fn is_reflection_path(path : String) -> Bool {
  path
  is ("/grpc.reflection.v1.ServerReflection/ServerReflectionInfo"
  | "/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo")
}

///|
/// The files that the built-in reflection service of `mock` answers
/// `request`, a gRPC call to the Mock, with, or `None` when the call goes
/// elsewhere: when the Mock does not turn reflection on, the call's
/// `:path` is not reflection's method, or a Stub is on the path, from the
/// Definition files or an Ephemeral one of the call's Session.
fn H2Connection::reflection_call(
  self : H2Connection,
  mock : @definitions.Mock,
  request : H2Request,
) -> ReadOnlyArray[Bytes]? {
  // A Mock that does not turn reflection on pays this test only.
  guard mock.reflection is Some(files) else { return None }
  guard is_reflection_path(request.target) else { return None }
  let session = self.ports.sessions.session_of(request.headers)
  if self.ports.engine.has_grpc_stub(mock, request.target, session~) {
    return None
  }
  Some(files)
}

///|
/// Answers `stream`, a call to reflection whose first message has arrived
/// whole while the client still sends, or that `answer_from_headers` no
/// longer sends to reflection: it looks the call up again, from the
/// definition set served now, and returns whether it answered it. A call
/// that still goes to the reflection service of its Mock is answered
/// (`answer_reflection`), and RST_STREAM NO_ERROR follows. One that a
/// reload has sent elsewhere is answered as from its HEADERS, or waits for
/// the end of its request when it can now reach a gRPC Stub.
fn[S : @io.Writer + ReadOutput] H2Connection::answer_first_message(
  self : H2Connection,
  stream : Int32,
  request : H2Request,
  out : WatchedStream[S],
) -> Bool {
  let mock = self.ports.engine.mock_for_call(
    request.without_body(),
    authority?=request.authority,
  )
  if mock is Some(found) && self.reflection_call(found, request) is Some(files) {
    self.requests.remove(stream)
    self.answer_reflection(stream, request, found, files, out, ended=false)
    self.end_stream()
    return true
  }
  request.reflection = false
  self.answer_from_headers(stream, request)
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
/// protobuf's parsers read a proto3 message: unknown fields are skipped, of
/// the members of the oneof `message_request` the last one wins, and a
/// known field of another wire type, or a string that is not UTF-8, is an
/// error. Its `host` is read, and not used.
fn read_reflection_request(message : BytesView) -> Asked raise {
  let reader = @protobuf.Reader(message)
  let mut asked = Nothing
  while !reader.at_end() {
    match reader.tag() {
      1 => ignore(reflection_text(reader))
      3 => asked = File(reflection_text(reader))
      4 => asked = Symbol(reflection_text(reader))
      5 => {
        reader.expect(Len)
        let extension = @protobuf.Reader(reader.length_delimited())
        let mut containing_type = ""
        let mut number = 0
        while !extension.at_end() {
          match extension.tag() {
            1 => containing_type = reflection_text(extension)
            2 => {
              extension.expect(Varint)
              number = extension.varint().to_int()
            }
            _ => extension.skip()
          }
        }
        asked = Extension(containing_type, number)
      }
      6 => asked = ExtensionNumbers(reflection_text(reader))
      7 => {
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
/// `reader` read: a length-delimited value in UTF-8.
fn reflection_text(reader : @protobuf.Reader) -> String raise {
  reader.expect(Len)
  @utf8.decode(reader.length_delimited())
}

///|
/// Where the reflection service of a Mock finds files: a Descriptor set and
/// its files as reflection sends them, in the order of the set's `files`.
priv struct Source {
  set : @protobuf.DescriptorSet
  files : ReadOnlyArray[Bytes]
}

///|
/// The sources of the reflection service of `mock`, whose set's files, as
/// reflection sends them, are `files`: the Mock's set, if it has one, then,
/// when the Mock turns health on and its set does not define the package
/// `grpc.health.v1`, the descriptor of gRPC's health.proto that smock
/// embeds.
fn reflection_sources(
  mock : @definitions.Mock,
  files : ReadOnlyArray[Bytes],
) -> Array[Source] {
  let sources = []
  let mut defines_health = false
  if mock.descriptor_set is Some(set) {
    sources.push({ set, files, })
    for file in set.files {
      if file.package_name == "grpc.health.v1" {
        defines_health = true
      }
    }
  }
  if mock.health && !defines_health {
    let types = HealthTypes::get()
    sources.push({ set: types.set, files: types.files, })
  }
  sources
}

///|
/// The index in `source`'s files of the file named `name`, or -1.
fn Source::index_of(self : Source, name : String) -> Int32 {
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
fn Source::with_imports(self : Source, index : Int32) -> Bytes {
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
fn reflection_answer(asked : Asked, sources : Array[Source]) -> (Int32, Bytes) {
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

///|
/// Answers `stream`, a call to the reflection service of `mock`, whose set's
/// files, as reflection sends them, are `files`, and whose request is
/// `request`. A body whose first message is not whole gets the refusal
/// that `refuse_call` sends, and so does a first message that does not
/// read as a ServerReflectionRequest; messages after the first are not
/// read. Otherwise the ServerReflectionResponse is sent as any reply is
/// (`send_built_in`), followed by RST_STREAM NO_ERROR when the request has
/// not `ended`. The answer carries `smock-mock` when the Default Mock gives
/// it, and counts under the Mock with `stub=""`.
fn[S : @io.Writer + ReadOutput] H2Connection::answer_reflection(
  self : H2Connection,
  stream : Int32,
  request : H2Request,
  mock : @definitions.Mock,
  files : ReadOnlyArray[Bytes],
  out : WatchedStream[S],
  ended~ : Bool,
) -> Unit {
  guard request.deframer is Some(deframer) else {
    abort("a gRPC call reads its framing")
  }
  if deframer.whole_messages() == 0 {
    let refusal : CallRefusal = match deframer.ending() {
      InPrefix => EndsInPrefix
      InMessage(..) => EndsInMessage
      Whole(..) => NoMessage
    }
    self.refuse_call(stream, refusal, ended~)
    return
  }
  let incoming = request.to_engine()
  let body = incoming.body
  let length = (body[1].to_int() << 24) |
    (body[2].to_int() << 16) |
    (body[3].to_int() << 8) |
    body[4].to_int()
  let message = body[@grpc.prefix_length:@grpc.prefix_length + length]
  let asked = read_reflection_request(message) catch {
    _ => {
      self.refuse_call(stream, Undecodable, ended~)
      return
    }
  }
  let (field, answer) = reflection_answer(
    asked,
    reflection_sources(mock, files),
  )
  let writer = @protobuf.Writer()
  let host = match request.authority {
    Some(authority) => authority
    None => header_value(request.headers, "host")
  }
  if host != "" {
    writer.tag(1, Len)
    writer.length_delimited(@utf8.encode(host))
  }
  writer.tag(2, Len)
  writer.length_delimited(message)
  writer.tag(field, Len)
  writer.length_delimited(answer)
  self.send_built_in(
    stream,
    mock,
    writer.to_bytes(),
    self.ports.engine.default_mock_field(incoming, authority?=request.authority),
    date=self.ports.dates.at(self.now),
    out,
    end_early=!ended,
  )
}

///|
/// The value of the first field of `headers` named `name`, in lower case
/// as HTTP/2 sends names, or `""` without one.
fn header_value(headers : Array[(String, String)], name : String) -> String {
  for header in headers {
    if header.0 == name {
      return header.1
    }
  }
  ""
}
