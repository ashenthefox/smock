// Seam 1 tests of rendering a gRPC Stub: a gRPC rendering, whatever the
// sample's method and content type, which are only conditions. The
// sample's body is the request message as JSON, checked against the input
// type and normalised, and the rendering shows the reply JSON with the
// gRPC part a call gets: its status, message, trailers and details, and no
// protobuf bytes. The set is details.binpb, gRPC's helloworld.proto with
// googleapis' error_details.proto (details_set_test.mbt); `Harness::render`
// comes from render_test.mbt.

///|
/// The Mock `greeter`, with the details set, and its Stubs: the spec's
/// `hello-tom` and `hello-unknown`.
let render_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    hosts: [greeter.svc]
  #|    grpc: { descriptorSet: details.binpb }
  #|stubs:
  #|  - id: hello-tom
  #|    mock: greeter
  #|    request:
  #|      path: /helloworld.Greeter/SayHello
  #|      headers: { x-tenant: acme }
  #|      body: { json: { name: Tom } }
  #|    response:
  #|      headers: { x-served-by: smock }
  #|      json: { message: Hello Tom }
  #|  - id: hello-unknown
  #|    mock: greeter
  #|    request:
  #|      path: /helloworld.Greeter/SayHello
  #|    response:
  #|      template: true
  #|      grpc:
  #|        status: NOT_FOUND
  #|        message: no user called ${body.name}
  #|        trailers: { x-trace: abc }
  #|        details:
  #|          - "@type": type.googleapis.com/google.rpc.ErrorInfo
  #|            reason: USER_UNKNOWN
  #|            domain: greeter.svc

///|
/// The sample of a call to SayHello for `name`, with the metadata
/// `x-tenant: acme`.
fn say_hello(name : String) -> Json {
  {
    "method": "POST",
    "path": "/helloworld.Greeter/SayHello",
    "headers": { "content-type": "application/grpc", "x-tenant": "acme" },
    "body": Json::string("{\"name\":\{name.escape()}}"),
  }
}

///|
test "a gRPC Stub's static reply renders as a call gets it: the reply JSON, its initial metadata, and the status OK" {
  let h = harness(
    [("greeter.yaml", render_greeter)],
    body_files=details_body_files(),
  )
  inspect(
    h.render("hello-tom", say_hello("Tom")),
    content=(
      #|{
      #|  "stub": "hello-tom",
      #|  "mock": "greeter",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "variables": {},
      #|  "dataWrites": [],
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [
      #|      {
      #|        "name": "x-served-by",
      #|        "value": "smock"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "{\"message\":\"Hello Tom\"}",
      #|      "size": 23,
      #|      "truncated": false
      #|    },
      #|    "events": null,
      #|    "grpc": {
      #|      "status": "OK",
      #|      "message": null,
      #|      "trailers": [],
      #|      "details": []
      #|    }
      #|  },
      #|  "templateError": null,
      #|  "failed": []
      #|}
    ),
  )
}

///|
test "the ticket's example: hello-unknown renders for Ann with NOT_FOUND, its message, its trailer and its ErrorInfo, and no protobuf bytes" {
  let h = harness(
    [("greeter.yaml", render_greeter)],
    body_files=details_body_files(),
  )
  let rendering = @json.parse(h.render("hello-unknown", say_hello("Ann")))
  guard rendering is { "response": response, "templateError": error, .. } else {
    fail("no response")
  }
  json_inspect(response, content={
    "status": 200,
    "headers": [],
    "body": { "encoding": "utf-8", "data": "", "size": 0, "truncated": false },
    "events": null,
    "grpc": {
      "status": "NOT_FOUND",
      "message": "no user called Ann",
      "trailers": [{ "name": "x-trace", "value": "abc" }],
      "details": [
        {
          "@type": "type.googleapis.com/google.rpc.ErrorInfo",
          "reason": "USER_UNKNOWN",
          "domain": "greeter.svc",
        },
      ],
    },
  })
  json_inspect(error, content=null)
}

///|
/// The body files of the Mock `catalog`: catalog.binpb.
fn catalog_body_files() -> Array[(String, Bytes)] raise {
  [("catalog.binpb", @hex.decode(catalog_set.replace_all(old="\n", new="")))]
}

///|
/// The Mock `catalog`, with the catalog set, and Stubs whose conditions and
/// replies read the request message.
let render_catalog : String =
  #|mocks:
  #|  - name: catalog
  #|    grpc: { descriptorSet: catalog.binpb }
  #|stubs:
  #|  - id: find-books
  #|    mock: catalog
  #|    request:
  #|      path: /catalog.Catalog/FindItems
  #|      body: { json: { kind: BOOK } }
  #|    response:
  #|      template: true
  #|      json: { count: 1, shelf: "${body.kind} ${body.price} ${body.stock.exact}" }
  #|  - id: count-in-stock
  #|    mock: catalog
  #|    request:
  #|      path: /catalog.Catalog/CountItems
  #|      body: { json: { inStock: true } }
  #|    response:
  #|      template: true
  #|      json: { count: 2, shelf: "${body.shelf}" }

///|
/// The rendering of `id` for a call to `rpc`, a method of catalog.Catalog, whose
/// message is `body`, as JSON text: its reply JSON, its gRPC status and
/// the conditions it fails, or why it cannot be rendered.
fn Harness::catalog(
  self : Harness,
  id : String,
  rpc : String,
  body : String,
) -> String {
  let sample : Json = {
    "method": "POST",
    "path": "/catalog.Catalog/\{rpc}",
    "body": Json::string(body),
  }
  let rendering = self.engine.render(
    id,
    @engine.SampleRequest::from_json(sample) catch {
      _ => panic()
    },
    now=self.now,
    fresh_seed=() => 7,
  ) catch {
    error => return "refused: \{error.message()}"
  }
  let reply = match rendering.body {
    Bytes(bytes) => @utf8.decode_lossy(bytes)
    Events(_) => "events"
  }
  let status = match rendering.grpc {
    Some(part) => part.status.name()
    None => "no gRPC part"
  }
  let failed = rendering.failed.map(failed => {
    guard failed.to_json() is { "condition": String(condition), .. } else {
      return "?"
    }
    condition
  })
  "\{status} \{reply} failed=[\{failed.join(",")}]"
}

///|
test "the sample's body is normalised as the loader normalises conditions, and read as a call's message is, with defaults for the fields it leaves out" {
  let h = harness(
    [("catalog.yaml", render_catalog)],
    body_files=catalog_body_files(),
  )
  inspect(
    [
      // An enum by its number, a field without presence left out, and a
      // message whose fields are left out.
      h.catalog("find-books", "FindItems", "{\"kind\": 1, \"stock\": {}}"),
      // A field by its proto name.
      h.catalog(
        "count-in-stock", "CountItems", "{\"in_stock\": true, \"shelf\": \"a\"}",
      ),
      // No body is the empty message, whose fields are all at their
      // defaults.
      h.catalog("count-in-stock", "CountItems", ""),
    ].join("\n"),
    content=(
      #|OK {"count":1,"shelf":"BOOK 0 false"} failed=[]
      #|OK {"count":2,"shelf":"a"} failed=[]
      #|OK {"count":2,"shelf":""} failed=[body]
    ),
  )
}
