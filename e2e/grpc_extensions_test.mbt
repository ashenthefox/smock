// Seam 2 tests of gRPC Stubs on proto2 types with extensions and groups,
// over h2c and through `smock check`: extensions in requests, conditions
// and replies under their `[full.name]` keys, groups in both directions,
// and a group whose end does not match. The set is
// fixtures/protobuf/extensions/shop.proto, and the messages are what
// protoc encodes from the .txtpb files beside it
// (scripts/gen-protobuf-fixtures.sh), so the codec is never checked
// against itself.

///|
/// The directory of the extensions fixtures.
let extensions_dir : String = "fixtures/protobuf/extensions"

///|
/// The message that protoc encoded from `<name>.txtpb` in the extensions
/// fixtures, unframed.
async fn shop_message(name : String) -> Bytes {
  @fs.read_file("\{extensions_dir}/\{name}.binpb").binary()
}

///|
/// Runs `f` with a definitions directory holding `shop.yaml`, which
/// declares the Mock `shop`, whose set is shop.proto's, then holds `stubs`,
/// the lines of its `stubs` array; and with the set at `files/shop.binpb`.
async fn with_shop(stubs : String, f : async (String) -> Unit) -> Unit {
  let yaml =
    #|mocks:
    #|  - name: shop
    #|    grpc: { descriptorSet: shop.binpb }
    #|stubs:
    #|
  with_definitions([("shop.yaml", yaml + stubs)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/shop.binpb",
      @fs.read_file("\{extensions_dir}/shop.binpb").binary(),
    )
    f(dir)
  })
}

///|
async test "the ticket's example: an Order with shop.priority set to 3 is journaled as {\"id\":7,\"[shop.priority]\":3} and meets the condition {\"[shop.priority]\": 3}; a reply sets the same key, with protoc's bytes" {
  let stubs =
    #|  - id: example
    #|    mock: shop
    #|    request: { path: /shop.Orders/Place, body: { json: { "[shop.priority]": 3 } } }
    #|    response: { json: { id: 7, "[shop.priority]": 3 } }
    #|  - id: templated
    #|    mock: shop
    #|    request: { path: /shop.Orders/Place, headers: { x-case: templated } }
    #|    response: { template: true, json: { id: "${body.id}", "[shop.priority]": "${body['[shop.priority]']}" } }
  with_shop(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call(
        "/shop.Orders/Place",
        body=framed(shop_message("order")),
      )
      inspect(
        reply.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: shop; via=default
          #|  date: <now>
          #|DATA 00000000050807a00603
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
        ),
      )
      // The reply is protoc's encoding of order.txtpb.
      inspect(reply.data == [framed(shop_message("order"))], content="true")
      // order-full.txtpb sets shop.priority to -2, so it meets the
      // templated Stub alone, whose reply sets the key from the call's own:
      // id 8, then field 100 holding -2.
      let templated = client.call(
        "/shop.Orders/Place",
        headers=[("x-case", "templated")],
        body=framed(shop_message("order-full")),
      )
      inspect(
        templated.data.map(hex).join(" "),
        content="000000000e0808a006feffffffffffffffff01",
      )
      // Without the header, it meets no Stub.
      let unmatched = client.call(
        "/shop.Orders/Place",
        body=framed(shop_message("order-full")),
      )
      inspect(unmatched.status(), content="12")
      inspect(
        smock.bodies(),
        content=(
          #|"example": {"id":7,"[shop.priority]":3}
          #|"templated": {"id":8,"note":"gift","[shop.priority]":-2,"[shop.codes]":["a",""],"[shop.label]":{"text":"fragile"},"[shop.Gift.gift]":{"wrap":"red"},"urgent":true}
          #|null: {"id":8,"note":"gift","[shop.priority]":-2,"[shop.codes]":["a",""],"[shop.label]":{"text":"fragile"},"[shop.Gift.gift]":{"wrap":"red"},"urgent":true}
        ),
      )
      let (_, journal) = smock.journal()
      guard journal
        is Object(
          { "entries": [_, _, Object({ "nearMiss": near_miss, .. })], .. }
        ) else {
        fail("not three entries: \{journal.stringify()}")
      }
      inspect(
        near_miss.stringify(),
        content=(
          #|{"stub":"example","stubSource":"file","failed":[{"condition":"body","expected":{"json":{"[shop.priority]":3}},"actual":["{\"id\":8,\"note\":\"gift\",\"[shop.priority]\":-2,\"[shop.codes]\":[\"a\",\"\"],\"[shop.label]\":{\"text\":\"fragile\"},\"[shop.Gift.gift]\":{\"wrap\":\"red\"},\"urgent\":true}"]}]}
        ),
      )
    })
  })
}

///|
async test "extensions of every kind meet conditions on them, and a reply that sets each, its keys in any order, has protoc's bytes" {
  let stubs =
    #|  - id: full
    #|    mock: shop
    #|    request:
    #|      path: /shop.Orders/Place
    #|      body:
    #|        json:
    #|          "[shop.codes]": { $includes: "" }
    #|          "[shop.label]": { text: fragile }
    #|          "[shop.Gift.gift]": { wrap: red }
    #|    response:
    #|      json:
    #|        urgent: true
    #|        "[shop.Gift.gift]": { wrap: red }
    #|        "[shop.label]": { text: fragile }
    #|        "[shop.codes]": [a, ""]
    #|        "[shop.priority]": -2
    #|        note: gift
    #|        id: "8"
  with_shop(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call(
        "/shop.Orders/Place",
        body=framed(shop_message("order-full")),
      )
      inspect(reply.status(), content="0")
      // The reply is protoc's encoding of order-full.txtpb: the extensions
      // in field-number order among the fields.
      inspect(
        reply.data.map(hex).join(" "),
        content="00000000330808120467696674a006feffffffffffffffff01aa060161aa0600b3060a0766726167696c65b406f206050a03726564c00c01",
      )
      inspect(
        reply.data == [framed(shop_message("order-full"))],
        content="true",
      )
    })
  })
}

///|
async test "groups decode and encode in both directions, repeated and nested; a group whose end does not match makes the message not parse, so the call gets INTERNAL and no Journal entry" {
  let stubs =
    #|  - id: tour
    #|    mock: shop
    #|    request:
    #|      path: /shop.Orders/Plan
    #|      body: { json: { stop: { $includes: { city: Paris, window: { opens: 9 } } }, note: { text: by train } } }
    #|    response:
    #|      json:
    #|        name: tour
    #|        stop: [{ city: Paris, window: { opens: 9, closes: 17 } }, { city: Lyon }]
    #|        note: { text: by train }
  with_shop(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let itinerary = shop_message("itinerary")
      let reply = client.call("/shop.Orders/Plan", body=framed(itinerary))
      inspect(reply.status(), content="0")
      // The reply is protoc's encoding of itinerary.txtpb.
      inspect(reply.data == [framed(itinerary)], content="true")
      inspect(
        smock.bodies(),
        content=(
          #|"tour": {"name":"tour","stop":[{"city":"Paris","window":{"opens":9,"closes":17}},{"city":"Lyon"}],"note":{"text":"by train"}}
        ),
      )
      // itinerary.txtpb with the end of the first Window, 0x24, made the
      // end of field 5, 0x2c.
      let broken = Bytes::makei(itinerary.length(), i => {
        if itinerary[i] == b'\x24' {
          b'\x2c'
        } else {
          itinerary[i]
        }
      })
      inspect(
        client.call("/shop.Orders/Plan", body=framed(broken)).render(),
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
      let (_, page) = smock.journal()
      inspect(
        answers(page),
        content=(
          #|"tour" 200 "OK"
        ),
      )
      inspect(
        smock.metric("smock_requests_total"),
        content=(
          #|smock_requests_total{mock="shop",stub="tour"} 1
          #|smock_requests_total{mock="",stub=""} 1
        ),
      )
    })
  })
}

///|
async test "smock check refuses a [full.name] key that names no extension of the set, or one that extends another type, in a condition and in a reply" {
  let stubs =
    #|  - id: unknown
    #|    mock: shop
    #|    request: { path: /shop.Orders/Place, body: { json: { "[shop.urgency]": 1 } } }
    #|    response: { json: { id: 7, "[shop.urgency]": 1 } }
    #|  - id: another-type
    #|    mock: shop
    #|    request: { path: /shop.Orders/Plan, body: { json: { "[shop.priority]": 3 } } }
    #|    response: { json: { note: { "[shop.priority]": 3 } } }
  with_shop(stubs, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|shop.yaml: /stubs/0/request/body/json/[shop.urgency]: is not an extension of shop.Order: the Descriptor set has no extension shop.urgency
        #|shop.yaml: /stubs/0/response/json/[shop.urgency]: is not an extension of shop.Order: the Descriptor set has no extension shop.urgency
        #|shop.yaml: /stubs/1/request/body/json/[shop.priority]: is not an extension of shop.Itinerary: shop.priority extends shop.Order
        #|shop.yaml: /stubs/1/response/json/note/[shop.priority]: is not an extension of shop.Itinerary.Note: shop.priority extends shop.Order
        #|
      ),
    )
  })
}
