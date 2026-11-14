// Seam 2 tests of Ephemeral gRPC Stubs over h2c and the Admin API: an
// Ephemeral Stub whose exact path names a unary method of its Mock's
// Descriptor set is a gRPC Stub, checked against the set and normalised as
// a file Stub is, or refused with 400 `invalid_stub`. A call tries its
// Session's Ephemeral gRPC Stubs before the file Stubs. They are not read
// again at a reload: one whose method the new set lacks stops answering,
// and one whose reply no longer fits the output type gets INTERNAL with a
// `templateError`. The sets and messages are protoc's
// (scripts/gen-protobuf-fixtures.sh), and the expected reply is encoded by
// hand, so the codec is never checked against itself.

///|
/// The entries of the Journal of `session`, or of the no-Session space,
/// one per line, as `answers` shows them: the Stub, the HTTP status and the
/// gRPC status, then the template error, if any.
async fn Smock::calls_of(self : Smock, session? : String) -> String {
  let (_, page) = self.journal(session?)
  answers(page)
}

///|
async test "an Ephemeral gRPC Stub added through the Admin API answers the calls of its Session before the file Stubs, with its condition normalised as a file Stub's is, and never an HTTP request" {
  let yaml =
    #|mocks:
    #|  - name: users
    #|    default: true
    #|    grpc: { descriptorSet: users.binpb }
    #|stubs:
    #|  - id: found
    #|    mock: users
    #|    request: { path: /users.Users/Find }
    #|    response: { json: { id: from the files } }
  with_users_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      // A condition with a proto name and an enum number, as in the files.
      let added = smock.call(
        "POST",
        "/v1/mocks/users/stubs",
        session="test-a",
        body=(
          #|{"request":{"path":"/users.Users/Find","body":{"json":{"user_id":42,"status":1}}},"response":{"json":{"id":"from-admin"}}}
        ),
      )
      let client = smock.h2c()
      defer client.close()
      let of_test_a = client.call(
        "/users.Users/Find",
        headers=[baggage("test-a")],
        body=users_message("query"),
      )
      let without = client.call(
        "/users.Users/Find",
        body=users_message("query"),
      )
      let http = smock.send("POST", "/users.Users/Find", headers=[
        ("Content-Type", "application/grpc"),
        baggage("test-a"),
      ])
      inspect(
        [
          "added: \{added}",
          "test-a:",
          of_test_a.render(),
          "no Session: \{without.status()}",
          "HTTP/1.1 of test-a: \{http.split("\n").next().unwrap_or("")}",
          "Journal of test-a:",
          smock.calls_of(session="test-a"),
          "Journal of the no-Session space:",
          smock.calls_of(),
        ].join("\n"),
        content=(
          #|added: 201 {"stub":{"id":"eph-1","mock":"users","session":"test-a","request":{"path":"/users.Users/Find","body":{"json":{"user_id":42,"status":1}}},"response":{"json":{"id":"from-admin"}}},"warnings":[]}
          #|test-a:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: users; via=default
          #|  date: <now>
          #|DATA 000000000c0a0a66726f6d2d61646d696e
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|no Session: 0
          #|HTTP/1.1 of test-a: HTTP/1.1 404 Not Found
          #|Journal of test-a:
          #|"eph-1" 200 "OK"
          #|null 404 -
          #|Journal of the no-Session space:
          #|"found" 200 "OK"
        ),
      )
    })
  })
}

///|
async test "an Ephemeral gRPC Stub that does not fit its Mock's set gets 400 invalid_stub with the problems smock check reports for the same Stub in a Definition file" {
  let stub =
    #|{"request":{"path":"/helloworld.Greeter/SayHello","query":{"page":"1"}},"response":{"json":{"mesage":"Hi"}}}
  let file = "mocks:\n  - name: greeter\n    grpc: { descriptorSet: greeter.binpb }\nstubs:\n  - " +
    stub.replace(old="{", new="{\"id\":\"s\",\"mock\":\"greeter\",")
  let mut checked = ""
  with_greeter(file, dir => checked = check([dir]))
  with_greeter(
    (
      #|mocks:
      #|  - name: greeter
      #|    grpc: { descriptorSet: greeter.binpb }
    ),
    dir => {
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        let response = smock.admin("POST", "/v1/mocks/greeter/stubs", body=stub)
        guard response.json() is Object(error) &&
          error.get("message") is Some(String(message)) else {
          fail(response.body)
        }
        inspect(
          "\{response.status} \{error.get("error").map(e => e.stringify()).unwrap_or("")}\n\{message}\n---\nsmock check:\n\{checked}",
          content=(
            #|400 "invalid_stub"
            #|/request/query: makes no sense on a gRPC Stub: a gRPC call's path has no query
            #|/response/json/mesage: is not a field of helloworld.HelloReply
            #|---
            #|smock check:
            #|status 1
            #|greeter.yaml: /stubs/0/request/query: makes no sense on a gRPC Stub: a gRPC call's path has no query
            #|greeter.yaml: /stubs/0/response/json/mesage: is not a field of helloworld.HelloReply
            #|
          ),
        )
      })
    },
  )
}

///|
async test "an Ephemeral gRPC Stub is not read again at a reload: a reply that no longer fits the output type gets INTERNAL with its templateError, and once the set lacks its method, calls get the answer from their HEADERS" {
  with_definitions([("greeter.yaml", versioned_greeter(2))], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/greeter.binpb",
      @fs.read_file(greeter_v2_set_path).binary(),
    )
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let added = smock.call(
        "POST",
        "/v1/mocks/greeter/stubs",
        body=(
          #|{"request":{"path":"/helloworld.Greeter/SayHello"},"response":{"json":{"message":"Hi","version":2}}}
        ),
      )
      let client = smock.h2c()
      defer client.close()
      let out = [
        "added: \{added.split(" ").next().unwrap_or("")}",
        "version 2:",
        client.call("/helloworld.Greeter/SayHello").render(),
      ]
      // Version 1's HelloReply has no field version.
      smock.switch_to(dir, 1)
      out.push("version 1:")
      out.push(client.call("/helloworld.Greeter/SayHello").render())
      // A set with no SayHello: the Definition file first, which fails to
      // load until the set is there.
      let before = smock.status()
      @fs.write_file(
        "\{dir}/greeter.yaml",
        (
          #|mocks:
          #|  - name: greeter
          #|    grpc: { descriptorSet: replies.binpb }
        ),
      )
      write_bytes(
        dir,
        "files/replies.binpb",
        @fs.read_file(replies_set_path).binary(),
      )
      let _ = smock.swapped(before)
      out.push("no SayHello:")
      out.push(client.call("/helloworld.Greeter/SayHello").render())
      out.push("Journal:")
      out.push(smock.calls_of())
      out.push(
        "listed: \{smock.call("GET", "/v1/mocks/greeter/stubs").split(" ").next().unwrap_or("")}",
      )
      inspect(
        out.join("\n"),
        content=(
          #|added: 201
          #|version 2:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 00000000060a0248691002
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|version 1:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: template failed
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|no SayHello:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 12
          #|  grpc-message: unknown method
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|Journal:
          #|"eph-1" 200 "OK"
          #|"eph-1" 200 "INTERNAL" templateError={"at":"/response/json/version","message":"is not a field of helloworld.HelloReply"}
          #|null 200 "UNIMPLEMENTED"
          #|listed: 200
        ),
      )
    })
  })
}
