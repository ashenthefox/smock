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
    guard entry is Object({ "request": Object({ "target": String(target), .. }), .. }) else {
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
/// The Mock `shelf`, with collections.proto's set, a gRPC Stub on Fill
/// that answers any message, and an HTTP Stub that takes uploads.
let limits_shelf : String =
  #|mocks:
  #|  - name: shelf
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
