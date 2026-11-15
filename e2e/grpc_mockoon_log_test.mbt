// Seam 2 tests of the mockoon log format for gRPC calls over h2c, as the
// gRPC guide's "The Journal and the metrics" says: a call that a Stub
// answers, or that no Stub matches, writes one Transaction recorded line,
// with POST, the method's path and the HTTP status 200, and no gRPC
// status; a call that a built-in service answers, and one that the
// protocol checks refuse, write none. Lines are compared whole, with only
// the value of `timestamp` masked.

///|
/// A Mock with the set of gRPC's helloworld.proto, the health service on
/// and one gRPC Stub, for the Host localhost, and a second Mock, so that a
/// call for any other Host reaches no Mock.
let mockoon_grpc_mocks : String =
  #|mocks:
  #|  - name: greeter
  #|    hosts: [localhost]
  #|    grpc: { descriptorSet: greeter.binpb, health: true }
  #|  - name: other
  #|    hosts: [other.svc]
  #|stubs:
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: hello } }
  #|    response: { json: { message: Hello Tom } }

///|
/// The gRPC status of `reply`, from its trailers or its Trailers-Only
/// HEADERS, or its `:status` when it has none.
fn GrpcReply::outcome(self : GrpcReply) -> String {
  let fields = match self.trailers {
    Some(trailers) => trailers
    None => self.head
  }
  for field in fields {
    if field.0 == "grpc-status" {
      return "grpc-status \{field.1}"
    }
  }
  for field in self.head {
    if field.0 == ":status" {
      return ":status \{field.1}"
    }
  }
  "no status"
}

///|
async test "mockoon: a gRPC call that a Stub answers, one that no Stub matches and one for a Host no Mock answers each write a Transaction recorded line with POST, the path and 200; a health answer and a refused call write none" {
  with_greeter_set([("greeter.yaml", mockoon_grpc_mocks)], dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let client = smock.h2c()
      defer client.close()
      let path = "/helloworld.Greeter/SayHello"
      let out = []
      let hello = client.call(path, headers=[("x-case", "hello")])
      out.push("matched: \{hello.outcome()}")
      let health = client.call("/grpc.health.v1.Health/Check", body=framed(b""))
      out.push("health: \{health.outcome()}")
      let refused = client.call(path, content_type="application/grpc+json")
      out.push("refused: \{refused.outcome()}")
      let unmatched = client.call(path)
      out.push("unmatched: \{unmatched.outcome()}")
      let no_mock = client.call(path, authority="nobody.svc")
      out.push("no Mock: \{no_mock.outcome()}")
      // The lines come in the order the calls ended, so a line of the
      // health answer or of the refusal would come before the last two.
      out.push(masked_lines(smock.transaction_lines(3)))
      inspect(
        out.join("\n"),
        content=(
          #|matched: grpc-status 0
          #|health: grpc-status 0
          #|refused: grpc-status 12
          #|unmatched: grpc-status 12
          #|no Mock: grpc-status 12
          #|{"app":"smock","environmentName":"greeter","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/helloworld.Greeter/SayHello","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"greeter","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/helloworld.Greeter/SayHello","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/helloworld.Greeter/SayHello","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
        ),
      )
    })
  })
}
