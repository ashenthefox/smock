// Seam 2 tests of the decoder's bounds, beside spec E's denial-of-service
// cases: a hostile message cannot make smock print more JSON than
// `--body-limit`, nest deeper than 100, or read a length past the message.
// A message whose decoded JSON passes the limit gets RESOURCE_EXHAUSTED as
// soon as it does; one that nests too deep, or whose lengths run past it,
// does not parse and gets INTERNAL. None is journaled; each counts as
// rejected traffic. The hostile messages are written here, record by
// record, as no encoder writes them; the sets are protoc's
// (scripts/gen-protobuf-fixtures.sh).

///|
/// `count` copies of `record`, joined.
fn copies(record : Bytes, count : Int32) -> Bytes {
  let out = @buffer.Buffer(size_hint=record.length() * count)
  for _ in 0..<count {
    out.write_bytes(record)
  }
  out.to_bytes()
}

///|
/// The most process `pid`'s resident set has been, in bytes: VmHWM of
/// /proc/<pid>/status, in KiB.
async fn peak_resident_set(pid : Int32) -> Double {
  for line in @fs.read_file("/proc/\{pid}/status").text().split("\n") {
    if line.strip_prefix("VmHWM:") is Some(rest) &&
      rest.trim().strip_suffix(" kB") is Some(kib) {
      return @string.parse_double(kib.trim()) * 1024.0
    }
  }
  fail("no VmHWM in /proc/\{pid}/status")
}

///|
/// A reply as the tests show it: `:status`, `grpc-status` and
/// `grpc-message`, the DATA frames it had, and how it ended.
fn limits_reply(reply : GrpcReply) -> String {
  let fields = match reply.trailers {
    Some(trailers) => [..reply.head, ..trailers]
    None => reply.head
  }
  let shown = fields
    .filter(field => field.0 is (":status" | "grpc-status" | "grpc-message"))
    .map(field => "\{field.0}: \{field.1}")
  "\{shown.join(", ")}, \{reply.data.length()} DATA (\{reply.ended})"
}

///|
/// The targets of the Journal's entries, in order, joined by spaces, or
/// `none`.
async fn journaled_targets(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let targets = []
  for entry in entries {
    guard entry
      is Object({ "request": Object({ "target": String(target), .. }), .. }) else {
      fail("no target: \{entry.stringify()}")
    }
    targets.push(target)
  }
  if targets.is_empty() {
    "none"
  } else {
    targets.join(" ")
  }
}

///|
/// The Mock `shelf`, the Default Mock, with collections.proto's set, a
/// gRPC Stub on Fill that answers any message, and an HTTP Stub that takes
/// uploads.
let limits_shelf : String =
  #|mocks:
  #|  - name: shelf
  #|    default: true
  #|    grpc: { descriptorSet: collections.binpb }
  #|stubs:
  #|  - id: fill
  #|    mock: shelf
  #|    request: { path: /collections.Shelf/Fill }
  #|    response: { json: {} }
  #|  - id: upload
  #|    mock: shelf
  #|    request: { method: POST, path: /upload }
  #|    response: { status: 200 }

///|
/// The default `--body-limit`, 10 MiB.
let default_body_limit : Int32 = 10485760

///|
async test "the ticket's example: a message of 10 MiB of empty Items, whose JSON would pass --body-limit, gets RESOURCE_EXHAUSTED at once, is not journaled, and counts as rejected traffic; it costs smock no more memory than an HTTP/2 upload of 10 MiB and its JSON" {
  with_collections_set(limits_shelf, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      // First an HTTP/2 upload of as many octets as --body-limit lets
      // through, the most an HTTP request's body holds.
      let upload = client.send(
        "POST",
        "/upload",
        authority="localhost",
        headers=[],
        body=copies(b"a", default_body_limit),
      )
      guard client.response(upload).status == 200 else {
        fail("the upload failed")
      }
      let uploaded = peak_resident_set(smock.pid)
      // As many empty Items, field 10, of 2 octets each, as fit in
      // --body-limit with the prefix. Each prints
      // `{"name":"","sizes":[],"stock":{}}`, 16 times its size, so the
      // JSON would be 160 MiB.
      let body = framed(copies(b"\x52\x00", (default_body_limit - 5) / 2))
      let start = @async.now()
      let reply = client.call("/collections.Shelf/Fill", body~)
      let took = @async.now() - start
      let called = peak_resident_set(smock.pid)
      inspect(
        [
          limits_reply(reply),
          "answered within 5 s: \{took < 5000}",
          "peak RSS within the upload's, plus --body-limit for the JSON: \{called <= uploaded + default_body_limit.to_double()}",
          "journaled: \{journaled_targets(smock)}",
          smock.metric("smock_requests_total"),
        ].join("\n"),
        content=(
          #|:status: 200, grpc-status: 8, grpc-message: the decoded request message is over the body limit, 0 DATA (end)
          #|answered within 5 s: true
          #|peak RSS within the upload's, plus --body-limit for the JSON: true
          #|journaled: /upload
          #|smock_requests_total{mock="shelf",stub="upload"} 1
          #|smock_requests_total{mock="",stub=""} 1
        ),
      )
    })
  })
}

///|
/// The directory of the limits fixtures.
let limits_dir : String = "fixtures/protobuf/limits"

///|
/// Runs `f` with a definitions directory holding `limits.yaml`: the Mock
/// `burrows`, with limits.proto's set, and a gRPC Stub on Dig, and the
/// Mock `documents`, with dynamic.proto's set, and gRPC Stubs on Wrap,
/// Describe and Echo, each answering any message; and the Mock `shelf` of
/// `limits_shelf`, with collections.proto's set.
async fn with_burrows(f : async (String) -> Unit) -> Unit {
  let yaml =
    #|mocks:
    #|  - name: burrows
    #|    hosts: [burrows.svc]
    #|    grpc: { descriptorSet: limits.binpb }
    #|  - name: documents
    #|    hosts: [documents.svc]
    #|    grpc: { descriptorSet: dynamic.binpb }
    #|stubs:
    #|  - id: dig
    #|    mock: burrows
    #|    request: { path: /limits.Burrows/Dig }
    #|    response: { json: {} }
    #|  - id: wrap
    #|    mock: documents
    #|    request: { path: /dynamic.Documents/Wrap }
    #|    response: { json: {} }
    #|  - id: describe
    #|    mock: documents
    #|    request: { path: /dynamic.Documents/Describe }
    #|    response: { json: {} }
    #|  - id: echo
    #|    mock: documents
    #|    request: { path: /dynamic.Documents/Echo }
    #|    response: { json: {} }
  with_collections_set(limits_shelf, dir => {
    write_bytes(dir, "limits.yaml", @utf8.encode(yaml))
    write_bytes(
      dir,
      "files/limits.binpb",
      @fs.read_file("\{limits_dir}/limits.binpb").binary(),
    )
    write_bytes(
      dir,
      "files/dynamic.binpb",
      @fs.read_file("\{wellknown_dir}/dynamic.binpb").binary(),
    )
    f(dir)
  })
}

///|
/// A length-delimited record of field `field` that holds `value`: its tag,
/// then its length as a varint.
fn length_delimited(field : Int32, value : Bytes) -> Bytes {
  let out = @buffer.Buffer(size_hint=value.length() + 10)
  out.write_byte(((field << 3) | 2).to_byte())
  let mut length = value.length()
  while length >= 0x80 {
    out.write_byte(((length & 0x7F) | 0x80).to_byte())
    length = length >> 7
  }
  out.write_byte(length.to_byte())
  out.write_bytes(value)
  out.to_bytes()
}

///|
async test "strings whose JSON passes --body-limit get RESOURCE_EXHAUSTED and cost smock no more than an HTTP/2 upload of 10 MiB and its JSON: a proto2 string and a proto2 map key that are not UTF-8, which print U+FFFD, 3 octets, for each bad octet, and a proto3 string of control characters, which print 6 each" {
  with_burrows(dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let upload = client.send(
        "POST",
        "/upload",
        authority="localhost",
        headers=[],
        body=copies(b"a", default_body_limit),
      )
      guard client.response(upload).status == 200 else {
        fail("the upload failed")
      }
      let uploaded = peak_resident_set(smock.pid)
      // Octets that fit in --body-limit with the prefix and a record's
      // tags and lengths.
      let octets = default_body_limit - 64
      let bad = copies(b"\xff", octets)
      let calls = [
        (
          "a proto2 string",
          "burrows.svc",
          "/limits.Burrows/Dig",
          length_delimited(1, bad),
        ),
        (
          "a proto2 map key",
          "burrows.svc",
          "/limits.Burrows/Dig",
          length_delimited(4, length_delimited(1, bad)),
        ),
        (
          "a proto3 string",
          "localhost",
          "/collections.Shelf/Fill",
          length_delimited(8, copies(b"\x01", octets)),
        ),
      ]
      let out = []
      for call in calls {
        let (what, authority, path, message) = call
        let reply = client.call(path, authority~, body=framed(message))
        out.push("\{what}: \{limits_reply(reply)}")
      }
      let called = peak_resident_set(smock.pid)
      out.push(
        "peak RSS within the upload's, plus --body-limit for the JSON: \{called <= uploaded + default_body_limit.to_double()}",
      )
      out.push("journaled: \{journaled_targets(smock)}")
      inspect(
        out.join("\n"),
        content=(
          #|a proto2 string: :status: 200, grpc-status: 8, grpc-message: the decoded request message is over the body limit, 0 DATA (end)
          #|a proto2 map key: :status: 200, grpc-status: 8, grpc-message: the decoded request message is over the body limit, 0 DATA (end)
          #|a proto3 string: :status: 200, grpc-status: 8, grpc-message: the decoded request message is over the body limit, 0 DATA (end)
          #|peak RSS within the upload's, plus --body-limit for the JSON: true
          #|journaled: /upload
        ),
      )
    })
  })
}

///|
/// A Burrow that holds `levels` more, each in the one before, through
/// `field`: 2, a message field, 3, a group, whose field 1 holds the next,
/// or 4, a map's values. The last holds `last`.
fn burrows(levels : Int32, field : Int32, last : Bytes) -> Bytes {
  let mut message = last
  for _ in 0..<levels {
    message = match field {
      3 => b"\x1b" + length_delimited(1, message) + b"\x1c"
      4 => length_delimited(4, length_delimited(2, message))
      _ => length_delimited(field, message)
    }
  }
  message
}

///|
/// An Any of `type_url` and `value`.
fn any_of(type_url : String, value : Bytes) -> Bytes {
  length_delimited(1, @utf8.encode(type_url)) + length_delimited(2, value)
}

///|
/// A Value that holds the number 1.5.
let number_value : Bytes = b"\x11\x00\x00\x00\x00\x00\x00\xf8\x3f"

///|
/// A Struct of one member, `x`, whose Value holds a Struct of the same,
/// `levels` times, the last holding the Value `last`.
fn structs(levels : Int32, last : Bytes) -> Bytes {
  let entry = (value : Bytes) => {
    length_delimited(1, length_delimited(1, b"x") + length_delimited(2, value))
  }
  let mut message = entry(last)
  for _ in 1..<levels {
    message = entry(length_delimited(5, message))
  }
  message
}

///|
/// A Value that holds a ListValue of one Value, `levels` times, the last
/// being `last`.
fn listed_values(levels : Int32, last : Bytes) -> Bytes {
  let mut message = last
  for _ in 0..<levels {
    message = length_delimited(6, length_delimited(1, message))
  }
  message
}

///|
async test "a message nested deeper than 100 gets INTERNAL, through a message field, a group, a map's values, an Any, a Struct and its Values, and a ListValue, each group, map entry and Any's message counting as a message; 100 deep is served" {
  with_burrows(dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let dig = "/limits.Burrows/Dig"
      let hello = any_of(
        "type.googleapis.com/helloworld.HelloRequest",
        length_delimited(1, b"Tom"),
      )
      let anys = (levels : Int32) => {
        let mut message = hello
        for _ in 0..<levels {
          message = any_of("type.googleapis.com/google.protobuf.Any", message)
        }
        message
      }
      let calls : Array[(String, String, String, Bytes)] = [
        ("a message field, 100", "burrows.svc", dig, burrows(100, 2, b"")),
        ("a message field, 101", "burrows.svc", dig, burrows(101, 2, b"")),
        ("a group, 100", "burrows.svc", dig, burrows(50, 3, b"")),
        ("a group, 101", "burrows.svc", dig, burrows(50, 3, b"\x1b\x1c")),
        ("a map's values, 100", "burrows.svc", dig, burrows(50, 4, b"")),
        ("a map's values, 101", "burrows.svc", dig, burrows(50, 4, b"\x22\x00")),
        ("an Any, 100", "documents.svc", "/dynamic.Documents/Wrap", anys(99)),
        ("an Any, 101", "documents.svc", "/dynamic.Documents/Wrap", anys(100)),
        (
          "a Struct, 98",
          "documents.svc",
          "/dynamic.Documents/Describe",
          structs(33, number_value),
        ),
        (
          "a Struct, 101",
          "documents.svc",
          "/dynamic.Documents/Describe",
          structs(34, number_value),
        ),
        (
          "a ListValue, 100",
          "documents.svc",
          "/dynamic.Documents/Echo",
          listed_values(50, number_value),
        ),
        (
          "a ListValue, 101",
          "documents.svc",
          "/dynamic.Documents/Echo",
          listed_values(50, b"\x32\x00"),
        ),
      ]
      let out = []
      for call in calls {
        let (what, authority, path, message) = call
        let reply = client.call(path, authority~, body=framed(message))
        out.push("\{what}: \{limits_reply(reply)}")
      }
      out.push("journaled: \{journaled_targets(smock)}")
      out.push(smock.metric("smock_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|a message field, 100: :status: 200, grpc-status: 0, 1 DATA (end)
          #|a message field, 101: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|a group, 100: :status: 200, grpc-status: 0, 1 DATA (end)
          #|a group, 101: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|a map's values, 100: :status: 200, grpc-status: 0, 1 DATA (end)
          #|a map's values, 101: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|an Any, 100: :status: 200, grpc-status: 0, 1 DATA (end)
          #|an Any, 101: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|a Struct, 98: :status: 200, grpc-status: 0, 1 DATA (end)
          #|a Struct, 101: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|a ListValue, 100: :status: 200, grpc-status: 0, 1 DATA (end)
          #|a ListValue, 101: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|journaled: /limits.Burrows/Dig /limits.Burrows/Dig /limits.Burrows/Dig /dynamic.Documents/Wrap /dynamic.Documents/Describe /dynamic.Documents/Echo
          #|smock_requests_total{mock="burrows",stub="dig"} 3
          #|smock_requests_total{mock="",stub=""} 6
          #|smock_requests_total{mock="documents",stub="wrap"} 1
          #|smock_requests_total{mock="documents",stub="describe"} 1
          #|smock_requests_total{mock="documents",stub="echo"} 1
        ),
      )
    })
  })
}

///|
async test "a length that runs past its message, or past the message that holds it, makes the message not parse: the call gets INTERNAL, is not journaled, and counts as rejected traffic" {
  with_burrows(dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let dig = "/limits.Burrows/Dig"
      let calls : Array[(String, String, String, Bytes)] = [
        ("a Burrow's name", "burrows.svc", dig, b"\x0a\x05a"),
        (
          "the name of the Burrow it holds, followed by a name", "burrows.svc", dig,
          b"\x12\x03\x0a\x05a\x0a\x01a",
        ),
        ("in a group", "burrows.svc", dig, b"\x1b\x0a\x03\x0a\x05a\x1c"),
        ("in a map entry", "burrows.svc", dig, b"\x22\x03\x0a\x05a"),
        (
          "the largest length a varint holds", "burrows.svc", dig, b"\x0a\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01a",
        ),
        (
          "a packed record", "localhost", "/collections.Shelf/Fill", b"\x0a\x05\x01",
        ),
        (
          "in an Any's message",
          "documents.svc",
          "/dynamic.Documents/Wrap",
          any_of("type.googleapis.com/helloworld.HelloRequest", b"\x0a\x05a"),
        ),
      ]
      let out = []
      for call in calls {
        let (what, authority, path, message) = call
        let reply = client.call(path, authority~, body=framed(message))
        out.push("\{what}: \{limits_reply(reply)}")
      }
      out.push("journaled: \{journaled_targets(smock)}")
      out.push(smock.metric("smock_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|a Burrow's name: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|the name of the Burrow it holds, followed by a name: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|in a group: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|in a map entry: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|the largest length a varint holds: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|a packed record: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|in an Any's message: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
          #|journaled: none
          #|smock_requests_total{mock="",stub=""} 7
        ),
      )
    })
  })
}
