// Seam 2 tests of rendering a gRPC Stub: `smock render` on a temporary
// definitions directory, and the Admin render operation, checked against
// the OpenAPI document (contract_test.mbt). The Mock is `greeter`, with the
// set of gRPC's helloworld.proto and googleapis' error_details.proto
// (`with_details`, grpc_details_test.mbt). Both are given the time and the
// seed, so their renderings are the same, and are shown whole.

///|
/// The spec's `hello-tom`, with `method: POST`, and `hello-unknown`.
let grpc_render_stubs : String =
  #|  - id: hello-tom
  #|    mock: greeter
  #|    request:
  #|      method: POST
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
/// The sample requests, by name: a call for Tom; a call for Ann, with the
/// default method; a message with a misspelt field; and Tom's call made
/// with GET and no gRPC content type.
let grpc_render_samples : Array[(String, String)] = [
  (
    "tom",
    (
      #|{ "method": "POST", "path": "/helloworld.Greeter/SayHello",
      #|  "headers": { "content-type": "application/grpc", "x-tenant": "acme" },
      #|  "body": "{\"name\": \"Tom\"}" }
    ),
  ),
  (
    "ann",
    (
      #|{ "path": "/helloworld.Greeter/SayHello", "body": "{\"name\": \"Ann\"}" }
    ),
  ),
  (
    "misspelt",
    (
      #|{ "method": "POST", "path": "/helloworld.Greeter/SayHello",
      #|  "headers": { "content-type": "application/grpc", "x-tenant": "acme" },
      #|  "body": "{\"nmae\": \"Tom\"}" }
    ),
  ),
  (
    "get",
    (
      #|{ "method": "GET", "path": "/helloworld.Greeter/SayHello",
      #|  "headers": { "content-type": "text/plain", "x-tenant": "acme" },
      #|  "body": "{\"name\": \"Tom\"}" }
    ),
  ),
]

///|
/// Renders the Stub `id` for the sample `sample` with `smock render` and
/// with the Admin render operation of a smock serving the same directory,
/// at one time and with one seed, and shows both: the CLI's exit status and
/// output, then the Admin API's status and body.
async fn render_both(id : String, sample : String) -> String {
  let mut out = ""
  with_details(grpc_render_stubs, dir => {
    for named in grpc_render_samples {
      write(dir, "samples/\{named.0}.json", named.1)
    }
    let file = "\{dir}/samples/\{sample}.json"
    let cli = render([
      "--dir", dir, id, "--request", file, "--time", "2026-11-15T09:00:00Z", "--seed",
      "7",
    ])
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let admin = smock.render(
        id,
        sample=file,
        query="?time=2026-11-15T09:00:00Z&seed=7",
      )
      out = "\{cli}---\n\{admin.status}\n\{admin.body}"
    })
  })
  out
}

///|
async test "a gRPC Stub's static reply: smock render and the Admin render show the reply JSON, the initial metadata and the status OK, and no protobuf bytes" {
  inspect(
    render_both("hello-tom", "tom"),
    content=(
      #|status 0
      #|{
      #|  "stub": "hello-tom",
      #|  "mock": "greeter",
      #|  "time": "2026-11-15T09:00:00.000Z",
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
      #|---
      #|200
      #|{"stub":"hello-tom","mock":"greeter","time":"2026-11-15T09:00:00.000Z","seed":7,"responseIndex":null,"variables":{},"dataWrites":[],"response":{"status":200,"headers":[{"name":"x-served-by","value":"smock"}],"body":{"encoding":"utf-8","data":"{\"message\":\"Hello Tom\"}","size":23,"truncated":false},"events":null,"grpc":{"status":"OK","message":null,"trailers":[],"details":[]}},"templateError":null,"failed":[],"warnings":[]}
    ),
  )
}

///|
async test "the ticket's example: smock render and the Admin render of hello-unknown for Ann show NOT_FOUND, its message, the trailer x-trace and the ErrorInfo detail" {
  inspect(
    render_both("hello-unknown", "ann"),
    content=(
      #|status 0
      #|{
      #|  "stub": "hello-unknown",
      #|  "mock": "greeter",
      #|  "time": "2026-11-15T09:00:00.000Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "variables": {},
      #|  "dataWrites": [],
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "",
      #|      "size": 0,
      #|      "truncated": false
      #|    },
      #|    "events": null,
      #|    "grpc": {
      #|      "status": "NOT_FOUND",
      #|      "message": "no user called Ann",
      #|      "trailers": [
      #|        {
      #|          "name": "x-trace",
      #|          "value": "abc"
      #|        }
      #|      ],
      #|      "details": [
      #|        {
      #|          "@type": "type.googleapis.com/google.rpc.ErrorInfo",
      #|          "reason": "USER_UNKNOWN",
      #|          "domain": "greeter.svc"
      #|        }
      #|      ]
      #|    }
      #|  },
      #|  "templateError": null,
      #|  "failed": []
      #|}
      #|---
      #|200
      #|{"stub":"hello-unknown","mock":"greeter","time":"2026-11-15T09:00:00.000Z","seed":7,"responseIndex":null,"variables":{},"dataWrites":[],"response":{"status":200,"headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false},"events":null,"grpc":{"status":"NOT_FOUND","message":"no user called Ann","trailers":[{"name":"x-trace","value":"abc"}],"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"USER_UNKNOWN","domain":"greeter.svc"}]}},"templateError":null,"failed":[],"warnings":[]}
    ),
  )
}

///|
async test "a sample whose body is not a message of the input type: smock render exits with status 1, and the Admin render answers 400 invalid_request" {
  inspect(
    render_both("hello-tom", "misspelt"),
    content=(
      #|status 1
      #|stderr:
      #|smock render: the sample request's body must be a helloworld.HelloRequest as JSON, the message that the method of the gRPC Stub "hello-tom" takes: /nmae is not a field of helloworld.HelloRequest
      #|---
      #|400
      #|{"error":"invalid_request","message":"the sample request's body must be a helloworld.HelloRequest as JSON, the message that the method of the gRPC Stub \"hello-tom\" takes: /nmae is not a field of helloworld.HelloRequest","warnings":[]}
    ),
  )
}

///|
async test "a sample made with GET and no gRPC content type still renders hello-tom as a call, and lists its method among the conditions it fails" {
  inspect(
    render_both("hello-tom", "get"),
    content=(
      #|status 0
      #|{
      #|  "stub": "hello-tom",
      #|  "mock": "greeter",
      #|  "time": "2026-11-15T09:00:00.000Z",
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
      #|  "failed": [
      #|    {
      #|      "condition": "method",
      #|      "expected": "POST",
      #|      "actual": [
      #|        "GET"
      #|      ]
      #|    }
      #|  ]
      #|}
      #|---
      #|200
      #|{"stub":"hello-tom","mock":"greeter","time":"2026-11-15T09:00:00.000Z","seed":7,"responseIndex":null,"variables":{},"dataWrites":[],"response":{"status":200,"headers":[{"name":"x-served-by","value":"smock"}],"body":{"encoding":"utf-8","data":"{\"message\":\"Hello Tom\"}","size":23,"truncated":false},"events":null,"grpc":{"status":"OK","message":null,"trailers":[],"details":[]}},"templateError":null,"failed":[{"condition":"method","expected":"POST","actual":["GET"]}],"warnings":[]}
    ),
  )
}
