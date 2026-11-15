// Seam 2 tests of state over gRPC: Scenarios move on gRPC calls, gRPC Stubs
// read and write Variables and Data buckets, and weighted `responses` pick
// a reply for each call, as on HTTP. A Mock's state is one for its HTTP
// requests and its gRPC calls: what a call writes, a request of the same
// Session reads, and the other way round. The set is gRPC's
// helloworld.proto, and the messages are protoc-encoded fixtures
// (scripts/gen-protobuf-fixtures.sh); the replies are decoded here, by
// hand.

///|
/// What the client reads from a reply to SayHello: the `message` of its
/// HelloReply, decoded by hand (field 1, a string of fewer than 128
/// octets, after the 5-octet prefix), or else its `grpc-status` and its
/// `grpc-message`.
fn GrpcReply::hello(self : GrpcReply) -> String {
  let status = self.status_field("grpc-status").unwrap_or("none")
  guard self.data is [octets] &&
    octets.length() >= 7 &&
    octets[5] == b'\x0a' &&
    octets.length() == 7 + octets[6].to_int() else {
    return match self.status_field("grpc-message") {
      Some(message) => "grpc-status \{status}: \{message}"
      None => "grpc-status \{status}"
    }
  }
  "\{@utf8.decode_lossy(octets[7:])} (grpc-status \{status})"
}

///|
/// The status line and the body of `response`, an HTTP/1.1 response as
/// `Smock::send` reads it, on one line, without the body when it is empty.
fn status_and_body(response : String) -> String {
  let lines = response.split("\n").map(line => line.to_owned()).collect()
  let status = lines[0]
  guard lines.search("") is Some(blank) else { return status }
  let body = lines[blank + 1:].iter().collect().join("\n")
  if body == "" {
    status
  } else {
    "\{status} \{body}"
  }
}

///|
/// The entries of `page`, a Journal page, one per line: the Stub, the HTTP
/// status and the gRPC status, each as JSON, `-` for a member the entry
/// does not have, then each of `members` the entry gives, as JSON, unless
/// it is null or empty.
fn state_answers(page : Json, members~ : Array[String]) -> String raise {
  guard page is Object({ "entries": Array(entries), .. }) else {
    fail("not a Journal page: \{page.stringify()}")
  }
  let lines = []
  for entry in entries {
    guard entry is Object(fields) else { fail("not an entry") }
    let shown = (name : String) => {
      fields.get(name).map_or("-", value => value.stringify())
    }
    let line = StringBuilder()
    line.write_string(
      "\{shown("stub")} \{shown("status")} \{shown("grpcStatus")}",
    )
    for name in members {
      match fields.get(name) {
        Some(Null) | Some(Array([])) | None => ()
        Some(value) => line.write_string(" \{name}=\{value.stringify()}")
      }
    }
    lines.push(line.to_string())
  }
  lines.join("\n")
}

///|
async test "a create, then get Scenario over gRPC: a call moves the Scenario, a later call and an HTTP request see its state, and an HTTP request moves it back" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: get-missing
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-op: get } }
    #|    scenario: { name: greeting, requires: Started }
    #|    response: { grpc: { status: NOT_FOUND, message: no greeting yet } }
    #|  - id: create
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-op: create } }
    #|    scenario: { name: greeting, moveTo: Created }
    #|    response: { template: true, json: { message: "Created a greeting for ${body.name}" } }
    #|  - id: get
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-op: get } }
    #|    scenario: { name: greeting, requires: Created }
    #|    response: { template: true, json: { message: "Hello ${body.name}" } }
    #|  - id: status
    #|    mock: greeter
    #|    request: { method: GET, path: /greeting }
    #|    scenario: { name: greeting, requires: Created }
    #|    response: { status: 200, body: created }
    #|  - id: reset
    #|    mock: greeter
    #|    request: { method: POST, path: /greeting/reset }
    #|    scenario: { name: greeting, moveTo: Started }
    #|    response: { status: 204 }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let op = (name : String) => [("x-op", name)]
      let out = []
      let call = async fn(name : String) {
        let reply = client.call(
          "/helloworld.Greeter/SayHello",
          headers=op(name),
        )
        out.push("gRPC \{name}: \{reply.hello()}")
      }
      let send = async fn(meth : String, target : String) {
        out.push(
          "HTTP \{meth} \{target}: \{status_and_body(smock.send(meth, target))}",
        )
      }
      call("get")
      send("GET", "/greeting")
      call("create")
      call("get")
      send("GET", "/greeting")
      send("POST", "/greeting/reset")
      call("get")
      inspect(
        out.join("\n"),
        content=(
          #|gRPC get: grpc-status 5: no greeting yet
          #|HTTP GET /greeting: HTTP/1.1 404 Not Found {"error":"no Stub matched"}
          #|gRPC create: Created a greeting for Tom (grpc-status 0)
          #|gRPC get: Hello Tom (grpc-status 0)
          #|HTTP GET /greeting: HTTP/1.1 200 OK created
          #|HTTP POST /greeting/reset: HTTP/1.1 204 No Content
          #|gRPC get: grpc-status 5: no greeting yet
        ),
      )
      let (_, journal) = smock.journal()
      inspect(
        state_answers(journal, members=["scenario"]),
        content=(
          #|"get-missing" 200 "NOT_FOUND" scenario={"name":"greeting","from":"Started","to":"Started"}
          #|null 404 -
          #|"create" 200 "OK" scenario={"name":"greeting","from":"Started","to":"Created"}
          #|"get" 200 "OK" scenario={"name":"greeting","from":"Created","to":"Created"}
          #|"status" 200 - scenario={"name":"greeting","from":"Created","to":"Created"}
          #|"reset" 204 - scenario={"name":"greeting","from":"Created","to":"Started"}
          #|"get-missing" 200 "NOT_FOUND" scenario={"name":"greeting","from":"Started","to":"Started"}
        ),
      )
    })
  })
}

///|
/// The Mock `greeter`, with the set: `hello` counts the calls of a Session
/// and keeps the last caller's name in Variables, and greets with the
/// Variable `greeting`, which `PUT /greeting` sets over HTTP; `GET /vars`
/// shows the call count and the last caller.
let counting_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    variables:
  #|      calls: "${add(vars.calls ?? 0, 1)}"
  #|      last: "${body.name}"
  #|    response:
  #|      template: true
  #|      json: { message: "Hello ${body.name}, call ${vars.calls}: ${vars.greeting ?? 'no greeting'}" }
  #|  - id: set-greeting
  #|    mock: greeter
  #|    request: { method: PUT, path: /greeting }
  #|    variables: { greeting: "${body.text}" }
  #|    response: { status: 204 }
  #|  - id: vars
  #|    mock: greeter
  #|    request: { method: GET, path: /vars }
  #|    response: { status: 200, template: true, json: { calls: "${vars.calls ?? 0}", last: "${vars.last ?? null}" } }

///|
async test "gRPC Stubs write and read Variables: a call's writes are read by a later call and by an HTTP request of the same Session, a request's by a call, and another Session sees neither" {
  with_greeter_set([("greeter.yaml", counting_greeter)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let run = [baggage("run-1")]
      let out = []
      let call = async fn(
        label : String,
        body : Bytes?,
        headers : Array[(String, String)],
      ) {
        let reply = client.call("/helloworld.Greeter/SayHello", headers~, body?)
        out.push("gRPC \{label}: \{reply.hello()}")
      }
      let send = async fn(
        label : String,
        meth : String,
        target : String,
        headers : Array[(String, String)],
        body : String,
      ) {
        out.push(
          "HTTP \{label}: \{status_and_body(smock.send(meth, target, headers~, body~))}",
        )
      }
      call("Tom in run-1", None, run)
      send(
        "a greeting in run-1",
        "PUT",
        "/greeting",
        [("Content-Type", "application/json"), ..run],
        "{\"text\":\"welcome back\"}",
      )
      call("Ann in run-1", Some(hello_ann()), run)
      send("the Variables of run-1", "GET", "/vars", run, "")
      send("the Variables without a Session", "GET", "/vars", [], "")
      call("Tom without a Session", None, [])
      inspect(
        out.join("\n"),
        content=(
          #|gRPC Tom in run-1: Hello Tom, call 1: no greeting (grpc-status 0)
          #|HTTP a greeting in run-1: HTTP/1.1 204 No Content
          #|gRPC Ann in run-1: Hello Ann, call 2: welcome back (grpc-status 0)
          #|HTTP the Variables of run-1: HTTP/1.1 200 OK {"calls":2,"last":"Ann"}
          #|HTTP the Variables without a Session: HTTP/1.1 200 OK {"calls":0,"last":null}
          #|gRPC Tom without a Session: Hello Tom, call 1: no greeting (grpc-status 0)
        ),
      )
      let (_, journal) = smock.journal(session="run-1")
      inspect(
        state_answers(journal, members=["variablesWritten"]),
        content=(
          #|"hello" 200 "OK" variablesWritten=["calls","last"]
          #|"set-greeting" 204 - variablesWritten=["greeting"]
          #|"hello" 200 "OK" variablesWritten=["calls","last"]
          #|"vars" 200 -
        ),
      )
    })
  })
}

///|
/// The Mock `greeter`, with the set and the keyed Data bucket `greetings`,
/// which the CRUD Stub `greetings` serves over HTTP: `greet` appends the
/// caller to it, and `find` answers with the note of the caller's item.
let greeting_book : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|data:
  #|  - { mock: greeter, name: greetings, key: name, json: [{ name: Bob, note: from the files }] }
  #|stubs:
  #|  - id: greet
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-op: greet } }
  #|    dataWrites:
  #|      - { op: append, bucket: greetings, value: { name: "${body.name}", note: over gRPC } }
  #|    response: { template: true, json: { message: "${len(data.greetings)} greetings" } }
  #|  - id: find
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-op: find } }
  #|    response:
  #|      template: true
  #|      json: { message: "${find(data.greetings, 'name', body.name).note ?? 'no greeting'}" }
  #|  - id: greetings
  #|    mock: greeter
  #|    crud: { bucket: greetings, path: /greetings }

///|
async test "gRPC Stubs write and read Data buckets: an item a call writes is fetched over HTTP, and one an HTTP request creates is read by a call" {
  with_greeter_set([("greeter.yaml", greeting_book)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      let call = async fn(label : String, op : String, body : Bytes?) {
        let reply = client.call(
          "/helloworld.Greeter/SayHello",
          headers=[("x-op", op)],
          body?,
        )
        out.push("gRPC \{label}: \{reply.hello()}")
      }
      let send = async fn(
        label : String,
        meth : String,
        target : String,
        body : String,
      ) {
        let headers = if body == "" {
          []
        } else {
          [("Content-Type", "application/json")]
        }
        out.push(
          "HTTP \{label}: \{status_and_body(smock.send(meth, target, headers~, body~))}",
        )
      }
      call("find Tom", "find", None)
      call("greet Tom", "greet", None)
      send("get Tom", "GET", "/greetings/Tom", "")
      call("find Tom", "find", None)
      call("find Ann", "find", Some(hello_ann()))
      send(
        "create Ann", "POST", "/greetings", "{\"name\":\"Ann\",\"note\":\"over HTTP\"}",
      )
      call("find Ann", "find", Some(hello_ann()))
      send("list", "GET", "/greetings", "")
      inspect(
        out.join("\n"),
        content=(
          #|gRPC find Tom: no greeting (grpc-status 0)
          #|gRPC greet Tom: 2 greetings (grpc-status 0)
          #|HTTP get Tom: HTTP/1.1 200 OK {"name":"Tom","note":"over gRPC"}
          #|gRPC find Tom: over gRPC (grpc-status 0)
          #|gRPC find Ann: no greeting (grpc-status 0)
          #|HTTP create Ann: HTTP/1.1 201 Created {"name":"Ann","note":"over HTTP"}
          #|gRPC find Ann: over HTTP (grpc-status 0)
          #|HTTP list: HTTP/1.1 200 OK [{"name":"Bob","note":"from the files"},{"name":"Tom","note":"over gRPC"},{"name":"Ann","note":"over HTTP"}]
        ),
      )
      let (_, journal) = smock.journal()
      inspect(
        state_answers(journal, members=["dataWritten"]),
        content=(
          #|"find" 200 "OK"
          #|"greet" 200 "OK" dataWritten=["greetings"]
          #|"greetings" 200 -
          #|"find" 200 "OK"
          #|"find" 200 "OK"
          #|"greetings" 201 - dataWritten=["greetings"]
          #|"find" 200 "OK"
          #|"greetings" 200 -
        ),
      )
    })
  })
}

///|
async test "weighted responses pick a reply for each gRPC call, an error's included, and the Journal records the one picked" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: flaky
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    responses:
    #|      - { weight: 2, json: { message: Hello } }
    #|      - { weight: 1, template: true, json: { message: "Hi ${body.name}" } }
    #|      - { weight: 1, grpc: { status: UNAVAILABLE, message: try again } }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0", "--seed", "42"], smock => {
      let client = smock.h2c()
      defer client.close()
      let replies = []
      for _ in 0..<40 {
        replies.push(client.call("/helloworld.Greeter/SayHello").hello())
      }
      let (_, journal) = smock.journal(query="{\"limit\":40}")
      guard journal is Object({ "entries": Array(entries), .. }) else {
        fail("no entries: \{journal.stringify()}")
      }
      // Each reply is the response its entry records as picked.
      let picked = ["Hello", "Hi Tom", "grpc-status 14: try again"]
      let counts = [0, 0, 0]
      for i, entry in entries {
        guard entry is Object({ "responseIndex": Number(index, ..), .. }) else {
          fail("no responseIndex: \{entry.stringify()}")
        }
        let index = index.to_int()
        counts[index] += 1
        let expected = picked[index]
        guard replies[i].has_prefix(expected) else {
          fail("call \{i}: \{replies[i]}, but its entry picked \{expected}")
        }
      }
      // Each response is picked, the first about twice as often as each
      // of the others.
      inspect(
        counts.iter().all(count => count > 0) && counts[0] > counts[2],
        content="true",
      )
      inspect(entries.length(), content="40")
    })
  })
}
