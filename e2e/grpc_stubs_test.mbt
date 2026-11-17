// Seam 2 tests of gRPC Stubs: a Stub whose exact path names a unary method
// of its Mock's Descriptor set. smock check reads and checks them, and HTTP
// requests never reach them. The set is gRPC's helloworld.proto, as
// scripts/gen-protobuf-fixtures.sh builds it.

///|
/// The Mock `greeter`, the Default Mock, whose set is `files/greeter.binpb`
/// and whose unmatched requests get 501, with the gRPC Stub `hello`, whose
/// reply is `json`, written in YAML, and the HTTP Stub `greet`.
fn greeter_stubs(json : String) -> String {
  (
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|    noMatch: { status: 501 }
    #|stubs:
    #|  - id: hello
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { json:
  ) +
  " \{json} }\n" +
  (
    #|  - id: greet
    #|    mock: greeter
    #|    request: { method: GET, path: /hello }
    #|    response: { status: 200, body: Hello }
  )
}

///|
async test "smock check passes a gRPC Stub without status, and reports an unknown field of its reply at its pointer" {
  let out = []
  for json in ["{ message: Hello Tom }", "{ mesage: Hi }"] {
    with_greeter(greeter_stubs(json), dir => out.push(check([dir])))
  }
  inspect(
    out.join("---\n"),
    content=(
      #|status 0
      #|---
      #|status 1
      #|greeter.yaml: /stubs/0/response/json/mesage: is not a field of helloworld.HelloReply
      #|
    ),
  )
}

///|
async test "an HTTP/1.1 POST to a gRPC Stub's path gets the Mock's noMatch answer, and its Near miss names an HTTP Stub, never the gRPC Stub" {
  with_greeter(greeter_stubs("{ message: Hello Tom }"), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.send(
          "POST",
          "/helloworld.Greeter/SayHello",
          headers=[("Content-Type", "application/grpc")],
          body="\u{0}\u{0}\u{0}\u{0}\u{5}\n\u{3}Tom",
        ),
        content=(
          #|HTTP/1.1 501 Not Implemented
          #|Content-Type: application/json
          #|Smock-Near-Miss: greet; failed=method,path
          #|Smock-Mock: greeter; via=default
          #|Date: <now>
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
    })
  })
}

///|
async test "smock check refuses each field that makes no sense on a gRPC Stub, and a method other than POST, each at its pointer, saying why" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: example
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, query: { page: "1" } }
    #|    response: { json: { message: Hello } }
    #|  - id: conditions
    #|    mock: greeter
    #|    request: { method: GET, path: /helloworld.Greeter/SayHello, cookies: { session: abc }, body: Tom }
    #|    response: { status: 200, body: Hello }
    #|  - id: body-kinds
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, body: { pattern: Tom } }
    #|    responses:
    #|      - { bodyFile: greeter.binpb }
    #|      - { events: [{ data: Hello }] }
    #|      - { llm: { api: openai-chat, text: Hello } }
    #|  - id: form
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, body: { form: { name: Tom } } }
    #|    response: {}
    #|  - id: xml
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, body: { xml: { /name: Tom } } }
    #|    response: {}
  with_greeter(yaml, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|greeter.yaml: /stubs/0/request/query: makes no sense on a gRPC Stub: a gRPC call's path has no query
        #|greeter.yaml: /stubs/1/request/method: must be POST on a gRPC Stub, or left out: a gRPC call is always a POST
        #|greeter.yaml: /stubs/1/request/cookies: makes no sense on a gRPC Stub: a gRPC call sends metadata, which headers conditions match, not cookies
        #|greeter.yaml: /stubs/1/request/body: an exact-text condition makes no sense on a gRPC Stub: a call's message is matched as JSON, with a json condition
        #|greeter.yaml: /stubs/1/response/status: makes no sense on a gRPC Stub: a gRPC reply's HTTP status is always 200, and grpc.status gives its gRPC status
        #|greeter.yaml: /stubs/1/response/body: makes no sense on a gRPC Stub: its reply message is json, which smock encodes with the method's output type
        #|greeter.yaml: /stubs/2/request/body/pattern: makes no sense on a gRPC Stub: a call's message is matched as JSON, with a json condition
        #|greeter.yaml: /stubs/2/responses/0/bodyFile: makes no sense on a gRPC Stub: its reply message is json, which smock encodes with the method's output type
        #|greeter.yaml: /stubs/2/responses/1/events: makes no sense on a gRPC Stub: a unary call gets one reply message, not an event stream
        #|greeter.yaml: /stubs/2/responses/2/llm: makes no sense on a gRPC Stub: an LLM reply is written in an LLM API's HTTP wire form
        #|greeter.yaml: /stubs/3/request/body/form: makes no sense on a gRPC Stub: a call's message is matched as JSON, with a json condition
        #|greeter.yaml: /stubs/4/request/body/xml: makes no sense on a gRPC Stub: a call's message is matched as JSON, with a json condition
        #|
      ),
    )
  })
}

///|
async test "llm in a gRPC Stub's response or in an element of its weighted responses is refused at its pointer on a reload, which keeps the set served, for an Ephemeral Stub with 400 invalid_stub, by smock check and at startup" {
  let llm_stubs =
    #|stubs:
    #|  - id: llm
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { llm: { api: openai-chat, text: Hello } }
    #|  - id: llm-weighted
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    responses:
    #|      - { json: { message: Hello }, weight: 9 }
    #|      - { llm: { api: anthropic-messages, text: Hello }, weight: 1 }
  let ephemeral = [
    (
      #|{"request":{"path":"/helloworld.Greeter/SayHello"},"response":{"llm":{"api":"openai-chat","text":"Hello"}}}
    ),
    (
      #|{"request":{"path":"/helloworld.Greeter/SayHello"},"responses":[{"json":{"message":"Hello"}},{"llm":{"api":"openai-responses","text":"Hello"}}]}
    ),
  ]
  with_greeter(greeter_stubs("{ message: Hello }"), dir => {
    let out = []
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let before = smock.status()
      write(dir, "llm.yaml", llm_stubs)
      let failed = smock.reloaded(before)
      out.push("a reload: \{last_reload(failed)}")
      out.push("digest kept: \{failed.get("digest") == before.get("digest")}")
      for stub in ephemeral {
        let response = smock.admin("POST", "/v1/mocks/greeter/stubs", body=stub)
        guard response.json() is Object(error) &&
          error.get("message") is Some(String(message)) else {
          fail(response.body)
        }
        out.push(
          "an Ephemeral Stub: \{response.status} \{error.get("error").map(e => e.stringify()).unwrap_or("")}\n  \{message}",
        )
      }
    })
    out.push("smock check: \{check([dir])}")
    let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
    out.push(
      "smock serve: status \{stopped.status}\n" +
      log_entries(stopped.logs.filter(line => line.contains("\"error\""))),
    )
    inspect(
      out.join("\n"),
      content=(
        #|a reload: "failed"
        #|  {"file":"llm.yaml","pointer":"/stubs/0/response/llm","message":"makes no sense on a gRPC Stub: an LLM reply is written in an LLM API's HTTP wire form"}
        #|  {"file":"llm.yaml","pointer":"/stubs/1/responses/1/llm","message":"makes no sense on a gRPC Stub: an LLM reply is written in an LLM API's HTTP wire form"}
        #|digest kept: true
        #|an Ephemeral Stub: 400 "invalid_stub"
        #|  /response/llm: makes no sense on a gRPC Stub: an LLM reply is written in an LLM API's HTTP wire form
        #|an Ephemeral Stub: 400 "invalid_stub"
        #|  /responses/1/llm: makes no sense on a gRPC Stub: an LLM reply is written in an LLM API's HTTP wire form
        #|smock check: status 1
        #|llm.yaml: /stubs/0/response/llm: makes no sense on a gRPC Stub: an LLM reply is written in an LLM API's HTTP wire form
        #|llm.yaml: /stubs/1/responses/1/llm: makes no sense on a gRPC Stub: an LLM reply is written in an LLM API's HTTP wire form
        #|
        #|smock serve: status 1
        #|{"level":"error","msg":"invalid definitions","file":"llm.yaml","pointer":"/stubs/0/response/llm","error":"makes no sense on a gRPC Stub: an LLM reply is written in an LLM API's HTTP wire form"}
        #|{"level":"error","msg":"invalid definitions","file":"llm.yaml","pointer":"/stubs/1/responses/1/llm","error":"makes no sense on a gRPC Stub: an LLM reply is written in an LLM API's HTTP wire form"}
      ),
    )
  })
}

///|
async test "smock check warns about an HTTP Stub of a Mock with a set whose path looks like a gRPC method that the set lacks, and still exits 0" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: hello
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { json: { message: Hello } }
    #|  - id: hello-typo
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHelo }
    #|    response: { json: { message: Hello } }
    #|  - id: rest
    #|    mock: greeter
    #|    request: { path: /users/1 }
    #|    response: { status: 200 }
  with_greeter(yaml, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|greeter.yaml: /stubs/1/response: needs "status"
        #|
      ),
    )
    @fs.write_file(
      "\{dir}/greeter.yaml",
      yaml.replace(
        old="path: /helloworld.Greeter/SayHelo }\n    response: { json: { message: Hello } }",
        new="path: /helloworld.Greeter/SayHelo }\n    response: { status: 200, json: { message: Hello } }",
      ),
    )
    inspect(
      check([dir]),
      content=(
        #|status 0
        #|greeter.yaml: /stubs/1/request/path: warning: the Stub "hello-typo" is an HTTP Stub that gRPC calls never reach: its path has the form of a gRPC method, /package.Service/Method, but the Mock's Descriptor set has no method helloworld.Greeter/SayHelo
        #|
      ),
    )
  })
}
