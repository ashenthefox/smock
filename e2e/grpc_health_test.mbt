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

///|
/// The Mock of the ticket's example, with the gRPC Stub `hello` on
/// `SayHello`.
let health_example_with_hello : String = health_example +
  (
    #|
    #|stubs:
    #|  - id: hello
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { json: { message: Hello Tom } }
  )

///|
async test "health: once SIGTERM starts the drain, every Check and List says NOT_SERVING, an unknown name's included, while a call already in flight finishes" {
  with_greeter_set([("greeter.yaml", health_example_with_hello)], dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--drain-timeout-ms", "10000"],
      smock => {
        let raw = smock.raw_h2()
        defer raw.close()
        let start = @async.now()
        let hello_path = "/helloworld.Greeter/SayHello"
        // A call in flight: its HEADERS have arrived, and its message has
        // not.
        raw.send([
          headers_frame(
            1,
            raw.block(call_fields(hello_path, "localhost")),
            end_stream=false,
          ),
          Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
        ])
        let out = [raw.frames_until_ping_ack()]
        smock.terminate()
        // The client does not acknowledge the drain's PING yet, so smock
        // still takes new streams.
        let warned = raw.frames_until(start, frame => {
          frame is Ping(ack=false, ..)
        })
        out.append(warned.shown)
        let calls = [
          (3, check_path, b""),
          (5, check_path, health_fixture("check-nope")),
          (7, list_path, b""),
        ]
        for call in calls {
          let (stream, path, message) = call
          raw.send([
            headers_frame(
              stream,
              raw.block(call_fields(path, "localhost")),
              end_stream=false,
            ),
            Data(
              stream_id=stream,
              data=framed(message),
              end_stream=true,
              padding=0,
            ),
          ])
        }
        let data : Map[Int32, Bytes] = {}
        let answered = raw.frames_until(start, frame => {
          match frame {
            Data(stream_id~, data=octets, ..) => data[stream_id] = octets
            _ => ()
          }
          frame is Headers(stream_id=7, end_stream=true, ..)
        })
        // smock sends the final GOAWAY a second after its PING, which
        // could come in any of these reads on a slow machine.
        out.append(answered.shown.filter(line => !line.has_prefix("GOAWAY")))
        let not_serving = framed(health_fixture("not-serving"))
        out.push(
          "Check \"\" and Check nope.Svc say NOT_SERVING: \{data.get(3) == Some(not_serving) && data.get(5) == Some(not_serving)}",
        )
        out.push(
          "List says NOT_SERVING for each: \{data.get(7) == Some(framed(health_fixture("list-greeter-not-serving")))}",
        )
        out.push(calls_journaled(smock))
        out.push(smock.metric("smock_requests_total"))
        // The call in flight sends its message, and finishes.
        raw.send([
          Data(
            stream_id=1,
            data=framed(@fs.read_file(hello_request_path).binary()),
            end_stream=true,
            padding=0,
          ),
        ])
        let finished = raw.frames_until(start, frame => {
          frame is Headers(stream_id=1, end_stream=true, ..)
        })
        out.append(finished.shown.filter(line => !line.has_prefix("GOAWAY")))
        inspect(
          out.join("\n"),
          content=(
            #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|GOAWAY last=2147483647 NO_ERROR
            #|PING
            #|HEADERS 3 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
            #|DATA 3 7 octets
            #|HEADERS 3 END_STREAM END_HEADERS [grpc-status: 0]
            #|HEADERS 5 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
            #|DATA 5 7 octets
            #|HEADERS 5 END_STREAM END_HEADERS [grpc-status: 0]
            #|HEADERS 7 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
            #|DATA 7 39 octets
            #|HEADERS 7 END_STREAM END_HEADERS [grpc-status: 0]
            #|Check "" and Check nope.Svc say NOT_SERVING: true
            #|List says NOT_SERVING for each: true
            #|
            #|smock_requests_total{mock="greeter",stub=""} 3
            #|HEADERS 1 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
            #|DATA 1 16 octets
            #|HEADERS 1 END_STREAM END_HEADERS [grpc-status: 0]
          ),
        )
      },
    )
  })
}

///|
/// Runs `f` with a definitions directory holding `files`, the set of gRPC's
/// helloworld.proto at `files/greeter.binpb`, and the set of gRPC's
/// health.proto, the one smock embeds, at `files/health.binpb`.
async fn with_health_set(
  files : Array[(String, String)],
  f : async (String) -> Unit,
) -> Unit {
  with_greeter_set(files, dir => {
    write_bytes(
      dir,
      "files/health.binpb",
      @fs.read_file("fixtures/protobuf/health/health.binpb").binary(),
    )
    f(dir)
  })
}

///|
async test "health: a gRPC Stub on a health method answers in the service's place, so a Scenario can make Check say NOT_SERVING, and so does an Ephemeral one for its Session; such calls are journaled, while List, which no Stub is on, is still the service's" {
  let yaml =
    #|mocks:
    #|  - name: probed
    #|    hosts: [probed.svc]
    #|    grpc: { descriptorSet: health.binpb, health: true }
    #|  - name: other
    #|    hosts: [other.svc]
    #|    grpc: { descriptorSet: health.binpb, health: true }
    #|stubs:
    #|  - id: down
    #|    mock: probed
    #|    scenario: { name: health, requires: down }
    #|    request: { path: /grpc.health.v1.Health/Check }
    #|    response: { json: { status: NOT_SERVING } }
    #|  - id: up
    #|    mock: probed
    #|    request: { path: /grpc.health.v1.Health/Check }
    #|    response: { json: { status: SERVING } }
  with_health_set([("mocks.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let serving = framed(health_fixture("serving"))
      let not_serving = framed(health_fixture("not-serving"))
      let shown = (reply : GrpcReply) => {
        if reply.data == [serving] {
          "SERVING"
        } else if reply.data == [not_serving] {
          "NOT_SERVING"
        } else {
          reply.render()
        }
      }
      let check = (authority : String, headers : Array[(String, String)]) => {
        shown(client.call(check_path, authority~, headers~, body=framed(b"")))
      }
      let out = []
      out.push("probed, Started: \{check("probed.svc", [])}")
      out.push(
        "Scenario set to down: \{smock.call("PUT", "/v1/mocks/probed/scenarios/health", body="{\"state\":\"down\"}")}",
      )
      out.push("probed, down: \{check("probed.svc", [])}")
      let list = client.call(
        list_path,
        authority="probed.svc",
        body=framed(b""),
      )
      out.push("probed, List: \{hex(list.data[0])}")
      let added = smock.call(
        "POST",
        "/v1/mocks/other/stubs",
        session="test-a",
        body=(
          #|{"request":{"path":"/grpc.health.v1.Health/Check"},"response":{"json":{"status":"NOT_SERVING"}}}
        ),
      )
      out.push("added for test-a: \{added.split(" ").next().unwrap_or("")}")
      out.push("other, test-a: \{check("other.svc", [baggage("test-a")])}")
      out.push("other, no Session: \{check("other.svc", [])}")
      out.push("Journal, no Session:")
      out.push(smock.calls_of())
      out.push("Journal, test-a:")
      out.push(smock.calls_of(session="test-a"))
      out.push(smock.metric("smock_requests_total"))
      out.push(smock.metric("smock_unmatched_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|probed, Started: SERVING
          #|Scenario set to down: 200 {"scenario":{"name":"health","state":"down","states":["Started","down"]},"warnings":[]}
          #|probed, down: NOT_SERVING
          #|probed, List: 00000000250a060a00120208010a1b0a15677270632e6865616c74682e76312e4865616c746812020801
          #|added for test-a: 201
          #|other, test-a: NOT_SERVING
          #|other, no Session: SERVING
          #|Journal, no Session:
          #|"up" 200 "OK"
          #|"down" 200 "OK"
          #|Journal, test-a:
          #|"eph-1" 200 "OK"
          #|smock_requests_total{mock="probed",stub="up"} 1
          #|smock_requests_total{mock="probed",stub="down"} 1
          #|smock_requests_total{mock="probed",stub=""} 1
          #|smock_requests_total{mock="other",stub="ephemeral"} 1
          #|smock_requests_total{mock="other",stub=""} 1
          #|
        ),
      )
    })
  })
}

///|
async test "health: a reply larger than the stream's window is sent as the client widens it, then its trailers, and is counted once it is sent" {
  with_greeter_set([("greeter.yaml", health_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      // A window of 8 octets for each stream the client opens.
      let client = smock.h2c(
        settings=@http2.Settings::new(initial_window_size=8),
      )
      defer client.close()
      let list = client.call(list_path, body=framed(b""))
      let whole = @buffer.Buffer()
      for octets in list.data {
        whole.write_bytes(octets)
      }
      inspect(
        [
          "DATA frames: \{list.data.length()}, each of 8 octets at most: \{list.data.iter().all(octets => octets.length() <= 8)}",
          "the framed List reply: \{whole.to_bytes() == framed(health_fixture("list-greeter"))}",
          "trailers: \{list.trailers}, \{list.ended}",
          smock.metric("smock_requests_total"),
        ].join("\n"),
        content=(
          #|DATA frames: 5, each of 8 octets at most: true
          #|the framed List reply: true
          #|trailers: Some([(grpc-status, 0)]), end
          #|smock_requests_total{mock="greeter",stub=""} 1
        ),
      )
    })
  })
}

///|
async test "health: gRPC's protocol checks come first, so a health call with no message, with two, or whose message does not decode is refused as any call is, counted as rejected traffic" {
  with_greeter_set([("greeter.yaml", health_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for
        call in [
          ("no message", b""),
          ("two messages", framed(b"") + framed(b"")),
          // `service`, field 1, a string that is not UTF-8.
          ("a string that is not UTF-8", framed(b"\x0a\x01\xff")),
        ] {
        let (what, body) = call
        let reply = client.call(check_path, body~)
        out.push(
          "\{what}: \{reply.trailers}, \{reply.head.filter(field => field.0.has_prefix("grpc-"))}",
        )
      }
      out.push(smock.metric("smock_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|no message: None, [(grpc-status, 12), (grpc-message, the request has no message)]
          #|two messages: None, [(grpc-status, 12), (grpc-message, the request has more than one message)]
          #|a string that is not UTF-8: None, [(grpc-status, 13), (grpc-message, the request message cannot be decoded)]
          #|smock_requests_total{mock="",stub=""} 3
        ),
      )
    })
  })
}
