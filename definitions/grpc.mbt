// gRPC Stubs: a Stub whose exact path names a method of its Mock's
// Descriptor set, as `/helloworld.Greeter/SayHello` names `SayHello` of the
// service `helloworld.Greeter`. It is an ordinary Stub that carries its
// method. HTTP requests never match it, and it is shadowed only by gRPC
// Stubs. It is checked against its method's types when the files load,
// the fields that make no sense on it, and those the branch cannot serve
// yet, are refused, and its static replies are encoded with its output
// type.

///|
/// The Descriptor sets that the Mocks of the parsed files name, each decoded
/// once, so that a Stub of a Mock declared in any file, earlier or later,
/// knows its Mock's set before it is read.
priv struct DeclaredSets {
  /// Each set that a Mock names and that is in the body-file subdirectory,
  /// by its path there: decoded, or the error that stopped it. A set that
  /// several Mocks name is decoded once.
  by_path : Map[String, DecodedSet]
  /// The set of each Mock whose set decodes, by the Mock's name. When two
  /// Mocks have one name, which is a problem, the first one's.
  by_mock : Map[String, @protobuf.DescriptorSet]
}

///|
/// A body file read as a Descriptor set.
priv enum DecodedSet {
  Decoded(@protobuf.DescriptorSet)
  /// It does not decode, or is not a self-contained set, for these
  /// reasons.
  NotASet(@protobuf.DescriptorSetError)
}

///|
/// No Descriptor sets, for Stubs read without the Definition files' Mocks,
/// such as an Ephemeral Stub.
let no_declared_sets : DeclaredSets = { by_path: Map([]), by_mock: Map([]), }

///|
/// The Descriptor sets that the Mocks of `files` name, from `body_files`.
/// A Mock whose `grpc.descriptorSet` is not a path to a body file names
/// none here: `File::read_mock` reports why.
fn declared_sets(
  files : Array[(String, Result[Map[String, Json], Diagnostic])],
  body_files : Map[String, Bytes],
) -> DeclaredSets {
  let sets = { by_path: Map([]), by_mock: Map([]), }
  for file in files {
    guard file.1 is Ok(top) && top.get("mocks") is Some(Array(mocks)) else {
      continue
    }
    for mock in mocks {
      guard mock is Object(mock) &&
        mock.get("name") is Some(String(name)) &&
        mock.get("grpc") is Some(Object(grpc)) &&
        grpc.get("descriptorSet") is Some(String(path)) &&
        is_inside(path) &&
        body_files.get(path) is Some(bytes) else {
        continue
      }
      let decoded = match sets.by_path.get(path) {
        Some(decoded) => decoded
        None => {
          let decoded = decode_set(bytes)
          sets.by_path[path] = decoded
          decoded
        }
      }
      if decoded is Decoded(set) && !sets.by_mock.contains(name) {
        sets.by_mock[name] = set
      }
    }
  }
  sets
}

///|
/// `bytes` read as a Descriptor set, or the error that stops it.
fn decode_set(bytes : Bytes) -> DecodedSet {
  Decoded(@protobuf.read_descriptor_set(bytes)) catch {
    err => NotASet(err)
  }
}

///|
/// Whether `path`, relative to the body-file subdirectory, stays inside it:
/// its names are not empty, and none starts with `.`, as smock skips such
/// files.
fn is_inside(path : String) -> Bool {
  path.split("/").all(name => !name.is_empty() && !name.has_prefix("."))
}

///|
/// The method a Stub's exact path names in a Descriptor set, with its name
/// as the path gives it.
priv struct NamedMethod {
  /// The path without its leading `/`, such as
  /// `helloworld.Greeter/SayHello`.
  name : String
  /// The method, as the set declares it.
  rpc : @protobuf.MethodDescriptor
  /// The set.
  set : @protobuf.DescriptorSet
}

///|
/// The method that `stub`, a Stub as written, names in its Mock's set, if
/// it is a gRPC Stub: its `mock` names a Mock with a set, and its exact
/// `request.path` names a method of it: `/`, a service's full name, `/`
/// and the name of one of its methods. A CRUD Stub is never one: it has no
/// request path.
fn File::grpc_method_of(self : File, stub : Map[String, Json]) -> NamedMethod? {
  guard !stub.contains("crud") &&
    stub.get("mock") is Some(String(mock)) &&
    self.sets.by_mock.get(mock) is Some(set) &&
    stub.get("request") is Some(Object(request)) &&
    request.get("path") is Some(String(path)) &&
    set.find_method(path) is Some(rpc) else {
    return None
  }
  Some({ name: path[1:].to_owned(), rpc, set, })
}

///|
/// The types of a gRPC Stub's method that gRPC Stubs serve, as
/// `File::check_grpc_stub` finds them.
priv struct ServedTypes {
  /// The input type, when it is served: the Stub's `json` condition is
  /// checked against it.
  input : @protobuf.MessageDescriptor?
  /// The output type, when it is served: the Stub's static replies are
  /// encoded with it.
  output : @protobuf.MessageDescriptor?
}

///|
/// Checks the gRPC Stub `stub`, at `pointer`, against `named`, the method
/// its exact path names. Its fields must make sense on a gRPC Stub and be
/// served, as `File::refuse_fields` says. The method must be unary. Its input type
/// must be served, as `File::check_input` says, and its output type, as
/// `File::check_output` says. Returns each of them that is served, and
/// neither for a streaming method.
fn File::check_grpc_stub(
  self : File,
  pointer : String,
  stub : Map[String, Json],
  named : NamedMethod,
) -> ServedTypes {
  self.refuse_fields(pointer, stub)
  let rpc = named.rpc
  let path = child_pointer(child_pointer(pointer, "request"), "path")
  let streaming = match (rpc.client_streaming, rpc.server_streaming) {
    (false, false) => None
    (true, false) => Some("client-streaming")
    (false, true) => Some("server-streaming")
    (true, true) => Some("bidi-streaming")
  }
  if streaming is Some(streaming) {
    self.error(
      path,
      "the method \{named.name} is \{streaming}, and smock serves only unary methods: streaming methods are planned for R3",
    )
    return { input: None, output: None, }
  }
  let input = named.set.input_of(rpc)
  let output = named.set.output_of(rpc)
  {
    input: if self.check_input(path, named.set, input) {
      Some(input)
    } else {
      None
    },
    output: if self.check_output(path, named.set, output) {
      Some(output)
    } else {
      None
    },
  }
}

///|
/// The reply message of `json`, a gRPC Stub's response at `pointer`,
/// encoded with `output`, a type of `set`: its `json`, read as ProtoJSON,
/// or an empty message without one. `None` for a templated response, whose
/// message is encoded once rendered, and for a reply that is not a message
/// of the type, which is reported at the JSON Pointer of the value at
/// fault.
fn File::encode_reply(
  self : File,
  pointer : String,
  json : Json,
  set : @protobuf.DescriptorSet,
  output : @protobuf.MessageDescriptor,
) -> EncodedMessage? {
  guard json is Object(response) else { return None }
  if response.get("template") is Some(True) {
    return None
  }
  let message = match response.get("json") {
    Some(json) =>
      set.encode_json(output, json) catch {
        EncodeError(pointer=at, message~) => {
          self.error(child_pointer(pointer, "json") + at, message)
          return None
        }
      }
    None => b""
  }
  Some({ output, message, })
}

///|
/// Reports at `pointer`, a gRPC Stub's path, what gRPC Stubs do not serve
/// of `output`, the output type of its method, a message of `set`, and of
/// each type it reaches through its fields and the extensions that extend
/// it, each once, a map's values included: what `File::check_reached` and
/// `File::check_field` refuse. Every other field is served, groups and the
/// well-known types included, as `File::check_input` words its problems.
/// Returns whether every type it reaches is served.
fn File::check_output(
  self : File,
  pointer : String,
  set : @protobuf.DescriptorSet,
  output : @protobuf.MessageDescriptor,
) -> Bool {
  let mut served = true
  let seen : Set[String] = Set([output.full_name])
  let pending = [output]
  while pending.pop() is Some(message) {
    if !self.check_reached(pointer, "output", output, message) {
      served = false
      continue
    }
    let reached_types = []
    for field in fields_and_extensions(message) {
      if !self.check_field(pointer, "output", output, field, set, seen) {
        served = false
        continue
      }
      // A map field reaches the type of its values.
      let value = match set.message_of(field) {
        Some(entry) if entry.map_entry =>
          entry.find_field_by_number(2).unwrap_or(field)
        _ => field
      }
      if set.message_of(value) is Some(type_) && !seen.contains(type_.full_name) {
        seen.add(type_.full_name)
        reached_types.push(type_)
      }
    }
    // The types this one reaches are checked next, in the order of its
    // fields.
    for i = reached_types.length() - 1; i >= 0; i = i - 1 {
      pending.push(reached_types[i])
    }
  }
  served
}

///|
/// Reports at `pointer`, a gRPC Stub's path, why `message`, the `side`
/// type of its method, `top`, or a message type it reaches, is not served,
/// and returns whether it is, as far as the type itself goes: a type of an
/// editions file, or one that an extension declared in an editions file
/// extends, comes in a later spec; and a MessageSet is not served, since
/// its extensions use another wire form. Its fields and the extensions that
/// extend it are checked by the caller.
fn File::check_reached(
  self : File,
  pointer : String,
  side : String,
  top : @protobuf.MessageDescriptor,
  message : @protobuf.MessageDescriptor,
) -> Bool {
  let reached = message.full_name != top.full_name
  let it = if reached {
    "\{message.full_name}, a type it reaches,"
  } else {
    "it"
  }
  if message.syntax is Editions {
    let defines = if reached {
      "\{message.full_name}, a type it reaches"
    } else {
      "it"
    }
    self.error(
      pointer,
      "the \{side} type \{top.full_name} is not served yet: \{message.file_name}, which defines \{defines}, is an editions file, and editions come in a later spec",
    )
    return false
  }
  if message.message_set_wire_format {
    self.error(
      pointer,
      "the \{side} type \{top.full_name} is not served: \{it} is a MessageSet, whose extensions use another wire form, and smock serves no MessageSet types",
    )
    return false
  }
  for extension in message.extended_by() {
    if extension.syntax is Editions {
      let of = if reached {
        "\{message.full_name}, a type it reaches,"
      } else {
        "it,"
      }
      self.error(
        pointer,
        "the \{side} type \{top.full_name} is not served yet: \{extension.file_name}, which declares \{extension.full_name}, an extension of \{of} is an editions file, and editions come in a later spec",
      )
      return false
    }
  }
  true
}

///|
/// Reports at `pointer`, a gRPC Stub's path, why `field`, a field of
/// `message`, the `side` type of its method, `top`, or a message type of
/// `set` it reaches, or an extension that extends one, is not served, and
/// returns whether it is, as far as its kind goes: an enum of an editions
/// file, a map's values included, comes in a later spec. An enum is
/// reported once, as `seen`, the full names of the types reached so far,
/// says.
fn File::check_field(
  self : File,
  pointer : String,
  side : String,
  top : @protobuf.MessageDescriptor,
  field : @protobuf.FieldDescriptor,
  set : @protobuf.DescriptorSet,
  seen : Set[String],
) -> Bool {
  // A map field reaches the type of its values.
  let value = match set.message_of(field) {
    Some(entry) if entry.map_entry =>
      entry.find_field_by_number(2).unwrap_or(field)
    _ => field
  }
  guard set.enum_of(value) is Some(type_) && type_.syntax is Editions else {
    return true
  }
  if !seen.contains(type_.full_name) {
    seen.add(type_.full_name)
    self.error(
      pointer,
      "the \{side} type \{top.full_name} is not served yet: \{type_.file_name}, which defines \{type_.full_name}, a type it reaches, is an editions file, and editions come in a later spec",
    )
  }
  false
}

///|
/// Reports at `pointer`, a gRPC Stub's path, what gRPC Stubs do not serve
/// of `input`, the input type of its method, a message of `set`, and of
/// each type it reaches through its fields and the extensions that extend
/// it, a map's values included, each once: what `File::check_reached` and
/// `File::check_field` refuse. Every other field or extension is served,
/// singular or repeated, a map or in a oneof: one of any scalar type, of an
/// enum, or of a message or a group, which is checked in turn, the
/// well-known types included. Returns whether every type it reaches is
/// served.
fn File::check_input(
  self : File,
  pointer : String,
  set : @protobuf.DescriptorSet,
  input : @protobuf.MessageDescriptor,
) -> Bool {
  let mut served = true
  let seen : Set[String] = Set([input.full_name])
  let pending = [input]
  while pending.pop() is Some(message) {
    if !self.check_reached(pointer, "input", input, message) {
      served = false
      continue
    }
    let reached_types = []
    for field in fields_and_extensions(message) {
      if !self.check_field(pointer, "input", input, field, set, seen) {
        served = false
        continue
      }
      // A map's values are checked as the field's own values are.
      let value = match set.message_of(field) {
        Some(entry) if field.label is Repeated && entry.map_entry =>
          entry.find_field_by_number(2).unwrap_or(field)
        _ => field
      }
      if set.message_of(value) is Some(type_) && !seen.contains(type_.full_name) {
        seen.add(type_.full_name)
        reached_types.push(type_)
      }
    }
    // The types this one reaches are checked next, in the order of its
    // fields.
    for i = reached_types.length() - 1; i >= 0; i = i - 1 {
      pending.push(reached_types[i])
    }
  }
  served
}

///|
/// The fields of `message`, then the extensions of its set that extend it,
/// which a message of the type may hold as it holds its fields.
fn fields_and_extensions(
  message : @protobuf.MessageDescriptor,
) -> Array[@protobuf.FieldDescriptor] {
  let all = []
  for field in message.fields {
    all.push(field)
  }
  for extension in message.extended_by() {
    all.push(extension)
  }
  all
}

///|
/// Reports each member of the gRPC Stub `stub`, at `pointer`, that a gRPC
/// Stub cannot give, or that gRPC Stubs do not serve yet. They serve `id`,
/// `mock`, `priority`, `scenario`, `variables`, `dataWrites`, `fault.seed`,
/// `fault.delay`, `request.method` when it is `POST`, `request.path`,
/// `request.headers`, a `json` body condition, and `headers`, `json`,
/// `grpc`, `template` and `weight` in a reply. `query`, `cookies`, every
/// other body condition, another method, and a reply's `status`, `body`,
/// `bodyFile`, `events` and `llm` make no sense on a gRPC Stub
/// (`File::refuse_reply`); `fault.connection` is not served yet. A member
/// that no Stub has is reported as unknown where it is read, and a method
/// that is not an HTTP token as such.
fn File::refuse_fields(
  self : File,
  pointer : String,
  stub : Map[String, Json],
) -> Unit {
  for key, value in stub {
    let at = child_pointer(pointer, key)
    match (key, value) {
      ("fault", Object(fault)) =>
        for name, _ in fault {
          if name == "connection" {
            self.not_served(child_pointer(at, name))
          }
        }
      ("request", Object(request)) =>
        for name, condition in request {
          let field = child_pointer(at, name)
          match (name, condition) {
            ("method", String(meth)) if meth != "POST" && @http1.is_token(meth) =>
              self.error(
                field, "must be POST on a gRPC Stub, or left out: a gRPC call is always a POST",
              )
            ("query", _) =>
              self.no_sense(field, "a gRPC call's path has no query")
            ("cookies", _) =>
              self.no_sense(
                field, "a gRPC call sends metadata, which headers conditions match, not cookies",
              )
            ("body", String(_)) =>
              self.error(
                field,
                "an exact-text condition makes no sense on a gRPC Stub: \{matched_as_json}",
              )
            ("body", Object(body)) =>
              for kind, _ in body {
                if kind is ("pattern" | "form" | "xml") {
                  self.no_sense(child_pointer(field, kind), matched_as_json)
                }
              }
            _ => ()
          }
        }
      ("response", Object(response)) => self.refuse_reply(at, response)
      ("responses", Array(responses)) =>
        for i, response in responses {
          if response is Object(response) {
            self.refuse_reply(child_pointer(at, i.to_string()), response)
          }
        }
      _ => ()
    }
  }
}

///|
/// Why a body condition other than `json` makes no sense on a gRPC Stub.
let matched_as_json : String = "a call's message is matched as JSON, with a json condition"

///|
/// Reports each member of `response`, a reply of a gRPC Stub at `pointer`,
/// that it cannot give: `status`, `body`, `bodyFile`, `events` and `llm`,
/// which make no sense on a gRPC Stub. It may give `headers`, its initial
/// metadata, `json`, `grpc`, `template` and `weight`.
fn File::refuse_reply(
  self : File,
  pointer : String,
  response : Map[String, Json],
) -> Unit {
  for name, _ in response {
    let field = child_pointer(pointer, name)
    match name {
      "status" =>
        self.no_sense(
          field, "a gRPC reply's HTTP status is always 200, and grpc.status gives its gRPC status",
        )
      "body" | "bodyFile" =>
        self.no_sense(
          field, "its reply message is json, which smock encodes with the method's output type",
        )
      "events" =>
        self.no_sense(
          field, "a unary call gets one reply message, not an event stream",
        )
      "llm" =>
        self.no_sense(
          field, "an LLM reply is written in an LLM API's HTTP wire form",
        )
      _ => ()
    }
  }
}

///|
/// Reports that the member at `pointer` makes no sense on a gRPC Stub, for
/// the reason `why`.
fn File::no_sense(self : File, pointer : String, why : String) -> Unit {
  self.error(pointer, "makes no sense on a gRPC Stub: \{why}")
}

///|
/// Reports that the member at `pointer` is not served on gRPC Stubs yet.
fn File::not_served(self : File, pointer : String) -> Unit {
  self.error(pointer, "is not served on gRPC Stubs yet")
}

///|
/// The gRPC Stubs of `path`, the `:path` of a gRPC call, in matching order:
/// the Stubs of the Mock whose exact path it is. A gRPC call is matched
/// against these alone. Its Near miss is chosen among every gRPC Stub of
/// the Mock, those of `stubs` that are gRPC Stubs.
pub fn Mock::grpc_candidates(self : Mock, path : String) -> ReadOnlyArray[Stub] {
  match self.grpc_stubs.get(path) {
    Some(stubs) => stubs
    None => no_stubs
  }
}

///|
/// No Stubs.
let no_stubs : ReadOnlyArray[Stub] = ReadOnlyArray::from_array([])

///|
/// The gRPC Stubs of a Mock that has none, by path: none, shared by every
/// such Mock, so that a Mock without gRPC Stubs holds nothing new for them.
let no_grpc_stubs : Map[String, ReadOnlyArray[Stub]] = Map([])

///|
/// The gRPC Stubs among `stubs`, a Mock's Stubs in matching order, by their
/// exact path, each list in matching order.
fn grpc_stubs_by_path(
  stubs : ReadOnlyArray[Stub],
) -> Map[String, ReadOnlyArray[Stub]] {
  let by_path : Map[String, Array[Stub]] = Map([])
  for stub in stubs {
    if stub.serves
      is Ordinary(
        {
          grpc_method: Some(_),
          request: { path: Some(Has(Exact(path))), .. },
          ..
        }
      ) {
      match by_path.get(path) {
        Some(list) => list.push(stub)
        None => by_path[path] = [stub]
      }
    }
  }
  if by_path.is_empty() {
    return no_grpc_stubs
  }
  let out = Map([])
  for path, list in by_path {
    out[path] = ReadOnlyArray::from_array(list)
  }
  out
}
