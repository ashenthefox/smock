// Connection Faults on gRPC calls. A gRPC Stub's connection Faults take
// spec E's per-stream forms (http2_faults.mbt), with no `content-length`,
// and the engine decides them as for an HTTP request, with the same draws
// and seeds:
//
// - `reset`: once the call has arrived in full, RST_STREAM INTERNAL_ERROR
//   on its stream alone (`H2Connection::reset_after`). The client sees
//   INTERNAL, and the connection's other calls go on.
// - `partial`: the HEADERS of the call's answer and the first half of its
//   framed message, rounded down, then RST_STREAM INTERNAL_ERROR
//   (`H2Connection::send_partial`). An answer with no message, such as an
//   error, sends the HEADERS it would send before its trailers, without
//   ending the stream, then the reset: neither its status fields nor its
//   trailing metadata go out. The client sees INTERNAL.
// - `close`: GOAWAY NO_ERROR, then the connection closes
//   (`H2Connection::close_by_fault`). Every call in flight on the
//   connection ends with it, and the client sees UNAVAILABLE.
//
// Each runs where the answer would: in place, while the event is handled,
// when the Stub has no delay, and otherwise in the stream's task, once the
// delay is over (`wait_call`). A delay that the call's deadline cuts short
// never ends, so its Fault never comes: the call gets DEADLINE_EXCEEDED
// (grpc_deadlines.mbt). The Journal entry of a call that a reset or close
// Fault ends has no status and no gRPC status; a partial one keeps both.

///|
/// Sends on `stream`, a gRPC call that the engine decided `outcome` for
/// with a partial Fault, the first half of `answer`, the answer it would
/// otherwise get (`send_answer`), then RST_STREAM INTERNAL_ERROR, and
/// commits the call's Journal entry just before the reset. `date` is the
/// value of the answer's `date` field.
///
/// A reply sends its HEADERS and the first half of its framed message,
/// rounded down. An answer with no message sends the HEADERS it would send
/// before its trailers, with its initial metadata, if it has any, and
/// without ending the stream. smock's own INTERNAL, in place of a reply it
/// cannot send, sends HEADERS with none of the Stub's metadata, and the
/// entry records it, as `answer_own` records it. So do a Stub's HEADERS
/// that are too large to send, as `answer_too_large` counts them, with the
/// reason in the entry's `templateError`. smock's own answers, such as its
/// failures, carry nothing the Stub wrote, and their HEADERS go out as
/// they are.
///
/// A half that does not fit the windows gets as much as fits, or with
/// `bounded`, from the stream's task, as the output bound leaves for one
/// DATA frame: the rest is returned, which the caller sends from the
/// stream's task, then the reset, with the entry still to commit.
/// Otherwise it returns nothing.
fn H2Connection::send_partial(
  self : H2Connection,
  stream : Int32,
  outcome : @engine.Outcome,
  answer : CallAnswer,
  date~ : String,
  bounded~ : Bool = false,
) -> BytesView {
  let headers = outcome.plan.headers
  let entry = outcome.journal
  let mut message = None
  let mut head = match answer {
    Internal(template_error~, ..) => {
      if entry is Some(entry) {
        entry.set_grpc_status(Internal, template_error?)
      }
      own_head(headers, date~)
    }
    Reply(_, reply) => {
      message = Some(reply)
      reply_head(headers, date~)
    }
    Status(_) => reply_head(headers, date~)
  }
  if !(answer is Internal(..)) &&
    outcome.plan.grpc is Some({ own: false, .. }) &&
    self.too_large("header block", head) is Some(why) {
    if entry is Some(entry) {
      entry.set_grpc_status(Internal, template_error?=reply_error(outcome, why))
    }
    message = None
    head = own_head(headers, date~)
  }
  guard message is Some(reply) else {
    self.headers_only(stream, head, entry, partial=true)
    return b""[:]
  }
  let framed = @grpc.frame(reply)
  self.queue_reply(
    stream,
    head,
    framed[0:framed.length() / 2],
    [],
    entry,
    bounded~,
    partial=true,
  )
}

///|
/// The HEADERS of smock's own answer to a gRPC call that the engine decided
/// with the plan's `headers`, when they do not end the stream: `:status`
/// 200, `content-type: application/grpc`, `smock-mock` when the Default
/// Mock answered, and `date` with the value `date`, with none of the
/// Stub's metadata.
fn own_head(
  headers : Array[(String, String)],
  date~ : String,
) -> Array[@header.Header] {
  let fields = Array(capacity=4)
  fields.push(@header.Header::{ name: b":status", value: b"200", })
  fields.push({ name: b"content-type", value: grpc_content_type, })
  if smock_mock_of(headers) is Some(value) {
    fields.push({ name: b"smock-mock", value: @http1.field_octets(value), })
  }
  fields.push({ name: b"date", value: @http1.field_octets(date), })
  fields
}
