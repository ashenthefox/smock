// gRPC Stubs whose methods' types hold the well-known types that ProtoJSON
// prints in forms of their own, Timestamp, Duration, FieldMask, the
// wrappers and Empty: served on both sides, their `json` conditions checked
// against the printed forms and normalised, and their static replies
// encoded. The set is fixtures/protobuf/wellknown/wellknown.proto with
// protobuf's files beside it (wellknown_set_test.mbt), which
// scripts/gen-protobuf-fixtures.sh builds with protoc.

///|
/// Loads `a.yaml`, which declares the Mock `leases`, whose set is
/// wellknown.proto's, and then `stubs`, the lines of its `stubs` array.
/// Renders what the loader makes of them: every problem, one per line, as
/// `smock check` prints it; or, for a valid set, each Stub with its `json`
/// body condition as matching sees it and the reply message of each of its
/// responses, encoded at load, in hex.
fn leases(stubs : String) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: leases, grpc: { descriptorSet: wellknown.binpb } }
    #|stubs:
    #|
  match
    @definitions.load({
      files: [("a.yaml", @utf8.encode(yaml + stubs))],
      body_files: [("wellknown.binpb", set_bytes(wellknown_set))],
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
test "the ticket's example: a condition in the printed forms is kept, and {ttl: \"1.5s\"} is a problem that suggests \"1.500s\"" {
  inspect(
    leases(
      (
        #|  - id: example
        #|    mock: leases
        #|    request:
        #|      path: /wellknown.Leases/Open
        #|      body: { json: { created_at: "1970-01-01T00:00:01.500Z", ttl: "1.500s" } }
        #|    response: { json: { createdAt: "1970-01-01T00:00:01.5Z", ttl: 1.5s } }
      ),
    ),
    // protoc encodes the reply as 0a0808011080cab5ee01120808011080cab5ee01:
    // fixtures/protobuf/wellknown/lease.binpb.
    content=(
      #|example: {"createdAt":"1970-01-01T00:00:01.500Z","ttl":"1.500s"} [0a0808011080cab5ee01120808011080cab5ee01]
    ),
  )
  inspect(
    leases(
      (
        #|  - id: short
        #|    mock: leases
        #|    request: { path: /wellknown.Leases/Open, body: { json: { ttl: "1.5s" } } }
        #|    response: {}
        #|  - id: offset
        #|    mock: leases
        #|    request: { path: /wellknown.Leases/Open, body: { json: { createdAt: "1970-01-01T09:00:01.500+09:00" } } }
        #|    response: {}
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/body/json/ttl: must be written "1.500s", as smock prints it: the field ttl of wellknown.Lease has the type google.protobuf.Duration
      #|a.yaml: /stubs/1/request/body/json/createdAt: must be written "1970-01-01T00:00:01.500Z", as smock prints it: the field created_at of wellknown.Lease has the type google.protobuf.Timestamp
    ),
  )
}

///|
test "conditions on a FieldMask, the wrappers and Empty: a FloatValue is rounded as a float is, a wrapper is written as its value, and Empty is an object of no fields" {
  inspect(
    leases(
      (
        #|  - id: known
        #|    mock: leases
        #|    request:
        #|      path: /wellknown.Leases/Know
        #|      body:
        #|        json:
        #|          mask: userName,address.cityName
        #|          a_float: 16777217
        #|          aDouble: 1e21
        #|          an_int64: 9223372036854775807
        #|          a_bytes: "+/8="
        #|          a_bool: true
        #|          nothing: {}
        #|          ids: { $includes: 1e3 }
        #|          history: { $includes: { pattern: "^2025-" } }
        #|          limits: { read: "60s" }
        #|          ttl: { $exists: true }
        #|    response: {}
      ),
    ),
    content=(
      #|known: {"mask":"userName,address.cityName","aFloat":16777216,"aDouble":1e+21,"anInt64":9223372036854775807,"aBytes":"+/8=","aBool":true,"nothing":{},"ids":{"$includes":1000},"history":{"$includes":{"pattern":"^2025-"}},"limits":{"read":"60s"},"ttl":{"$exists":true}} []
    ),
  )
  inspect(
    leases(
      (
        #|  - id: unprinted
        #|    mock: leases
        #|    request:
        #|      path: /wellknown.Leases/Know
        #|      body:
        #|        json:
        #|          mask: user_name
        #|          aFloat: "9.99"
        #|          anInt64: "42"
        #|          aBytes: "-_8"
        #|          nothing: { x: 1 }
        #|          at: { seconds: 1 }
        #|          history: ["1970-01-01T00:00:00.000Z"]
        #|          limits: { read: 60.0s }
        #|          ids: { $includes: "1" }
        #|          ttl: null
        #|    response: {}
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/body/json/mask: must be a string of field paths in lowerCamelCase, joined by commas, such as "userName,address.city": the field mask of wellknown.Known has the type google.protobuf.FieldMask
      #|a.yaml: /stubs/0/request/body/json/aFloat: must be written 9.99, as smock prints it: the field a_float of wellknown.Known has the type google.protobuf.FloatValue
      #|a.yaml: /stubs/0/request/body/json/anInt64: must be written 42, as smock prints it: the field an_int64 of wellknown.Known has the type google.protobuf.Int64Value
      #|a.yaml: /stubs/0/request/body/json/aBytes: must be written "+/8=", as smock prints it: the field a_bytes of wellknown.Known has the type google.protobuf.BytesValue
      #|a.yaml: /stubs/0/request/body/json/nothing/x: is not a field of google.protobuf.Empty
      #|a.yaml: /stubs/0/request/body/json/at: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field at of wellknown.Known has the type google.protobuf.Timestamp
      #|a.yaml: /stubs/0/request/body/json/history/0: must be written "1970-01-01T00:00:00Z", as smock prints it: the elements of the field history of wellknown.Known have the type google.protobuf.Timestamp
      #|a.yaml: /stubs/0/request/body/json/limits/read: must be written "60s", as smock prints it: the values of the map field limits of wellknown.Known have the type google.protobuf.Duration
      #|a.yaml: /stubs/0/request/body/json/ids/$includes: must be written 1, as smock prints it: the elements of the field ids of wellknown.Known have the type google.protobuf.Int64Value
      #|a.yaml: /stubs/0/request/body/json/ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Known has the type google.protobuf.Duration
    ),
  )
}

///|
test "a well-known type as a method's whole input or output is served: its condition is checked in its form, and its static reply is encoded" {
  inspect(
    leases(
      (
        #|  - id: now
        #|    mock: leases
        #|    request: { path: /wellknown.Leases/Now, body: { json: {} } }
        #|    response: { json: "1970-01-01T00:00:01.5Z" }
        #|  - id: wait
        #|    mock: leases
        #|    request: { path: /wellknown.Leases/Wait, body: { json: "-0.500s" } }
        #|    response: {}
        #|  - id: scale
        #|    mock: leases
        #|    request: { path: /wellknown.Leases/Scale, body: { json: 16777217 } }
        #|    response: { json: 0.1 }
      ),
    ),
    content=(
      #|now: {} [08011080cab5ee01]
      #|wait: "-0.500s" []
      #|scale: 16777216 [0dcdcccc3d]
    ),
  )
  inspect(
    leases(
      (
        #|  - id: now
        #|    mock: leases
        #|    request: { path: /wellknown.Leases/Now, body: { json: { x: 1 } } }
        #|    response: { json: "1970-01-01T00:00:01.5+09:00" }
        #|  - id: wait
        #|    mock: leases
        #|    request: { path: /wellknown.Leases/Wait, body: { json: "1.5s" } }
        #|    response: { json: { x: 1 } }
        #|  - id: scale
        #|    mock: leases
        #|    request: { path: /wellknown.Leases/Scale, body: { json: { value: 1 } } }
        #|    response: { json: { value: 1 } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/body/json/x: is not a field of google.protobuf.Empty
      #|a.yaml: /stubs/1/request/body/json: must be written "1.500s", as smock prints it: the message is a google.protobuf.Duration
      #|a.yaml: /stubs/1/response/json/x: is not a field of google.protobuf.Empty
      #|a.yaml: /stubs/2/request/body/json: must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity": the message is a google.protobuf.FloatValue
      #|a.yaml: /stubs/2/response/json: must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity": the message is a google.protobuf.FloatValue
    ),
  )
}

///|
test "a static reply with a value out of its type's range, or in a form ProtoJSON does not read, is a problem at its pointer" {
  inspect(
    leases(
      (
        #|  - id: early
        #|    mock: leases
        #|    request: { path: /wellknown.Leases/Open }
        #|    response: { json: { createdAt: "0000-12-31T23:59:59Z" } }
        #|  - id: long
        #|    mock: leases
        #|    request: { path: /wellknown.Leases/Know }
        #|    responses:
        #|      - json: { limits: { read: "315576000001s" } }
        #|      - json: { anInt32: 2147483648 }
        #|      - json: { history: ["1970-01-01T00:00:00"] }
        #|      - json: { mask: "user_name" }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/response/json/createdAt: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field created_at of wellknown.Lease has the type google.protobuf.Timestamp
      #|a.yaml: /stubs/1/responses/0/json/limits/read: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the values of the map field limits of wellknown.Known have the type google.protobuf.Duration
      #|a.yaml: /stubs/1/responses/1/json/anInt32: must be an integer from -2147483648 to 2147483647: the field an_int32 of wellknown.Known has the type google.protobuf.Int32Value
      #|a.yaml: /stubs/1/responses/2/json/history/0: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the elements of the field history of wellknown.Known have the type google.protobuf.Timestamp
      #|a.yaml: /stubs/1/responses/3/json/mask: must be a string of field paths in lowerCamelCase, joined by commas, such as "userName,address.city": the field mask of wellknown.Known has the type google.protobuf.FieldMask
    ),
  )
}
