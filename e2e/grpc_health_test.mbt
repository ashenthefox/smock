// Seam 2 tests of a Mock's built-in health service, gRPC's
// `grpc.health.v1.Health`, over h2c: `Check` and `List` say SERVING for
// `""` and for each service of the Mock's set, `Check` gives NOT_FOUND for
// other names, `Watch` gets UNIMPLEMENTED, and every answer says
// NOT_SERVING once SIGTERM starts the drain. A gRPC Stub on a health
// method, an Ephemeral one of the call's Session included, answers in its
// place. Health answers are not journaled, and count in the request metrics
// under their Mock with `stub=""`. The requests and replies are
// protoc-encoded fixtures of gRPC's health.proto
// (scripts/gen-protobuf-fixtures.sh).

///|
/// The path of the health service's `Check`.
let check_path : String = "/grpc.health.v1.Health/Check"

///|
/// The path of the health service's `List`.
let list_path : String = "/grpc.health.v1.Health/List"

///|
/// The path of the health service's `Watch`, which streams.
let watch_path : String = "/grpc.health.v1.Health/Watch"

///|
/// The octets of the protoc-encoded health message `name`, under
/// fixtures/protobuf/health/.
async fn health_fixture(name : String) -> Bytes {
  @fs.read_file("fixtures/protobuf/health/\{name}.binpb").binary()
}

///|
/// The Mock of the ticket's example: the only Mock, so the Default Mock,
/// with the set of gRPC's helloworld.proto and the health service on.
let health_example : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb, health: true }

///|
async test "health: a Check for \"\", sent as a message of zero octets, and one for a service of the Mock's set get SERVING, one for another name gets NOT_FOUND, and none is journaled, each counted under the Mock with stub=\"\"" {
  with_greeter_set([("greeter.yaml", health_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let empty = client.call(check_path, body=framed(b""))
      inspect(
        empty.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 00000000020801
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
        ),
      )
      let serving = framed(health_fixture("serving"))
      inspect(empty.data == [serving], content="true")
      let greeter = client.call(
        check_path,
        body=framed(health_fixture("check-greeter")),
      )
      inspect(greeter.data == [serving], content="true")
      debug_inspect(
        greeter.trailers,
        content="Some([(\"grpc-status\", \"0\")])",
      )
      inspect(
        client
        .call(check_path, body=framed(health_fixture("check-nope")))
        .render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 5
          #|  grpc-message: unknown service
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
        ),
      )
      let (_, journal) = smock.journal()
      inspect(
        journal.stringify(),
        content=(
          #|{"entries":[],"more":false,"evicted":0,"warnings":[]}
        ),
      )
      inspect(
        smock.metric("smock_requests_total") +
        "\n" +
        smock.metric("smock_unmatched_requests_total"),
        content=(
          #|smock_requests_total{mock="greeter",stub=""} 3
          #|
        ),
      )
    })
  })
}

///|
/// Three Mocks by Host: `greeter`, with the set of gRPC's helloworld.proto
/// and health on; `probed`, with health on and no set; and `quiet`, with
/// the set and health off.
let health_mocks : String =
  #|mocks:
  #|  - name: greeter
  #|    hosts: [greeter.svc]
  #|    grpc: { descriptorSet: greeter.binpb, health: true }
  #|  - name: probed
  #|    hosts: [probed.svc]
  #|    grpc: { health: true }
  #|  - name: quiet
  #|    hosts: [quiet.svc]
  #|    grpc: { descriptorSet: greeter.binpb }

///|
async test "health: List gives SERVING for \"\" and each service of the Mock's set, a Mock without a set serves health for \"\" alone, and a Mock that does not turn health on has no health service" {
  with_greeter_set([("mocks.yaml", health_mocks)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let list = client.call(
        list_path,
        authority="greeter.svc",
        body=framed(b""),
      )
      inspect(
        list.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  date: <now>
          #|DATA 00000000220a060a00120208010a180a1268656c6c6f776f726c642e4772656574657212020801
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
        ),
      )
      inspect(
        list.data == [framed(health_fixture("list-greeter"))],
        content="true",
      )
      let out = []
      for
        call in [
          ("probed.svc", list_path, b""),
          ("probed.svc", check_path, b""),
          ("probed.svc", check_path, health_fixture("check-greeter")),
          ("quiet.svc", check_path, b""),
        ] {
        let (authority, path, message) = call
        let reply = client.call(path, authority~, body=framed(message))
        out.push("\{authority} \{path}:")
        out.push(reply.render())
      }
      out.push(calls_journaled(smock))
      out.push(smock.metric("smock_requests_total"))
      out.push(smock.metric("smock_unmatched_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|probed.svc /grpc.health.v1.Health/List:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  date: <now>
          #|DATA 00000000080a060a0012020801
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|probed.svc /grpc.health.v1.Health/Check:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  date: <now>
          #|DATA 00000000020801
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|probed.svc /grpc.health.v1.Health/Check:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 5
          #|  grpc-message: unknown service
          #|  date: <now>
          #|(end)
          #|quiet.svc /grpc.health.v1.Health/Check:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 12
          #|  grpc-message: unknown method
          #|  date: <now>
          #|(end)
          #|"quiet" /grpc.health.v1.Health/Check ""/0 200 "UNIMPLEMENTED" near miss null
          #|smock_requests_total{mock="greeter",stub=""} 1
          #|smock_requests_total{mock="probed",stub=""} 3
          #|smock_requests_total{mock="quiet",stub=""} 1
          #|smock_unmatched_requests_total{mock="quiet"} 1
        ),
      )
    })
  })
}

///|
async test "health: Watch, which streams, gets UNIMPLEMENTED from its HEADERS, followed by RST_STREAM NO_ERROR while the client still sends, or alone when its HEADERS end the request, and is not journaled" {
  with_greeter_set([("mocks.yaml", health_mocks)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = [raw.acknowledge_settings()]
      raw.send([
        headers_frame(
          1,
          raw.block(call_fields(watch_path, "greeter.svc")),
          end_stream=false,
        ),
      ])
      out.push("Watch, its request still open:")
      out.push(raw.frames_until_stream_ends(1))
      out.push(raw.frames_until_stream_ends(1))
      // Sent before the client learnt of the answer, as a client does:
      // ignored.
      raw.send([
        Data(stream_id=1, data=framed(b""), end_stream=true, padding=0),
        headers_frame(3, raw.block(call_fields(watch_path, "probed.svc"))),
      ])
      out.push("Watch, its HEADERS ending the request:")
      out.push(raw.frames_until_stream_ends(3))
      out.push(calls_journaled(smock))
      out.push(smock.metric("smock_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|Watch, its request still open:
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: streaming methods are not served yet, date: <now>]
          #|RST_STREAM 1 NO_ERROR
          #|Watch, its HEADERS ending the request:
          #|HEADERS 3 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: streaming methods are not served yet, date: <now>]
          #|
          #|smock_requests_total{mock="greeter",stub=""} 1
          #|smock_requests_total{mock="probed",stub=""} 1
        ),
      )
    })
  })
}
