// Delays and deadlines of gRPC calls. A gRPC Stub's delay waits before the
// reply's HEADERS, in the stream's task, as spec E's delays wait on HTTP/2
// (`H2Connection::wait`), and a call the client cancels during it ends
// there, its Journal entry as planned. A call's deadline comes from its
// `grpc-timeout` and counts from the arrival of its HEADERS
// (`check_head`); a call without one has none, nor has one whose timeout
// no delay can outlast. A delay that would end after the deadline ends at
// the deadline instead, with Trailers-Only DEADLINE_EXCEEDED `deadline
// exceeded`, which the Journal entry records, and so does a client reset
// that arrives while such a delay runs, in the last 100 ms before the
// deadline, as clients that keep deadlines reset the stream at theirs. The
// deadline is watched only while a delay runs: once the reply's HEADERS
// are out, the reply finishes as planned. The stream's task sleeps until
// the earlier of the delay's end and the deadline, so a deadline adds no
// task and no timer.

///|
/// The fixed `grpc-message` of the DEADLINE_EXCEEDED that ends a call
/// whose delay outlasts its deadline.
let deadline_message : String = "deadline exceeded"

///|
/// How long before a gRPC call's deadline a client reset counts as the
/// client's own deadline, while the call's delay runs past it: 100 ms.
/// Clients that keep deadlines, such as grpc-go, grpc-java and grpcurl's
/// `-max-time`, reset the stream with CANCEL at their own deadline, and
/// `grpc-timeout` carries the time left when the client built the HEADERS,
/// so smock's deadline trails the client's by about one transit.
let deadline_tolerance_ms : Int64 = 100

///|
/// A gRPC call whose delay runs past its deadline, while it runs.
priv struct PastDeadline {
  /// When its deadline passes, in `@async.now()` milliseconds.
  deadline : Int64
  /// Its Journal entry, still to commit.
  entry : @engine.JournalEntry?
}

///|
/// Answers `stream`, a gRPC call whose request is `request`, which the
/// engine decided `outcome` for with a delay, with `answer` in a task of
/// its own, as `wait` answers an HTTP request: once the delay is over, the
/// task sends `answer` (`send_answer`), and writes it to `out`, while the
/// connection's other streams are answered meanwhile. When the delay would
/// end after the call's deadline, the task sleeps until the deadline
/// instead, and then ends the call with Trailers-Only DEADLINE_EXCEEDED
/// `deadline exceeded`, which the call's Journal entry records before it
/// is committed. Scenario moves, Variables and data writes stand, as after
/// any delay. A deadline that has already passed, as a timeout of 0 gives,
/// ends the call at once. From the end of the sleep on, the deadline no
/// longer counts: a reply whose HEADERS are out finishes as planned.
///
/// The task ends with its stream, as `wait`'s does. While a delay runs
/// past the deadline, the call is among those `past_deadline` holds, so
/// that a client reset near the deadline ends it as DEADLINE_EXCEEDED
/// (`reset_near_deadline`); any other reset leaves its entry as planned.
/// Until the answer is queued, the entry is committed when the task ends,
/// and the call is counted then.
fn[S : @io.Writer + ReadOutput] H2Connection::wait_call(
  self : H2Connection,
  stream : Int32,
  request : H2Request,
  outcome : @engine.Outcome,
  answer : CallAnswer,
  out : WatchedStream[S],
) -> Unit {
  // The read that brought the request in full.
  let stopwatch = self.last_read
  let delay = outcome.plan.delay_ms
  let deadline = request.call_deadline
  // Whether the delay would end after the deadline, which `forever` never
  // passes.
  let cut = delay.to_int64() > deadline - self.now
  if cut {
    self.past_deadline[stream] = { deadline, entry: outcome.journal, }
  }
  self.will_wait(stream, request, outcome)
  let task = self.group.spawn(no_wait=true, () => {
    let ports = self.ports
    let mut entry = outcome.journal
    defer {
      if cut {
        self.past_deadline.remove(stream)
      }
      ports.commit(entry)
      ports.done(outcome, stopwatch)
    }
    if cut {
      // At least 0 ms, so that the task always waits once.
      let left = deadline - @async.now()
      @async.sleep(if left > 0L { left.to_int() } else { 0 })
    } else {
      @async.sleep(delay)
    }
    // What was queued before goes out first, so that the answer keeps
    // within the output bound. A reset meanwhile, once the deadline has
    // passed, ends the call as DEADLINE_EXCEEDED.
    let mut finished = self.output_written(stream, out)
    if finished {
      // From here on the answer ends the stream, and commits the entry.
      entry = None
      if cut {
        self.past_deadline.remove(stream)
      }
      let date = ports.dates.at(@async.now())
      if cut {
        self.answer_own(
          stream,
          outcome,
          DeadlineExceeded,
          deadline_message,
          date~,
        )
      } else if self.send_answer(stream, outcome, answer, date~, bounded=true)
        is Some(unsent) {
        finished = self.trickle(
          stream,
          unsent.rest,
          outcome.journal,
          out,
          end=false,
        )
        if finished {
          self.end_with_trailers(stream, unsent.trailers)
        }
      }
    }
    self.end_task(stream, out, finished~)
  })
  self.waiting[stream] = task
}

///|
/// The client has reset `stream`, whose response may wait in a task. When
/// it is a gRPC call whose delay runs past its deadline, and the reset
/// arrived at or after that deadline less `deadline_tolerance_ms`, the
/// call's Journal entry records DEADLINE_EXCEEDED, as if smock had ended
/// the call at its deadline, before the task commits it (`stop_waiting`).
/// So the entry does not depend on which comes first, the client's reset
/// or smock's deadline. Any other reset leaves the entry as planned. A
/// connection without such a call pays one test.
fn H2Connection::reset_near_deadline(
  self : H2Connection,
  stream : Int32,
) -> Unit {
  if self.past_deadline.is_empty() {
    return
  }
  if self.past_deadline.get(stream) is Some({ deadline, entry: Some(entry), }) &&
    self.read_at >= deadline - deadline_tolerance_ms {
    entry.set_grpc_status(DeadlineExceeded)
  }
}
