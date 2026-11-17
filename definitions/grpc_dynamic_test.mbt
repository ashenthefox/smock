// gRPC Stubs whose methods' types hold the well-known types whose JSON
// forms hold any JSON value or a message of another type, Struct, Value,
// ListValue, NullValue and Any: served on both sides, their `json`
// conditions checked against the printed forms and normalised, a Struct's
// keys as data and an Any's members against the type it names, and their
// static replies encoded. The set is fixtures/protobuf/wellknown/
// dynamic.proto with protobuf's files and gRPC's helloworld.proto beside
// it (dynamic_set_test.mbt), which scripts/gen-protobuf-fixtures.sh builds
// with protoc.

///|
/// Loads `a.yaml`, which declares the Mock `documents`, whose set is
/// dynamic.proto's, and then `stubs`, the lines of its `stubs` array.
/// Renders what the loader makes of them: every problem, one per line, as
/// `smock check` prints it; or, for a valid set, each Stub with its `json`
/// body condition as matching sees it and the reply message of each of its
/// responses, encoded at load, in hex.
fn documents(stubs : String) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: documents, grpc: { descriptorSet: dynamic.binpb } }
    #|stubs:
    #|
  match
    @definitions.load({
      files: [("a.yaml", @utf8.encode(yaml + stubs))],
      body_files: [("dynamic.binpb", set_bytes(dynamic_set))],
    }) {
    Ok(snapshot) => {
      let lines = []
      for stub in snapshot.mocks[0].stubs {
        guard stub.serves is Ordinary(ordinary) else { continue }
        let condition = match ordinary.request.body {
          Some(Json(condition)) => condition.to_json().stringify()
          _ => "no condition"
        }
        let messages = []
        for weighted in ordinary.responses {
          messages.push(
            match weighted.response.encoded {
              Some(encoded) => "[\{@hex.encode(encoded.message)}]"
              None => "none"
            },
          )
        }
        lines.push("\{stub.id}: \{condition} \{messages.join(" ")}")
      }
      lines.join("\n")
    }
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
test "the ticket's example: conditions on an Any that holds a HelloRequest and one that holds a Duration are kept, and their replies encoded" {
  inspect(
    documents(
      (
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
      ),
    ),
    // protoc encodes the replies as fixtures/protobuf/wellknown/
    // any-hello.binpb and any-duration.binpb.
    content=(
      #|hello: {"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Tom"} [0a2b747970652e676f6f676c65617069732e636f6d2f68656c6c6f776f726c642e48656c6c6f5265717565737412050a03546f6d]
      #|wait: {"@type":"type.googleapis.com/google.protobuf.Duration","value":"1.500s"} [0a2c747970652e676f6f676c65617069732e636f6d2f676f6f676c652e70726f746f6275662e4475726174696f6e120808011080cab5ee01]
    ),
  )
}

///|
test "conditions on Struct, Value, ListValue and NullValue: a Struct's keys are data, kept as written; a Value's numbers print as doubles; a NullValue's name or number becomes null; an Any's members are checked against its type; patterns and operators go anywhere" {
  inspect(
    documents(
      (
        #|  - id: put
        #|    mock: documents
        #|    request:
        #|      path: /dynamic.Documents/Put
        #|      body:
        #|        json:
        #|          labels: { count: 3.0, user_name: x, $$exists: true, nested: { sizes: { $includes: 2.50 } }, team: { pattern: "^c" } }
        #|          value: 2.50
        #|          nothing: NULL_VALUE
        #|          list: [1, null, { a: 1, b: [true] }]
        #|          by_name: { a: null, b: { $exists: true } }
        #|          values: { $includes: null }
        #|          maybe: 0
        #|          none: null
        #|          attachment: { "@type": type.googleapis.com/helloworld.HelloRequest, name: { pattern: "^T" } }
        #|          attachments:
        #|            - { "@type": type.googleapis.com/google.protobuf.Empty }
        #|            - { "@type": type.googleapis.com/google.protobuf.Value, value: 2.0 }
        #|            - { "@type": type.googleapis.com/google.protobuf.Any, value: { "@type": type.googleapis.com/helloworld.HelloRequest, name: Ann } }
        #|            - { "@type": { pattern: "Duration$" } }
        #|            - {}
        #|    response:
        #|      json: { labels: { gone: null }, value: null, list: [null], nothing: null, values: [null], by_name: { gone: null }, none: null, maybe: null, nothings: [null] }
      ),
    ),
    // protoc encodes the reply as fixtures/protobuf/wellknown/
    // document-nulls.binpb.
    content=(
      #|put: {"labels":{"count":3,"user_name":"x","$$exists":true,"nested":{"sizes":{"$includes":2.5}},"team":{"pattern":"^c"}},"value":2.5,"nothing":null,"list":[1,null,{"a":1,"b":[true]}],"byName":{"a":null,"b":{"$exists":true}},"values":{"$includes":null},"maybe":null,"none":null,"attachment":{"@type":"type.googleapis.com/helloworld.HelloRequest","name":{"pattern":"^T"}},"attachments":[{"@type":"type.googleapis.com/google.protobuf.Empty"},{"@type":"type.googleapis.com/google.protobuf.Value","value":2},{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Ann"}},{"@type":{"pattern":"Duration$"}},{}]} [0a0c0a0a0a04676f6e6512020800120208001a040a0208002a020800320a0a04676f6e651202080048005800620100]
    ),
  )
}

///|
/// The Stub `huge` gives a Struct a member of 1e309, the first power of ten
/// beyond the range of a double. A Struct's members are values that a
/// google.protobuf.Value holds, "a number, which prints as a `double`
/// does" (docs/grpc/messages.md), so no call's message can hold it: "A
/// value that can never match is a problem: a number out of its type's
/// range", reported "at the JSON Pointer of the value at fault"
/// (docs/definition-files/grpc.md). The message ends as #283 names it. Its
/// first part, "must be a JSON value: null, a number within the range of a
/// double, a string, true or false, an object or an array", is the code's
/// wording, which the maintainer confirmed on 2026-11-17 (#275).
test "an Any's type that the set lacks, in a condition or a static reply, is a problem; so are members that do not fit the type it names, and values of the wrong form" {
  inspect(
    documents(
      (
        #|  - id: missing
        #|    mock: documents
        #|    request: { path: /dynamic.Documents/Wrap, body: { json: { "@type": type.googleapis.com/missing.Greeting, name: Tom } } }
        #|    response: { json: { "@type": type.googleapis.com/missing.Greeting, name: Tom } }
        #|  - id: misfit
        #|    mock: documents
        #|    request: { path: /dynamic.Documents/Wrap, body: { json: { "@type": type.googleapis.com/helloworld.HelloRequest, nmae: Tom } } }
        #|    response: { json: { "@type": type.googleapis.com/google.protobuf.Empty, value: { a: 1 } } }
        #|  - id: forms
        #|    mock: documents
        #|    request: { path: /dynamic.Documents/Wrap, body: { json: { "@type": type.googleapis.com/google.protobuf.Duration, value: 1.5s, seconds: 1 } } }
        #|    response: {}
        #|  - id: untyped
        #|    mock: documents
        #|    request: { path: /dynamic.Documents/Wrap, body: { json: { name: Tom } } }
        #|    response: {}
        #|  - id: pattern
        #|    mock: documents
        #|    request: { path: /dynamic.Documents/Wrap, body: { json: { "@type": { pattern: x }, name: Tom } } }
        #|    response: {}
        #|  - id: not-a-url
        #|    mock: documents
        #|    request: { path: /dynamic.Documents/Wrap, body: { json: { "@type": helloworld.HelloRequest } } }
        #|    response: {}
        #|  - id: empty
        #|    mock: documents
        #|    request: { path: /dynamic.Documents/Wrap, body: { json: { "@type": type.googleapis.com/google.protobuf.Empty, value: {} } } }
        #|    response: {}
        #|  - id: put
        #|    mock: documents
        #|    request: { path: /dynamic.Documents/Put, body: { json: { labels: [], list: {}, nothing: x, attachment: x, values: [{ "@type": 1 }] } } }
        #|    response: { json: { list: [{ a: [null] }], attachments: [null] } }
        #|  - id: huge
        #|    mock: documents
        #|    request: { path: /dynamic.Documents/Describe, body: { json: { a: 1e309 } } }
        #|    response: {}
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/body/json/@type: names the type missing.Greeting, which the Descriptor set does not define
      #|a.yaml: /stubs/0/response/json/@type: names the type missing.Greeting, which the Descriptor set does not define
      #|a.yaml: /stubs/1/request/body/json/nmae: is not a field of helloworld.HelloRequest
      #|a.yaml: /stubs/1/response/json/value: is not a field of google.protobuf.Empty
      #|a.yaml: /stubs/2/request/body/json/value: must be written "1.500s", as smock prints it: the Any holds a google.protobuf.Duration
      #|a.yaml: /stubs/2/request/body/json/seconds: is not a member of an Any that holds a google.protobuf.Duration: give the google.protobuf.Duration as "value"
      #|a.yaml: /stubs/3/request/body/json: must give "@type", the type URL of the message the Any holds, so that its other members can be checked against its type
      #|a.yaml: /stubs/4/request/body/json/@type: must be a type URL: / and the full name of a type of the set at its end, such as "type.googleapis.com/helloworld.HelloRequest", when the Any gives other members: they are checked against the type it names
      #|a.yaml: /stubs/5/request/body/json/@type: must be a type URL: / and the full name of a type of the set at its end, such as "type.googleapis.com/helloworld.HelloRequest"
      #|a.yaml: /stubs/6/request/body/json/value: is not a field of google.protobuf.Empty
      #|a.yaml: /stubs/7/request/body/json/labels: must be an object, whose members are any JSON values: the field labels of dynamic.Document has the type google.protobuf.Struct
      #|a.yaml: /stubs/7/request/body/json/list: must be an array, whose elements are any JSON values: the field list of dynamic.Document has the type google.protobuf.ListValue
      #|a.yaml: /stubs/7/request/body/json/nothing: must be null: the field nothing of dynamic.Document has the type google.protobuf.NullValue
      #|a.yaml: /stubs/7/request/body/json/attachment: must be an object that gives the type URL of the message it holds as "@type": the field attachment of dynamic.Document has the type google.protobuf.Any
      #|a.yaml: /stubs/7/response/json/attachments/0: cannot be null: it is an element of the repeated field attachments of dynamic.Document
      #|a.yaml: /stubs/8/request/body/json/a: must be a JSON value: null, a number within the range of a double, a string, true or false, an object or an array: it is a value of a google.protobuf.Value
    ),
  )
}
