// Seam 2 tests of gRPC Stubs on proto2 types over h2c: required fields in
// requests and replies, presence, closed enums, packing and strings that
// are not UTF-8; and `smock check` on methods whose types reach a type of
// an editions file, a MessageSet, a group or an extended type. The set is
// fixtures/protobuf/shipping/shipping.proto, and the messages are what
// protoc encodes from the .txtpb files beside it
// (scripts/gen-protobuf-fixtures.sh), so the codec is never checked
// against itself.

///|
/// The directory of the shipping fixtures.
let shipping_dir : String = "fixtures/protobuf/shipping"

///|
/// The message that protoc encoded from `<name>.txtpb` in the shipping
/// fixtures, unframed.
async fn shipping_message(name : String) -> Bytes {
  @fs.read_file("\{shipping_dir}/\{name}.binpb").binary()
}

///|
/// Runs `f` with a definitions directory holding `shipping.yaml`, which
/// declares the Mock `shipping`, whose set is shipping.proto's, then holds
/// `stubs`, the lines of its `stubs` array; and with the set at
/// `files/shipping.binpb`.
async fn with_shipping(stubs : String, f : async (String) -> Unit) -> Unit {
  let yaml =
    #|mocks:
    #|  - name: shipping
    #|    grpc: { descriptorSet: shipping.binpb }
    #|stubs:
    #|
  with_definitions([("shipping.yaml", yaml + stubs)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/shipping.binpb",
      @fs.read_file("\{shipping_dir}/shipping.binpb").binary(),
    )
    f(dir)
  })
}

///|
async test "the ticket's example: an Order with the id 7 and no note is journaled as {\"id\":7}; one without the required id gets INTERNAL and is not journaled; a templated reply without it gets INTERNAL with templateError" {
  let stubs =
    #|  - id: templated
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Place, headers: { x-tenant: templated } }
    #|    response: { template: true, json: { note: "for ${body.id}" } }
    #|  - id: place
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Place, body: { json: { id: 7, note: { $exists: false } } } }
    #|    response: { json: { id: 7 } }
  with_shipping(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call(
        "/shipping.Orders/Place",
        body=framed(shipping_message("order")),
      )
      inspect(
        reply.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: shipping; via=default
          #|  date: <now>
          #|DATA 00000000020807
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
        ),
      )
      // The reply is protoc's encoding of order.txtpb, id 7.
      inspect(
        reply.data == [framed(shipping_message("order"))],
        content="true",
      )
      inspect(
        smock.bodies(),
        content=(
          #|"place": {"id":7}
        ),
      )
      // draft.txtpb: an Order without its id.
      inspect(
        client
        .call("/shipping.Orders/Place", body=framed(shipping_message("draft")))
        .render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: the request message cannot be decoded
          #|  date: <now>
          #|(end)
        ),
      )
      inspect(
        smock.metric("smock_requests_total"),
        content=(
          #|smock_requests_total{mock="shipping",stub="place"} 1
          #|smock_requests_total{mock="",stub=""} 1
        ),
      )
      inspect(
        client
        .call(
          "/shipping.Orders/Place",
          headers=[("x-tenant", "templated")],
          body=framed(shipping_message("order")),
        )
        .render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: template failed
          #|  smock-mock: shipping; via=default
          #|  date: <now>
          #|(end)
        ),
      )
      let (_, page) = smock.journal()
      inspect(
        answers(page),
        content=(
          #|"place" 200 "OK"
          #|"templated" 200 "INTERNAL" x-tenant=templated templateError={"at":"/response/json","message":"lacks the required field id of shipping.Order"}
        ),
      )
    })
  })
}

///|
async test "proto2 fields are journaled only when set; an unknown number of a closed enum is skipped, so matching never sees it; requests may pack scalars or not; strings that are not UTF-8 print with U+FFFD" {
  let stubs =
    #|  - id: by-post
    #|    mock: shipping
    #|    request:
    #|      path: /shipping.Orders/Track
    #|      body: { json: { carrierName: post, state: SHIPPED, label: { $exists: false } } }
    #|    response: { json: {} }
    #|  - id: any-parcel
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Track }
    #|    response: { json: {} }
  with_shipping(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let calls = [
        framed(shipping_message("parcel")),
        framed(b""),
        // parcel-unknown.txtpb then carrier-unknown.txtpb, which protobuf's
        // parsers read as one message.
        framed(
          shipping_message("parcel-unknown") +
          shipping_message("carrier-unknown"),
        ),
        framed(shipping_message("parcel-unpacked")),
        framed(shipping_message("parcel-not-utf8")),
      ]
      for call in calls {
        let reply = client.call("/shipping.Orders/Track", body=call)
        guard reply.trailers is Some([("grpc-status", "0")]) else {
          fail(reply.render())
        }
      }
      inspect(
        smock.bodies(),
        content=(
          #|"any-parcel": {"state":"SHIPPED","history":["NEW","DELIVERED"],"weights":[1,300],"sizes":[3,4],"order":{"id":7},"orders":[{"id":8,"note":""},{"id":-1}],"states":{"a":"NEW","b":"DELIVERED"},"label":"","tags":["x",""],"notes":{"k":"v"},"fragile":false,"count":0,"carrierName":"post","byId":{"2":{"id":2}}}
          #|"any-parcel": {"history":[],"weights":[],"sizes":[],"orders":[],"states":{},"tags":[],"notes":{},"byId":{}}
          #|"by-post": {"state":"SHIPPED","history":["NEW","DELIVERED"],"weights":[],"sizes":[],"orders":[],"states":{"a":"SHIPPED"},"tags":[],"notes":{},"carrierName":"post","byId":{}}
          #|"any-parcel": {"history":[],"weights":[],"sizes":[3,4],"orders":[],"states":{},"tags":[],"notes":{},"byId":{}}
          #|"any-parcel": {"history":[],"weights":[],"sizes":[],"orders":[],"states":{},"label":"a�(b","tags":["��","ok"],"notes":{"�":"�"},"byId":{}}
        ),
      )
    })
  })
}

///|
async test "a reply of a proto2 type has protoc's bytes: fields written whenever set, at their defaults too, repeated scalars packed only with packed = true" {
  let stubs =
    #|  - id: parcel
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Track }
    #|    response:
    #|      json:
    #|        state: SHIPPED
    #|        history: [NEW, 2]
    #|        weights: [1, 300]
    #|        sizes: [3, 4]
    #|        order: { id: 7 }
    #|        orders: [{ id: "8", note: "" }, { id: -1 }]
    #|        states: { b: DELIVERED, a: NEW }
    #|        label: ""
    #|        tags: [x, ""]
    #|        notes: { k: v }
    #|        fragile: false
    #|        count: 0
    #|        carrier_name: post
    #|        byId: { "2": { id: 2 } }
  with_shipping(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call("/shipping.Orders/Track", body=framed(b""))
      // weights, field 3, unpacked: 18 01 18 ac02; sizes, field 4, packed:
      // 22 02 03 04.
      inspect(
        reply.data.map(hex).join(" "),
        content="0000000055080110001002180118ac02220203042a020807320408081200320b08ffffffffffffffffff013a050a016110003a050a0162100242004a01784a0052060a016b120176580060007204706f73747a06080212020802",
      )
      inspect(
        reply.data == [framed(shipping_message("parcel"))],
        content="true",
      )
    })
  })
}

///|
async test "smock check refuses a static reply without a required field and numbers a closed enum does not define, and methods whose types reach an editions file, a MessageSet, a group or an extended type; editions files that no Stub uses load quietly" {
  let stubs =
    #|  - id: no-id
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Place }
    #|    response: { json: { note: no id } }
    #|  - id: unknown-state
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Track, body: { json: { state: 9 } } }
    #|    response: { json: { orders: [{ id: 1 }, {}], states: { a: 7 } } }
    #|  - id: print
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Print }
    #|    response: { json: {} }
    #|  - id: scan
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Scan }
    #|    response: { json: { id: 1 } }
    #|  - id: pack
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Pack }
    #|    response: { json: { id: 1 } }
    #|  - id: plan
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Plan }
    #|    response: { json: { id: 1 } }
    #|  - id: stamp
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Stamp }
    #|    response: { json: {} }
  with_shipping(stubs, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|shipping.yaml: /stubs/0/response/json: lacks the required field id of shipping.Order
        #|shipping.yaml: /stubs/1/request/body/json/state: must be the name or the number of a value of shipping.State: the field state of shipping.Parcel has the type shipping.State
        #|shipping.yaml: /stubs/1/response/json/orders/1: lacks the required field id of shipping.Order
        #|shipping.yaml: /stubs/2/request/path: the output type shipping.Sheet is not served yet: labels.proto, which defines labels.Color, a type it reaches, is an editions file, and editions come in a later spec
        #|shipping.yaml: /stubs/2/request/path: the output type shipping.Sheet is not served yet: labels.proto, which defines labels.Label, a type it reaches, is an editions file, and editions come in a later spec
        #|shipping.yaml: /stubs/3/request/path: the input type labels.Label is not served yet: labels.proto, which defines it, is an editions file, and editions come in a later spec
        #|shipping.yaml: /stubs/4/request/path: the input type shipping.Crate is not served: shipping.Bag, a type it reaches, is a MessageSet, whose extensions use another wire form, and smock serves no MessageSet types
        #|shipping.yaml: /stubs/5/request/path: the input type shipping.Itinerary is not served yet: its field stop is a group, and gRPC Stubs serve no groups so far
        #|shipping.yaml: /stubs/6/request/path: the output type shipping.Stamped is not served yet: it is extended by an extension of the set, and gRPC Stubs serve no extended types so far
        #|
      ),
    )
  })
  // The set holds labels.proto, an editions file, and types no Stub uses.
  let stubs =
    #|  - id: place
    #|    mock: shipping
    #|    request: { path: /shipping.Orders/Place }
    #|    response: { json: { id: 7 } }
  with_shipping(stubs, dir => inspect(check([dir]), content="status 0\n"))
}
