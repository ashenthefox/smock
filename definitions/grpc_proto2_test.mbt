// gRPC Stubs on methods whose types come from proto2 files, at load: they
// are served, with their required fields checked in static replies and
// closed enums in conditions, groups and extended types included; a type
// of an editions file and a MessageSet are load errors, per method. The
// set is
// fixtures/protobuf/shipping/shipping.proto (shipping_set_test.mbt), which
// imports labels.proto, an editions file.

///|
/// Loads `a.yaml`, which declares the Mock `shipping`, whose set is
/// shipping.proto, and then `stubs`, the lines of its `stubs` array.
/// Renders what `smock check` would print: every problem, one per line; or,
/// for a valid set, each Stub with its kind.
fn check_shipping(stubs : String) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: shipping, grpc: { descriptorSet: shipping.binpb } }
    #|stubs:
    #|
  match
    @definitions.load({
      files: [("a.yaml", @utf8.encode(yaml + stubs))],
      body_files: [("shipping.binpb", set_bytes(shipping_set))],
    }) {
    Ok(snapshot) => {
      let lines = []
      for mock in snapshot.mocks {
        for stub in mock.stubs {
          let kind = match stub.serves {
            Ordinary({ grpc_method: Some(rpc), .. }) =>
              "gRPC Stub of \{rpc.name}"
            Ordinary(_) | Crud(_) => "HTTP Stub"
          }
          lines.push("\{mock.name}: \{stub.id}: \{kind}")
        }
      }
      lines.join("\n")
    }
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
test "the ticket's example: a method of proto2 types is served, and a static reply without the required id is a load error" {
  inspect(
    check_shipping(
      (
        #|  - id: place
        #|    mock: shipping
        #|    request: { path: /shipping.Orders/Place, body: { json: { id: 7 } } }
        #|    response: { json: { id: 7 } }
        #|  - id: track
        #|    mock: shipping
        #|    request: { path: /shipping.Orders/Track, body: { json: { state: SHIPPED, history: [1] } } }
        #|    response: { json: { state: 2, sizes: [1, 2], order: { id: 1 } } }
        #|  - id: templated
        #|    mock: shipping
        #|    request: { path: /shipping.Orders/Place }
        #|    response: { template: true, json: { note: "${body.note}" } }
      ),
    ),
    content=(
      #|shipping: place: gRPC Stub of Place
      #|shipping: track: gRPC Stub of Track
      #|shipping: templated: gRPC Stub of Place
    ),
  )
  inspect(
    check_shipping(
      (
        #|  - id: place
        #|    mock: shipping
        #|    request: { path: /shipping.Orders/Place }
        #|    response: { json: { note: no id } }
        #|  - id: track
        #|    mock: shipping
        #|    request: { path: /shipping.Orders/Track }
        #|    responses:
        #|      - json: { orders: [{ id: 1 }, { note: x }] }
        #|      - json: { state: 9 }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/response/json: lacks the required field id of shipping.Order
      #|a.yaml: /stubs/1/responses/0/json/orders/1: lacks the required field id of shipping.Order
      #|a.yaml: /stubs/1/responses/1/json/state: must be the name or the number of a value of shipping.State: the field state of shipping.Parcel has the type shipping.State
    ),
  )
}

///|
test "a condition on a closed enum takes only the numbers it defines" {
  inspect(
    check_shipping(
      (
        #|  - id: track
        #|    mock: shipping
        #|    request: { path: /shipping.Orders/Track, body: { json: { state: 9, history: [0, 7] } } }
        #|    response: { json: {} }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/body/json/state: must be the name or the number of a value of shipping.State: the field state of shipping.Parcel has the type shipping.State
      #|a.yaml: /stubs/0/request/body/json/history/1: must be the name or the number of a value of shipping.State: the elements of the field history of shipping.Parcel have the type shipping.State
    ),
  )
}

///|
test "a method whose types are, or reach, types of an editions file or a MessageSet is a load error; one with a group or a type that an extension extends is served" {
  inspect(
    check_shipping(
      (
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
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/path: the output type shipping.Sheet is not served yet: labels.proto, which defines labels.Color, a type it reaches, is an editions file, and editions come in a later spec
      #|a.yaml: /stubs/0/request/path: the output type shipping.Sheet is not served yet: labels.proto, which defines labels.Label, a type it reaches, is an editions file, and editions come in a later spec
      #|a.yaml: /stubs/1/request/path: the input type labels.Label is not served yet: labels.proto, which defines it, is an editions file, and editions come in a later spec
      #|a.yaml: /stubs/2/request/path: the input type shipping.Crate is not served: shipping.Bag, a type it reaches, is a MessageSet, whose extensions use another wire form, and smock serves no MessageSet types
    ),
  )
  // Plan takes an Itinerary, which has a group, and Stamp returns a
  // Stamped, which the extension shipping.stamp extends.
  inspect(
    check_shipping(
      (
        #|  - id: plan
        #|    mock: shipping
        #|    request: { path: /shipping.Orders/Plan, body: { json: { stop: [{ city: Paris }] } } }
        #|    response: { json: { id: 1 } }
        #|  - id: stamp
        #|    mock: shipping
        #|    request: { path: /shipping.Orders/Stamp }
        #|    response: { json: { by: me, "[shipping.stamp]": paid } }
      ),
    ),
    content=(
      #|shipping: plan: gRPC Stub of Plan
      #|shipping: stamp: gRPC Stub of Stamp
    ),
  )
}
