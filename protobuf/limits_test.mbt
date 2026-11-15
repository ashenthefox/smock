// The decoder's bounds, through the public interface: what `decode_json`
// prints is counted as it is printed, and a message whose JSON passes the
// limit it is given is refused as soon as it does, however small the
// message. The messages are written by hand, as hostile clients write
// them; the sets are protoc's (scripts/gen-protobuf-fixtures.sh).

///|
/// `input` decoded as a message of the type whose full name is `name` in
/// the set the script wrote in `hex`, with its JSON bounded by `limit`, as
/// text, or the error that stops it.
fn bounded(
  hex : String,
  name : String,
  input : Bytes,
  limit~ : Int32,
) -> String {
  let set = hex_set(hex)
  guard set.find_message(name) is Some(message) else {
    abort("no message \{name}")
  }
  @utf8.decode(@protobuf.decode_json(set, message, input[:], limit~)) catch {
    err => "error: \{err}"
  }
}

///|
/// `count` copies of `record`, joined.
fn repeated(record : Bytes, count : Int32) -> Bytes {
  let out = @buffer.Buffer(size_hint=record.length() * count)
  for _ in 0..<count {
    out.write_bytes(record)
  }
  out.to_bytes()
}

///|
test "the JSON is counted as it is printed: a message whose JSON passes the limit is refused, and one whose JSON is at the limit is printed" {
  // Three empty Items, each printed with every field at its default.
  let items = repeated(b"\x52\x00", 3)
  let text = bounded(collections_set, "collections.Lists", items, limit=1000)
  inspect(
    "\{text.length()} \{text}",
    content=(
      #|219 {"numbers":[],"offsets":[],"codes":[],"ratios":[],"weights":[],"flags":[],"kinds":[],"words":[],"blobs":[],"items":[{"name":"","sizes":[],"stock":{}},{"name":"","sizes":[],"stock":{}},{"name":"","sizes":[],"stock":{}}]}
    ),
  )
  inspect(
    [
      bounded(collections_set, "collections.Lists", items, limit=219),
      bounded(collections_set, "collections.Lists", items, limit=218),
    ].join("\n"),
    content=(
      #|{"numbers":[],"offsets":[],"codes":[],"ratios":[],"weights":[],"flags":[],"kinds":[],"words":[],"blobs":[],"items":[{"name":"","sizes":[],"stock":{}},{"name":"","sizes":[],"stock":{}},{"name":"","sizes":[],"stock":{}}]}
      #|error: the decoded message passes the limit of 218 octets
    ),
  )
}
