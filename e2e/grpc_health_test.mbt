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
