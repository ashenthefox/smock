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
/// for a call whose Host is `host`, or `None` when the request does not
/// decode.
fn reply(
  request : Bytes,
  host~ : String = "reflected.svc",
  set~ : @serverparsers.ReflectionSource? = Some(source(annotated_set)),
  health~ : (() -> @serverparsers.ReflectionSource)? = Some(embedded_health),
) -> Bytes? {
  try @serverparsers.reflection_reply(request, host~, set~, health~) catch {
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
  let out = []
  let exchange = (
    name : String,
    request : String,
    expected : String,
    files : Bytes,
  ) => {
    let expected = if files.length() > 0 {
      with_files(octets(expected), files)
    } else {
      octets(expected)
    }
    out.push("\{name}: \{compared(reply(octets(request)), expected)}")
  }
  exchange("list", reflection_list, reflection_list_reply, b"")
  exchange(
    "by-filename", reflection_by_filename, reflection_by_filename_reply, annotated,
  )
  exchange(
    "by-symbol", reflection_by_symbol, reflection_by_symbol_reply, annotated,
  )
  exchange(
    "by-extension", reflection_by_extension, reflection_by_extension_reply, annotated,
  )
  exchange(
    "extension-numbers", reflection_extension_numbers, reflection_extension_numbers_reply,
    b"",
  )
  // annotated.Account, which no extension extends.
  exchange(
    "extension-numbers-none", reflection_extension_numbers_none, reflection_extension_numbers_none_reply,
    b"",
  )
  exchange(
    "health-symbol", reflection_health_symbol, reflection_health_symbol_reply, health,
  )
  exchange(
    "health-filename", reflection_health_filename, reflection_health_filename_reply,
    health,
  )
  exchange(
    "missing-file", reflection_missing_file, reflection_missing_file_reply, b"",
  )
  exchange(
    "missing-symbol", reflection_missing_symbol, reflection_missing_symbol_reply,
    b"",
  )
  exchange(
    "missing-extension", reflection_missing_extension, reflection_missing_extension_reply,
    b"",
  )
  exchange(
    "missing-type", reflection_missing_type, reflection_missing_type_reply, b"",
  )
  // A message of zero octets asks for nothing.
  exchange("nothing", "", reflection_nothing_reply, b"")
  inspect(
    out.join("\n"),
    content=(
      #|list: as protoc encodes it
      #|by-filename: as protoc encodes it
      #|by-symbol: as protoc encodes it
      #|by-extension: as protoc encodes it
      #|extension-numbers: as protoc encodes it
      #|extension-numbers-none: as protoc encodes it
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

///|
/// `reply`, a reply that protoc encodes, as the service gives it for
/// `request`: the same fields, but `original_request`, which echoes the
/// request as received (docs/grpc/services-and-connections.md, Reflection),
/// and without `valid_host` unless `host`, as proto3 writes no string that
/// is empty (protobuf's encoding guide).
fn echoing(reply : Bytes, request : Bytes, host~ : Bool = true) -> Bytes {
  let reader = @protobuf.Reader(reply[:])
  let writer = @protobuf.Writer()
  try {
    while !reader.at_end() {
      let number = reader.tag()
      reader.expect(Len)
      let value = reader.length_delimited()
      match number {
        1 if !host => ()
        2 => {
          writer.tag(2, Len)
          writer.length_delimited(request)
        }
        _ => {
          writer.tag(number, Len)
          writer.length_delimited(value)
        }
      }
    }
  } catch {
    _ => abort("a reply that protoc encodes reads")
  }
  writer.to_bytes()
}

///|
/// The tag of field `number` with the wire type `wire_type` (protobuf's
/// encoding guide: `(field_number << 3) | wire_type`).
fn tag(number : Int32, wire_type : Int32) -> Bytes {
  varint((number << 3) | wire_type)
}

///|
/// Field `number` of `value`, length-delimited (wire type 2, LEN).
fn len(number : Int32, value : Bytes) -> Bytes {
  tag(number, 2) + varint(value.length()) + value
}

///|
/// Field 1, `containing_type`, of by-extension.txtpb's ExtensionRequest:
/// the type that the extension of annotated.proto extends.
let field_options : Bytes = len(1, b"google.protobuf.FieldOptions")

///|
/// Field 2, `extension_number`, of by-extension.txtpb's ExtensionRequest:
/// the number of the extension of annotated.proto.
let number_50000 : Bytes = tag(2, 0) + varint(50000)

///|
test "the request is read as protobuf's parsers read a proto3 message: unknown fields of each wire type are skipped, fields come in any order, the last member of the oneof wins, and the request's host is read but not used; the reply echoes the request as received, with the call's Host, or none (protobuf's proto3 guide, Unknown Fields and Oneof; its encoding guide, Field Order; gRPC's reflection.proto; docs/grpc/services-and-connections.md, Reflection)" {
  let annotated = octets(annotated_file) + octets(descriptor_file)
  let list_reply = octets(reflection_list_reply)
  let by_extension_reply = with_files(
    octets(reflection_by_extension_reply),
    annotated,
  )
  // Fields that reflection.proto's ServerReflectionRequest does not define,
  // field 2 and fields 9 to 12, one of each wire type: VARINT, I64, LEN, I32
  // and a group (SGROUP then EGROUP).
  let unknown = tag(2, 0) +
    varint(150) +
    tag(9, 1) +
    b"\x01\x02\x03\x04\x05\x06\x07\x08" +
    len(10, b"hello") +
    tag(11, 5) +
    b"\x01\x02\x03\x04" +
    tag(12, 3) +
    tag(1, 0) +
    varint(1) +
    tag(12, 4)
  let cases = [
    (
      "unknown fields around list_services",
      unknown + octets(reflection_list) + unknown,
      list_reply,
    ),
    (
      "an unknown field in file_containing_extension",
      len(5, field_options + number_50000 + tag(3, 0) + varint(1)),
      by_extension_reply,
    ),
    (
      "file_containing_extension, its number first",
      len(5, number_50000 + field_options),
      by_extension_reply,
    ),
    (
      "a host of its own in the request",
      len(1, b"other.svc") + octets(reflection_list),
      list_reply,
    ),
    (
      "file_containing_symbol, then file_by_filename",
      octets(reflection_by_symbol) + octets(reflection_missing_file),
      octets(reflection_missing_file_reply),
    ),
    (
      "file_by_filename, then file_containing_symbol",
      octets(reflection_missing_file) + octets(reflection_by_symbol),
      with_files(octets(reflection_by_symbol_reply), annotated),
    ),
  ]
  let out = []
  for case in cases {
    let (name, request, expected) = case
    out.push("\{name}: \{compared(reply(request), echoing(expected, request))}")
  }
  let request = octets(reflection_list)
  out.push(
    "a call without a Host: \{compared(reply(request, host=""), echoing(list_reply, request, host=false))}",
  )
  inspect(
    out.join("\n"),
    content=(
      #|unknown fields around list_services: as protoc encodes it
      #|an unknown field in file_containing_extension: as protoc encodes it
      #|file_containing_extension, its number first: as protoc encodes it
      #|a host of its own in the request: as protoc encodes it
      #|file_containing_symbol, then file_by_filename: as protoc encodes it
      #|file_by_filename, then file_containing_symbol: as protoc encodes it
      #|a call without a Host: as protoc encodes it
    ),
  )
}

///|
test "a request that does not parse raises, before the embedded descriptor is asked for, so that server refuses the call with INTERNAL: a proto3 string that is not UTF-8 in any field, field number 0, wire type 7, a length or a varint cut short, and a group that ends with another field's end tag (docs/grpc/services-and-connections.md, One request per call; docs/grpc/unmatched-and-refused-calls.md, Protocol checks and limits)" {
  let mut asked = 0
  let counted = () => {
    asked += 1
    embedded_health()
  }
  let not_utf8 = b"\xff"
  let cases = [
    ("host", len(1, not_utf8)),
    ("file_by_filename", len(3, not_utf8)),
    ("file_containing_symbol", len(4, not_utf8)),
    ("the extension's containing_type", len(5, len(1, not_utf8))),
    ("all_extension_numbers_of_type", len(6, not_utf8)),
    ("list_services", len(7, not_utf8)),
    ("field number 0", tag(0, 0) + varint(1)),
    ("wire type 7", tag(3, 7)),
    ("a length cut short", tag(3, 2) + varint(5) + b"a"),
    ("the extension's number cut short", len(5, tag(2, 0) + b"\xff")),
    ("an unknown field cut short in the extension", len(5, tag(3, 0) + b"\xff")),
    ("a group ended by another field's end tag", tag(12, 3) + tag(13, 4)),
  ]
  inspect(
    cases
    .map(case => {
      asked = 0
      let got = match reply(case.1, health=Some(counted)) {
        Some(_) => "a reply"
        None => "raised"
      }
      "\{case.0}: \{got}, the embedded descriptor asked for: \{asked}"
    })
    .join("\n"),
    content=(
      #|host: raised, the embedded descriptor asked for: 0
      #|file_by_filename: raised, the embedded descriptor asked for: 0
      #|file_containing_symbol: raised, the embedded descriptor asked for: 0
      #|the extension's containing_type: raised, the embedded descriptor asked for: 0
      #|all_extension_numbers_of_type: raised, the embedded descriptor asked for: 0
      #|list_services: raised, the embedded descriptor asked for: 0
      #|field number 0: raised, the embedded descriptor asked for: 0
      #|wire type 7: raised, the embedded descriptor asked for: 0
      #|a length cut short: raised, the embedded descriptor asked for: 0
      #|the extension's number cut short: raised, the embedded descriptor asked for: 0
      #|an unknown field cut short in the extension: raised, the embedded descriptor asked for: 0
      #|a group ended by another field's end tag: raised, the embedded descriptor asked for: 0
    ),
  )
}

///|
/// The names of the files that `reply` carries in its
/// `file_descriptor_response`, in their order, or what it holds instead. A
/// FileDescriptorResponse has the octets of a FileDescriptorSet of the same
/// files, as each is field 1 of its message.
fn files_sent(reply : Bytes?) -> String {
  guard reply is Some(reply) else { return "raised" }
  let reader = @protobuf.Reader(reply[:])
  try {
    while !reader.at_end() {
      let number = reader.tag()
      reader.expect(Len)
      let value = reader.length_delimited()
      if number == 4 {
        return @protobuf.read_descriptor_set(value).files
          .map(file => file.name)
          .join(", ")
      }
    }
    "no files"
  } catch {
    _ => "a reply that does not read"
  }
}

///|
test "a file is sent first, then the files it imports, at any depth, breadth first, each once, also when two of its imports import the same file (docs/grpc/services-and-connections.md, Reflection: once each; grpc-go's reflection server, FileDescWithDependencies, for the order)" {
  let set = Some(source(diamond_set))
  let sent = (request : Bytes) => files_sent(reply(request, set~, health=None))
  inspect(
    [
      "diamond/top.proto: \{sent(len(3, b"diamond/top.proto"))}",
      "diamond.Top: \{sent(len(4, b"diamond.Top"))}",
      "diamond/left.proto: \{sent(len(3, b"diamond/left.proto"))}",
      "diamond/base.proto: \{sent(len(3, b"diamond/base.proto"))}",
    ].join("\n"),
    content=(
      #|diamond/top.proto: diamond/top.proto, diamond/left.proto, diamond/right.proto, diamond/base.proto
      #|diamond.Top: diamond/top.proto, diamond/left.proto, diamond/right.proto, diamond/base.proto
      #|diamond/left.proto: diamond/left.proto, diamond/base.proto
      #|diamond/base.proto: diamond/base.proto
    ),
  )
}
