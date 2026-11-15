// The built-in health service of a Mock, gRPC's `grpc.health.v1.Health`,
// which a Mock turns on with `grpc.health`. It answers as gRPC's health
// servers do: `Check` says SERVING for `""`, the server as a whole, and for
// each service of the Mock's Descriptor set, and gives NOT_FOUND for other
// names; `List` gives the same statuses, by name. Once SIGTERM starts the
// drain, every answer says NOT_SERVING, so that health-checking clients
// move away before smock stops. `Watch` streams, so it gets UNIMPLEMENTED,
// answered from its HEADERS, as any streaming method is.
//
// A call goes to the service when its Mock turns health on, its `:path`
// names a method of the service, and no Stub is on that path: neither a
// gRPC Stub of the Definition files nor an Ephemeral gRPC Stub of the
// call's Session (`@engine.Engine::has_grpc_stub`). Such a Stub answers in
// the service's place, so a Scenario can make the service NOT_SERVING; it
// needs the service's `.proto` in the Mock's set, as any gRPC Stub does. The
// service is looked up with the call's Mock, before the method of the set,
// when the call's HEADERS arrive and again once its request has ended; a
// Mock that does not turn health on pays one test of its flag each time.
//
// The service's messages are decoded and encoded with smock/protobuf, from
// the descriptor of gRPC's health.proto that smock embeds (`health_set`),
// so the Mock's set need not hold it. The protocol checks apply to a health
// call as to any call. Its answer does not reach the engine: it is not in
// the Journal and gets no Mockoon line, and it counts in the request
// metrics under its Mock with `stub=""`, not as an unmatched request.

///|
/// The types of the health service's messages, from the descriptor of
/// gRPC's health.proto that smock embeds.
priv struct HealthTypes {
  /// The embedded descriptor, decoded.
  set : @protobuf.DescriptorSet
  /// `HealthCheckRequest`, the input of `Check`.
  check_request : @protobuf.MessageDescriptor
  /// `HealthCheckResponse`, the output of `Check`.
  check_response : @protobuf.MessageDescriptor
  /// `HealthListRequest`, the input of `List`.
  list_request : @protobuf.MessageDescriptor
  /// `HealthListResponse`, the output of `List`.
  list_response : @protobuf.MessageDescriptor
}

///|
/// The types, once a call to a health service has needed them: the
/// embedded descriptor is decoded then, so that a process whose Mocks do
/// not turn health on holds nothing of it.
let health_types : Ref[HealthTypes?] = Ref(None)

///|
/// The types of the health service's messages, decoded from the embedded
/// descriptor the first time.
fn HealthTypes::get() -> HealthTypes {
  if health_types.val is Some(types) {
    return types
  }
  let set = @protobuf.read_descriptor_set(
    @hex.decode(health_set.replace_all(old="\n", new="")),
  ) catch {
    _ => abort("the embedded descriptor of health.proto decodes")
  }
  guard set.find_message("grpc.health.v1.HealthCheckRequest")
    is Some(check_request) &&
    set.find_message("grpc.health.v1.HealthCheckResponse")
    is Some(check_response) &&
    set.find_message("grpc.health.v1.HealthListRequest") is Some(list_request) &&
    set.find_message("grpc.health.v1.HealthListResponse") is Some(list_response) else {
    abort("the embedded descriptor of health.proto has the service's messages")
  }
  let types = {
    set,
    check_request,
    check_response,
    list_request,
    list_response,
  }
  health_types.val = Some(types)
  types
}

///|
/// A method of the health service.
priv enum HealthMethod {
  /// `Check`, unary: the status of one service.
  Check
  /// `List`, unary: the status of every service.
  List
  /// `Watch`, server streaming, which smock does not serve yet.
  Watch
}

///|
/// The method of the health service that a gRPC call to `path` calls, or
/// `None` when `path` names none.
fn health_method(path : String) -> HealthMethod? {
  match path {
    "/grpc.health.v1.Health/Check" => Some(Check)
    "/grpc.health.v1.Health/List" => Some(List)
    "/grpc.health.v1.Health/Watch" => Some(Watch)
    _ => None
  }
}

///|
/// The method of the built-in health service of `mock` that `request`, a
/// gRPC call to the Mock, goes to, or `None` when the call goes elsewhere:
/// when the Mock does not turn health on, the call's `:path` names no
/// method of the service, or a Stub is on the path, from the Definition
/// files or an Ephemeral one of the call's Session.
fn H2Connection::health_call(
  self : H2Connection,
  mock : @definitions.Mock,
  request : H2Request,
) -> HealthMethod? {
  // A Mock that does not turn health on pays this test only.
  guard mock.health else { return None }
  guard health_method(request.target) is Some(called) else { return None }
  let session = self.ports.sessions.session_of(request.headers)
  if self.ports.engine.has_grpc_stub(mock, request.target, session~) {
    return None
  }
  Some(called)
}

///|
/// The fixed `grpc-message` of the NOT_FOUND that `Check` gives for a name
/// that is not a service of the Mock's set, as grpc-go's health server
/// words it.
let unknown_service_message : String = "unknown service"

///|
/// Answers `stream`, a gRPC call to `method` of the built-in health service
/// of `mock`, whose request is `request`. `Watch` gets Trailers-Only
/// UNIMPLEMENTED, followed by RST_STREAM NO_ERROR when the request has not
/// `ended` (`end_early`). `Check` and `List` are answered once the request
/// has ended: a body that is not one whole message gets the refusal that
/// `refuse_call` sends, and so does a message that does not decode as the
/// method's input type. Otherwise the reply is sent as any reply is
/// (`reply_built_in`), or, for a `Check` of a name that is not a service of
/// the Mock's set, Trailers-Only NOT_FOUND. Once the drain has started,
/// every reply says NOT_SERVING. The answer carries `smock-mock` when the
/// Default Mock gives it, and counts under the Mock with `stub=""`.
fn[S : @io.Writer + ReadOutput] H2Connection::answer_health(
  self : H2Connection,
  stream : Int32,
  request : H2Request,
  mock : @definitions.Mock,
  called : HealthMethod,
  out : WatchedStream[S],
  ended~ : Bool,
) -> Unit {
  if called is Watch {
    self.answer_watch(stream, request, mock, ended~)
    return
  }
  let incoming = request.to_engine()
  let smock_mock = self.ports.engine.default_mock_field(
    incoming,
    authority?=request.authority,
  )
  let date = self.ports.dates.at(self.now)
  guard request.deframer is Some(deframer) else {
    abort("a gRPC call reads its framing")
  }
  if check_end(deframer) is Some(refusal) {
    self.refuse_call(stream, refusal, ended=true)
    return
  }
  let types = HealthTypes::get()
  let input = if called is Check {
    types.check_request
  } else {
    types.list_request
  }
  let message = incoming.body[@grpc.prefix_length:]
  let json = @protobuf.decode_json(types.set, input, message) catch {
    _ => {
      self.refuse_call(stream, Undecodable, ended=true)
      return
    }
  }
  let status = Json::string(
    if self.ports.lifecycle.is_draining() {
      "NOT_SERVING"
    } else {
      "SERVING"
    },
  )
  if called is List {
    // `""` first, then each service of the set, in the set's order.
    let statuses : Map[String, Json] = { "": { "status": status } }
    if mock.descriptor_set is Some(set) {
      for file in set.files {
        for service in file.services {
          statuses[service.full_name] = { "status": status }
        }
      }
    }
    self.reply_built_in(
      stream,
      mock,
      types.set,
      types.list_response,
      { "statuses": Json::object(statuses) },
      smock_mock,
      date~,
      out,
    )
    return
  }
  let parsed = @json.parse(@utf8.decode(json)) catch { _ => Json::null() }
  let service = match parsed {
    Object({ "service": String(service), .. }) => service
    _ => ""
  }
  // Once the drain has started, every answer says NOT_SERVING, an unknown
  // name's included.
  if !self.ports.lifecycle.is_draining() &&
    service != "" &&
    !has_service(mock, service) {
    self.answer_built_in_status(
      stream,
      mock,
      @grpc.NotFound,
      unknown_service_message,
      smock_mock,
      date~,
    )
    return
  }
  self.reply_built_in(
    stream,
    mock,
    types.set,
    types.check_response,
    { "status": status },
    smock_mock,
    date~,
    out,
  )
}

///|
/// Answers `stream`, a gRPC call to `Watch` of the built-in health service
/// of `mock`, whose request is `request`, as a call to any streaming method
/// is answered: Trailers-Only UNIMPLEMENTED `streaming methods are not
/// served yet`, followed by RST_STREAM NO_ERROR when the request has not
/// `ended` (`end_early`). It counts under the Mock with `stub=""`.
fn H2Connection::answer_watch(
  self : H2Connection,
  stream : Int32,
  request : H2Request,
  mock : @definitions.Mock,
  ended~ : Bool,
) -> Unit {
  self.answer_built_in_status(
    stream,
    mock,
    @grpc.Unimplemented,
    streaming_message,
    self.ports.engine.default_mock_field(
      request.without_body(),
      authority?=request.authority,
    ),
    date=self.ports.dates.at(self.now),
  )
  if !ended {
    self.end_early(stream)
  }
}

///|
/// Sends on `stream` the reply of a built-in service of `mock`: `reply`,
/// JSON encoded with `output`, a type of `set`, as any reply is sent:
/// HEADERS with `smock-mock` when `smock_mock` gives its value, and `date`
/// with the value `date`; the framed message in one DATA frame when it
/// fits the windows, or else in a task of its own, which writes to `out`
/// (`write_built_in_slowly`); then trailers with `grpc-status: 0`. The
/// answer counts under the Mock with `stub=""` once it is queued in full.
fn[S : @io.Writer + ReadOutput] H2Connection::reply_built_in(
  self : H2Connection,
  stream : Int32,
  mock : @definitions.Mock,
  set : @protobuf.DescriptorSet,
  output : @protobuf.MessageDescriptor,
  reply : Json,
  smock_mock : String?,
  date~ : String,
  out : WatchedStream[S],
) -> Unit {
  let encoded = set.encode_json(output, reply) catch {
    _ => abort("a reply of a built-in service encodes")
  }
  let head = reply_head(
    match smock_mock {
      Some(value) => [("Smock-Mock", value)]
      None => []
    },
    date~,
  )
  let trailers = status_trailers(@grpc.Ok, None, [])
  let rest = self.queue_reply(
    stream,
    head,
    @grpc.frame(encoded),
    trailers,
    None,
  )
  if rest.length() > 0 {
    self.write_built_in_slowly(stream, rest, trailers, mock.name, out)
    return
  }
  self.ports.built_in(mock.name, self.last_read)
}

///|
/// Whether `service`, the full name of a gRPC service, such as
/// `helloworld.Greeter`, is a service of the Descriptor set of `mock`. A
/// Mock without a set has none.
fn has_service(mock : @definitions.Mock, service : String) -> Bool {
  guard mock.descriptor_set is Some(set) else { return false }
  for file in set.files {
    for declared in file.services {
      if declared.full_name == service {
        return true
      }
    }
  }
  false
}

///|
/// The fixed `grpc-message` of the UNIMPLEMENTED that a call to a streaming
/// method gets, a call to the health service's `Watch` included.
let streaming_message : String = "streaming methods are not served yet"

///|
/// Answers `stream`, a gRPC call that a built-in service of `mock` answers
/// with `status`, other than OK, and the fixed ASCII `message`, as
/// Trailers-Only, with `smock-mock` when `smock_mock` gives its value, and
/// counts it under the Mock with `stub=""`. `date` is the value of the
/// answer's `date` field.
fn H2Connection::answer_built_in_status(
  self : H2Connection,
  stream : Int32,
  mock : @definitions.Mock,
  status : @grpc.Status,
  message : String,
  smock_mock : String?,
  date~ : String,
) -> Unit {
  let fields = trailers_only(status, Some(message), smock_mock, date~)
  self.headers_only(stream, fields, None, partial=false)
  self.ports.built_in(mock.name, self.last_read)
}

///|
/// Sends `rest`, the part of the framed message of a built-in service's
/// reply on `stream` that did not fit the windows when it was queued, in a
/// task of its own, which writes to `out` (`trickle`), then the trailers
/// `trailers`, which end the stream. The answer counts under the Mock
/// named `mock`, with `stub=""`, when the task ends. The task ends with its
/// stream, as a slow write of a Stub's reply does (`write_slowly`).
fn[S : @io.Writer + ReadOutput] H2Connection::write_built_in_slowly(
  self : H2Connection,
  stream : Int32,
  rest : BytesView,
  trailers : Array[@header.Header],
  mock : String,
  out : WatchedStream[S],
) -> Unit {
  // The read that brought the request in full.
  let stopwatch = self.last_read
  let task = self.group.spawn(no_wait=true, () => {
    defer self.ports.built_in(mock, stopwatch)
    let finished = self.trickle(stream, rest, None, out, end=false)
    if finished {
      self.end_with_trailers(stream, trailers)
    }
    self.end_task(stream, out, finished~)
  })
  self.waiting[stream] = task
}
