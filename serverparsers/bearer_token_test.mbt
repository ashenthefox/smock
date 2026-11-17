// Tests of the Admin API's bearer token: how a request carries it, and when
// it is the token smock was given. The Admin API guide's paragraph on the
// token (docs/admin-api.md, "Authentication") says that every operation but
// the probes and `/metrics` needs `Authorization: Bearer <token>`, and that a
// missing or wrong token gets 401. The form of the field is RFC 6750's,
// section 2.1, where `credentials = "Bearer" 1*SP b64token`, and the scheme
// is a case-insensitive token (RFC 9110, section 11.1). The requests are
// parsed by the HTTP/1.1 codec, as the admin port parses them.

///|
/// The request `GET /v1/status` with the header lines `fields` after its
/// Host, as the HTTP/1.1 codec parses it.
fn admin_request(fields : Array[String]) -> @http1.Request {
  let head = StringBuilder()
  head.write_string("GET /v1/status HTTP/1.1\r\nHost: localhost:9090\r\n")
  for field in fields {
    head.write_string("\{field}\r\n")
  }
  head.write_string("\r\n")
  let parser = @http1.Parser()
  parser.feed(@utf8.encode(head.to_string()))
  guard parser.next() is Complete(request) else {
    abort("the codec parses a test's request")
  }
  request
}

///|
/// The bearer token of `request`, written as an option of its text.
fn token_in(request : @http1.Request) -> String {
  match @serverparsers.bearer_token(request) {
    Some(token) => "Some(\"\{@utf8.decode_lossy(token)}\")"
    None => "None"
  }
}

///|
/// The bearer token of the request with the header lines `fields`, written
/// as an option of its text.
fn token_of(fields : Array[String]) -> String {
  token_in(admin_request(fields))
}

///|
test "the bearer token is what follows the scheme Bearer, in any case, and the spaces after it, in the one Authorization field, whose name is in any case (RFC 6750, section 2.1; RFC 9110, sections 5.1 and 11.1; docs/admin-api.md, Authentication)" {
  let cases = [
    // The token of the README's quick start, which the guide's examples
    // send.
    ("the guide's example", ["Authorization: Bearer change-me"]),
    // RFC 6750's own example, in section 2.1.
    ("RFC 6750's example", ["Authorization: Bearer mF_9.B5f-4.1JqM"]),
    // A b64token may end with `=`.
    ("a token that ends with =", ["Authorization: Bearer YWJj=="]),
    ("the scheme in lower case", ["Authorization: bearer change-me"]),
    ("the scheme in upper case", ["Authorization: BEARER change-me"]),
    ("the scheme in mixed case", ["Authorization: bEaReR change-me"]),
    // `1*SP`.
    ("three spaces after the scheme", ["Authorization: Bearer   change-me"]),
    ("the field name in lower case", ["authorization: Bearer change-me"]),
    ("the field name in upper case", ["AUTHORIZATION: Bearer change-me"]),
    (
      "beside other fields",
      ["Accept: */*", "Authorization: Bearer change-me", "X-Debug: 1"],
    ),
  ]
  inspect(
    cases.map(c => "\{c.0}: \{token_of(c.1)}").join("\n"),
    content=(
      #|the guide's example: Some("change-me")
      #|RFC 6750's example: Some("mF_9.B5f-4.1JqM")
      #|a token that ends with =: Some("YWJj==")
      #|the scheme in lower case: Some("change-me")
      #|the scheme in upper case: Some("change-me")
      #|the scheme in mixed case: Some("change-me")
      #|three spaces after the scheme: Some("change-me")
      #|the field name in lower case: Some("change-me")
      #|the field name in upper case: Some("change-me")
      #|beside other fields: Some("change-me")
    ),
  )
}

///|
test "a request without exactly one Authorization: Bearer <token> field carries no bearer token, so smock answers that the Admin API needs one: another scheme, another field, no space after the scheme, no token, or two fields (RFC 6750, section 2.1; RFC 9110, sections 5.3 and 11.6.2; docs/admin-api.md, Authentication)" {
  let cases = [
    ("no Authorization field", []),
    // The e2e test of the token sends this as well.
    ("Basic credentials", ["Authorization: Basic Y2hhbmdlLW1l"]),
    // A scheme as long as Bearer.
    ("Digest credentials", ["Authorization: Digest username=\"admin\""]),
    ("a scheme one letter short", ["Authorization: Beare change-me"]),
    ("a scheme one letter long", ["Authorization: Bearers change-me"]),
    ("a letter before the scheme", ["Authorization: XBearer change-me"]),
    // `"Bearer" 1*SP b64token`: at least one space.
    ("no space after the scheme", ["Authorization: Bearerchange-me"]),
    // A b64token has at least one character. The codec takes the spaces
    // at the end of a field value away, so these two are the same.
    ("the scheme alone", ["Authorization: Bearer"]),
    ("the scheme and spaces", ["Authorization: Bearer   "]),
    ("Proxy-Authorization", ["Proxy-Authorization: Bearer change-me"]),
    ("X-Authorization", ["X-Authorization: Bearer change-me"]),
    // Authorization is `credentials`, not a list (RFC 9110, section
    // 11.6.2), so a sender must not send it twice (section 5.3).
    (
      "two Authorization fields",
      ["Authorization: Bearer change-me", "Authorization: Bearer change-me"],
    ),
  ]
  let out = cases.map(c => "\{c.0}: \{token_of(c.1)}")
  // The codec never gives a field value that ends with a space, but a
  // request built by hand may.
  let kept : @http1.Request = {
    meth: "GET",
    target: "/v1/status",
    version: Http11,
    headers: [{ name: "Authorization", value: b"Bearer   ", }],
    body: b"",
    keep_alive: true,
  }
  out.push("the scheme and spaces, kept: \{token_in(kept)}")
  inspect(
    out.join("\n"),
    content=(
      #|no Authorization field: None
      #|Basic credentials: None
      #|Digest credentials: None
      #|a scheme one letter short: None
      #|a scheme one letter long: None
      #|a letter before the scheme: None
      #|no space after the scheme: None
      #|the scheme alone: None
      #|the scheme and spaces: None
      #|Proxy-Authorization: None
      #|X-Authorization: None
      #|two Authorization fields: None
      #|the scheme and spaces, kept: None
    ),
  )
}

///|
test "a bearer token gets through only when its octets are those of the token, all of them and no more; any other is wrong, and gets 401 (docs/admin-api.md, Authentication)" {
  let token = @utf8.encode("change-me")
  let cases = [
    ("the token", "change-me"),
    ("its first octet changed", "xhange-me"),
    ("its last octet changed", "change-mf"),
    ("in upper case", "CHANGE-ME"),
    ("a prefix of it", "change-"),
    ("an octet more", "change-mex"),
    ("nothing", ""),
  ]
  let out = cases.map(c => {
    "\{c.0}: \{@serverparsers.same_token(token, @utf8.encode(c.1)[:])}"
  })
  // A given token that, repeated, gives the token, or that is the token
  // repeated.
  let repeated = @utf8.encode("abab")
  for given in ["ab", "abab", "abababab"] {
    out.push(
      "\{given} for abab: \{@serverparsers.same_token(repeated, @utf8.encode(given)[:])}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|the token: true
      #|its first octet changed: false
      #|its last octet changed: false
      #|in upper case: false
      #|a prefix of it: false
      #|an octet more: false
      #|nothing: false
      #|ab for abab: false
      #|abab for abab: true
      #|abababab for abab: false
    ),
  )
}
