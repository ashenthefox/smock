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

///|
/// Reads frames until smock has ended `n` streams with HEADERS, as
/// Trailers-Only does, or ends the connection, and shows how the reading
/// ended: `open` once they have all come.
async fn RawH2::trailers_only(self : RawH2, n : Int32) -> String {
  let mut ended = 0
  let frames = self.frames_until(@async.now(), frame => {
    if frame is Headers(end_stream=true, ..) {
      ended += 1
    }
    ended == n || is_goaway(frame)
  })
  "\{ended} calls ended by smock, then \{frames.how}"
}

///|
async test "the exemption: 101 calls each reset in the last 100 ms before its deadline, while its delay runs past it, and 101 calls each reset after smock ended it with DEADLINE_EXCEEDED, leave their connections open; each one's second reset counts among the frames that do no work, and past the bound gets GOAWAY ENHANCE_YOUR_CALM" {
  with_greeter_set([("greeter.yaml", slow_second)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--http2-max-concurrent-streams", "128"],
      smock => {
        let hello = framed(@fs.read_file(hello_request_path).binary())
        let out = []
        // Each call is reset as soon as it is sent: a deadline of 50 ms is
        // within 100 ms of its HEADERS.
        let raw = smock.raw_h2()
        let calls = []
        for i in 0..<101 {
          calls.append(raw.calls(1 + 2 * i, 1, hello, timeout="50m"))
          calls.append(cancels(1 + 2 * i, 1))
        }
        raw.send(calls)
        out.push("101 calls reset before their deadlines:")
        out.push(raw.goaways())
        raw.send(cancels(1, 101))
        out.push("their second resets:")
        out.push(raw.tally_until_closed())
        raw.close()
        // Each call is reset once smock has ended it at its deadline.
        let raw = smock.raw_h2()
        raw.send(raw.calls(1, 101, hello, timeout="50m"))
        out.push("101 calls:")
        out.push(raw.trailers_only(101))
        raw.send(cancels(1, 101))
        out.push("reset after smock ended them:")
        out.push(raw.goaways())
        raw.send(cancels(1, 101))
        out.push("their second resets:")
        out.push(raw.tally_until_closed())
        raw.close()
        out.push("Journal:")
        out.push(smock.statuses(202))
        inspect(
          out.join("\n"),
          content=(
            #|101 calls reset before their deadlines:
            #|then open
            #|their second resets:
            #|GOAWAY last=201 ENHANCE_YOUR_CALM
            #|then a FIN
            #|101 calls:
            #|101 calls ended by smock, then open
            #|reset after smock ended them:
            #|then open
            #|their second resets:
            #|GOAWAY last=201 ENHANCE_YOUR_CALM
            #|then a FIN
            #|Journal:
            #|"slow" 200 "DEADLINE_EXCEEDED" x202
          ),
        )
      },
    )
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"RST_STREAM on a closed stream"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"RST_STREAM on a closed stream"}
      ),
    )
  })
}

///|
async test "other resets of gRPC calls count as spec E says: 100 calls without a timeout reset during their delays leave the connection open, and the 101st gets GOAWAY ENHANCE_YOUR_CALM; so do calls reset well before their deadlines, more than 100 ms before, though their delays run past them" {
  with_greeter_set([("greeter.yaml", slow_second)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let hello = framed(@fs.read_file(hello_request_path).binary())
      let out = []
      for timeout in [None, Some("500m")] {
        let raw = smock.raw_h2()
        let calls = []
        for i in 0..<100 {
          calls.append(raw.calls(1 + 2 * i, 1, hello, timeout?))
          calls.append(cancels(1 + 2 * i, 1))
        }
        raw.send(calls)
        let label = match timeout {
          Some(timeout) => "grpc-timeout \{timeout}"
          None => "no timeout"
        }
        out.push("100 calls with \{label}, reset at once:")
        out.push(raw.goaways())
        raw.send([..raw.calls(201, 1, hello, timeout?), ..cancels(201, 1)])
        out.push("one more:")
        out.push(raw.tally_until_closed())
        raw.close()
      }
      out.push("Journal:")
      out.push(smock.statuses(202))
      inspect(
        out.join("\n"),
        content=(
          #|100 calls with no timeout, reset at once:
          #|then open
          #|one more:
          #|GOAWAY last=201 ENHANCE_YOUR_CALM
          #|then a FIN
          #|100 calls with grpc-timeout 500m, reset at once:
          #|then open
          #|one more:
          #|GOAWAY last=201 ENHANCE_YOUR_CALM
          #|then a FIN
          #|Journal:
          #|"slow" 200 "OK" x202
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"Rapid Reset","frame":"RST_STREAM"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"Rapid Reset","frame":"RST_STREAM"}
      ),
    )
  })
}

///|
async test "smock keeps the IDs of at most --http2-max-concurrent-streams calls it ended at their deadlines, and drops the oldest first: with a limit of 2, the resets of the last two of three such calls do not count, and the reset of the first counts among the frames that do no work" {
  with_greeter_set([("greeter.yaml", slow_second)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--http2-max-concurrent-streams", "2"],
      smock => {
        let hello = framed(@fs.read_file(hello_request_path).binary())
        let out = []
        let raw = smock.raw_h2()
        defer raw.close()
        // A timeout of 0 ends each delayed call at once.
        raw.send(raw.calls(1, 2, hello, timeout="0m"))
        out.push(raw.trailers_only(2))
        raw.send(raw.calls(5, 1, hello, timeout="0m"))
        out.push(raw.trailers_only(1))
        // Once the client's SETTINGS is more than a second old, 100
        // PRIORITY frames are the most frames that do no work the bound
        // lets pass in one second: one more reset that counts passes it.
        @async.sleep(1100)
        let priorities = times(
          Priority(stream_id=101, priority={
            exclusive: false,
            stream_dependency: 0,
            weight: 16,
          }),
          100,
        )
        raw.send([..cancels(3, 2), ..priorities])
        out.push("the resets of 3 and 5, and 100 PRIORITY frames:")
        out.push(raw.goaways())
        raw.send(cancels(1, 1))
        out.push("the reset of 1:")
        out.push(raw.tally_until_closed())
        inspect(
          out.join("\n"),
          content=(
            #|2 calls ended by smock, then open
            #|1 calls ended by smock, then open
            #|the resets of 3 and 5, and 100 PRIORITY frames:
            #|then open
            #|the reset of 1:
            #|GOAWAY last=5 ENHANCE_YOUR_CALM
            #|then a FIN
          ),
        )
      },
    )
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"RST_STREAM on a closed stream"}
      ),
    )
  })
}
