// Seam 2 tests of spec E's defences on gRPC calls that time out, over h2c,
// sent as raw frames with moonhttp's frame encoder. Clients that keep
// deadlines reset each timed-out call with CANCEL. Such a reset counts
// neither toward the Rapid Reset bound nor among the frames that do no
// work, once per stream: a reset that the deadline rule turns into
// DEADLINE_EXCEEDED, and a reset that lands on a stream smock ended with
// DEADLINE_EXCEEDED. Every other reset counts, as spec E's tests show for
// any HTTP/2 stream. The set is gRPC's helloworld.proto, and the request
// message a protoc-encoded fixture (scripts/gen-protobuf-fixtures.sh).

///|
/// The Mock `greeter`, the Default Mock, with the set, and the gRPC Stub
/// `slow` on SayHello, whose reply waits 1000 ms.
let slow_second : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: slow
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello Tom } }
  #|    fault: { delay: { fixed: 1000 } }

///|
/// For each of `n` streams from `first` on, a call to SayHello, with
/// `grpc-timeout: <timeout>` when given: HEADERS, then DATA that carries
/// `hello`, a framed request message, and ends the stream.
fn RawH2::calls(
  self : RawH2,
  first : Int32,
  n : Int32,
  hello : Bytes,
  timeout? : String,
) -> Array[@http2.Frame] {
  let more = match timeout {
    Some(timeout) => [("grpc-timeout", timeout)]
    None => []
  }
  let frames = []
  for i in 0..<n {
    let stream = first + 2 * i
    frames.push(
      headers_frame(
        stream,
        self.block(checked_call("POST", more~)),
        end_stream=false,
      ),
    )
    frames.push(Data(stream_id=stream, data=hello, end_stream=true, padding=0))
  }
  frames
}

///|
/// For each of `n` streams from `first` on, the client's RST_STREAM CANCEL,
/// as a client sends it at its deadline.
fn cancels(first : Int32, n : Int32) -> Array[@http2.Frame] {
  let frames = []
  for i in 0..<n {
    frames.push(
      @http2.Frame::RstStream(
        stream_id=first + 2 * i,
        error_code=@http2.error_cancel,
      ),
    )
  }
  frames
}

///|
/// Sends a PING, reads what smock sends until it acknowledges it or ends
/// the connection, and shows the GOAWAY frames among them, then how the
/// reading ended: `open` when the PING was acknowledged.
async fn RawH2::goaways(self : RawH2) -> String {
  self.send([fence])
  let frames = self.frames_until(@async.now(), frame => {
    frame is Ping(ack=true, ..)
  })
  let goaways = frames.shown.filter(frame => frame.has_prefix("GOAWAY"))
  [..goaways, "then \{frames.how}"].join("\n")
}

///|
/// Waits until the Journal holds `count` entries, for 5 s at most, and
/// shows how many have each Stub, HTTP status and gRPC status, in the order
/// each first comes.
async fn Smock::statuses(self : Smock, count : Int32) -> String {
  let start = @async.now()
  for ;; {
    let (_, journal) = self.journal(query="{\"limit\":1000}")
    guard journal is Object({ "entries": Array(entries), .. }) else {
      fail("no entries: \{journal.stringify()}")
    }
    if entries.length() >= count || @async.now() - start >= 5000 {
      let counts : Map[String, Int32] = Map([])
      for entry in entries {
        guard entry
          is Object(
            { "stub": stub, "status": status, "grpcStatus": grpc_status, .. }
          ) else {
          fail("not a gRPC call's entry: \{entry.stringify()}")
        }
        let key = "\{stub.stringify()} \{status.stringify()} \{grpc_status.stringify()}"
        counts[key] = counts.get(key).unwrap_or(0) + 1
      }
      let out = []
      for key, n in counts {
        out.push("\{key} x\{n}")
      }
      return out.join("\n")
    }
    @async.sleep(20)
  }
}

///|
async test "the ticket's example: 500 calls on one connection, each with grpc-timeout 50m to a Stub with a 1 s delay and each reset by the client at its deadline, leave the connection open; each is journaled as DEADLINE_EXCEEDED, and a later call on the connection is answered" {
  with_greeter_set([("greeter.yaml", slow_second)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let hello = framed(@fs.read_file(hello_request_path).binary())
      // Ten rounds of 50 calls, so that the calls in progress stay within
      // the concurrent-streams limit. Each round's resets go out at the
      // client's deadline, about when smock's passes: either comes first.
      for round in 0..<10 {
        let first = 1 + 100 * round
        raw.send(raw.calls(first, 50, hello, timeout="50m"))
        @async.sleep(50)
        raw.send(cancels(first, 50))
      }
      let open = raw.goaways()
      let journaled = smock.statuses(500)
      // One more call on the same connection, which the client lets run.
      raw.send(raw.calls(1001, 1, hello, timeout="50m"))
      let later = raw.frames_until_stream_ends(1001)
      inspect(
        [
          "500 calls reset at their deadlines:", open, "Journal:", journaled, "a later call:",
          later,
        ].join("\n"),
        content=(
          #|500 calls reset at their deadlines:
          #|then open
          #|Journal:
          #|"slow" 200 "DEADLINE_EXCEEDED" x500
          #|a later call:
          #|HEADERS 1001 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 4, grpc-message: deadline exceeded, smock-mock: greeter; via=default, date: <now>]
        ),
      )
    })
  })
}
