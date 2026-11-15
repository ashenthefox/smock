// The gRPC layer of the HTTP/2 mapping, on the plain and TLS ports alike: an
// HTTP/2 stream whose `content-type` is `application/grpc`, alone or
// followed by `+` or `;`, is a gRPC unary call (`@grpc.content_subtype`).
// One whose content subtype is neither none nor `proto`, such as `json`, is
// refused from its HEADERS, after spec E's checks, with Trailers-Only
// UNIMPLEMENTED. Every other stream is an HTTP request. The call's
// Mock and its Descriptor set are looked up twice, from the definition set
// served at the time. When the call's HEADERS arrive, a call that cannot
// reach a gRPC Stub, since its Host reaches no Mock, its Mock has no set,
// or its `:path` names no unary method of the set, is answered at once,
// without waiting for its message. Once the request has ended, the call is
// looked up again, its one message is taken from the body and decoded into
// JSON, and the engine decides the call as a POST to the method's path,
// with the metadata as headers, the JSON as the body and the gRPC call
// marker. The reply is the message that a static reply was encoded into
// when the files were loaded, or else the rendered reply JSON, encoded here
// with the method's output type. It is written as gRPC writes it: HEADERS
// with the reply's initial metadata, one DATA frame with the framed
// message, then trailers with `grpc-status: 0`, the reply's
// `grpc-message`, if it gives one, and its trailing metadata. The
// second lookup, the decoding, `handle` and the encoding run with no await
// between them, so a reload never splits them, and a call that the reload
// leaves without a gRPC Stub to reach gets the answer it would have got
// from its HEADERS.
//
// A call that cannot reach a gRPC Stub still goes to the engine, with an
// empty body, which plans its UNIMPLEMENTED answer and journals it as
// unmatched. A plan whose gRPC status is not OK, such as a gRPC Stub's
// error or that UNIMPLEMENTED, is sent as Trailers-Only, one HEADERS block
// that ends the stream, with `:status` 200, its `grpc-status`, its
// `grpc-message` and its trailers, such as the Near miss, unless the reply
// has initial metadata: it then gets HEADERS with it, then the trailers.
// Metadata goes out as spec E sends header fields: names in lower case,
// values trimmed, and the fields HTTP/2 forbids left out. A `grpc-message`
// is the status message percent-encoded, so any Unicode text fits in the
// field (`@grpc.percent_encode`). Both blocks of a Stub's reply are built
// before either is sent, and a reply with a block over
// `--header-size-limit`, or over the SETTINGS_MAX_HEADER_LIST_SIZE the
// client advertised, gets Trailers-Only INTERNAL `reply metadata too large`
// instead (`answer_too_large`). An answer sent before the client has
// ended its request is followed by RST_STREAM NO_ERROR (`end_early`). What
// gRPC's rules refuse in a call, checked as soon as it arrives, and what the
// layer cannot serve yet, get Trailers-Only too, with their `grpc-status`
// and a fixed `grpc-message`, and `:status` 200 but for a method other than
// POST and a malformed `grpc-timeout` (grpc_checks.mbt). A call that does
// not reach the engine is counted as rejected traffic and is not
// journaled; one that does is journaled as the engine planned it, with the
// gRPC status INTERNAL, which the entry records before it is committed.

///|
/// The content type of gRPC calls, as the octets of a field value.
let grpc_content_type : Bytes = @utf8.encode(@grpc.content_type)

///|
/// Whether `subtype`, the content subtype of a gRPC call, is one smock
/// serves: none, or `proto`, the subtypes of protobuf messages.
fn is_served_subtype(subtype : BytesView) -> Bool {
  subtype.length() == 0 || subtype == b"proto"[:]
}

///|
/// The unary method that a gRPC call to `path` calls in `set`, the
/// Descriptor set of the call's Mock, or `None` when `path` names no method
/// of the set, or names a streaming method: such a call cannot reach a gRPC
/// Stub.
fn unary_method(
  set : @protobuf.DescriptorSet,
  path : String,
) -> @protobuf.MethodDescriptor? {
  guard set.find_method(path) is Some(rpc) else { return None }
  if rpc.client_streaming || rpc.server_streaming {
    return None
  }
  Some(rpc)
}

///|
/// Answers `stream`, a gRPC call whose HEADERS have just arrived, with
/// `request` as they give it, when the call cannot reach a gRPC Stub: when
/// its Host reaches no Mock, its Mock has no Descriptor set, or its `:path`
/// names no unary method of the set. Returns whether it answered it. The
/// call is then no longer among the requests: its answer is sent at once,
/// without waiting for its message (`answer_unserved`), and RST_STREAM
/// NO_ERROR follows it. A call that can reach a gRPC Stub waits for the end
/// of its request, which looks it up again.
fn H2Connection::answer_from_headers(
  self : H2Connection,
  stream : Int32,
  request : H2Request,
) -> Bool {
  let mock = self.ports.engine.mock_for_call(
    request.without_body(),
    authority?=request.authority,
  )
  if mock is Some({ descriptor_set: Some(set), .. }) &&
    unary_method(set, request.target) is Some(_) {
    return false
  }
  self.requests.remove(stream)
  self.answer_unserved(stream, request, ended=false)
  self.end_stream()
  true
}

///|
/// Answers `stream`, a gRPC call whose request is `request` and that cannot
/// reach a gRPC Stub, through the engine, which decides it with an empty
/// body and the count of octets received so far: it plans Trailers-Only
/// UNIMPLEMENTED with the fixed message that says why, and journals the
/// call as unmatched. A call whose request has not `ended` then gets
/// RST_STREAM NO_ERROR (`end_early`).
fn H2Connection::answer_unserved(
  self : H2Connection,
  stream : Int32,
  request : H2Request,
  ended~ : Bool,
) -> Unit {
  let outcome = self.ports.decide(
    request.without_body(),
    authority?=request.authority,
    grpc={ path: request.target, octets: request.received(), },
    now=self.now,
  )
  guard outcome.plan.grpc is Some(part) else {
    abort("a gRPC call that reaches no gRPC Stub is planned UNIMPLEMENTED")
  }
  self.answer_status(stream, outcome, part, date=self.ports.dates.at(self.now))
  self.ended_in_place(request, outcome)
  if !ended {
    self.end_early(stream)
  }
}

///|
/// Ends `stream`, a gRPC call that smock has answered before the client
/// ended its request, with RST_STREAM NO_ERROR, so that the client stops
/// sending it (RFC 9113, section 8.1), as grpc-go does. Every gRPC answer
/// sent before the request has ended is followed by it.
fn H2Connection::end_early(self : H2Connection, stream : Int32) -> Unit {
  self.reset(stream, @http2.error_no_error)
}

///|
/// Answers the gRPC call that has arrived in full on `stream`: through the
/// engine, when the call can be served, or else with the refusal that
/// `refuse_call` sends, when its body is not one whole message
/// (`check_end`) or the message does not decode. The call's Mock and its
/// set are looked up again first, and a call that cannot reach a gRPC Stub
/// now is answered as from its HEADERS (`answer_unserved`). The engine's
/// plan becomes the call's answer (`call_answer`), which is sent at once
/// (`send_answer`), or once the plan's delay is over, in a task of its own
/// (`wait_call`), which writes to `out`. The rest of a reply too large for
/// the windows is sent in a task of its own too (`write_slowly`), with the
/// trailers after it.
fn[S : @io.Writer + ReadOutput] H2Connection::answer_call(
  self : H2Connection,
  stream : Int32,
  request : H2Request,
  out : WatchedStream[S],
) -> Unit {
  let ports = self.ports
  let incoming = request.to_engine()
  // The second lookup, from the definition set served now: a reload since
  // the HEADERS may have changed the Mock, its set or the method.
  guard ports.engine.mock_for_call(incoming, authority?=request.authority)
    is Some({ descriptor_set: Some(set), .. }) &&
    unary_method(set, incoming.target) is Some(rpc) else {
    self.answer_unserved(stream, request, ended=true)
    return
  }
  // Each prefix was checked as it arrived, so the body's one message, if
  // it has one, is as it is, uncompressed.
  guard request.deframer is Some(deframer) else {
    abort("a gRPC call reads its framing")
  }
  if check_end(deframer) is Some(refusal) {
    self.refuse_call(stream, refusal, ended=true)
    return
  }
  // A message that does not parse, or whose type has a field that smock
  // does not decode yet, does not decode.
  let message = incoming.body[@grpc.prefix_length:]
  let json = @protobuf.decode_json(set, set.input_of(rpc), message) catch {
    _ => {
      self.refuse_call(stream, Undecodable, ended=true)
      return
    }
  }
  let outcome = ports.decide(
    { ..incoming, body: json, },
    authority?=request.authority,
    grpc={ path: incoming.target, octets: incoming.body.length(), },
    now=self.now,
  )
  let answer = call_answer(set, rpc, outcome)
  // A delay waits in the stream's task, which the call's deadline can cut
  // short.
  if outcome.plan.delay_ms > 0 {
    self.wait_call(stream, request, outcome, answer, out)
    return
  }
  match
    self.send_answer(stream, outcome, answer, date=ports.dates.at(self.now)) {
    Some(unsent) =>
      self.write_slowly(
        stream,
        request,
        unsent.rest,
        outcome,
        out,
        trailers=unsent.trailers,
      )
    None => self.ended_in_place(request, outcome)
  }
}

///|
/// What a gRPC call that reached the engine gets, as `call_answer` makes it
/// from the engine's plan, once the reply message is encoded.
priv enum CallAnswer {
  /// The reply of a Stub that matched, with the status OK: the plan's gRPC
  /// part and the reply message, encoded.
  Reply(@engine.GrpcPart, Bytes)
  /// An answer without a message, with the plan's gRPC part, whose status
  /// is not OK, such as a Stub's error or the UNIMPLEMENTED of a call that
  /// no Stub matched.
  Status(@engine.GrpcPart)
  /// smock's own Trailers-Only INTERNAL, with the fixed `message`, in place
  /// of a reply it cannot send, with the template error that says why, if
  /// there is one.
  Internal(message~ : String, template_error~ : @engine.TemplateError?)
}

///|
/// The answer to a gRPC call to `rpc`, a unary method of `set`, that the
/// engine decided `outcome` for. A plan without a gRPC part is smock's own
/// answer to a gRPC Stub that could not serve its content, which gets
/// INTERNAL. A plan whose status is OK gets its reply message encoded with
/// the method's output type: a static reply was encoded when the files
/// were loaded, with the output type of the set served then, which is
/// `set` unless the Stub outlived a reload; a templated one is encoded
/// here, once rendered, and one that does not fit the output type gets
/// INTERNAL `template failed`. It runs with no await after the second
/// lookup, the decoding and `handle`, so a reload never splits them, even
/// when the answer then waits for the plan's delay.
fn call_answer(
  set : @protobuf.DescriptorSet,
  rpc : @protobuf.MethodDescriptor,
  outcome : @engine.Outcome,
) -> CallAnswer {
  let plan = outcome.plan
  guard plan.grpc is Some(part) else {
    let message = match outcome.content_error {
      Some({ failure: Template(_), .. }) => "template failed"
      Some({ failure: Data(_), .. }) => "data write failed"
      None => "state limit reached"
    }
    return Internal(message~, template_error=None)
  }
  // Any status but OK, such as the UNIMPLEMENTED of a call that no Stub
  // matched, ends the call without a message.
  guard part.status is Ok else { return Status(part) }
  let output = set.output_of(rpc)
  match part.encoded {
    Some(encoded) if physical_equal(encoded.output, output) =>
      Reply(part, encoded.message)
    _ => {
      let reply = encode_reply(set, output, plan.body) catch {
        EncodeError(pointer~, message~) =>
          return Internal(
            message="template failed",
            template_error=match outcome.journal {
              Some(entry) =>
                Some(@engine.TemplateError::{
                  at: reply_pointer(entry.response_index) + pointer,
                  message,
                })
              None => None
            },
          )
      }
      Reply(part, reply)
    }
  }
}

///|
/// The part of a reply's framed message that did not fit when the reply
/// was queued, and the trailers that follow it.
priv struct Unsent {
  rest : BytesView
  trailers : Array[@header.Header]
}

///|
/// Sends `answer` on `stream`, a gRPC call that the engine decided
/// `outcome` for, with the value `date` in its `date` field, and commits
/// the call's Journal entry just before the block that ends the stream. A
/// Stub's reply too large to send gets INTERNAL instead
/// (`answer_too_large`). A reply whose framed message does not fit the
/// windows, or with `bounded`, from the stream's task, the room the output
/// bound leaves for one DATA frame (`H2Writer::frame_room`), gets as much
/// as fits: the rest is returned, with the trailers that follow it, which
/// the caller sends from the stream's task, with the entry still to
/// commit. Otherwise it returns `None`.
fn H2Connection::send_answer(
  self : H2Connection,
  stream : Int32,
  outcome : @engine.Outcome,
  answer : CallAnswer,
  date~ : String,
  bounded~ : Bool = false,
) -> Unsent? {
  match answer {
    Internal(message~, template_error~) => {
      self.answer_own(
        stream,
        outcome,
        Internal,
        message,
        date~,
        template_error?,
      )
      None
    }
    Status(part) => {
      self.answer_status(stream, outcome, part, date~)
      None
    }
    Reply(part, reply) => {
      let head = reply_head(outcome.plan.headers, date~)
      let trailers = status_trailers(Ok, part.message, part.trailers)
      if self.answer_too_large(stream, outcome, Some(head), trailers, date~) {
        return None
      }
      let rest = self.queue_reply(
        stream,
        head,
        @grpc.frame(reply),
        trailers,
        outcome.journal,
        bounded~,
      )
      if rest.length() > 0 {
        Some({ rest, trailers, })
      } else {
        None
      }
    }
  }
}

///|
/// Answers `stream`, a gRPC call that the engine decided `outcome` for,
/// whose plan has the gRPC part `part`, with a status other than OK, and
/// commits the call's Journal entry just before the block that ends the
/// stream. A reply with initial metadata, header fields of its plan other
/// than smock's own, gets HEADERS with them, as a reply that succeeded
/// does, then trailers with the part's status, message and trailing
/// metadata. One without gets Trailers-Only, one HEADERS block that
/// carries all of these. A Stub's reply too large to send gets INTERNAL
/// instead (`answer_too_large`). `date` is the value of the answer's `date`
/// field.
fn H2Connection::answer_status(
  self : H2Connection,
  stream : Int32,
  outcome : @engine.Outcome,
  part : @engine.GrpcPart,
  date~ : String,
) -> Unit {
  let headers = outcome.plan.headers
  if has_initial_metadata(headers) {
    let head = reply_head(headers, date~)
    let trailers = status_trailers(part.status, part.message, part.trailers)
    if self.answer_too_large(stream, outcome, Some(head), trailers, date~) {
      return
    }
    self.head_then_trailers(stream, head, trailers, outcome.journal)
  } else {
    let fields = trailers_only(
      part.status,
      part.message,
      smock_mock_of(headers),
      date~,
      trailers=part.trailers,
    )
    if self.answer_too_large(stream, outcome, None, fields, date~) {
      return
    }
    self.headers_only(stream, fields, outcome.journal, partial=false)
  }
}

///|
/// The fixed `grpc-message` of the INTERNAL that replaces a reply too large
/// to send.
let too_large_message : String = "reply metadata too large"

///|
/// Answers `stream`, a gRPC call that the engine decided `outcome` for,
/// with Trailers-Only INTERNAL `reply metadata too large` in place of the
/// reply of the Stub that matched it, when one of the blocks the reply
/// would go out in is too large to send, and returns whether it did. The
/// blocks are `head`, its header block, and `last`, its trailers, or its
/// one Trailers-Only block when `head` is `None`. Each is counted as RFC
/// 7541, section 4.1, counts a header list, and is too large when it takes
/// more than `--header-size-limit`, or than the SETTINGS_MAX_HEADER_LIST_SIZE
/// the client advertised, which it would refuse in its framing layer. Both
/// blocks are built before anything is sent, so the swap is always
/// possible. The call's Journal entry records INTERNAL, with the reason in
/// its `templateError`, at the reply's JSON Pointer. smock's own answers,
/// such as an unmatched call's, are sent as they are.
fn H2Connection::answer_too_large(
  self : H2Connection,
  stream : Int32,
  outcome : @engine.Outcome,
  head : Array[@header.Header]?,
  last : Array[@header.Header],
  date~ : String,
) -> Bool {
  guard outcome.matched is Some(_) else { return false }
  let why = match head {
    Some(head) =>
      match self.too_large("header block", head) {
        Some(why) => Some(why)
        None => self.too_large("trailers", last)
      }
    None => self.too_large("Trailers-Only block", last)
  }
  guard why is Some(message) else { return false }
  let template_error = match outcome.journal {
    Some(entry) =>
      Some(@engine.TemplateError::{
        at: reply_at(entry.response_index),
        message,
      })
    None => None
  }
  self.answer_own(
    stream,
    outcome,
    Internal,
    too_large_message,
    date~,
    template_error?,
  )
  true
}

///|
/// Why `fields`, the block of a gRPC reply that `block` names, is too large
/// to send, or `None` when it is not: when it takes more octets, counted
/// as RFC 7541, section 4.1, counts a header list, than
/// `--header-size-limit` or than the client's SETTINGS_MAX_HEADER_LIST_SIZE.
/// The reason names the smaller of the two, and the flag when they are
/// equal.
fn H2Connection::too_large(
  self : H2Connection,
  block : String,
  fields : Array[@header.Header],
) -> String? {
  let mut size = 0
  for field in fields {
    size += field.cost()
  }
  let limit = self.header_size_limit
  match self.conn.peer_settings().max_header_list_size {
    Some(client) if client < limit && size > client =>
      Some(
        "the reply's \{block} would take \{size} bytes, over the \{client} that the client allows in its SETTINGS_MAX_HEADER_LIST_SIZE",
      )
    _ if size > limit =>
      Some(
        "the reply's \{block} would take \{size} bytes, over --header-size-limit, \{limit}",
      )
    _ => None
  }
}

///|
/// Whether `headers`, a gRPC reply's plan's, hold initial metadata: a
/// field other than `Smock-Mock`, smock's own field, which the engine adds
/// when the Default Mock answered. An error with initial metadata is sent
/// as HEADERS, then trailers; one without, as Trailers-Only.
fn has_initial_metadata(headers : Array[(String, String)]) -> Bool {
  for header in headers {
    if header.0 != "Smock-Mock" {
      return true
    }
  }
  false
}

///|
/// Sends on `stream` the HEADERS `head` of a reply without a message, then
/// the trailers `trailers`, which end the stream, and commits the Journal
/// entry `entry` just before the trailers. HEADERS or trailers the `Conn`
/// refuses get RST_STREAM INTERNAL_ERROR, the entry committed just before.
fn H2Connection::head_then_trailers(
  self : H2Connection,
  stream : Int32,
  head : Array[@header.Header],
  trailers : Array[@header.Header],
  entry : @engine.JournalEntry?,
) -> Unit {
  self.conn.headers(stream, head) catch {
    _ => {
      self.reset_after(stream, entry)
      return
    }
  }
  self.ports.commit(entry)
  self.end_with_trailers(stream, trailers)
}

///|
/// Answers `stream`, a gRPC call that the engine decided `outcome` for, with
/// smock's own Trailers-Only `status` and the fixed ASCII `message` instead
/// of the plan's answer: INTERNAL for a reply it cannot send, or
/// DEADLINE_EXCEEDED at the call's deadline. It records `status` as the
/// call's gRPC status in its Journal entry, which is then committed, with
/// `template_error`, when given, as the reason. `date` is the value of the
/// answer's `date` field.
fn H2Connection::answer_own(
  self : H2Connection,
  stream : Int32,
  outcome : @engine.Outcome,
  status : @grpc.Status,
  message : String,
  date~ : String,
  template_error? : @engine.TemplateError,
) -> Unit {
  let fields = trailers_only(
    status,
    Some(message),
    smock_mock_of(outcome.plan.headers),
    date~,
  )
  if outcome.journal is Some(entry) {
    entry.set_grpc_status(status, template_error?)
  }
  self.headers_only(stream, fields, outcome.journal, partial=false)
}

///|
/// The reply message that `body`, a plan's body, holds as JSON, read as
/// ProtoJSON and encoded with `output`, a type of `set`: an empty body is
/// an empty message. Raises `EncodeError`, at the JSON Pointer of the value
/// at fault, when the body is not a message of the type.
fn encode_reply(
  set : @protobuf.DescriptorSet,
  output : @protobuf.MessageDescriptor,
  body : @engine.Body,
) -> Bytes raise @protobuf.EncodeError {
  guard body is Bytes(json) && json.length() > 0 else { return b"" }
  let value = @json.parse(@utf8.decode(json)) catch {
    _ =>
      raise @protobuf.EncodeError(
        pointer="",
        message="the rendered reply is not JSON",
      )
  }
  set.encode_json(output, value)
}

///|
/// The JSON Pointer, within its Stub, of the `json` of the reply that the
/// Stub's pick chose (`reply_at`).
fn reply_pointer(index : Int32?) -> String {
  reply_at(index) + "/json"
}

///|
/// The JSON Pointer, within its Stub, of the reply that the Stub's pick
/// chose: its `response`, when `index` is `None`, or else that element of
/// its `responses`.
fn reply_at(index : Int32?) -> String {
  match index {
    Some(index) => "/responses/\{index}"
    None => "/response"
  }
}

///|
/// Queues on `stream` the reply whose HEADERS are `head`, whose framed
/// message is `framed` and whose trailers are `trailers`, and commits the
/// Journal entry `entry` just before the trailers, which end the stream. A
/// message that fits the windows is queued whole, in one DATA frame that
/// does not end the stream, then the trailers. One that does not fit gets
/// as much as the windows allow; the rest is returned, which the caller
/// sends in the stream's task, with the trailers after it and the entry
/// still to commit. HEADERS or trailers the `Conn` refuses get RST_STREAM
/// INTERNAL_ERROR, the entry committed just before (`reset_after`). In the
/// stream's task, `bounded` is true: the message queued now is also no
/// more than the output bound leaves for one DATA frame
/// (`H2Writer::frame_room`), as `queue` holds a body to it.
fn H2Connection::queue_reply(
  self : H2Connection,
  stream : Int32,
  head : Array[@header.Header],
  framed : Bytes,
  trailers : Array[@header.Header],
  entry : @engine.JournalEntry?,
  bounded~ : Bool = false,
) -> BytesView {
  self.conn.headers(stream, head) catch {
    _ => {
      self.reset_after(stream, entry)
      return framed[0:0]
    }
  }
  let mut room = self.room(stream)
  if bounded {
    let bound = self.writer.frame_room()
    if bound < room {
      room = bound
    }
  }
  if framed.length() > room {
    if room > 0 {
      self.conn.data(stream, framed[0:room]) catch {
        _ => return framed[0:0]
      }
    }
    return framed[room:]
  }
  // The message fits the windows, so the `Conn` takes it.
  self.conn.data(stream, framed) catch {
    _ => return framed[0:0]
  }
  self.ports.commit(entry)
  self.end_with_trailers(stream, trailers)
  framed[0:0]
}

///|
/// Ends `stream`, whose reply's message is queued, with the trailers
/// `trailers`. Trailers the `Conn` refuses get RST_STREAM INTERNAL_ERROR
/// instead. It runs where the reply is queued, so the reset leaves the
/// stream's task be.
fn H2Connection::end_with_trailers(
  self : H2Connection,
  stream : Int32,
  trailers : Array[@header.Header],
) -> Unit {
  self.conn.headers(stream, trailers, end=true) catch {
    _ => {
      self.reset(stream, @http2.error_internal_error, own_task=true)
      return
    }
  }
  self.streams.ended_by_smock(stream)
}

///|
/// Answers `stream`, a gRPC call that this layer refuses for `refusal`,
/// with Trailers-Only, the refusal's `:status`, gRPC status and fixed
/// `grpc-message`, and counts it as rejected traffic, with `mock=""` and
/// `stub=""`. It never reached the engine, so it has no Journal entry. A
/// call whose request has not `ended` then gets RST_STREAM NO_ERROR
/// (`end_early`).
fn H2Connection::refuse_call(
  self : H2Connection,
  stream : Int32,
  refusal : CallRefusal,
  ended~ : Bool,
) -> Unit {
  let fields = trailers_only(
    refusal.status(),
    Some(refusal.message()),
    None,
    date=self.ports.dates.at(self.now),
    trailers=refusal.fields(),
    http_status=refusal.http_status(),
  )
  self.conn.headers(stream, fields, end=true) catch {
    _ => {
      self.reset(stream, @http2.error_internal_error)
      return
    }
  }
  self.streams.ended_by_smock(stream)
  if !ended {
    self.end_early(stream)
  }
  self.ports.rejected(self.last_read)
}

///|
/// The HEADERS of a gRPC reply: `:status` 200, `content-type:
/// application/grpc`, then each of `headers` as `response_fields` sends a
/// header field, then `date` with the value `date`, unless `headers` give
/// one. A gRPC reply has no `content-length`.
fn reply_head(
  headers : ArrayView[(String, String)],
  date~ : String,
) -> Array[@header.Header] {
  let fields = Array(capacity=headers.length() + 3)
  fields.push(@header.Header::{ name: b":status", value: b"200", })
  fields.push({ name: b"content-type", value: grpc_content_type, })
  let mut has_date = false
  for header in headers {
    let name = lower_case(header.0)
    if is_connection_specific(name) {
      continue
    }
    if name == b"date" {
      has_date = true
    }
    fields.push({ name, value: @http1.field_octets(trimmed(header.1)), })
  }
  if !has_date {
    fields.push({ name: b"date", value: @http1.field_octets(date), })
  }
  fields
}

///|
/// The trailers of a reply that sent HEADERS: `grpc-status` with the code
/// of `status`, `grpc-message` with `message`, percent-encoded, when the
/// reply gives one, then each of `trailers`, the trailing metadata, as
/// `push_metadata` sends it.
fn status_trailers(
  status : @grpc.Status,
  message : String?,
  trailers : ReadOnlyArray[(String, String)],
) -> Array[@header.Header] {
  let fields = Array(capacity=trailers.length() + 2)
  fields.push(@header.Header::{
    name: b"grpc-status",
    value: decimal(status.code()),
  })
  if message is Some(text) {
    fields.push({ name: b"grpc-message", value: @grpc.percent_encode(text), })
  }
  let _ = push_metadata(fields, trailers)
  fields
}

///|
/// Pushes onto `fields` each of `metadata`, fields of a gRPC reply's
/// metadata or smock's own, as spec E's rules for HTTP/2 responses send a
/// header field: its name in lower case, its value trimmed of spaces and
/// tabs, and the fields HTTP/2 forbids left out. Returns whether one of
/// them is `date`.
fn push_metadata(
  fields : Array[@header.Header],
  metadata : ReadOnlyArray[(String, String)],
) -> Bool {
  let mut has_date = false
  for i in 0..<metadata.length() {
    let (name, value) = metadata[i]
    let name = lower_case(name)
    if is_connection_specific(name) {
      continue
    }
    if name == b"date" {
      has_date = true
    }
    fields.push({ name, value: @http1.field_octets(trimmed(value)), })
  }
  has_date
}

///|
/// The fields of a Trailers-Only answer, one HEADERS block that ends the
/// stream: `:status` `http_status`, by default 200, `content-type:
/// application/grpc`, `grpc-status`
/// with the code of `status`, `grpc-message` when `message` gives its text,
/// percent-encoded, then `smock-mock` when `mock` gives its value, each of
/// `trailers`, the trailing metadata or smock's own fields such as
/// `smock-near-miss`, as `push_metadata` sends it, and `date` with the
/// value `date`, unless `trailers` give one.
fn trailers_only(
  status : @grpc.Status,
  message : String?,
  mock : String?,
  date~ : String,
  trailers~ : ReadOnlyArray[(String, String)] = [],
  http_status~ : Bytes = b"200",
) -> Array[@header.Header] {
  let fields = Array(capacity=trailers.length() + 6)
  fields.push(@header.Header::{ name: b":status", value: http_status, })
  fields.push({ name: b"content-type", value: grpc_content_type, })
  fields.push({ name: b"grpc-status", value: decimal(status.code()), })
  if message is Some(text) {
    fields.push({ name: b"grpc-message", value: @grpc.percent_encode(text), })
  }
  if mock is Some(value) {
    fields.push({ name: b"smock-mock", value: @http1.field_octets(value), })
  }
  if !push_metadata(fields, trailers) {
    fields.push({ name: b"date", value: @http1.field_octets(date), })
  }
  fields
}

///|
/// The value of the `Smock-Mock` field among `headers`, a plan's, which the
/// engine adds when the Default Mock answered: smock's own field, which a
/// Trailers-Only answer carries. The plan's other fields, such as the
/// Mock's `noMatch.headers`, never reach a gRPC call.
fn smock_mock_of(headers : Array[(String, String)]) -> String? {
  for header in headers {
    if header.0 == "Smock-Mock" {
      return Some(header.1)
    }
  }
  None
}
