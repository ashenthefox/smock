// Seam 1 tests of Ephemeral gRPC Stubs: an Ephemeral Stub whose exact path
// names a unary method of its Mock's Descriptor set is a gRPC Stub, checked
// and normalised against the set as a file Stub is. A gRPC call tries its
// Session's Ephemeral gRPC Stubs on its method first, then the file gRPC
// Stubs, and an HTTP request never tries them. They are not read again at
// a reload: one whose method the new set no longer has as a unary method
// stops answering. The sets are gRPC's helloworld.proto and catalog.proto
// (greeter_set_test.mbt).

///|
/// The body files of these tests: the sets of helloworld.proto and
/// catalog.proto.
fn ephemeral_body_files() -> Array[(String, Bytes)] raise {
  [
    ..greeter_body_files(),
    ("catalog.binpb", @hex.decode(catalog_set.replace_all(old="\n", new=""))),
  ]
}

///|
/// The Mock `greeter`, the Default Mock, whose set is `set`, with the file
/// gRPC Stub `hello`, which answers a call for Tom, and the Mock `catalog`,
/// for the Host `catalog.svc`, whose set is catalog.proto.
fn greeter_with_set(set : String) -> Array[(String, String)] {
  let stubs = if set == "greeter.binpb" {
    (
      #|stubs:
      #|  - id: hello
      #|    mock: greeter
      #|    request: { path: /helloworld.Greeter/SayHello, body: { json: { name: Tom } } }
      #|    response: { json: { message: Hello from the files } }
    )
  } else {
    ""
  }
  [
    (
      "mocks.yaml",
      (
        $|mocks:
        $|  - name: greeter
        $|    default: true
        $|    grpc: { descriptorSet: \{set} }
        $|  - name: catalog
        $|    hosts: [catalog.svc]
        $|    grpc: { descriptorSet: catalog.binpb }
        $|
      ) +
      stubs,
    ),
  ]
}

///|
/// What answered `outcome`: the Stub, from a file or Ephemeral, or none,
/// then the plan's gRPC part on the same line, or its HTTP status for a
/// plan without one.
fn answered_call(outcome : @engine.Outcome) -> String {
  let stub = match outcome.matched {
    Some(FromFile(id)) => "file \{id}"
    Some(Ephemeral(id)) => "ephemeral \{id}"
    None => "none"
  }
  let part = match outcome.plan.grpc {
    Some(_) => grpc_part(outcome).replace_all(old="\n", new="; ")
    None => "HTTP \{outcome.plan.status}"
  }
  "\{stub}: \{part}"
}

///|
/// A call to SayHello for `name`, decoded as `{"name":<name>}`, with
/// `session` when it is given.
fn Harness::say_hello(
  self : Harness,
  name : String,
  session? : String,
) -> @engine.Outcome {
  let path = "/helloworld.Greeter/SayHello"
  self.engine.handle(
    {
      meth: "POST",
      target: path,
      version: "HTTP/2",
      headers: [("content-type", "application/grpc")],
      body: @utf8.encode("{\"name\":\"\{name}\"}"),
    },
    grpc={ path, octets: 2 + name.length(), },
    session~,
    now=self.now,
    rand=self.rand,
  )
}

///|
test "an Ephemeral Stub on a unary method of its Mock's set is a gRPC Stub: a call of its Session tries it before the file Stubs, and its Near miss counts it" {
  let h = harness(
    greeter_with_set("greeter.binpb"),
    body_files=ephemeral_body_files(),
  )
  inspect(
    h.add(
      "greeter",
      None,
      (
        #|{ "request": { "path": "/helloworld.Greeter/SayHello", "body": { "json": { "name": "Ann" } } },
        #|  "response": { "json": { "message": "Hello Ann" } } }
      ),
    ),
    content="eph-1",
  )
  inspect(
    h.add(
      "greeter",
      Some("test-a"),
      (
        #|{ "request": { "path": "/helloworld.Greeter/SayHello" },
        #|  "response": { "grpc": { "status": "NOT_FOUND" } } }
      ),
    ),
    content="eph-2",
  )
  let lines = [
    "Ann: \{answered_call(h.say_hello("Ann"))}",
    "Tom: \{answered_call(h.say_hello("Tom"))}",
    "Bob: \{answered_call(h.say_hello("Bob"))}",
    "Tom of test-a: \{answered_call(h.say_hello("Tom", session="test-a"))}",
    "Ann of test-b: \{answered_call(h.say_hello("Ann", session="test-b"))}",
  ]
  inspect(
    lines.join("\n"),
    content=(
      #|Ann: ephemeral eph-1: OK
      #|Tom: file hello: OK
      #|Bob: none: UNIMPLEMENTED; grpc-message: no Stub matched; smock-near-miss: eph-1; failed=body
      #|Tom of test-a: ephemeral eph-2: NOT_FOUND
      #|Ann of test-b: none: UNIMPLEMENTED; grpc-message: no Stub matched; smock-near-miss: hello; failed=body
    ),
  )
}

///|
test "an HTTP request never tries an Ephemeral gRPC Stub, nor counts it for its Near miss, and a gRPC call never tries an Ephemeral HTTP Stub" {
  let h = harness(
    greeter_with_set("greeter.binpb"),
    body_files=ephemeral_body_files(),
  )
  let grpc_stub = h.add(
    "greeter",
    None,
    (
      #|{ "request": { "path": "/helloworld.Greeter/SayHello" },
      #|  "response": { "json": { "message": "Hello over gRPC" } } }
    ),
  )
  let http_stub = h.add(
    "greeter",
    None,
    (
      #|{ "request": { "method": "POST", "path": { "pattern": "/helloworld[.]Greeter/.*" },
      #|               "headers": { "x-route": "http" } },
      #|  "response": { "status": 200, "body": "Hello over HTTP" } }
    ),
  )
  let http = h.send(
    "POST",
    "/helloworld.Greeter/SayHello",
    body="{\"name\":\"Ann\"}",
  )
  let near_miss = match http.near_miss {
    Some(near_miss) => near_miss.stub
    None => "none"
  }
  let routed = h.send("POST", "/helloworld.Greeter/SayHello", headers=[
    ("x-route", "http"),
  ])
  let path = "/helloworld.Greeter/SayHello"
  let call = h.engine.handle(
    {
      meth: "POST",
      target: path,
      version: "HTTP/2",
      headers: [("x-route", "http")],
      body: b"{\"name\":\"Ann\"}",
    },
    grpc={ path, octets: 5, },
    session=None,
    now=h.now,
    rand=h.rand,
  )
  inspect(
    [
      "added \{grpc_stub} and \{http_stub}",
      "HTTP: \{answered_call(http)}, Near miss \{near_miss}",
      "HTTP with x-route: \{answered_call(routed)}",
      "gRPC with x-route: \{answered_call(call)}",
    ].join("\n"),
    content=(
      #|added eph-1 and eph-2
      #|HTTP: none: HTTP 404, Near miss eph-2
      #|HTTP with x-route: ephemeral eph-2: HTTP 200
      #|gRPC with x-route: ephemeral eph-1: OK
    ),
  )
}

///|
test "an Ephemeral gRPC Stub is checked against its Mock's set as a file Stub is: refused with every problem at its pointer, or its condition normalised" {
  let h = harness(
    greeter_with_set("greeter.binpb"),
    body_files=ephemeral_body_files(),
  )
  let stub = @json.parse(
    (
      #|{ "request": { "method": "GET", "path": "/helloworld.Greeter/SayHello", "query": { "page": "1" } },
      #|  "response": { "status": 200, "json": { "mesage": "Hi" } } }
    ),
  )
  let refused = try
    h.engine.add_ephemeral_stub(mock="greeter", session=None, stub)
  catch {
    InvalidStub(problems) => problems.map(p => p.to_string()).join("\n")
    error => @debug.to_string(error)
  } noraise {
    added => "added \{added.id}"
  }
  inspect(
    refused,
    content=(
      #|/request/method: must be POST on a gRPC Stub, or left out: a gRPC call is always a POST
      #|/request/query: makes no sense on a gRPC Stub: a gRPC call's path has no query
      #|/response/status: makes no sense on a gRPC Stub: a gRPC reply's HTTP status is always 200, and grpc.status gives its gRPC status
      #|/response/json/mesage: is not a field of helloworld.HelloReply
    ),
  )
  // A condition by the field's proto name is matched as smock prints the
  // call's message, by its JSON name.
  let count = h.add(
    "catalog",
    None,
    (
      #|{ "request": { "path": "/catalog.Catalog/CountItems", "body": { "json": { "in_stock": true } } },
      #|  "response": { "json": { "count": 3 } } }
    ),
  )
  let path = "/catalog.Catalog/CountItems"
  let call = h.engine.handle(
    {
      meth: "POST",
      target: path,
      version: "HTTP/2",
      headers: [],
      body: b"{\"shelf\":\"\",\"inStock\":true}",
    },
    authority="catalog.svc",
    grpc={ path, octets: 2, },
    session=None,
    now=h.now,
    rand=h.rand,
  )
  inspect(
    "\{count}: \{answered_call(call)}",
    content="eph-1: ephemeral eph-1: OK",
  )
}

///|
test "an Ephemeral gRPC Stub is not read again at a reload: it stops answering when the new set no longer has its method as a unary method, and answers again once it has" {
  let h = harness(
    greeter_with_set("greeter.binpb"),
    body_files=ephemeral_body_files(),
  )
  let _ = h.add(
    "greeter",
    None,
    (
      #|{ "request": { "path": "/helloworld.Greeter/SayHello" },
      #|  "response": { "json": { "message": "Hello from the Admin API" } } }
    ),
  )
  let lines = ["before: \{answered_call(h.say_hello("Ann"))}"]
  // The Mock's set becomes catalog.proto, which has no SayHello.
  let _ = h.reload(
    greeter_with_set("catalog.binpb"),
    body_files=ephemeral_body_files(),
  )
  lines.push("unknown method: \{answered_call(h.say_hello("Ann"))}")
  // The Mock has no set at all.
  let _ = h.reload(
    [
      (
        "mocks.yaml",
        (
          #|mocks:
          #|  - name: greeter
          #|    default: true
        ),
      ),
    ],
    body_files=ephemeral_body_files(),
  )
  lines.push("no set: \{answered_call(h.say_hello("Ann"))}")
  // The HTTP request it never answered still does not reach it.
  lines.push(
    "HTTP: \{answered_call(h.send("POST", "/helloworld.Greeter/SayHello", body="{}"))}",
  )
  let _ = h.reload(
    greeter_with_set("greeter.binpb"),
    body_files=ephemeral_body_files(),
  )
  lines.push("the method again: \{answered_call(h.say_hello("Ann"))}")
  lines.push(
    "listed: \{h.engine.ephemeral_stubs(mock="greeter", session=None).map(stub => stub.id).join(", ")}",
  )
  inspect(
    lines.join("\n"),
    content=(
      #|before: ephemeral eph-1: OK
      #|unknown method: none: UNIMPLEMENTED; grpc-message: unknown method
      #|no set: none: UNIMPLEMENTED; grpc-message: the Mock has no Descriptor set
      #|HTTP: none: HTTP 404
      #|the method again: ephemeral eph-1: OK
      #|listed: eph-1
    ),
  )
}
