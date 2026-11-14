// Seam 2 tests of the well-known types whose JSON forms hold any JSON value
// or a message of another type, Struct, Value, ListValue, NullValue and
// Any, over h2c and through `smock check`: requests journaled and matched
// in their printed forms, an Any with the type its URL names in the set,
// and replies read as ProtoJSON, `null` setting a Value and a NullValue.
// The set is fixtures/protobuf/wellknown/dynamic.proto with protobuf's
// files and gRPC's helloworld.proto beside it, and the requests and the
// replies compared are what protoc encodes from the .txtpb files there
// (scripts/gen-protobuf-fixtures.sh), so the codec is never checked
// against itself.

///|
/// Runs `f` with a definitions directory holding `documents.yaml`, which
/// declares the Mock `documents`, the Default Mock, whose set is
/// dynamic.proto's, then holds `stubs`, the lines of its `stubs` array;
/// and with the set at `files/dynamic.binpb`.
async fn with_documents(stubs : String, f : async (String) -> Unit) -> Unit {
  let yaml =
    #|mocks:
    #|  - name: documents
    #|    default: true
    #|    grpc: { descriptorSet: dynamic.binpb }
    #|stubs:
    #|
  with_definitions([("documents.yaml", yaml + stubs)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/dynamic.binpb",
      @fs.read_file("\{wellknown_dir}/dynamic.binpb").binary(),
    )
    f(dir)
  })
}

///|
async test "the ticket's example: an Any that holds a HelloRequest, a Duration or an Empty is journaled with its @type, meets a condition written so, and a reply in any form ProtoJSON reads has protoc's bytes" {
  let stubs =
    #|  - id: hello
    #|    mock: documents
    #|    request:
    #|      path: /dynamic.Documents/Wrap
    #|      body: { json: { "@type": type.googleapis.com/helloworld.HelloRequest, name: Tom } }
    #|    response: { json: { "@type": type.googleapis.com/helloworld.HelloRequest, name: Tom } }
    #|  - id: wait
    #|    mock: documents
    #|    request:
    #|      path: /dynamic.Documents/Wrap
    #|      body: { json: { "@type": type.googleapis.com/google.protobuf.Duration, value: "1.500s" } }
    #|    response: { json: { "@type": type.googleapis.com/google.protobuf.Duration, value: 1.5s } }
    #|  - id: empty
    #|    mock: documents
    #|    request:
    #|      path: /dynamic.Documents/Wrap
    #|      body: { json: { "@type": type.googleapis.com/google.protobuf.Empty } }
    #|    response: { json: { "@type": type.googleapis.com/google.protobuf.Empty, value: {} } }
  with_documents(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for name in ["any-hello", "any-duration", "any-empty"] {
        let reply = client.call(
          "/dynamic.Documents/Wrap",
          body=wellknown_message(name),
        )
        let same = reply.data == [wellknown_message(name)]
        out.push(
          "\{name}: \{reply.status()} \{if same { "protoc's bytes" } else { reply.render() }}",
        )
      }
      inspect(
        out.join("\n"),
        content=(
          #|any-hello: 0 protoc's bytes
          #|any-duration: 0 protoc's bytes
          #|any-empty: 0 protoc's bytes
        ),
      )
      inspect(
        smock.bodies(),
        content=(
          #|"hello": {"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Tom"}
          #|"wait": {"@type":"type.googleapis.com/google.protobuf.Duration","value":"1.500s"}
          #|"empty": {"@type":"type.googleapis.com/google.protobuf.Empty"}
        ),
      )
    })
  })
}

///|
async test "every type, from protoc-encoded requests: a Struct in key order, Values, ListValues, NullValues as null and Anys are journaled and meet conditions written so; replies in other spellings, and null in a Value and a Struct entry, have protoc's bytes" {
  let stubs =
    #|  - id: document
    #|    mock: documents
    #|    request:
    #|      path: /dynamic.Documents/Put
    #|      headers: { x-case: document }
    #|      body:
    #|        json:
    #|          labels: { count: 3.0, team: { pattern: "co.*" }, nested: { sizes: { $includes: 1.5 } }, none: null }
    #|          value: ["x", null, []]
    #|          nothing: NULL_VALUE
    #|          by_name: { a: null }
    #|          attachment: { "@type": type.googleapis.com/helloworld.HelloRequest, name: Tom }
    #|          attachments: { $includes: { "@type": type.googleapis.com/google.protobuf.Value, value: 2.0 } }
    #|          none: 0
    #|          nothings: [null, null]
    #|    response:
    #|      json:
    #|        nothings: [NULL_VALUE, 0]
    #|        maybe: null
    #|        none: NULL_VALUE
    #|        attachments:
    #|          - { "@type": type.googleapis.com/google.protobuf.Duration, value: 1.5s }
    #|          - { "@type": type.googleapis.com/google.protobuf.Empty }
    #|          - { "@type": type.googleapis.com/google.protobuf.Value, value: 2 }
    #|          - { "@type": type.googleapis.com/google.protobuf.Struct, value: { k: true } }
    #|          - { "@type": type.googleapis.com/google.protobuf.Any, value: { name: Ann, "@type": type.googleapis.com/helloworld.HelloRequest } }
    #|        attachment: { "@type": type.googleapis.com/helloworld.HelloRequest, name: Tom }
    #|        byName: { b: B, a: null }
    #|        values: ["a\"b", 0]
    #|        nothing: null
    #|        list: [-0.25, false]
    #|        value: ["x", null, []]
    #|        labels: { team: core, "on": true, none: null, nested: { sizes: [1.5, 1e21], empty: {} }, count: 3 }
    #|  - id: nulls
    #|    mock: documents
    #|    request:
    #|      path: /dynamic.Documents/Put
    #|      headers: { x-case: nulls }
    #|      body: { json: { value: null, labels: { gone: null }, list: [null], maybe: null } }
    #|    response:
    #|      json: { labels: { gone: null }, value: null, list: [null], nothing: null, values: [null], by_name: { gone: null }, attachment: null, none: null, maybe: null, nothings: [null] }
    #|  - id: describe
    #|    mock: documents
    #|    request: { path: /dynamic.Documents/Describe, body: { json: { name: Tom, age: 42 } } }
    #|    response: { json: { age: 42.0, name: Tom } }
    #|  - id: echo
    #|    mock: documents
    #|    request: { path: /dynamic.Documents/Echo, body: { json: { ok: true } } }
    #|    response: { json: { ok: true } }
    #|  - id: list
    #|    mock: documents
    #|    request: { path: /dynamic.Documents/List, body: { json: [Tom, null, 7] } }
    #|    response: { json: [Tom, null, 7.0] }
  with_documents(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for
        case in [
          ("Put", "document", "document"),
          ("Put", "document-nulls", "nulls"),
          ("Describe", "struct", ""),
          ("Echo", "value", ""),
          ("List", "list", ""),
        ] {
        let (rpc, name, case_) = case
        let reply = client.call(
          "/dynamic.Documents/\{rpc}",
          headers=if case_ == "" { [] } else { [("x-case", case_)] },
          body=wellknown_message(name),
        )
        let same = reply.data == [wellknown_message(name)]
        out.push(
          "\{name}: \{reply.status()} \{if same { "protoc's bytes" } else { reply.render() }}",
        )
      }
      inspect(
        out.join("\n"),
        content=(
          #|document: 0 protoc's bytes
          #|document-nulls: 0 protoc's bytes
          #|struct: 0 protoc's bytes
          #|value: 0 protoc's bytes
          #|list: 0 protoc's bytes
        ),
      )
      inspect(
        smock.bodies(),
        content=(
          #|"document": {"labels":{"count":3,"nested":{"empty":{},"sizes":[1.5,1e+21]},"none":null,"on":true,"team":"core"},"value":["x",null,[]],"list":[-0.25,false],"nothing":null,"values":["a\"b",0],"byName":{"a":null,"b":"B"},"attachment":{"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Tom"},"attachments":[{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1.500s"},{"@type":"type.googleapis.com/google.protobuf.Empty"},{"@type":"type.googleapis.com/google.protobuf.Value","value":2},{"@type":"type.googleapis.com/google.protobuf.Struct","value":{"k":true}},{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Ann"}}],"none":null,"maybe":null,"nothings":[null,null]}
          #|"nulls": {"labels":{"gone":null},"value":null,"list":[null],"nothing":null,"values":[null],"byName":{"gone":null},"attachments":[],"none":null,"maybe":null,"nothings":[null]}
          #|"describe": {"age":42,"name":"Tom"}
          #|"echo": {"ok":true}
          #|"list": ["Tom",null,7]
        ),
      )
    })
  })
}

///|
async test "an Any whose type the set lacks: a request gets INTERNAL and is not journaled, and a templated reply gets INTERNAL template failed, with templateError" {
  let stubs =
    #|  - id: echo
    #|    mock: documents
    #|    request: { path: /dynamic.Documents/Wrap }
    #|    response: { template: true, json: { "@type": "type.googleapis.com/${header.x-type}", name: Tom } }
  with_documents(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let hello = client.call(
        "/dynamic.Documents/Wrap",
        headers=[("x-type", "helloworld.HelloRequest")],
        body=wellknown_message("any-hello"),
      )
      let missing_reply = client.call(
        "/dynamic.Documents/Wrap",
        headers=[("x-type", "missing.Greeting")],
        body=wellknown_message("any-hello"),
      )
      let missing_request = client.call(
        "/dynamic.Documents/Wrap",
        headers=[("x-type", "helloworld.HelloRequest")],
        body=wellknown_message("any-missing"),
      )
      inspect(
        [
          "hello: \{hello.status()} \{hello.data == [wellknown_message("any-hello")]}",
          "missing reply: \{missing_reply.render()}",
          "missing request: \{missing_request.render()}",
        ].join("\n"),
        content=(
          #|hello: 0 true
          #|missing reply: HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: template failed
          #|  smock-mock: documents; via=default
          #|  date: <now>
          #|(end)
          #|missing request: HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: the request message cannot be decoded
          #|  date: <now>
          #|(end)
        ),
      )
      let (_, page) = smock.journal()
      inspect(
        answers(page),
        content=(
          #|"echo" 200 "OK"
          #|"echo" 200 "INTERNAL" templateError={"at":"/response/json/@type","message":"names the type missing.Greeting, which the Descriptor set does not define"}
        ),
      )
    })
  })
}

///|
async test "smock check refuses an Any whose type the set lacks, in a condition and in a static reply, and members that do not fit the type an Any names" {
  let stubs =
    #|  - id: missing
    #|    mock: documents
    #|    request:
    #|      path: /dynamic.Documents/Wrap
    #|      body: { json: { "@type": type.googleapis.com/missing.Greeting, name: Tom } }
    #|    response: { json: { "@type": type.googleapis.com/missing.Greeting, name: Tom } }
    #|  - id: misfit
    #|    mock: documents
    #|    request:
    #|      path: /dynamic.Documents/Put
    #|      body: { json: { attachment: { "@type": type.googleapis.com/google.protobuf.Duration, value: 1.5s } } }
    #|    response: { json: { attachments: [{ "@type": type.googleapis.com/helloworld.HelloRequest, nmae: Tom }] } }
  with_documents(stubs, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|documents.yaml: /stubs/0/request/body/json/@type: names the type missing.Greeting, which the Descriptor set does not define
        #|documents.yaml: /stubs/0/response/json/@type: names the type missing.Greeting, which the Descriptor set does not define
        #|documents.yaml: /stubs/1/request/body/json/attachment/value: must be written "1.500s", as smock prints it: the Any holds a google.protobuf.Duration
        #|documents.yaml: /stubs/1/response/json/attachments/0/nmae: is not a field of helloworld.HelloRequest
        #|
      ),
    )
  })
}
