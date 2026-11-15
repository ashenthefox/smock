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
  #|  - id: hello-post
  #|    mock: greeter
  #|    request: { method: POST, path: /helloworld.Greeter/SayHello }
  #|    response: { template: true, json: { message: "Hello ${body.name}" } }
  #|  - id: plain
  #|    mock: greeter
  #|    request: { method: POST, path: /hello }
  #|    response: { status: 200, template: true, body: "${bodyText}" }
  #|  - id: typed
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response:
  #|      template: true
  #|      grpc:
  #|        status: INVALID_ARGUMENT
  #|        details:
  #|          - "@type": "type.googleapis.com/${header.x-type}"
  #|            fieldViolations: [{ field: name, description: "no user called ${body.name}" }]
  #|  - id: tokened
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-token-bin: AAE } }
  #|    response: { template: true, json: { message: "${header.x-token-bin}" } }

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
  #|  - id: priced
  #|    mock: catalog
  #|    request: { path: /catalog.Catalog/GetItem, headers: { x-case: priced } }
  #|    responses:
  #|      - { template: true, json: { price: "${body.id}" } }
  #|  - id: unknown
  #|    mock: catalog
  #|    request: { path: /catalog.Catalog/GetItem, headers: { x-case: unknown } }
  #|    response:
  #|      template: true
  #|      headers: { x-served-by: smock }
  #|      grpc:
  #|        status: NOT_FOUND
  #|        message: "no item ${body.nothing}"
  #|  - id: counted
  #|    mock: catalog
  #|    request: { path: /catalog.Catalog/GetItem, headers: { x-case: counted } }
  #|    dataWrites:
  #|      - { op: merge, bucket: counts, value: { last: "${body.id}" } }
  #|    response: { json: { price: 1 } }
  #|data:
  #|  - { mock: catalog, name: counts, json: 0 }

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

///|
test "a sample's body that is not a message of the input type is refused, with every problem, as is one whose JSON passes the body limit once decoded" {
  let h = harness(
    [("catalog.yaml", render_catalog)],
    body_files=catalog_body_files(),
  )
  inspect(
    [
      h.catalog("find-books", "FindItems", "{\"kind\": BOOK}"),
      h.catalog("find-books", "FindItems", "[]"),
      h.catalog(
        "find-books", "FindItems", "{\"prize\": 1, \"price\": \"42\", \"kind\": \"NOVEL\"}",
      ),
      // What the loader keeps in a condition is not a message.
      h.catalog("find-books", "FindItems", "{\"kind\": {\"$eq\": 1}}"),
      h.catalog(
        "count-in-stock", "CountItems", "{\"shelf\": {\"pattern\": \"a.*\"}}",
      ),
    ].join("\n"),
    content=(
      #|refused: the sample request's body must be a catalog.Item as JSON, the message that the method of the gRPC Stub "find-books" takes: is not JSON
      #|refused: the sample request's body must be a catalog.Item as JSON, the message that the method of the gRPC Stub "find-books" takes: must be an object: the message is a catalog.Item
      #|refused: the sample request's body must be a catalog.Item as JSON, the message that the method of the gRPC Stub "find-books" takes: /prize is not a field of catalog.Item; /price must be written 42, as smock prints it: the field price of catalog.Item has the type int64; /kind must be the name of a value of catalog.Kind, or an integer from -2147483648 to 2147483647: the field kind of catalog.Item has the type catalog.Kind
      #|refused: the sample request's body must be a catalog.Item as JSON, the message that the method of the gRPC Stub "find-books" takes: /kind must be the name of a value of catalog.Kind, or an integer from -2147483648 to 2147483647: the field kind of catalog.Item has the type catalog.Kind
      #|refused: the sample request's body must be a catalog.CountRequest as JSON, the message that the method of the gRPC Stub "count-in-stock" takes: /shelf must be a string of Unicode text: the field shelf of catalog.CountRequest has the type string
    ),
  )
  // The JSON of this CountRequest, whose shelf is 40 letters, takes 67
  // octets.
  let shelf = "a".repeat(40)
  let small = harness(
    [("catalog.yaml", render_catalog)],
    body_files=catalog_body_files(),
    body_limit=66,
  )
  inspect(
    small.catalog(
      "count-in-stock",
      "CountItems",
      "{\"shelf\": \"\{shelf}\", \"inStock\": true}",
    ),
    content=(
      #|refused: the sample request's body must be a catalog.CountRequest as JSON, the message that the method of the gRPC Stub "count-in-stock" takes: takes more than 66 octets as JSON once decoded, the body limit of a call's message (--body-limit)
    ),
  )
  let enough = harness(
    [("catalog.yaml", render_catalog)],
    body_files=catalog_body_files(),
    body_limit=67,
  )
  inspect(
    enough.catalog(
      "count-in-stock",
      "CountItems",
      "{\"shelf\": \"\{shelf}\", \"inStock\": true}",
    ),
    content=(
      #|OK {"count":2,"shelf":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"} failed=[]
    ),
  )
}

///|
test "the Stub's kind decides: a gRPC Stub renders as a call whatever the sample's method and content type, which fail as conditions, and an HTTP Stub as a request whatever its content type" {
  let h = harness(
    [("greeter.yaml", render_greeter)],
    body_files=details_body_files(),
  )
  let brief = (rendering : String) => {
    guard @json.parse(rendering)
      is { "response": Object(response), "failed": failed, .. } else {
      return "no response"
    }
    let grpc = response
      .get("grpc")
      .map_or("no gRPC part", grpc => grpc.stringify())
    guard response is { "body": { "data": String(body), .. }, .. } else {
      return "no body"
    }
    "body \{body}\n\{grpc}\nfailed \{failed.stringify()}"
  }
  let get : Json = {
    "method": "GET",
    "path": "/helloworld.Greeter/SayHello",
    "headers": { "content-type": "text/plain" },
    "body": "{\"name\":\"Ann\"}",
  }
  let grpc_text : Json = {
    "method": "POST",
    "path": "/hello",
    "headers": { "content-type": "application/grpc" },
    "body": "not a message",
  }
  inspect(
    [brief(h.render("hello-post", get)), brief(h.render("plain", grpc_text))].join(
      "\n---\n",
    ),
    content=(
      #|body {"message":"Hello Ann"}
      #|{"status":"OK","message":null,"trailers":[],"details":[]}
      #|failed [{"condition":"method","expected":"POST","actual":["GET"]}]
      #|---
      #|body not a message
      #|no gRPC part
      #|failed []
    ),
  )
}

///|
test "a gRPC Stub that cannot serve its content renders the INTERNAL a call gets, without the Stub's metadata, and its templateError: a reply that does not fit the output type, a template that fails, a data write that cannot be applied" {
  let h = harness(
    [("catalog.yaml", render_catalog)],
    body_files=catalog_body_files(),
  )
  let shown = (id : String, case_ : String, body : String) => {
    let sample : Json = {
      "method": "POST",
      "path": "/catalog.Catalog/GetItem",
      "headers": { "x-case": Json::string(case_) },
      "body": Json::string(body),
    }
    guard @json.parse(h.render(id, sample))
      is { "response": response, "templateError": error, .. } else {
      return "no response"
    }
    "\{response.stringify()}\n  templateError \{error.stringify()}"
  }
  inspect(
    [
      shown("priced", "priced", "{\"id\": \"x\"}"),
      // A reply that fits: the id is an integer.
      shown("priced", "priced", "{\"id\": \"42\"}"),
      shown("unknown", "unknown", "{\"id\": \"x\"}"),
      shown("counted", "counted", "{\"id\": \"x\"}"),
    ].join("\n"),
    content=(
      #|{"status":200,"headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false},"events":null,"grpc":{"status":"INTERNAL","message":"template failed","trailers":[],"details":[]}}
      #|  templateError {"at":"/responses/0/json/price","message":"must be an integer from -9223372036854775808 to 9223372036854775807: the field price of catalog.Item has the type int64"}
      #|{"status":200,"headers":[],"body":{"encoding":"utf-8","data":"{\"price\":\"42\"}","size":14,"truncated":false},"events":null,"grpc":{"status":"OK","message":null,"trailers":[],"details":[]}}
      #|  templateError null
      #|{"status":200,"headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false},"events":null,"grpc":{"status":"INTERNAL","message":"template failed","trailers":[],"details":[]}}
      #|  templateError {"at":"/response/grpc/message","message":"body.nothing is missing"}
      #|{"status":200,"headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false},"events":null,"grpc":{"status":"INTERNAL","message":"data write failed","trailers":[],"details":[]}}
      #|  templateError null
    ),
  )
}

///|
test "rendered details are shown as JSON when they fit their types, and a detail that does not fit gets INTERNAL with its templateError" {
  let h = harness(
    [("greeter.yaml", render_greeter)],
    body_files=details_body_files(),
  )
  let shown = (x_type : String) => {
    let sample : Json = {
      "path": "/helloworld.Greeter/SayHello",
      "headers": { "x-type": Json::string(x_type) },
      "body": "{\"name\":\"Ann\"}",
    }
    guard @json.parse(h.render("typed", sample))
      is { "response": { "grpc": grpc, .. }, "templateError": error, .. } else {
      return "no gRPC part"
    }
    "\{grpc.stringify()}\n  templateError \{error.stringify()}"
  }
  inspect(
    [shown("google.rpc.BadRequest"), shown("google.rpc.ErrorInfo")].join("\n"),
    content=(
      #|{"status":"INVALID_ARGUMENT","message":null,"trailers":[],"details":[{"@type":"type.googleapis.com/google.rpc.BadRequest","fieldViolations":[{"field":"name","description":"no user called Ann"}]}]}
      #|  templateError null
      #|{"status":"INTERNAL","message":"template failed","trailers":[],"details":[]}
      #|  templateError {"at":"/response/grpc/details/0/fieldViolations","message":"is not a field of google.rpc.ErrorInfo"}
    ),
  )
}

///|
test "binary metadata in the sample loses its padding, as a call's does, so it meets the Stub's conditions and templates read it unpadded" {
  let h = harness(
    [("greeter.yaml", render_greeter)],
    body_files=details_body_files(),
  )
  let sample : Json = {
    "path": "/helloworld.Greeter/SayHello",
    "headers": { "X-Token-Bin": "AAE=" },
  }
  guard @json.parse(h.render("tokened", sample))
    is {
      "response": { "body": { "data": body, .. }, .. },
      "failed": failed,
      ..
    } else {
    fail("no response")
  }
  json_inspect([body, failed], content=["{\"message\":\"AAE\"}", []])
}
