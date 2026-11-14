// gRPC Stubs on methods whose types have extensions and groups, at load:
// conditions and replies may give an extension under its `[full.name]`
// key, which must name an extension of the set that extends the type at
// its place; groups are checked as messages. The sets are
// fixtures/protobuf/extensions/shop.proto (extensions_set_test.mbt) and
// edition.proto, which extends shop.Order from an editions file
// (edition_extensions_set_test.mbt).

///|
/// Loads `a.yaml`, which declares the Mock `shop`, whose set is shop.proto,
/// and the Mock `edition`, whose set is edition.proto's, and then `stubs`,
/// the lines of its `stubs` array. Renders what the loader makes of them:
/// every problem, one per line, as `smock check` prints it; or, for a valid
/// set, each Stub's `json` body condition as matching sees it.
fn shop_conditions(stubs : String) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: shop, grpc: { descriptorSet: shop.binpb } }
    #|  - { name: edition, grpc: { descriptorSet: edition.binpb } }
    #|stubs:
    #|
  match
    @definitions.load({
      files: [("a.yaml", @utf8.encode(yaml + stubs))],
      body_files: [
        ("shop.binpb", set_bytes(extensions_set)),
        ("edition.binpb", set_bytes(edition_extensions_set)),
      ],
    }) {
    Ok(snapshot) => {
      let lines = []
      for mock in snapshot.mocks {
        for stub in mock.stubs {
          let condition = match stub.serves {
            Ordinary({ request: { body: Some(Json(condition)), .. }, .. }) =>
              condition.to_json().stringify()
            _ => "no json condition"
          }
          lines.push("\{stub.id}: \{condition}")
        }
      }
      lines.join("\n")
    }
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
test "the ticket's example: a condition and a reply may give the extension shop.priority under its [full.name] key" {
  inspect(
    shop_conditions(
      (
        #|  - id: example
        #|    mock: shop
        #|    request: { path: /shop.Orders/Place, body: { json: { "[shop.priority]": 3 } } }
        #|    response: { json: { id: 7, "[shop.priority]": 3 } }
      ),
    ),
    content=(
      #|example: {"[shop.priority]":3}
    ),
  )
}

///|
test "an extension's value is checked and normalised at its place, as a field's is, and groups are messages" {
  inspect(
    shop_conditions(
      (
        #|  - id: every-kind
        #|    mock: shop
        #|    request:
        #|      path: /shop.Orders/Place
        #|      body:
        #|        json:
        #|          "[shop.priority]": 1e1
        #|          "[shop.codes]": { $includes: a }
        #|          "[shop.label]": { text: { pattern: "^frag" } }
        #|          "[shop.Gift.gift]": { wrap: red }
        #|          urgent: true
        #|    response: { json: { "[shop.codes]": [a, b], "[shop.label]": {}, "[shop.Gift.gift]": { wrap: red } } }
        #|  - id: groups
        #|    mock: shop
        #|    request:
        #|      path: /shop.Orders/Plan
        #|      body: { json: { stop: [{ city: Paris, window: { opens: 9 } }], note: { text: { $exists: true } } } }
        #|    response: { json: { stop: [{ city: Lyon, window: {} }], note: { text: x } } }
      ),
    ),
    content=(
      #|every-kind: {"[shop.priority]":10,"[shop.codes]":{"$includes":"a"},"[shop.label]":{"text":{"pattern":"^frag"}},"[shop.Gift.gift]":{"wrap":"red"},"urgent":true}
      #|groups: {"stop":[{"city":"Paris","window":{"opens":9}}],"note":{"text":{"$exists":true}}}
    ),
  )
}

///|
test "a [full.name] key that names no extension of the set, or one that extends another type, is a problem in a condition and in a reply" {
  inspect(
    shop_conditions(
      (
        #|  - id: unknown
        #|    mock: shop
        #|    request: { path: /shop.Orders/Place, body: { json: { "[shop.urgency]": 1 } } }
        #|    response: { json: { "[shop.urgency]": 1 } }
        #|  - id: another-type
        #|    mock: shop
        #|    request: { path: /shop.Orders/Plan, body: { json: { note: {}, "[shop.priority]": 1 } } }
        #|    response: { json: { "[shop.priority]": 1 } }
        #|  - id: values
        #|    mock: shop
        #|    request: { path: /shop.Orders/Place, body: { json: { "[shop.priority]": "3", "[shop.codes]": [1], "[shop.Gift.gift]": { wrap: 1 } } } }
        #|    response: { json: {} }
        #|  - id: unbracketed
        #|    mock: shop
        #|    request: { path: /shop.Orders/Place, body: { json: { priority: 3 } } }
        #|    response: { json: {} }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/body/json/[shop.urgency]: is not an extension of shop.Order: the Descriptor set has no extension shop.urgency
      #|a.yaml: /stubs/0/response/json/[shop.urgency]: is not an extension of shop.Order: the Descriptor set has no extension shop.urgency
      #|a.yaml: /stubs/1/request/body/json/[shop.priority]: is not an extension of shop.Itinerary: shop.priority extends shop.Order
      #|a.yaml: /stubs/1/response/json/[shop.priority]: is not an extension of shop.Itinerary: shop.priority extends shop.Order
      #|a.yaml: /stubs/2/request/body/json/[shop.priority]: must be written 3, as smock prints it: the extension shop.priority of shop.Order has the type int32
      #|a.yaml: /stubs/2/request/body/json/[shop.codes]/0: must be a string of Unicode text: the elements of the extension shop.codes of shop.Order have the type string
      #|a.yaml: /stubs/2/request/body/json/[shop.Gift.gift]/wrap: must be a string of Unicode text: the field wrap of shop.Gift has the type string
      #|a.yaml: /stubs/3/request/body/json/priority: is not a field of shop.Order
    ),
  )
}

///|
test "a method whose types are extended from an editions file is a load error, as a type of an editions file is; one whose types are not loads" {
  inspect(
    shop_conditions(
      (
        #|  - id: place
        #|    mock: edition
        #|    request: { path: /shop.Orders/Place }
        #|    response: { json: { id: 7 } }
        #|  - id: plan
        #|    mock: edition
        #|    request: { path: /shop.Orders/Plan }
        #|    response: { json: {} }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/path: the input type shop.Order is not served yet: edition.proto, which declares shop.edition.counts, an extension of it, is an editions file, and editions come in a later spec
      #|a.yaml: /stubs/0/request/path: the output type shop.Order is not served yet: edition.proto, which declares shop.edition.counts, an extension of it, is an editions file, and editions come in a later spec
    ),
  )
}
