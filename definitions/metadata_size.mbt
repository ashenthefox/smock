// The size of a gRPC reply's metadata. A reply goes out in two blocks of
// header fields, its header block and its trailers, or, for an error
// without initial metadata, in one Trailers-Only block. Each block counts
// against `--header-size-limit` as RFC 7541, section 4.1, counts a header
// list: each field's name and value, plus 32 octets, smock's own fields
// included. A static reply with a block over the limit is a problem at
// load, and `smock check` warns about one with a block over 8 KiB, the size
// gRPC lets a client limit each block to. The server counts the blocks of
// each reply it sends the same way, before it sends any of them.

///|
/// The default `--header-size-limit`, 16 KiB: the limit a load that is
/// given none counts a static gRPC reply's metadata against.
pub let default_header_size_limit : Int32 = 16384

///|
/// The octets a field whose name takes `name` octets and whose value takes
/// `value` costs in a header list (RFC 7541, section 4.1).
fn field_cost(name : Int32, value : Int32) -> Int32 {
  name + value + 32
}

///|
/// The fields smock adds to a gRPC reply's header block and to a
/// Trailers-Only block: `:status: 200` and `content-type:
/// application/grpc`.
let reply_head_cost : Int32 = field_cost(7, 3) + field_cost(12, 16)

///|
/// The `date` field smock adds, unless the metadata gives one: an
/// IMF-fixdate, such as `Sat, 14 Nov 2026 07:00:00 GMT`, takes 29 octets.
let date_cost : Int32 = field_cost(4, 29)

///|
/// A block of header fields that a static gRPC reply goes out in, with its
/// size, as RFC 7541 counts a header list.
priv struct MetadataBlock {
  /// The block, as a problem names it: `header block`, `trailers` or
  /// `Trailers-Only block`.
  name : String
  /// Its size, in octets.
  size : Int32
}

///|
/// The blocks that `response`, a gRPC Stub's reply, goes out in, as the
/// server sends it, each with its size: its header block, then its
/// trailers, or its one Trailers-Only block for an error without initial
/// metadata. Each counts `:status`, `content-type`, `grpc-status`,
/// `grpc-message` percent-encoded, the metadata with values trimmed of
/// spaces at either end, and `date` unless the metadata gives one.
/// `smock-mock`, which smock adds only when the Default Mock answers, is
/// not counted. `None` for a templated reply, whose sizes are known only
/// once rendered.
fn metadata_blocks(response : Response) -> Array[MetadataBlock]? {
  guard response.headers is Written(headers) else { return None }
  let (status, message, trailers) = match response.grpc {
    None => (@grpc.Status::Ok, 0, 0)
    Some({ status, message, trailers }) => {
      guard trailers is Written(trailers) else { return None }
      let message = match message {
        Some(Written(text)) =>
          field_cost(12, @grpc.percent_encode(text).length())
        Some(Templated(_)) => return None
        None => 0
      }
      (status, message, metadata_cost(trailers))
    }
  }
  let code = status.code()
  let ending = field_cost(11, if code < 10 { 1 } else { 2 }) +
    message +
    trailers
  if status is Ok || headers.length() > 0 {
    let head = reply_head_cost + metadata_cost(headers)
    Some([
      {
        name: "header block",
        size: if gives_date(headers) { head } else { head + date_cost },
      },
      { name: "trailers", size: ending },
    ])
  } else {
    let only = reply_head_cost + ending
    let given = match response.grpc {
      Some({ trailers: Written(trailers), .. }) => gives_date(trailers)
      _ => false
    }
    Some([
      {
        name: "Trailers-Only block",
        size: if given { only } else { only + date_cost },
      },
    ])
  }
}

///|
/// The octets `fields`, metadata as written, cost in a header list, each
/// value trimmed of spaces and tabs at either end, as the server sends it.
fn metadata_cost(fields : ReadOnlyArray[(String, String)]) -> Int32 {
  let mut cost = 0
  for i in 0..<fields.length() {
    let (name, value) = fields[i]
    cost += field_cost(name.length(), trimmed_length(value))
  }
  cost
}

///|
/// The length of `value` once trimmed of spaces and tabs at either end.
fn trimmed_length(value : String) -> Int32 {
  let mut start = 0
  let mut end = value.length()
  while start < end && value[start] is (' ' | '\t') {
    start += 1
  }
  while end > start && value[end - 1] is (' ' | '\t') {
    end -= 1
  }
  end - start
}

///|
/// Whether `fields`, metadata with names in lower case, give a `date`,
/// which then goes out in place of smock's.
fn gives_date(fields : ReadOnlyArray[(String, String)]) -> Bool {
  for i in 0..<fields.length() {
    if fields[i].0 == "date" {
      return true
    }
  }
  false
}

///|
/// Reports at `pointer` each block of `response`, a gRPC Stub's static
/// reply at `pointer`, that takes more than `--header-size-limit`: the
/// server could not send it.
fn File::check_metadata_size(
  self : File,
  pointer : String,
  response : Response,
) -> Unit {
  guard metadata_blocks(response) is Some(blocks) else { return }
  let limit = self.header_size_limit
  for block in blocks {
    if block.size > limit {
      self.error(
        pointer,
        "the reply's \{block.name} would take \{block.size} bytes, over --header-size-limit, \{limit}: each block of a gRPC reply's metadata counts as RFC 7541 counts a header list, each field's name and value plus 32, smock's own fields included",
      )
    }
  }
}
