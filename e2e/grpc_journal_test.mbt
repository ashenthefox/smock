// Seam 2 tests of gRPC calls in the Journal: each entry records the gRPC
// status the call got as `grpcStatus`, beside its HTTP status, 200 for a
// reply. Queries, verification and the unmatched list take gRPC calls by
// their Mock, `POST`, the method's path and their metadata as headers. The
// set is gRPC's helloworld.proto, and the messages are protoc-encoded
// fixtures (scripts/gen-protobuf-fixtures.sh). Every Admin API response is
// checked against the OpenAPI document (contract_test.mbt).

///|
async test "a call's entry records grpcStatus OK beside its HTTP status 200, an unmatched call's UNIMPLEMENTED, and queries, verification and the unmatched list take calls by Mock, POST, path and metadata" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: hello
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-tenant: acme } }
    #|    response: { json: { message: Hello Tom } }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let acme = [("x-tenant", "acme")]
      let call = client.call("/helloworld.Greeter/SayHello", headers=acme)
      debug_inspect(call.trailers, content="Some([(\"grpc-status\", \"0\")])")
      let by_path = "{\"mock\":\"greeter\",\"method\":\"POST\",\"path\":\"/helloworld.Greeter/SayHello\"}"
      let (_, page) = smock.journal(query="{\"filter\":\{by_path}}")
      inspect(answers(page), content="\"hello\" 200 \"OK\" x-tenant=acme")
      inspect(
        smock.call(
          "POST",
          "/v1/journal/verify",
          body="{\"filter\":\{by_path},\"exactly\":1}",
        ),
        content=(
          #|200 {"ok":true,"count":1,"evicted":0,"reason":null,"warnings":[]}
        ),
      )
      // Two calls that no Stub matches: smock answers UNIMPLEMENTED.
      for headers in [[], [("x-tenant", "other")]] {
        let reply = client.call("/helloworld.Greeter/SayHello", headers~)
        guard reply.head.contains(("grpc-status", "12")) else {
          fail("not UNIMPLEMENTED: \{reply.render()}")
        }
      }
      let (_, page) = smock.journal(query="{\"filter\":\{by_path}}")
      inspect(
        answers(page),
        content=(
          #|"hello" 200 "OK" x-tenant=acme
          #|null 200 "UNIMPLEMENTED"
          #|null 200 "UNIMPLEMENTED" x-tenant=other
        ),
      )
      // Metadata filters as headers do.
      let (_, page) = smock.journal(
        query="{\"filter\":{\"headers\":{\"x-tenant\":\"acme\"}}}",
      )
      inspect(answers(page), content="\"hello\" 200 \"OK\" x-tenant=acme")
      inspect(
        smock.call(
          "POST",
          "/v1/journal/verify",
          body="{\"filter\":\{by_path},\"exactly\":3}",
        ),
        content=(
          #|200 {"ok":true,"count":3,"evicted":0,"reason":null,"warnings":[]}
        ),
      )
      let unmatched = smock.admin("GET", "/v1/journal/unmatched")
      inspect(
        answers(unmatched.json()),
        content=(
          #|null 200 "UNIMPLEMENTED"
          #|null 200 "UNIMPLEMENTED" x-tenant=other
        ),
      )
    })
  })
}

///|
async test "smock's INTERNAL answers to calls that reached the Stubs are journaled with grpcStatus INTERNAL and the HTTP status 200: a template that fails, and a rendered reply that does not fit the output type" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: fails
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-tenant: fails } }
    #|    response: { template: true, json: { message: "${body.missing.name}" } }
    #|  - id: misfit
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-tenant: misfit } }
    #|    response: { template: true, json: { mesage: "${body.name}" } }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      for tenant in ["fails", "misfit"] {
        let reply = client.call("/helloworld.Greeter/SayHello", headers=[
          ("x-tenant", tenant),
        ])
        guard reply.head.contains(("grpc-message", "template failed")) else {
          fail("not template failed: \{reply.render()}")
        }
      }
      let (_, page) = smock.journal()
      inspect(
        answers(page),
        content=(
          #|"fails" 200 "INTERNAL" x-tenant=fails templateError={"at":"/response/json/message","message":"body.missing.name is missing"}
          #|"misfit" 200 "INTERNAL" x-tenant=misfit templateError={"at":"/response/json/mesage","message":"is not a field of helloworld.HelloReply"}
        ),
      )
    })
  })
}

///|
async test "a call's decoded body longer than --journal-body-limit is cut at it, truncated, and its size still counts the octets received" {
  with_greeter_set([("greeter.yaml", greeter_example)], dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--journal-body-limit", "5"],
      smock => {
        let client = smock.h2c()
        defer client.close()
        let _ = client.call("/helloworld.Greeter/SayHello")
        let (_, page) = smock.journal()
        guard page
          is Object(
            {
              "entries": [
                Object({ "request": Object({ "body": body, .. }), .. }),
              ],
              ..
            }
          ) else {
          fail("not one entry: \{page.stringify()}")
        }
        // HelloRequest {name: "Tom"} takes 5 octets, framed in 10.
        json_inspect(body, content={
          "encoding": "utf-8",
          "data": "{\"nam",
          "size": 10,
          "truncated": true,
        })
      },
    )
  })
}
