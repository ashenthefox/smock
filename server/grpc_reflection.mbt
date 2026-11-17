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
// request. serverparsers reads the request and builds the reply
// (`@serverparsers.reflection_reply`), from the Mock's set and, with health
// on, the descriptor of gRPC's health.proto that smock embeds; it says what
// each request kind is answered with.
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
/// whole while the client still sends, and returns whether it answered it.
/// The call is looked up again, from the definition set served now. One
/// that still goes to the reflection service of its Mock is answered
/// (`answer_reflection`), and RST_STREAM NO_ERROR follows. One that a
/// reload has sent elsewhere is handled as from its HEADERS
/// (`answer_from_headers`): answered at once, or left to wait for the end
/// of its request when it can now reach a gRPC Stub.
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
  let host = match request.authority {
    Some(authority) => authority
    None => header_value(request.headers, "host")
  }
  let set : @serverparsers.ReflectionSource? = match mock.descriptor_set {
    Some(set) => Some({ set, files, })
    None => None
  }
  let reply = @serverparsers.reflection_reply(
    message,
    host~,
    set~,
    health=if mock.health { Some(embedded_health) } else { None },
  ) catch {
    _ => {
      self.refuse_call(stream, Undecodable, ended~)
      return
    }
  }
  self.send_built_in(
    stream,
    mock,
    reply,
    self.ports.engine.default_mock_field(incoming, authority?=request.authority),
    date=self.ports.dates.at(self.now),
    out,
    end_early=!ended,
  )
}

///|
/// The embedded descriptor of health.proto, as a source of the reflection
/// service of a Mock that turns health on: decoded the first time a call
/// needs it (`HealthTypes::get`).
fn embedded_health() -> @serverparsers.ReflectionSource {
  let types = HealthTypes::get()
  { set: types.set, files: types.files, }
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
