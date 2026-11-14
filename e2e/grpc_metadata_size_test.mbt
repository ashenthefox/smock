// Seam 2 tests of the size of a gRPC reply's metadata. Its header block and
// its trailers, or its one Trailers-Only block, each count against
// `--header-size-limit` as RFC 7541 counts a header list: each field's name
// and value plus 32 octets, smock's own fields included. A static reply
// over the limit is a load error, and `smock check`, which reads the limit
// as `smock serve` does, warns above 8 KiB. The set is gRPC's
// helloworld.proto, and the request is its protoc-encoded HelloRequest
// `{name: "Tom"}` (scripts/gen-protobuf-fixtures.sh).

///|
/// A Definition file with the Mock `greeter`, whose set is gRPC's
/// helloworld.proto, on the Host `localhost`, and the gRPC Stub `traced` on
/// SayHello, whose static reply is NOT_FOUND with an `x-trace` trailer of
/// `n` octets: a Trailers-Only block of 250 + n octets (`:status`, 42;
/// `content-type`, 60; `grpc-status`, 44; `date`, 65; `x-trace`, 39 + n).
fn traced(n : Int32) -> String {
  (
    $|mocks:
    $|  - name: greeter
    $|    hosts: [localhost]
    $|    grpc: { descriptorSet: greeter.binpb }
    $|stubs:
    $|  - id: traced
    $|    mock: greeter
    $|    request: { path: /helloworld.Greeter/SayHello }
    $|    response: { grpc: { status: NOT_FOUND, trailers: { x-trace: \{"a".repeat(n)} } } }
    $|
  )
}

///|
async test "the ticket's example: under the default --header-size-limit, a static reply whose trailers hold 20 KiB of metadata fails smock check and smock serve, and one of 9 KiB loads with a warning" {
  let out = []
  with_greeter(traced(20 * 1024), dir => {
    out.push(check([dir]))
    out.push("serve: \{serve_verdict(["--dir", dir])}")
  })
  with_greeter(traced(9 * 1024), dir => {
    out.push(check([dir]))
    out.push("serve: \{serve_verdict(["--dir", dir])}")
  })
  inspect(
    out.join("---\n"),
    content=(
      #|status 1
      #|greeter.yaml: /stubs/0/response: the reply's Trailers-Only block would take 20730 bytes, over --header-size-limit, 16384: each block of a gRPC reply's metadata counts as RFC 7541 counts a header list, each field's name and value plus 32, smock's own fields included
      #|---
      #|serve: exits with status 1---
      #|status 0
      #|greeter.yaml: /stubs/0/response: warning: the reply's Trailers-Only block would take 9466 bytes, over 8192, the size gRPC lets a client limit each block of a reply's metadata to: such a client fails the call
      #|---
      #|serve: serves
    ),
  )
}

///|
async test "smock check reads --header-size-limit and SMOCK_HEADER_SIZE_LIMIT as smock serve does, so a larger limit loads a larger static reply in both" {
  let out = []
  with_greeter(traced(20 * 1024), dir => {
    out.push(check([dir, "--header-size-limit", "32768"]))
    out.push(
      check([dir], env=Map([("SMOCK_HEADER_SIZE_LIMIT", "32768")]))
      .split("\n")
      .next()
      .unwrap_or("")
      .to_owned(),
    )
    out.push(
      "serve: \{serve_verdict(["--dir", dir, "--header-size-limit", "32768"])}",
    )
  })
  inspect(
    out.join("---\n"),
    content=(
      #|status 0
      #|greeter.yaml: /stubs/0/response: warning: the reply's Trailers-Only block would take 20730 bytes, over 8192, the size gRPC lets a client limit each block of a reply's metadata to: such a client fails the call
      #|---
      #|status 0---
      #|serve: serves
    ),
  )
}

///|
async test "an Ephemeral gRPC Stub whose static reply's metadata is over --header-size-limit gets 400 invalid_stub, and one under a larger limit is added" {
  let stub =
    $|{"request":{"path":"/helloworld.Greeter/SayHello"},"response":{"grpc":{"status":"NOT_FOUND","trailers":{"x-trace":"\{"a".repeat(20 * 1024)}"}}}}
  let mocks =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
  let out = []
  with_greeter(mocks, dir => {
    for limit in ["16384", "32768"] {
      let _ = with_smock(
        ["--dir", dir, "--port", "0", "--header-size-limit", limit],
        smock => {
          let response = smock.admin(
            "POST",
            "/v1/mocks/greeter/stubs",
            body=stub,
          )
          let shown = match response.json() {
            Object({ "error": String(error), "message": String(message), .. }) =>
              "\{error}: \{message}"
            Object({ "stub": Object({ "id": String(id), .. }), .. }) => id
            _ => response.body
          }
          out.push("--header-size-limit \{limit}: \{response.status} \{shown}")
        },
      )
    }
  })
  inspect(
    out.join("\n"),
    content=(
      #|--header-size-limit 16384: 400 invalid_stub: /response: the reply's Trailers-Only block would take 20730 bytes, over --header-size-limit, 16384: each block of a gRPC reply's metadata counts as RFC 7541 counts a header list, each field's name and value plus 32, smock's own fields included
      #|--header-size-limit 32768: 201 eph-1
    ),
  )
}

///|
/// The Stubs of the per-call tests on SayHello, told apart by `x-case`, for
/// the Mock `greeter`, on the Host `localhost` and the Default Mock: a
/// templated OK reply whose `x-trace` trailers repeat the call's `x-pad`
/// `copies` times, one whose `x-trace` header does, and a static error
/// with an `x-trace` trailer of `n` octets, a Trailers-Only block of
/// 250 + n octets, or 312 + n when the Default Mock answers, with
/// `smock-mock: greeter; via=default` (10 + 20 + 32).
fn pad_stubs(copies~ : Int32 = 1, n~ : Int32 = 2000) -> String {
  let pads = Array::make(copies, "\"${header.x-pad}\"").join(", ")
  (
    $|mocks:
    $|  - name: greeter
    $|    hosts: [localhost]
    $|    default: true
    $|    grpc: { descriptorSet: greeter.binpb }
    $|stubs:
    $|  - id: trailers
    $|    mock: greeter
    $|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: trailers } }
    $|    response:
    $|      template: true
    $|      json: { message: "Hello ${body.name}" }
    $|      grpc: { trailers: { x-trace: [\{pads}] } }
    $|  - id: headers
    $|    mock: greeter
    $|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: headers } }
    $|    response:
    $|      template: true
    $|      headers: { x-trace: [\{pads}] }
    $|      json: { message: "Hello ${body.name}" }
    $|  - id: static
    $|    mock: greeter
    $|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: static } }
    $|    response: { grpc: { status: NOT_FOUND, trailers: { x-trace: \{"a".repeat(n)} } } }
    $|
  )
}

///|
/// Makes the call of `case` on `client`, to `authority`, with an `x-pad`
/// of `pad` octets, and renders its reply as the client got it.
async fn H2Client::padded_case(
  self : H2Client,
  case : String,
  pad~ : Int32 = 0,
  authority~ : String = "localhost",
) -> String {
  let reply = self.call("/helloworld.Greeter/SayHello", authority~, headers=[
    ("x-case", case),
    ("x-pad", "p".repeat(pad)),
  ])
  "\{case}, x-pad of \{pad}:\n\{reply.render()}"
}

///|
async test "the ticket's example: a templated reply that renders 4 KiB of trailers, to a client that advertised a SETTINGS_MAX_HEADER_LIST_SIZE of 1024, gets Trailers-Only INTERNAL reply metadata too large, and templateError says why" {
  with_greeter_set([("greeter.yaml", pad_stubs())], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c(
        settings=@http2.Settings::new(max_header_list_size=Some(1024)),
      )
      defer client.close()
      let replies = [
        client.padded_case("trailers", pad=4096),
        client.padded_case("trailers", pad=3),
        client.padded_case("static"),
      ]
      inspect(
        replies.join("\n"),
        content=(
          #|trailers, x-pad of 4096:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: reply metadata too large
          #|  date: <now>
          #|(end)
          #|trailers, x-pad of 3:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  date: <now>
          #|DATA 000000000b0a0948656c6c6f20546f6d
          #|TRAILERS
          #|  grpc-status: 0
          #|  x-trace: ppp
          #|(end)
          #|static, x-pad of 0:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: reply metadata too large
          #|  date: <now>
          #|(end)
        ),
      )
      // grpc-status: 0, 11 + 1 + 32; x-trace, 7 + 4096 + 32. The static
      // reply's Trailers-Only block takes 250 + 2000.
      let (_, page) = smock.journal()
      inspect(
        answers(page),
        content=(
          #|"trailers" 200 "INTERNAL" templateError={"at":"/response","message":"the reply's trailers would take 4179 bytes, over the 1024 that the client allows in its SETTINGS_MAX_HEADER_LIST_SIZE"}
          #|"trailers" 200 "OK"
          #|"static" 200 "INTERNAL" templateError={"at":"/response","message":"the reply's Trailers-Only block would take 2250 bytes, over the 1024 that the client allows in its SETTINGS_MAX_HEADER_LIST_SIZE"}
        ),
      )
    })
  })
}

///|
/// The gRPC status of `reply` as the client reads it, from its trailers or
/// its Trailers-Only block: `grpc-status`, then `grpc-message` if any.
fn grpc_status_of(reply : GrpcReply) -> String {
  let fields = reply.trailers.unwrap_or(reply.head)
  let shown = []
  for field in fields {
    if field.0 is ("grpc-status" | "grpc-message") {
      shown.push("\{field.0}: \{field.1}")
    }
  }
  shown.join(", ")
}

///|
async test "a templated reply whose trailers or header block render over --header-size-limit gets INTERNAL, and a static reply that takes the limit exactly is served, unless smock-mock pushes it over" {
  // A static Trailers-Only block of 250 + 1798 = 2048 octets.
  let stubs = pad_stubs(copies=3, n=1798)
  with_greeter_set([("greeter.yaml", stubs)], dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--header-size-limit", "2048"],
      smock => {
        let client = smock.h2c()
        defer client.close()
        let call = (case : String, pad : Int32, authority : String) => {
          let reply = client.call("/helloworld.Greeter/SayHello", authority~, headers=[
            ("x-case", case),
            ("x-pad", "p".repeat(pad)),
          ])
          "\{case}, x-pad of \{pad}, to \{authority}: \{grpc_status_of(reply)}"
        }
        inspect(
          [
            call("trailers", 1000, "localhost"),
            call("headers", 1000, "localhost"),
            call("headers", 10, "localhost"),
            call("static", 0, "localhost"),
            call("static", 0, "other.svc"),
          ].join("\n"),
          content=(
            #|trailers, x-pad of 1000, to localhost: grpc-status: 13, grpc-message: reply metadata too large
            #|headers, x-pad of 1000, to localhost: grpc-status: 13, grpc-message: reply metadata too large
            #|headers, x-pad of 10, to localhost: grpc-status: 0
            #|static, x-pad of 0, to localhost: grpc-status: 5
            #|static, x-pad of 0, to other.svc: grpc-status: 13, grpc-message: reply metadata too large
          ),
        )
        // The trailers: grpc-status: 0, 44, and three x-trace, 7 + 1000 +
        // 32 each. The header block: :status, content-type and date, 167,
        // and the same three. Through the Default Mock, smock-mock:
        // greeter; via=default takes 10 + 20 + 32 more.
        let (_, page) = smock.journal()
        inspect(
          answers(page),
          content=(
            #|"trailers" 200 "INTERNAL" templateError={"at":"/response","message":"the reply's trailers would take 3161 bytes, over --header-size-limit, 2048"}
            #|"headers" 200 "INTERNAL" templateError={"at":"/response","message":"the reply's header block would take 3284 bytes, over --header-size-limit, 2048"}
            #|"headers" 200 "OK"
            #|"static" 200 "NOT_FOUND"
            #|"static" 200 "INTERNAL" templateError={"at":"/response","message":"the reply's Trailers-Only block would take 2110 bytes, over --header-size-limit, 2048"}
          ),
        )
      },
    )
  })
}
