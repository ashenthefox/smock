// Seam 2 tests of the well-known types that ProtoJSON prints in forms of
// their own, Timestamp, Duration, FieldMask, the wrappers and Empty, over
// h2c and through `smock check`: requests journaled and matched in their
// printed forms, and replies read in every form ProtoJSON reads. The set is
// fixtures/protobuf/wellknown/wellknown.proto with protobuf's files beside
// it, and the requests and the replies compared are what protoc encodes
// from the .txtpb files there (scripts/gen-protobuf-fixtures.sh), so the
// codec is never checked against itself.

///|
async test "the ticket's example: a Timestamp 1.5 s after the epoch and a Duration of 1.5 s are journaled in their printed forms and meet a condition written so; a reply in other forms has protoc's bytes" {
  let stubs =
    #|  - id: example
    #|    mock: leases
    #|    request:
    #|      path: /wellknown.Leases/Open
    #|      body: { json: { createdAt: "1970-01-01T00:00:01.500Z", ttl: "1.500s" } }
    #|    response: { json: { created_at: "1970-01-01T09:00:01.5+09:00", ttl: 1.5s } }
  with_leases(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call(
        "/wellknown.Leases/Open",
        body=wellknown_message("lease"),
      )
      inspect(
        "\{reply.status()} \{reply.data == [wellknown_message("lease")]}",
        content="0 true",
      )
      inspect(
        smock.bodies(),
        content=(
          #|"example": {"createdAt":"1970-01-01T00:00:01.500Z","ttl":"1.500s"}
        ),
      )
    })
  })
}

///|
async test "every type in its printed form, from protoc-encoded requests, meets conditions written so, a FloatValue's in its short form among them, and replies in other forms have protoc's bytes" {
  let stubs =
    #|  - id: known
    #|    mock: leases
    #|    request:
    #|      path: /wellknown.Leases/Know
    #|      body:
    #|        json:
    #|          at: "2025-11-14T09:30:00.123456Z"
    #|          ttl: "-3.250s"
    #|          mask: userName,address.cityName
    #|          aFloat: 9.99
    #|          an_int64: 9223372036854775807
    #|          aBytes: "+/8="
    #|          nothing: {}
    #|          history: { $includes: "9999-12-31T23:59:59.999999999Z" }
    #|          limits: { write: "0.000001s" }
    #|          ids: [1, 0]
    #|    response:
    #|      json:
    #|        at: "2025-11-14T18:30:00.123456+09:00"
    #|        ttl: "-3.25s"
    #|        mask: userName,address.cityName
    #|        aDouble: "1.5"
    #|        a_float: 9.99
    #|        anInt64: "9223372036854775807"
    #|        aUint64: "18446744073709551615"
    #|        anInt32: -2147483648
    #|        aUint32: 4294967295
    #|        aBool: true
    #|        aString: Tom
    #|        aBytes: "-_8"
    #|        nothing: {}
    #|        history: ["0001-01-01T00:00:00.000Z", "9999-12-31T23:59:59.999999999Z"]
    #|        limits: { read: "315576000000.999999999s", write: "0.000001000s" }
    #|        ids: ["1", 0]
    #|  - id: defaults
    #|    mock: leases
    #|    request:
    #|      path: /wellknown.Leases/Know
    #|      body: { json: { at: "1970-01-01T00:00:00Z", ttl: "0s", mask: "", aFloat: 0, aString: "", nothing: {} } }
    #|    response:
    #|      json:
    #|        at: "1970-01-01T00:00:00Z"
    #|        ttl: "0s"
    #|        mask: ""
    #|        aDouble: 0
    #|        aFloat: 0
    #|        anInt64: 0
    #|        aUint64: 0
    #|        anInt32: 0
    #|        aUint32: 0
    #|        aBool: false
    #|        aString: ""
    #|        aBytes: ""
    #|        nothing: {}
    #|  - id: none
    #|    mock: leases
    #|    request:
    #|      path: /wellknown.Leases/Know
    #|      body: { json: { at: { $exists: false }, history: [] } }
    #|    response: { json: { at: null, ttl: null } }
  with_leases(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for name in ["known", "known-defaults"] {
        let reply = client.call(
          "/wellknown.Leases/Know",
          body=wellknown_message(name),
        )
        let same = reply.data == [wellknown_message(name)]
        out.push(
          "\{name}: \{if same { "protoc's bytes" } else { reply.render() }}",
        )
      }
      // A Known that leaves every field out.
      let reply = client.call("/wellknown.Leases/Know", body=framed(b""))
      out.push("empty: DATA \{reply.data.map(hex).join(" ")}")
      inspect(
        out.join("\n"),
        content=(
          #|known: protoc's bytes
          #|known-defaults: protoc's bytes
          #|empty: DATA 0000000000
        ),
      )
      inspect(
        smock.bodies(),
        content=(
          #|"known": {"at":"2025-11-14T09:30:00.123456Z","ttl":"-3.250s","mask":"userName,address.cityName","aDouble":1.5,"aFloat":9.99,"anInt64":9223372036854775807,"aUint64":18446744073709551615,"anInt32":-2147483648,"aUint32":4294967295,"aBool":true,"aString":"Tom","aBytes":"+/8=","nothing":{},"history":["0001-01-01T00:00:00Z","9999-12-31T23:59:59.999999999Z"],"limits":{"read":"315576000000.999999999s","write":"0.000001s"},"ids":[1,0]}
          #|"defaults": {"at":"1970-01-01T00:00:00Z","ttl":"0s","mask":"","aDouble":0,"aFloat":0,"anInt64":0,"aUint64":0,"anInt32":0,"aUint32":0,"aBool":false,"aString":"","aBytes":"","nothing":{},"history":[],"limits":{},"ids":[]}
          #|"none": {"history":[],"limits":{},"ids":[]}
        ),
      )
    })
  })
}

///|
async test "a well-known type as a method's whole input or output is journaled, matched and encoded in its form: an Empty request, a Duration, and a FloatValue met by its short form" {
  let stubs =
    #|  - id: now
    #|    mock: leases
    #|    request: { path: /wellknown.Leases/Now, body: { json: {} } }
    #|    response: { json: "1970-01-01T00:00:01.5Z" }
    #|  - id: wait
    #|    mock: leases
    #|    request: { path: /wellknown.Leases/Wait, body: { json: "-0.500s" } }
    #|    response: { json: {} }
    #|  - id: scale
    #|    mock: leases
    #|    request: { path: /wellknown.Leases/Scale, body: { json: 0.1 } }
    #|    response: { json: "0.1" }
  with_leases(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let now = client.call("/wellknown.Leases/Now", body=framed(b""))
      let wait = client.call(
        "/wellknown.Leases/Wait",
        body=wellknown_message("wait"),
      )
      let scale = client.call(
        "/wellknown.Leases/Scale",
        body=wellknown_message("scale"),
      )
      inspect(
        [
          "now: \{now.status()} \{now.data == [wellknown_message("now")]}",
          "wait: \{wait.status()} DATA \{wait.data.map(hex).join(" ")}",
          "scale: \{scale.status()} \{scale.data == [wellknown_message("scale")]}",
        ].join("\n"),
        content=(
          #|now: 0 true
          #|wait: 0 DATA 0000000000
          #|scale: 0 true
        ),
      )
      inspect(
        smock.bodies(),
        content=(
          #|"now": {}
          #|"wait": "-0.500s"
          #|"scale": 0.1
        ),
      )
    })
  })
}

///|
async test "a templated reply renders a request's Timestamp and Duration and is read in any form; one out of its type's range gets INTERNAL template failed, with templateError; a request out of range does not decode" {
  let stubs =
    #|  - id: echo
    #|    mock: leases
    #|    request: { path: /wellknown.Leases/Open, headers: { x-case: echo } }
    #|    response: { template: true, json: { createdAt: "${body.createdAt}", ttl: "${header.x-ttl}" } }
  with_leases(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let echo = client.call(
        "/wellknown.Leases/Open",
        headers=[("x-case", "echo"), ("x-ttl", "1.5s")],
        body=wellknown_message("lease"),
      )
      let too_long = client.call(
        "/wellknown.Leases/Open",
        headers=[("x-case", "echo"), ("x-ttl", "315576000001s")],
        body=wellknown_message("lease"),
      )
      let too_late = client.call(
        "/wellknown.Leases/Open",
        headers=[("x-case", "echo"), ("x-ttl", "1s")],
        body=wellknown_message("lease-too-late"),
      )
      inspect(
        [
          "echo: \{echo.status()} \{echo.data == [wellknown_message("lease")]}",
          "too long: \{too_long.render()}",
          "too late: \{too_late.render()}",
        ].join("\n"),
        content=(
          #|echo: 0 true
          #|too long: HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: template failed
          #|  smock-mock: leases; via=default
          #|  date: <now>
          #|(end)
          #|too late: HEADERS
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
          #|"echo" 200 "INTERNAL" templateError={"at":"/response/json/ttl","message":"must be a duration from \"-315576000000.999999999s\" to \"315576000000.999999999s\": seconds, with at most 9 fractional digits, then \"s\", such as \"1.500s\": the field ttl of wellknown.Lease has the type google.protobuf.Duration"}
        ),
      )
    })
  })
}

///|
async test "smock check refuses a condition that ProtoJSON reads but smock never prints, naming the printed form: a Duration of \"1.5s\" and a Timestamp with the offset +09:00; and a reply out of its type's range" {
  let stubs =
    #|  - id: short
    #|    mock: leases
    #|    request: { path: /wellknown.Leases/Open, body: { json: { ttl: "1.5s" } } }
    #|    response: {}
    #|  - id: offset
    #|    mock: leases
    #|    request: { path: /wellknown.Leases/Open, body: { json: { created_at: "1970-01-01T09:00:01.5+09:00" } } }
    #|    response: {}
    #|  - id: rounded
    #|    mock: leases
    #|    request: { path: /wellknown.Leases/Know, body: { json: { aFloat: "9.99", anInt64: "42" } } }
    #|    response: {}
    #|  - id: late
    #|    mock: leases
    #|    request: { path: /wellknown.Leases/Open }
    #|    response: { json: { createdAt: "10000-01-01T00:00:00Z" } }
    #|  - id: long
    #|    mock: leases
    #|    request: { path: /wellknown.Leases/Open }
    #|    responses: [{ json: { ttl: "-315576000001s" } }]
    #|  - id: scale
    #|    mock: leases
    #|    request: { path: /wellknown.Leases/Scale }
    #|    response: { json: 1e39 }
  with_leases(stubs, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|leases.yaml: /stubs/0/request/body/json/ttl: must be written "1.500s", as smock prints it: the field ttl of wellknown.Lease has the type google.protobuf.Duration
        #|leases.yaml: /stubs/1/request/body/json/created_at: must be written "1970-01-01T00:00:01.500Z", as smock prints it: the field created_at of wellknown.Lease has the type google.protobuf.Timestamp
        #|leases.yaml: /stubs/2/request/body/json/aFloat: must be written 9.99, as smock prints it: the field a_float of wellknown.Known has the type google.protobuf.FloatValue
        #|leases.yaml: /stubs/2/request/body/json/anInt64: must be written 42, as smock prints it: the field an_int64 of wellknown.Known has the type google.protobuf.Int64Value
        #|leases.yaml: /stubs/3/response/json/createdAt: must be a date and time in RFC 3339 form, from "0001-01-01T00:00:00Z" to "9999-12-31T23:59:59.999999999Z", such as "1970-01-01T00:00:01.500Z": the field created_at of wellknown.Lease has the type google.protobuf.Timestamp
        #|leases.yaml: /stubs/4/responses/0/json/ttl: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field ttl of wellknown.Lease has the type google.protobuf.Duration
        #|leases.yaml: /stubs/5/response/json: must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity": the message is a google.protobuf.FloatValue
        #|
      ),
    )
  })
}
