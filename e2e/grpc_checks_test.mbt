// Seam 2 tests of the protocol checks of gRPC calls, over h2c, sent as raw
// frames so that each answer, and the reset after it, show: a call that
// gRPC's rules refuse gets the answer a gRPC server gives, before it
// reaches the Stubs. On HEADERS, a method other than POST gets `:status`
// 405 and a malformed `grpc-timeout` 400, both with INTERNAL; a body over
// `--body-limit` gets RESOURCE_EXHAUSTED as soon as it shows; a message's
// prefix is checked as soon as it arrives, and the framing once the
// request ends. A refusal sent while the client still sends is followed by
// RST_STREAM NO_ERROR. None is journaled; each counts as rejected traffic.
// The set is gRPC's helloworld.proto, and the messages are protoc-encoded
// fixtures (scripts/gen-protobuf-fixtures.sh).

///|
/// The Mock `greeter`, the Default Mock, with the set, and the gRPC Stub
/// `hello` on SayHello, which answers any message.
let checks_example : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello Tom } }

///|
/// The fields of a gRPC call with the method `meth` to `path` at
/// `localhost`: `content-type: <content_type>`, by default
/// `application/grpc`, and `te: trailers`, unless `te` is false, then
/// `more`.
fn checked_call(
  meth : String,
  path~ : String = "/helloworld.Greeter/SayHello",
  content_type~ : String = "application/grpc",
  te~ : Bool = true,
  more~ : Array[(String, String)] = [],
) -> Array[(String, String)] {
  let fields = request_fields(meth, path, "localhost")
  fields.push(("content-type", content_type))
  if te {
    fields.push(("te", "trailers"))
  }
  fields.append(more)
  fields
}

///|
/// The Journal's entries, one per line: the target, the gRPC status and
/// the request's `grpc-timeout`, or `-` without one.
async fn checked_journaled(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "request": Object(
            { "target": String(target), "headers": Array(headers), .. }
          ),
          "grpcStatus": grpc_status,
          ..
        }
      ) else {
      fail("not a gRPC call's entry: \{entry.stringify()}")
    }
    let mut timeout = "-"
    for header in headers {
      if header
        is Object(
          { "name": String("grpc-timeout"), "value": String(value), .. }
        ) {
        timeout = value
      }
    }
    out.push("\{target} \{grpc_status.stringify()} grpc-timeout \{timeout}")
  }
  out.join("\n")
}

///|
async test "on HEADERS, a method other than POST gets :status 405 and a malformed grpc-timeout :status 400, both with INTERNAL, then RST_STREAM NO_ERROR while the client still sends; the first check that fails answers, before the Mock's; a call without te, or with a timeout of eight digits of hours or of 0, is served" {
  with_greeter_set([("greeter.yaml", checks_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = [raw.acknowledge_settings()]
      let bad_timeout = [("grpc-timeout", "1x")]
      raw.send([
        headers_frame(1, raw.block(checked_call("GET")), end_stream=false),
        headers_frame(
          3,
          raw.block(checked_call("POST", more=bad_timeout)),
          end_stream=false,
        ),
        // Nine digits, and HEADERS that end the request.
        headers_frame(
          5,
          raw.block(checked_call("POST", more=[("grpc-timeout", "123456789m")])),
        ),
        // Three checks broken: the method's answers.
        headers_frame(
          7,
          raw.block(
            checked_call(
              "PUT",
              content_type="application/grpc+json",
              more=bad_timeout,
            ),
          ),
          end_stream=false,
        ),
        // The subtype is checked before the timeout.
        headers_frame(
          9,
          raw.block(
            checked_call(
              "POST",
              content_type="application/grpc+json",
              more=bad_timeout,
            ),
          ),
          end_stream=false,
        ),
        // The timeout is checked before the method of the set.
        headers_frame(
          11,
          raw.block(
            checked_call(
              "POST",
              path="/helloworld.Greeter/SayGoodbye",
              more=bad_timeout,
            ),
          ),
          end_stream=false,
        ),
        // A CONNECT with a gRPC content type is a call too.
        headers_frame(
          13,
          raw.block([
            (":method", "CONNECT"),
            (":authority", "localhost:443"),
            ("content-type", "application/grpc"),
          ]),
          end_stream=false,
        ),
        Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
      ])
      out.push(
        "GET, a malformed timeout, nine digits, PUT with +json and a malformed timeout, +json with one, an unknown method with one, a CONNECT:",
      )
      out.push(raw.frames_until_ping_ack())
      let hello = framed(@fs.read_file(hello_request_path).binary())
      raw.send([
        // Sent before the client learnt of the answer, as a client does:
        // ignored.
        Data(stream_id=1, data=hello, end_stream=true, padding=0),
        Data(stream_id=3, data=hello, end_stream=true, padding=0),
        headers_frame(
          15,
          raw.block(checked_call("POST", te=false)),
          end_stream=false,
        ),
        Data(stream_id=15, data=hello, end_stream=true, padding=0),
      ])
      out.push("Late messages, then a call without te:")
      out.push(raw.frames_until_stream_ends(15))
      for i, timeout in ["99999999H", "0m", "00000001S", "99999999n"] {
        let stream = 17 + 2 * i
        raw.send([
          headers_frame(
            stream,
            raw.block(checked_call("POST", more=[("grpc-timeout", timeout)])),
            end_stream=false,
          ),
          Data(stream_id=stream, data=hello, end_stream=true, padding=0),
        ])
        out.push("grpc-timeout \{timeout}:")
        out.push(raw.frames_until_stream_ends(stream))
      }
      out.push("Journal:")
      out.push(checked_journaled(smock))
      out.push(smock.metric("smock_requests_total"))
      out.push(smock.metric("smock_unmatched_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|GET, a malformed timeout, nine digits, PUT with +json and a malformed timeout, +json with one, an unknown method with one, a CONNECT:
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 405, content-type: application/grpc, grpc-status: 13, grpc-message: the method must be POST, date: <now>]
          #|RST_STREAM 1 NO_ERROR
          #|HEADERS 3 END_STREAM END_HEADERS [:status: 400, content-type: application/grpc, grpc-status: 13, grpc-message: the grpc-timeout is malformed, date: <now>]
          #|RST_STREAM 3 NO_ERROR
          #|HEADERS 5 END_STREAM END_HEADERS [:status: 400, content-type: application/grpc, grpc-status: 13, grpc-message: the grpc-timeout is malformed, date: <now>]
          #|HEADERS 7 END_STREAM END_HEADERS [:status: 405, content-type: application/grpc, grpc-status: 13, grpc-message: the method must be POST, date: <now>]
          #|RST_STREAM 7 NO_ERROR
          #|HEADERS 9 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: only the proto content subtype is served, date: <now>]
          #|RST_STREAM 9 NO_ERROR
          #|HEADERS 11 END_STREAM END_HEADERS [:status: 400, content-type: application/grpc, grpc-status: 13, grpc-message: the grpc-timeout is malformed, date: <now>]
          #|RST_STREAM 11 NO_ERROR
          #|HEADERS 13 END_STREAM END_HEADERS [:status: 405, content-type: application/grpc, grpc-status: 13, grpc-message: the method must be POST, date: <now>]
          #|RST_STREAM 13 NO_ERROR
          #|Late messages, then a call without te:
          #|HEADERS 15 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
          #|DATA 15 16 octets
          #|HEADERS 15 END_STREAM END_HEADERS [grpc-status: 0]
          #|grpc-timeout 99999999H:
          #|HEADERS 17 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
          #|DATA 17 16 octets
          #|HEADERS 17 END_STREAM END_HEADERS [grpc-status: 0]
          #|grpc-timeout 0m:
          #|HEADERS 19 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
          #|DATA 19 16 octets
          #|HEADERS 19 END_STREAM END_HEADERS [grpc-status: 0]
          #|grpc-timeout 00000001S:
          #|HEADERS 21 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
          #|DATA 21 16 octets
          #|HEADERS 21 END_STREAM END_HEADERS [grpc-status: 0]
          #|grpc-timeout 99999999n:
          #|HEADERS 23 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
          #|DATA 23 16 octets
          #|HEADERS 23 END_STREAM END_HEADERS [grpc-status: 0]
          #|Journal:
          #|/helloworld.Greeter/SayHello "OK" grpc-timeout -
          #|/helloworld.Greeter/SayHello "OK" grpc-timeout 99999999H
          #|/helloworld.Greeter/SayHello "OK" grpc-timeout 0m
          #|/helloworld.Greeter/SayHello "OK" grpc-timeout 00000001S
          #|/helloworld.Greeter/SayHello "OK" grpc-timeout 99999999n
          #|smock_requests_total{mock="",stub=""} 7
          #|smock_requests_total{mock="greeter",stub="hello"} 5
          #|
        ),
      )
    })
  })
}

///|
async test "a body over --body-limit, its prefix included, gets RESOURCE_EXHAUSTED as soon as it shows, in content-length, in a prefix's length or in the octets received, then RST_STREAM NO_ERROR while the client still sends; a body at the limit is served" {
  with_greeter_set([("greeter.yaml", checks_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0", "--body-limit", "10"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = [raw.acknowledge_settings()]
      // The framed HelloRequest, 10 octets: the limit.
      let hello = framed(@fs.read_file(hello_request_path).binary())
      raw.send([
        headers_frame(
          1,
          raw.block(checked_call("POST", more=[("content-length", "11")])),
          end_stream=false,
        ),
        // A prefix that announces 6 octets, alone.
        headers_frame(3, raw.block(checked_call("POST")), end_stream=false),
        Data(
          stream_id=3,
          data=b"\x00\x00\x00\x00\x06",
          end_stream=false,
          padding=0,
        ),
        // One octet past a whole message.
        headers_frame(5, raw.block(checked_call("POST")), end_stream=false),
        Data(stream_id=5, data=hello, end_stream=false, padding=0),
        Data(stream_id=5, data=b"\x00", end_stream=false, padding=0),
        // The same, in the DATA that ends the request.
        headers_frame(7, raw.block(checked_call("POST")), end_stream=false),
        Data(stream_id=7, data=hello, end_stream=false, padding=0),
        Data(stream_id=7, data=b"\x00", end_stream=true, padding=0),
        Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
      ])
      out.push(
        "A content-length of 11, a prefix of 6 octets, one octet past a message, and that octet ending the request:",
      )
      out.push(raw.frames_until_ping_ack())
      raw.send([
        // Sent before the client learnt of the answer, as a client does:
        // ignored.
        Data(stream_id=3, data=b"\x0a\x04Anne", end_stream=true, padding=0),
        headers_frame(9, raw.block(checked_call("POST")), end_stream=false),
        Data(stream_id=9, data=hello, end_stream=true, padding=0),
      ])
      out.push("The rest of the 6 octets, then a call of 10 octets:")
      out.push(raw.frames_until_stream_ends(9))
      out.push("Journal:")
      out.push(checked_journaled(smock))
      out.push(smock.metric("smock_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|A content-length of 11, a prefix of 6 octets, one octet past a message, and that octet ending the request:
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 8, grpc-message: the request is over the body limit, date: <now>]
          #|RST_STREAM 1 NO_ERROR
          #|HEADERS 3 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 8, grpc-message: the request is over the body limit, date: <now>]
          #|RST_STREAM 3 NO_ERROR
          #|HEADERS 5 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 8, grpc-message: the request is over the body limit, date: <now>]
          #|RST_STREAM 5 NO_ERROR
          #|HEADERS 7 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 8, grpc-message: the request is over the body limit, date: <now>]
          #|The rest of the 6 octets, then a call of 10 octets:
          #|HEADERS 9 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
          #|DATA 9 16 octets
          #|HEADERS 9 END_STREAM END_HEADERS [grpc-status: 0]
          #|Journal:
          #|/helloworld.Greeter/SayHello "OK" grpc-timeout -
          #|smock_requests_total{mock="",stub=""} 4
          #|smock_requests_total{mock="greeter",stub="hello"} 1
        ),
      )
    })
  })
}

///|
/// `message` framed with the flag `flag`.
fn flagged(flag : Byte, message : Bytes) -> Bytes {
  let out = framed(message).to_array()
  out[0] = flag
  Bytes::from_array(out)
}

///|
async test "a message's prefix is checked as soon as it arrives: a flag other than 0 or 1, and 1 without a grpc-encoding other than identity, get INTERNAL; 1 with another grpc-encoding gets UNIMPLEMENTED with grpc-accept-encoding: identity and a message that names both; 0 is served whatever grpc-encoding says" {
  with_greeter_set([("greeter.yaml", checks_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = [raw.acknowledge_settings()]
      let message = @fs.read_file(hello_request_path).binary()
      let hello = framed(message)
      let encoding = (value : String) => [("grpc-encoding", value)]
      raw.send([
        // A prefix with the flag 2, alone.
        headers_frame(1, raw.block(checked_call("POST")), end_stream=false),
        Data(
          stream_id=1,
          data=b"\x02\x00\x00\x00\x05",
          end_stream=false,
          padding=0,
        ),
        headers_frame(3, raw.block(checked_call("POST")), end_stream=false),
        Data(
          stream_id=3,
          data=flagged(b'\x01', message),
          end_stream=false,
          padding=0,
        ),
        headers_frame(
          5,
          raw.block(checked_call("POST", more=encoding("identity"))),
          end_stream=false,
        ),
        Data(
          stream_id=5,
          data=flagged(b'\x01', message),
          end_stream=true,
          padding=0,
        ),
        headers_frame(
          7,
          raw.block(checked_call("POST", more=encoding("gzip"))),
          end_stream=false,
        ),
        Data(
          stream_id=7,
          data=flagged(b'\x01', message),
          end_stream=false,
          padding=0,
        ),
        headers_frame(
          9,
          raw.block(checked_call("POST", more=encoding("x%zip"))),
          end_stream=false,
        ),
        Data(
          stream_id=9,
          data=flagged(b'\x01', message),
          end_stream=true,
          padding=0,
        ),
        // A first message as it is, then a second whose flag is 2.
        headers_frame(11, raw.block(checked_call("POST")), end_stream=false),
        Data(stream_id=11, data=hello, end_stream=false, padding=0),
        Data(
          stream_id=11,
          data=flagged(b'\x02', message),
          end_stream=false,
          padding=0,
        ),
        Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
      ])
      out.push(
        "Flag 2, flag 1 without grpc-encoding, flag 1 under identity, gzip and x%zip, and flag 2 after a message:",
      )
      out.push(raw.frames_until_ping_ack())
      raw.send([
        headers_frame(
          13,
          raw.block(checked_call("POST", more=encoding("gzip"))),
          end_stream=false,
        ),
        Data(stream_id=13, data=hello, end_stream=true, padding=0),
      ])
      out.push("Flag 0 under gzip:")
      out.push(raw.frames_until_stream_ends(13))
      out.push("Journal:")
      out.push(checked_journaled(smock))
      out.push(smock.metric("smock_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|Flag 2, flag 1 without grpc-encoding, flag 1 under identity, gzip and x%zip, and flag 2 after a message:
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 13, grpc-message: a message flag is neither 0 nor 1, date: <now>]
          #|RST_STREAM 1 NO_ERROR
          #|HEADERS 3 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 13, grpc-message: a compressed message needs a grpc-encoding other than identity, date: <now>]
          #|RST_STREAM 3 NO_ERROR
          #|HEADERS 5 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 13, grpc-message: a compressed message needs a grpc-encoding other than identity, date: <now>]
          #|HEADERS 7 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: the grpc-encoding gzip is not served, only identity, grpc-accept-encoding: identity, date: <now>]
          #|RST_STREAM 7 NO_ERROR
          #|HEADERS 9 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: the grpc-encoding x%25zip is not served, only identity, grpc-accept-encoding: identity, date: <now>]
          #|HEADERS 11 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 13, grpc-message: a message flag is neither 0 nor 1, date: <now>]
          #|RST_STREAM 11 NO_ERROR
          #|Flag 0 under gzip:
          #|HEADERS 13 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
          #|DATA 13 16 octets
          #|HEADERS 13 END_STREAM END_HEADERS [grpc-status: 0]
          #|Journal:
          #|/helloworld.Greeter/SayHello "OK" grpc-timeout -
          #|smock_requests_total{mock="",stub=""} 6
          #|smock_requests_total{mock="greeter",stub="hello"} 1
        ),
      )
    })
  })
}
