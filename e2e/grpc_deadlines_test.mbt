// Seam 2 tests of delays and deadlines on gRPC calls, over h2c: a gRPC
// Stub's delay waits before the reply's HEADERS, in the stream's task, as
// on HTTP/2, and a call the client cancels during it ends there. The
// deadline comes from the call's `grpc-timeout` and counts from the arrival
// of its HEADERS. A delay that outlasts it ends the call at the deadline
// with Trailers-Only DEADLINE_EXCEEDED `deadline exceeded`, which the
// Journal records, and so does a client reset that arrives in the last
// 100 ms before it. The set is gRPC's helloworld.proto, and the messages
// are protoc-encoded fixtures (scripts/gen-protobuf-fixtures.sh).

///|
/// The Mock `greeter`, the Default Mock, with the set, and the gRPC Stub
/// `slow` on SayHello, whose reply waits 3000 ms: the ticket's example.
let slow_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: slow
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello Tom } }
  #|    fault: { delay: { fixed: 3000 } }

///|
/// Starts a call to SayHello with the framed HelloRequest `{name: "Tom"}`,
/// as `H2Client::call` sends it, with `grpc-timeout: <timeout>` when given,
/// then `headers`, and returns its stream without reading the reply.
async fn H2Client::start_call(
  self : H2Client,
  timeout? : String,
  headers~ : Array[(String, String)] = [],
) -> Int32 {
  let fields = [("content-type", "application/grpc"), ("te", "trailers")]
  if timeout is Some(timeout) {
    fields.push(("grpc-timeout", timeout))
  }
  self.send(
    "POST",
    "/helloworld.Greeter/SayHello",
    authority="localhost",
    headers=[..fields, ..headers],
    body=framed(@fs.read_file(hello_request_path).binary()),
  )
}

///|
async test "the ticket's example: a Stub with a delay of 3000 ms answers a call with grpc-timeout 5S after 3 s, and a call with grpc-timeout 1S gets Trailers-Only DEADLINE_EXCEEDED about 1 s after its HEADERS, journaled with status 200 and grpcStatus DEADLINE_EXCEEDED" {
  with_greeter_set([("greeter.yaml", slow_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let start = @async.now()
      let five = client.start_call(timeout="5S")
      let one = client.start_call(timeout="1S")
      let cut = client.reply(one)
      let cut_ms = @async.now() - start
      let served = client.reply(five)
      let served_ms = @async.now() - start
      let (_, page) = smock.journal()
      inspect(
        [
          "grpc-timeout 1S:",
          cut.render(),
          "after 1 s, before the delay is over: \{cut_ms >= 1000 && cut_ms < 3000}",
          "grpc-timeout 5S:",
          served.render(),
          "after 3 s: \{served_ms >= 3000}",
          "Journal:",
          answers(page),
        ].join("\n"),
        content=(
          #|grpc-timeout 1S:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 4
          #|  grpc-message: deadline exceeded
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|after 1 s, before the delay is over: true
          #|grpc-timeout 5S:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 000000000b0a0948656c6c6f20546f6d
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|after 3 s: true
          #|Journal:
          #|"slow" 200 "DEADLINE_EXCEEDED"
          #|"slow" 200 "OK"
        ),
      )
    })
  })
}
