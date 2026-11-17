// Tests of the reflection service's reader and builder: the reply that a
// Mock's built-in reflection service, gRPC's `grpc.reflection.v1` and
// `v1alpha`, sends to the first request message of a call
// (docs/grpc/services-and-connections.md, "Reflection"). The requests and
// the expected replies are protoc's encodings of messages of gRPC's
// reflection.proto (fixtures/protobuf/reflection/), as the e2e test of the
// service sends and expects them over HTTP/2; a reply that carries files is
// filled with protoc's sets of one file each, without source info, as
// reflection sends files. The Mock is the e2e test's: at `reflected.svc`,
// its set holds annotated.proto, with custom options and source info, and
// protobuf's descriptor.proto, which it imports, and it turns health on.
// The fixtures come in hex (scripts/gen-protobuf-fixtures.sh).

///|
/// The octets of `fixture`, a generated constant in hex.
fn octets(fixture : String) -> Bytes {
  @hex.decode(fixture.replace_all(old="\n", new="")) catch {
    _ => abort("a generated fixture is hex")
  }
}

///|
/// The reflection source of a Descriptor set, `set`, a generated constant
/// in hex: the set, and its files as reflection sends them, as a Mock with
/// `grpc.reflection` keeps them (`@definitions.Mock::reflection`), and as
/// server keeps the embedded descriptor of health.proto.
fn source(set : String) -> @serverparsers.ReflectionSource {
  let bytes = octets(set)
  {
    set: @protobuf.read_descriptor_set(bytes),
    files: @protobuf.files_without_source_info(bytes),
  } catch {
    _ => abort("a generated set reads")
  }
}

///|
/// The embedded descriptor of health.proto, as server gives it to the
/// reflection service of a Mock that turns health on.
fn embedded_health() -> @serverparsers.ReflectionSource {
  source(health_set)
}

///|
/// The reply of the reflection service of the e2e test's Mock to `request`,
/// for a call to `reflected.svc`: or `raised` when the request does not
/// decode.
fn reply(
  request : Bytes,
  set~ : @serverparsers.ReflectionSource? = Some(source(annotated_set)),
  health~ : (() -> @serverparsers.ReflectionSource)? = Some(embedded_health),
) -> Bytes? {
  try
    @serverparsers.reflection_reply(
      request,
      host="reflected.svc",
      set~,
      health~,
    )
  catch {
    _ => None
  } noraise {
    reply => Some(reply)
  }
}

///|
/// `n` as a varint, 7 bits to an octet, least significant first.
fn varint(n : Int32) -> Bytes {
  let out = @buffer.Buffer()
  let mut rest = n
  while rest >= 0x80 {
    out.write_byte(((rest & 0x7f) | 0x80).to_byte())
    rest = rest >> 7
  }
  out.write_byte(rest.to_byte())
  out.to_bytes()
}

///|
/// `reply`, a reply whose last field is an empty `file_descriptor_response`,
/// its tag and a length of 0, as protoc encodes `file_descriptor_response
/// {}`, with `files` in it instead: the octets of a FileDescriptorResponse,
/// which are those of a FileDescriptorSet with the same files, in the same
/// order, as each is field 1 of its message.
fn with_files(reply : Bytes, files : Bytes) -> Bytes {
  let n = reply.length()
  guard n >= 2 && reply[n - 2] == b'\x22' && reply[n - 1] == b'\x00' else {
    abort("the reply does not end with an empty file_descriptor_response")
  }
  reply[:n - 2].to_owned() + b"\x22" + varint(files.length()) + files
}

///|
/// How `got`, a reply, compares with `expected`: `as protoc encodes it`, or
/// the reply in hex.
fn compared(got : Bytes?, expected : Bytes) -> String {
  match got {
    Some(reply) if reply == expected => "as protoc encodes it"
    Some(reply) => @hex.encode(reply)
    None => "raised"
  }
}

///|
test "each request kind gets its reply from the Mock's set: the services, then health; a file and its imports, the file first, without source info and with custom options; the numbers of a type's extensions; and NOT_FOUND or INVALID_ARGUMENT, each echoing the request, with the call's Host (docs/grpc/services-and-connections.md, Reflection; gRPC's reflection.proto)" {
  let annotated = octets(annotated_file) + octets(descriptor_file)
  let health = octets(health_set)
  let exchanges = [
    ("list", reflection_list, reflection_list_reply, b""),
    (
      "by-filename", reflection_by_filename, reflection_by_filename_reply, annotated,
    ),
    ("by-symbol", reflection_by_symbol, reflection_by_symbol_reply, annotated),
    (
      "by-extension", reflection_by_extension, reflection_by_extension_reply, annotated,
    ),
    (
      "extension-numbers", reflection_extension_numbers, reflection_extension_numbers_reply,
      b"",
    ),
    (
      "health-symbol", reflection_health_symbol, reflection_health_symbol_reply,
      health,
    ),
    (
      "health-filename", reflection_health_filename, reflection_health_filename_reply,
      health,
    ),
    (
      "missing-file", reflection_missing_file, reflection_missing_file_reply, b"",
    ),
    (
      "missing-symbol", reflection_missing_symbol, reflection_missing_symbol_reply,
      b"",
    ),
    (
      "missing-extension", reflection_missing_extension, reflection_missing_extension_reply,
      b"",
    ),
    (
      "missing-type", reflection_missing_type, reflection_missing_type_reply, b"",
    ),
    // A message of zero octets asks for nothing.
    ("nothing", "", reflection_nothing_reply, b""),
  ]
  let out = []
  for exchange in exchanges {
    let (name, request, expected, files) = exchange
    let expected = if files.length() > 0 {
      with_files(octets(expected), files)
    } else {
      octets(expected)
    }
    out.push("\{name}: \{compared(reply(octets(request)), expected)}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|list: as protoc encodes it
      #|by-filename: as protoc encodes it
      #|by-symbol: as protoc encodes it
      #|by-extension: as protoc encodes it
      #|extension-numbers: as protoc encodes it
      #|health-symbol: as protoc encodes it
      #|health-filename: as protoc encodes it
      #|missing-file: as protoc encodes it
      #|missing-symbol: as protoc encodes it
      #|missing-extension: as protoc encodes it
      #|missing-type: as protoc encodes it
      #|nothing: as protoc encodes it
    ),
  )
}

///|
test "with health on, the health service is listed and described from the embedded descriptor of health.proto, unless the Mock's set defines grpc.health.v1, which then answers alone and the embedded descriptor is not used; a Mock without a set lists health alone; with health off, health is neither listed nor asked for (docs/grpc/services-and-connections.md, Reflection)" {
  let mut asked = 0
  let counted = () => {
    asked += 1
    embedded_health()
  }
  let out = []
  let exchange = (
    name : String,
    request : String,
    set : @serverparsers.ReflectionSource?,
    health : Bool,
    expected : Bytes,
  ) => {
    asked = 0
    let got = reply(
      octets(request),
      set~,
      health=if health { Some(counted) } else { None },
    )
    out.push(
      "\{name}: \{compared(got, expected)}, the embedded descriptor asked for: \{asked}",
    )
  }
  // A set of health.proto under the name health.proto: it defines
  // grpc.health.v1.
  let defines_health = Some(source(health_proto_set))
  exchange(
    "a set that defines health, list",
    reflection_list,
    defines_health,
    true,
    octets(reflection_list_health_reply),
  )
  exchange(
    "a set that defines health, health-symbol",
    reflection_health_symbol,
    defines_health,
    true,
    with_files(octets(reflection_health_symbol_reply), octets(health_proto_set)),
  )
  exchange(
    "a set that defines health, health-filename",
    reflection_health_filename,
    defines_health,
    true,
    octets(reflection_health_filename_missing_reply),
  )
  exchange(
    "no set, list",
    reflection_list,
    None,
    true,
    octets(reflection_list_health_reply),
  )
  exchange(
    "no set, health-symbol",
    reflection_health_symbol,
    None,
    true,
    with_files(octets(reflection_health_symbol_reply), octets(health_set)),
  )
  let annotated = Some(source(annotated_set))
  exchange(
    "health off, list",
    reflection_list,
    annotated,
    false,
    octets(reflection_list_without_health_reply),
  )
  exchange(
    "health off, health-filename",
    reflection_health_filename,
    annotated,
    false,
    octets(reflection_health_filename_missing_reply),
  )
  inspect(
    out.join("\n"),
    content=(
      #|a set that defines health, list: as protoc encodes it, the embedded descriptor asked for: 0
      #|a set that defines health, health-symbol: as protoc encodes it, the embedded descriptor asked for: 0
      #|a set that defines health, health-filename: as protoc encodes it, the embedded descriptor asked for: 0
      #|no set, list: as protoc encodes it, the embedded descriptor asked for: 1
      #|no set, health-symbol: as protoc encodes it, the embedded descriptor asked for: 1
      #|health off, list: as protoc encodes it, the embedded descriptor asked for: 0
      #|health off, health-filename: as protoc encodes it, the embedded descriptor asked for: 0
    ),
  )
}
