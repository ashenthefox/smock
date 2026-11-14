// The protocol checks of the gRPC layer: what gRPC's rules refuse in a call,
// answered as gRPC servers answer it, before the call reaches the engine.
// Each refusal is sent as Trailers-Only, with `:status` 200, except a
// method other than POST, which gets 405, and a malformed `grpc-timeout`,
// which gets 400, as grpc-go answers them. A refusal is not journaled, and
// counts as rejected traffic, with `mock=""` and `stub=""`; one sent while
// the client still sends is followed by RST_STREAM NO_ERROR
// (`H2Connection::refuse_call`).
//
// The checks run as soon as what they check arrives. On HEADERS, after
// spec E's 431 and 400, in this order, the first that fails answering: the
// method, the content subtype, the `grpc-timeout`, then the body limit by
// `content-length` (`check_head`); the Mock, its set and the method come
// after them. On each DATA frame, the body limit by the octets received,
// then each message's prefix as soon as it arrives, by the length it
// announces, then by its flag (`H2Connection::check_messages`). Once the
// request has ended, its framing: a request that ends inside a prefix or
// a message, and one with no message or several (`check_end`).

///|
/// Why smock refuses a gRPC call, and so how it answers it.
priv enum CallRefusal {
  /// Its `:method` is not POST: `:status` 405, INTERNAL.
  NotPost
  /// Its content subtype is neither none nor `proto`, such as `json`:
  /// UNIMPLEMENTED.
  UnservedSubtype
  /// A `grpc-timeout` that is not 1 to 8 digits and one of `H M S m u n`:
  /// `:status` 400, INTERNAL.
  MalformedTimeout
  /// A body over `--body-limit`, its prefixes included: RESOURCE_EXHAUSTED.
  OverBodyLimit
  /// A message whose flag is neither 0 nor 1: INTERNAL.
  UnknownFlag
  /// A compressed message, flag 1, with no `grpc-encoding`, or with
  /// `identity`: INTERNAL.
  CompressedWithoutEncoding
  /// A message compressed with the `grpc-encoding` it names, which smock
  /// never decompresses: UNIMPLEMENTED, with `grpc-accept-encoding:
  /// identity`.
  Compressed(String)
  /// A body that is not one uncompressed message: INTERNAL.
  NotOneMessage
  /// A message that does not parse, or that smock cannot print: INTERNAL.
  Undecodable
}

///|
/// The `:status` of the answer.
fn CallRefusal::http_status(self : CallRefusal) -> Bytes {
  match self {
    NotPost => b"405"
    MalformedTimeout => b"400"
    _ => b"200"
  }
}

///|
/// The gRPC status of the answer.
fn CallRefusal::status(self : CallRefusal) -> @grpc.Status {
  match self {
    NotPost
    | MalformedTimeout
    | UnknownFlag
    | CompressedWithoutEncoding
    | NotOneMessage
    | Undecodable => Internal
    UnservedSubtype | Compressed(_) => Unimplemented
    OverBodyLimit => ResourceExhausted
  }
}

///|
/// The answer's `grpc-message`.
fn CallRefusal::message(self : CallRefusal) -> String {
  match self {
    NotPost => "the method must be POST"
    UnservedSubtype => "only the proto content subtype is served"
    MalformedTimeout => "the grpc-timeout is malformed"
    OverBodyLimit => "the request is over the body limit"
    UnknownFlag => "a message flag is neither 0 nor 1"
    CompressedWithoutEncoding =>
      "a compressed message needs a grpc-encoding other than identity"
    Compressed(encoding) =>
      "the grpc-encoding \{encoding} is not served, only identity"
    NotOneMessage => "the request is not one uncompressed message"
    Undecodable => "the request message cannot be decoded"
  }
}

///|
/// The answer's other fields: `grpc-accept-encoding: identity` for a
/// compressed message, as gRPC's rules of compression ask, which tells the
/// client that smock takes only uncompressed messages.
fn CallRefusal::fields(self : CallRefusal) -> ReadOnlyArray[(String, String)] {
  match self {
    Compressed(_) => [("grpc-accept-encoding", "identity")]
    _ => []
  }
}

///|
/// What smock refuses in the HEADERS of `request`, a gRPC call, once spec
/// E's checks have passed, or `None`: in this order, a method other than
/// POST, a content subtype other than none and `proto`, a malformed
/// `grpc-timeout`, then a `content-length` over `body_limit`.
fn check_head(request : H2Request, body_limit : Int32) -> CallRefusal? {
  if request.meth != "POST" {
    return Some(NotPost)
  }
  if request.unserved_subtype {
    return Some(UnservedSubtype)
  }
  for header in request.headers {
    if header.0 == "grpc-timeout" && @grpc.timeout_ns(header.1) is None {
      return Some(MalformedTimeout)
    }
  }
  if request.declared > body_limit.to_int64() {
    return Some(OverBodyLimit)
  }
  None
}

///|
/// What smock refuses in `data`, the next DATA octets of `request`, a gRPC
/// call whose framing `deframer` reads, or `None`. Each message's prefix
/// is checked as soon as it arrives, before the message does: a length
/// that takes the body over `--body-limit`, then the flag. Flag 0 is
/// served whatever `grpc-encoding` says, and any other flag is refused,
/// since smock never decompresses.
fn H2Connection::check_messages(
  self : H2Connection,
  request : H2Request,
  deframer : @grpc.Deframer,
  data : Bytes,
) -> CallRefusal? {
  let mut rest = data[:]
  while deframer.take(rest) is Prefix(flag~, body_length~, rest=after, ..) {
    if body_length > self.body_limit.to_int64() {
      return Some(OverBodyLimit)
    }
    match flag {
      b'\x00' => ()
      b'\x01' =>
        return match encoding_of(request) {
          None | Some("" | "identity") => Some(CompressedWithoutEncoding)
          Some(encoding) => Some(Compressed(encoding))
        }
      _ => return Some(UnknownFlag)
    }
    rest = after
  }
  None
}

///|
/// The value of the `grpc-encoding` field of `request`, the compression of
/// its messages, or `None` without one. Of several, the last.
fn encoding_of(request : H2Request) -> String? {
  let mut encoding = None
  for header in request.headers {
    if header.0 == "grpc-encoding" {
      encoding = Some(header.1)
    }
  }
  encoding
}
