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
// a message, and one with no message or several (`check_end`). Then its
// message, as it is decoded: one that does not parse, one whose decoded
// JSON passes `--body-limit`, and one whose decoded JSON holds more values
// than a message of its size may print (`decoding_refusal`).

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
  /// A request that ends inside a message's prefix: INTERNAL.
  EndsInPrefix
  /// A request that ends inside a message: INTERNAL.
  EndsInMessage
  /// A request with no message: UNIMPLEMENTED.
  NoMessage
  /// A request with more than one message: UNIMPLEMENTED.
  SeveralMessages
  /// A message that does not parse, or that smock cannot print: INTERNAL.
  Undecodable
  /// A message whose decoded JSON passes `--body-limit` as it is printed:
  /// RESOURCE_EXHAUSTED.
  DecodedOverBodyLimit
  /// A message of `octets` octets whose decoded JSON holds more than
  /// `limit` JSON values, the most a message of its size may print:
  /// RESOURCE_EXHAUSTED. Its `grpc-message` carries both numbers, since
  /// nothing else records the refusal.
  DecodedTooManyValues(limit~ : Int32, octets~ : Int32)
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
    | EndsInPrefix
    | EndsInMessage
    | Undecodable => Internal
    UnservedSubtype | Compressed(_) | NoMessage | SeveralMessages =>
      Unimplemented
    OverBodyLimit | DecodedOverBodyLimit | DecodedTooManyValues(..) =>
      ResourceExhausted
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
    EndsInPrefix => "the request ends inside a message prefix"
    EndsInMessage => "the request ends inside a message"
    NoMessage => "the request has no message"
    SeveralMessages => "the request has more than one message"
    Undecodable => "the request message cannot be decoded"
    DecodedOverBodyLimit => "the decoded request message is over the body limit"
    DecodedTooManyValues(limit~, octets~) =>
      "the decoded request message holds more than \{limit} values, the most for a message of \{octets} octets"
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
/// `grpc-timeout`, then a `content-length` over `body_limit`. As it reads
/// the timeouts, it sets the call's deadline, which counts from `arrived`,
/// when its HEADERS arrived (`H2Request::time_out`).
fn check_head(
  request : H2Request,
  body_limit : Int32,
  arrived~ : Int64,
) -> CallRefusal? {
  if request.meth != "POST" {
    return Some(NotPost)
  }
  if request.unserved_subtype {
    return Some(UnservedSubtype)
  }
  for header in request.headers {
    if header.0 == "grpc-timeout" {
      guard @grpc.timeout_ms(header.1) is Some(timeout) else {
        return Some(MalformedTimeout)
      }
      request.time_out(timeout, arrived~)
    }
  }
  if request.declared > body_limit.to_int64() {
    return Some(OverBodyLimit)
  }
  None
}

///|
/// The longest delay smock can give, 2^31-1 ms, about 24.8 days: a call
/// whose timeout is longer has no deadline, since no delay can outlast it.
let longest_delay_ms : Int64 = 0x7FFF_FFFF

///|
/// Sets the deadline of `self`, a gRPC call whose `grpc-timeout` gives it
/// `timeout` milliseconds from `arrived`, when its HEADERS arrived. A
/// timeout longer than `longest_delay_ms` gives no deadline. Of several
/// `grpc-timeout` fields, each well formed, the last decides.
fn H2Request::time_out(
  self : H2Request,
  timeout : Int64,
  arrived~ : Int64,
) -> Unit {
  self.call_deadline = if timeout > longest_delay_ms {
    forever
  } else {
    arrived + timeout
  }
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

///|
/// What smock refuses in the framing of a gRPC call once its request has
/// ended, its framing read by `deframer`, or `None` when the body is one
/// whole message, a message of zero octets included: a request that ends
/// inside a prefix or a message, then one with no message or several, as
/// a unary method takes one.
fn check_end(deframer : @grpc.Deframer) -> CallRefusal? {
  match deframer.ending() {
    InPrefix => Some(EndsInPrefix)
    InMessage(..) => Some(EndsInMessage)
    Whole(messages=0) => Some(NoMessage)
    Whole(messages=1) => None
    Whole(..) => Some(SeveralMessages)
  }
}

///|
/// The refusal of a call whose message, of `octets` octets without its
/// prefix, did not decode with `error`: a message whose decoded JSON passed
/// `--body-limit`, one whose decoded JSON holds more values than a message
/// of its size may print, or else one that does not parse, or that smock
/// cannot print.
fn decoding_refusal(error : Error, octets : Int32) -> CallRefusal {
  match error {
    @protobuf.TooLarge(..) => DecodedOverBodyLimit
    @protobuf.TooManyValues(limit~) => DecodedTooManyValues(limit~, octets~)
    _ => Undecodable
  }
}
