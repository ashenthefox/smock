// Tests of the Admin API's path parameters: whether the path of a request
// fits the path of an operation, and what each of its parameters is. The
// templates are the paths of the Admin API's OpenAPI document,
// openapi/admin.json, where `{name}` is a path parameter (the OpenAPI
// Specification 3.1.0, "Path Templating"). Each path parameter there is
// required, and its schema takes no empty string. A parameter's value holds
// no unescaped `/` (the same section), and percent-encoded octets are
// decoded only once the components and segments are apart (RFC 3986,
// section 2.4), so the value is the segment as sent.

///|
/// Whether `path` fits the operation path `template`, with each parameter
/// as `name=value`, in the template's order.
fn fit(template : String, path : String) -> String {
  match @serverparsers.path_params(template, path) {
    None => "no fit"
    Some(params) if params.is_empty() => "fits"
    Some(params) =>
      "fits: " +
      params.iter().map(param => "\{param.0}=\{param.1}").collect().join(" ")
  }
}

///|
/// The cases `(template, path)`, each with what `fit` gives, one a line.
fn fits(cases : Array[(String, String)]) -> String {
  cases.map(c => "\{c.1} for \{c.0}: \{fit(c.0, c.1)}").join("\n")
}

///|
test "a path fits an operation path of the Admin API's OpenAPI document when its other segments are the same, and each {name} stands for one non-empty segment, kept as sent (openapi/admin.json; OpenAPI 3.1.0, Path Templating; RFC 3986, section 2.4)" {
  inspect(
    fits([
      ("/v1/status", "/v1/status"),
      ("/v1/mocks/{mock}/stubs", "/v1/mocks/users/stubs"),
      ("/v1/mocks/{mock}/stubs/{id}", "/v1/mocks/users/stubs/eph-1"),
      ("/v1/mocks/{mock}/variables/{name}", "/v1/mocks/users/variables/user-id"),
      ("/v1/stubs/{id}/render", "/v1/stubs/get-user/render"),
      // The scenario parameter is "percent-encoded like any path segment"
      // (openapi/admin.json), and so is a Mock's name.
      (
        "/v1/mocks/{mock}/scenarios/{scenario}", "/v1/mocks/users%20api/scenarios/checkout%2Fflow",
      ),
    ]),
    content=(
      #|/v1/status for /v1/status: fits
      #|/v1/mocks/users/stubs for /v1/mocks/{mock}/stubs: fits: mock=users
      #|/v1/mocks/users/stubs/eph-1 for /v1/mocks/{mock}/stubs/{id}: fits: mock=users id=eph-1
      #|/v1/mocks/users/variables/user-id for /v1/mocks/{mock}/variables/{name}: fits: mock=users name=user-id
      #|/v1/stubs/get-user/render for /v1/stubs/{id}/render: fits: id=get-user
      #|/v1/mocks/users%20api/scenarios/checkout%2Fflow for /v1/mocks/{mock}/scenarios/{scenario}: fits: mock=users%20api scenario=checkout%2Fflow
    ),
  )
}

///|
test "a path with a segment more or less, another segment, an empty segment for a parameter, or a parameter over two segments, fits no operation path (openapi/admin.json: a required parameter, at least one character; OpenAPI 3.1.0, Path Templating: no unescaped / in one; RFC 3986, section 6.2.2.1: a path is compared case by case)" {
  inspect(
    fits([
      ("/v1/status", "/v1/status/"),
      ("/v1/status", "/v1/statu"),
      ("/v1/status", "/v1/Status"),
      ("/v1/status", "/v1"),
      ("/v1/mocks/{mock}/stubs", "/v1/mocks//stubs"),
      ("/v1/mocks/{mock}/stubs", "/v1/mocks/stubs"),
      ("/v1/mocks/{mock}/stubs", "/v1/mocks/users/team/stubs"),
      ("/v1/mocks/{mock}/stubs", "/v1/mocks/users/stub"),
      ("/v1/mocks/{mock}/stubs", "/v1/mocks/users/stubs/"),
      ("/v1/mocks/{mock}/stubs/{id}", "/v1/mocks/users/stubs/"),
      ("/v1/mocks/{mock}/stubs/{id}", "/v1/mocks/users/scenarios/eph-1"),
    ]),
    content=(
      #|/v1/status/ for /v1/status: no fit
      #|/v1/statu for /v1/status: no fit
      #|/v1/Status for /v1/status: no fit
      #|/v1 for /v1/status: no fit
      #|/v1/mocks//stubs for /v1/mocks/{mock}/stubs: no fit
      #|/v1/mocks/stubs for /v1/mocks/{mock}/stubs: no fit
      #|/v1/mocks/users/team/stubs for /v1/mocks/{mock}/stubs: no fit
      #|/v1/mocks/users/stub for /v1/mocks/{mock}/stubs: no fit
      #|/v1/mocks/users/stubs/ for /v1/mocks/{mock}/stubs: no fit
      #|/v1/mocks/users/stubs/ for /v1/mocks/{mock}/stubs/{id}: no fit
      #|/v1/mocks/users/scenarios/eph-1 for /v1/mocks/{mock}/stubs/{id}: no fit
    ),
  )
}
