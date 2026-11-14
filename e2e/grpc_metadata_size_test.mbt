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
