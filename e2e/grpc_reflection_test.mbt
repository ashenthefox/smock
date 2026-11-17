// Seam 2 tests of a Mock's built-in reflection service, gRPC's
// `grpc.reflection.v1` and `v1alpha`, over h2c and h2: every request kind
// gets its reply from the Mock's set, each file without its source info,
// a name the set lacks gets the reflection error NOT_FOUND, the health
// service is described from the descriptor smock embeds unless the set
// defines it, and each call answers one request, as soon as its message is
// whole, then RST_STREAM NO_ERROR while the client still sends. Reflection
// answers are not journaled, and count in the request metrics under their
// Mock with `stub=""`. The requests and replies are protoc-encoded fixtures
// of gRPC's reflection.proto (scripts/gen-protobuf-fixtures.sh); a reply
// that carries files is filled with protoc's sets of one file each.

///|
/// The path of reflection's one method, in version `version`, `v1` or
/// `v1alpha`.
fn reflection_path(version : String) -> String {
  "/grpc.reflection.\{version}.ServerReflection/ServerReflectionInfo"
}

///|
/// The octets of the protoc-encoded fixture `path`, under
/// fixtures/protobuf/.
async fn protobuf_fixture(path : String) -> Bytes {
  @fs.read_file("fixtures/protobuf/\{path}").binary()
}

///|
/// The octets of the protoc-encoded reflection message `name`, under
/// fixtures/protobuf/reflection/.
async fn reflection_fixture(name : String) -> Bytes {
  protobuf_fixture("reflection/\{name}.binpb")
}

///|
/// `n` as a varint, 7 bits to an octet, least significant first.
fn varint_octets(n : Int32) -> Bytes {
  let out = @buffer.Buffer()
  let mut rest = n
  while rest >= 0x80 {
    out.write_byte(((rest & 0x7f) | 0x80).to_byte())
    rest = rest >> 7
  }
  out.write_byte(rest.to_byte())
  out.to_bytes()
}

///|
/// `reply`, a reply whose last field is an empty `file_descriptor_response`,
/// its tag and a length of 0, as protoc encodes `file_descriptor_response
/// {}`, with `files` in it instead: the octets of a FileDescriptorResponse,
/// which are those of a FileDescriptorSet with the same files, in the same
/// order, as each is field 1 of its message.
fn with_files(reply : Bytes, files : Bytes) -> Bytes {
  let n = reply.length()
  guard n >= 2 && reply[n - 2] == b'\x22' && reply[n - 1] == b'\x00' else {
    abort("the reply does not end with an empty file_descriptor_response")
  }
  reply[:n - 2].to_owned() + b"\x22" + varint_octets(files.length()) + files
}

///|
/// The files that a reply about `annotated.proto` carries: the file, then
/// protobuf's descriptor.proto, which it imports, each without its source
/// info, as protoc builds a set of each alone.
async fn annotated_files() -> Bytes {
  protobuf_fixture("annotated/annotated-file.binpb") +
  protobuf_fixture("annotated/descriptor-file.binpb")
}

///|
/// The requests of `reflection_mocks`' Mock, each with the reply it gets:
/// the name of the request's fixture, or `nothing` for a message of zero
/// octets, which asks nothing, and the reply's octets.
async fn reflection_exchanges() -> Array[(String, Bytes)] {
  let annotated = annotated_files()
  let health = protobuf_fixture("health/health.binpb")
  let out = []
  for
    exchange in [
      ("list", b""),
      ("by-filename", annotated),
      ("by-symbol", annotated),
      ("by-extension", annotated),
      ("extension-numbers", b""),
      ("health-symbol", health),
      ("health-filename", health),
      ("missing-file", b""),
      ("missing-symbol", b""),
      ("missing-extension", b""),
      ("missing-type", b""),
    ] {
    let (name, files) = exchange
    let reply = reflection_fixture("\{name}-reply")
    out.push(
      (name, if files.length() > 0 { with_files(reply, files) } else { reply }),
    )
  }
  out.push(("nothing", reflection_fixture("nothing-reply")))
  out
}

///|
/// The octets of the request `name`, as `reflection_exchanges` names it.
async fn reflection_request(name : String) -> Bytes {
  if name == "nothing" {
    b""
  } else {
    reflection_fixture(name)
  }
}

///|
/// A Mock at `reflected.svc` whose set holds annotated.proto, with custom
/// options and source info, and protobuf's descriptor.proto, with
/// reflection and health on; `quiet`, with the same set and reflection off.
let reflection_mocks : String =
  #|mocks:
  #|  - name: accounts
  #|    hosts: [reflected.svc]
  #|    grpc: { descriptorSet: annotated.binpb, reflection: true, health: true }
  #|  - name: quiet
  #|    hosts: [quiet.svc]
  #|    grpc: { descriptorSet: annotated.binpb }

///|
/// Runs `f` with a definitions directory holding `files` and the bodies
/// `bodies`, each a fixture under fixtures/protobuf/ copied to its name in
/// the body-file subdirectory.
async fn with_sets(
  files : Array[(String, String)],
  bodies : Array[(String, String)],
  f : async (String) -> Unit,
) -> Unit {
  with_definitions(files, dir => {
    @fs.mkdir("\{dir}/files")
    for body in bodies {
      write_bytes(dir, "files/\{body.0}", protobuf_fixture(body.1))
    }
    f(dir)
  })
}

///|
async test "reflection: each request kind, v1 and v1alpha alike, gets one reply from the Mock's set, files without their source info and with their custom options, a name the set lacks NOT_FOUND, and none is journaled, each counted under the Mock with stub=\"\"" {
  with_sets(
    [("mocks.yaml", reflection_mocks)],
    [("annotated.binpb", "annotated/annotated.binpb")],
    dir => {
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        let client = smock.h2c()
        defer client.close()
        let out = []
        for version in ["v1", "v1alpha"] {
          for exchange in reflection_exchanges() {
            let (name, expected) = exchange
            let reply = client.call(
              reflection_path(version),
              authority="reflected.svc",
              body=framed(reflection_request(name)),
            )
            out.push(
              "\{version} \{name}: \{reply.data == [framed(expected)]}, \{reply.outline()}",
            )
          }
        }
        out.push(calls_journaled(smock))
        out.push(smock.metric("smock_requests_total"))
        out.push(smock.metric("smock_unmatched_requests_total"))
        inspect(
          out.join("\n"),
          content=(
            #|v1 list: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1 by-filename: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1 by-symbol: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1 by-extension: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1 extension-numbers: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1 health-symbol: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1 health-filename: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1 missing-file: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1 missing-symbol: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1 missing-extension: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1 missing-type: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1 nothing: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha list: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha by-filename: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha by-symbol: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha by-extension: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha extension-numbers: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha health-symbol: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha health-filename: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha missing-file: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha missing-symbol: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha missing-extension: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha missing-type: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|v1alpha nothing: true, :status: 200, grpc-status: 0, 1 DATA (end)
            #|
            #|smock_requests_total{mock="accounts",stub=""} 24
            #|
          ),
        )
      })
    },
  )
}

///|
async test "reflection: a request on a stream the client keeps open is answered once its message is whole, then RST_STREAM NO_ERROR, and a second request on that stream gets nothing; two requests in one frame get one reply" {
  with_sets(
    [("mocks.yaml", reflection_mocks)],
    [("annotated.binpb", "annotated/annotated.binpb")],
    dir => {
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        let raw = smock.raw_h2()
        defer raw.close()
        let start = @async.now()
        let list = framed(reflection_fixture("list"))
        let by_symbol = framed(reflection_fixture("by-symbol"))
        let out = [raw.acknowledge_settings()]
        // The request's message in two DATA frames: its prefix and one
        // octet, then the rest.
        raw.send([
          headers_frame(
            1,
            raw.block(call_fields(reflection_path("v1"), "reflected.svc")),
            end_stream=false,
          ),
          Data(
            stream_id=1,
            data=list[:6].to_owned(),
            end_stream=false,
            padding=0,
          ),
          Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
        ])
        out.push("v1, its message not whole yet:")
        out.push(raw.frames_until_ping_ack())
        raw.send([
          Data(
            stream_id=1,
            data=list[6:].to_owned(),
            end_stream=false,
            padding=0,
          ),
        ])
        let data : Map[Int32, Array[Bytes]] = Map([])
        let collect = (frame : @http2.Frame) => {
          if frame is Data(stream_id~, data=octets, ..) {
            match data.get(stream_id) {
              Some(list) => list.push(octets)
              None => data[stream_id] = [octets]
            }
          }
        }
        out.push("v1, its message whole:")
        out.append(
          raw.frames_until(start, frame => {
            collect(frame)
            frame is RstStream(stream_id=1, ..)
          }).shown,
        )
        // A second request on the stream, which smock has reset, and two
        // requests in one frame on a stream to v1alpha.
        raw.send([
          Data(stream_id=1, data=by_symbol, end_stream=true, padding=0),
          headers_frame(
            3,
            raw.block(call_fields(reflection_path("v1alpha"), "reflected.svc")),
            end_stream=false,
          ),
          Data(stream_id=3, data=by_symbol + list, end_stream=false, padding=0),
        ])
        out.push("a second request on stream 1, then two in one frame on 3:")
        out.append(
          raw.frames_until(start, frame => {
            collect(frame)
            frame is RstStream(stream_id=3, ..)
          }).shown,
        )
        raw.send([Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x02", ack=false)])
        out.push("nothing more:")
        out.push(raw.frames_until_ping_ack())
        out.push(
          "stream 1 got the list: \{data.get(1) == Some([framed(reflection_fixture("list-reply"))])}",
        )
        out.push(
          "stream 3 got the symbol's file: \{data.get(3) == Some([framed(with_files(reflection_fixture("by-symbol-reply"), annotated_files()))])}",
        )
        out.push(calls_journaled(smock))
        out.push(smock.metric("smock_requests_total"))
        inspect(
          out.join("\n"),
          content=(
            #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
            #|v1, its message not whole yet:
            #|SETTINGS ACK
            #|v1, its message whole:
            #|HEADERS 1 END_HEADERS [:status: 200, content-type: application/grpc, date: <now>]
            #|DATA 1 74 octets
            #|HEADERS 1 END_STREAM END_HEADERS [grpc-status: 0]
            #|RST_STREAM 1 NO_ERROR
            #|a second request on stream 1, then two in one frame on 3:
            #|HEADERS 3 END_HEADERS [:status: 200, content-type: application/grpc, date: <now>]
            #|DATA 3 14457 octets
            #|HEADERS 3 END_STREAM END_HEADERS [grpc-status: 0]
            #|RST_STREAM 3 NO_ERROR
            #|nothing more:
            #|
            #|stream 1 got the list: true
            #|stream 3 got the symbol's file: true
            #|
            #|smock_requests_total{mock="accounts",stub=""} 2
          ),
        )
      })
    },
  )
}

///|
async test "reflection: the health service is described from the descriptor smock embeds, or from the Mock's set when it defines grpc.health.v1, and a Mock without a set lists health alone" {
  let yaml =
    #|mocks:
    #|  - name: probed
    #|    hosts: [reflected.svc]
    #|    grpc: { descriptorSet: health-proto.binpb, reflection: true, health: true }
  with_sets(
    [("mocks.yaml", yaml)],
    [("health-proto.binpb", "reflection/health-proto.binpb")],
    dir => {
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        let client = smock.h2c()
        defer client.close()
        let out = []
        for
          exchange in [
            ("list", reflection_fixture("list-health-reply")),
            (
              "health-symbol",
              with_files(
                reflection_fixture("health-symbol-reply"),
                reflection_fixture("health-proto"),
              ),
            ),
            (
              "health-filename",
              reflection_fixture("health-filename-missing-reply"),
            ),
          ] {
          let (name, expected) = exchange
          let reply = client.call(
            reflection_path("v1"),
            authority="reflected.svc",
            body=framed(reflection_fixture(name)),
          )
          out.push(
            "the set's health.proto, \{name}: \{reply.data == [framed(expected)]}",
          )
        }
        inspect(
          out.join("\n"),
          content=(
            #|the set's health.proto, list: true
            #|the set's health.proto, health-symbol: true
            #|the set's health.proto, health-filename: true
          ),
        )
      })
    },
  )
  let yaml =
    #|mocks:
    #|  - name: probed
    #|    hosts: [reflected.svc]
    #|    grpc: { reflection: true, health: true }
  with_sets([("mocks.yaml", yaml)], [], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for
        exchange in [
          ("list", reflection_fixture("list-health-reply")),
          (
            "health-symbol",
            with_files(
              reflection_fixture("health-symbol-reply"),
              protobuf_fixture("health/health.binpb"),
            ),
          ),
        ] {
        let (name, expected) = exchange
        let reply = client.call(
          reflection_path("v1"),
          authority="reflected.svc",
          body=framed(reflection_fixture(name)),
        )
        out.push("no set, \{name}: \{reply.data == [framed(expected)]}")
      }
      out.push(smock.metric("smock_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|no set, list: true
          #|no set, health-symbol: true
          #|smock_requests_total{mock="probed",stub=""} 2
        ),
      )
    })
  })
}

///|
async test "reflection: a Mock that does not turn reflection on has no reflection service, and gRPC's protocol checks come first, so a request with no message, cut short, or that does not decode is refused as any call is" {
  with_sets(
    [("mocks.yaml", reflection_mocks)],
    [("annotated.binpb", "annotated/annotated.binpb")],
    dir => {
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        let client = smock.h2c()
        defer client.close()
        let out = []
        let off = client.call(
          reflection_path("v1"),
          authority="quiet.svc",
          body=framed(reflection_fixture("list")),
        )
        out.push("reflection off: \{off.outline()}")
        let list = framed(reflection_fixture("list"))
        for
          call in [
            ("no message", b""),
            ("a message cut short", list[:list.length() - 1].to_owned()),
            ("a prefix cut short", b"\x00\x00"),
            // `list_services`, field 7, a string that is not UTF-8.
            ("a string that is not UTF-8", framed(b"\x3a\x01\xff")),
            // `file_by_filename`, field 3, with wire type 7, which protobuf
            // does not define (docs/grpc/unmatched-and-refused-calls.md,
            // Protocol checks and limits). A field that comes with another
            // defined wire type than its type's is skipped instead, as
            // protobuf's parsers skip it.
            ("wire type 7", framed(b"\x1f")),
          ] {
          let (what, body) = call
          let reply = client.call(
            reflection_path("v1"),
            authority="reflected.svc",
            body~,
          )
          out.push("\{what}: \{reply.outline()}")
        }
        out.push(calls_journaled(smock))
        out.push(smock.metric("smock_requests_total"))
        out.push(smock.metric("smock_unmatched_requests_total"))
        inspect(
          out.join("\n"),
          content=(
            #|reflection off: :status: 200, grpc-status: 12, grpc-message: unknown method, 0 DATA (end)
            #|no message: :status: 200, grpc-status: 12, grpc-message: the request has no message, 0 DATA (end)
            #|a message cut short: :status: 200, grpc-status: 13, grpc-message: the request ends inside a message, 0 DATA (end)
            #|a prefix cut short: :status: 200, grpc-status: 13, grpc-message: the request ends inside a message prefix, 0 DATA (end)
            #|a string that is not UTF-8: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
            #|wire type 7: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded, 0 DATA (end)
            #|"quiet" /grpc.reflection.v1.ServerReflection/ServerReflectionInfo ""/0 200 "UNIMPLEMENTED" near miss null
            #|smock_requests_total{mock="quiet",stub=""} 1
            #|smock_requests_total{mock="",stub=""} 5
            #|smock_unmatched_requests_total{mock="quiet"} 1
          ),
        )
      })
    },
  )
}

///|
async test "reflection: the service answers over h2 on the TLS port as over h2c on the plain port" {
  with_sets(
    [("mocks.yaml", reflection_mocks)],
    [("annotated.binpb", "annotated/annotated.binpb")],
    dir => {
      with_certificates(certs => {
        let _ = with_smock(["--dir", dir, "--port", "0", ..certs.args()], smock => {
          let out = []
          let expected = framed(
            with_files(
              reflection_fixture("by-filename-reply"),
              annotated_files(),
            ),
          )
          for port in ["h2c", "h2"] {
            let client = smock.h2_on(port)
            defer client.close()
            let reply = client.call(
              reflection_path("v1"),
              authority="reflected.svc",
              body=framed(reflection_fixture("by-filename")),
            )
            out.push("\{port}: \{reply.data == [expected]}, \{reply.outline()}")
          }
          inspect(
            out.join("\n"),
            content=(
              #|h2c: true, :status: 200, grpc-status: 0, 1 DATA (end)
              #|h2: true, :status: 200, grpc-status: 0, 1 DATA (end)
            ),
          )
        })
      })
    },
  )
}
