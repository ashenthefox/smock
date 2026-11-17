// Tests of smock's own checks of an HTTP/2 request, made once its HEADERS
// have arrived and moonhttp has checked them against RFC 9113's own field
// rules. The HTTP/2 guide's list of the requests smock refuses
// (docs/http2.md, "Requests smock refuses") gives which get 400, with RFC
// 9113 where the guide cites it. The guide compares `:authority` and `host`
// without the port, which RFC 9113 alone would not, so the guide decides. The
// HTTP/2 guide's rule that a `content-length` over `--body-limit` gets 413
// at once (docs/http2.md, "Request bodies"), with RFC 9110, section 8.6,
// gives how a `content-length` is read. The inputs are of the kind moonhttp
// passes on: names without upper case, values without NUL, CR or LF, and a
// `content-length` of digits alone.

///|
/// One request's fields as smock's checks take them, and what the case is.
priv struct Head {
  what : String
  meth : String
  /// `:path`, or `:authority` for a CONNECT, which has no `:path`.
  target : String
  authority : String?
  headers : Array[(String, String)]
}

///|
/// A request for `target` with the method `meth`, the `:authority`
/// `authority` and the regular fields `headers`, which `what` describes.
fn head(
  what : String,
  meth~ : String = "GET",
  target~ : String = "/users/1",
  authority~ : String? = Some("users.example.com"),
  headers~ : Array[(String, String)] = [("accept", "*/*")],
) -> Head {
  { what, meth, target, authority, headers, }
}

///|
/// Each request of `heads`, one a line, with whether smock refuses it as
/// malformed, so that its stream gets 400.
fn verdicts(heads : Array[Head]) -> String {
  heads
  .map(h => {
    let malformed = @serverparsers.is_malformed_http2_request(
      meth=h.meth,
      target=h.target,
      authority=h.authority,
      headers=h.headers,
    )
    "\{h.what}: \{if malformed { "400" } else { "passes" }}"
  })
  .join("\n")
}

///|
test "a request that HTTP/1.1's rules take passes smock's checks: a token for its method, a path starting with /, or * with OPTIONS, visible ASCII alone in :path, a valid Host in :authority and in one host field that names the same host, compared in any case, without the port and without a trailing dot, and tokens for names and values without control characters but tab (docs/http2.md, Requests smock refuses; RFC 9113, sections 8.3.1 and 8.5; RFC 9110, sections 5.5 and 5.6.2)" {
  inspect(
    verdicts([
      head("a GET"),
      head("a method that is a token, but not a standard one", meth="M-SEARCH"),
      head("OPTIONS *", meth="OPTIONS", target="*"),
      head("a path with a query", target="/users?q=a|b&sort=name"),
      // 0x21 and 0x7E, the ends of visible ASCII.
      head("a path with ! and ~", target="/!~"),
      head("no :authority", authority=None, headers=[
        ("host", "users.example.com"),
      ]),
      head("no :authority and no host", authority=None),
      head(
        "an :authority with a port",
        authority=Some("users.example.com:8080"),
      ),
      // The guide's own example of a CONNECT.
      head(
        "a CONNECT to a host and a port",
        meth="CONNECT",
        target="proxy.example.com:443",
        authority=Some("proxy.example.com:443"),
      ),
      // The guide's own example of a host that agrees with :authority.
      head(
        "host ORDERS.example.com:8080 for orders.example.com",
        authority=Some("orders.example.com"),
        headers=[("host", "ORDERS.example.com:8080")],
      ),
      head(
        "host orders.example.com. for orders.example.com",
        authority=Some("orders.example.com"),
        headers=[("host", "orders.example.com.")],
      ),
      head("a name of every token character", headers=[
        ("x-a1!#$%&'*+.^_`|~", "1"),
      ]),
      head("a tab in a value", headers=[("x-list", "a\tb")]),
      head("a value beyond ASCII", headers=[("x-name", "caf\u{e9}")]),
    ]),
    content=(
      #|a GET: passes
      #|a method that is a token, but not a standard one: passes
      #|OPTIONS *: passes
      #|a path with a query: passes
      #|a path with ! and ~: passes
      #|no :authority: passes
      #|no :authority and no host: passes
      #|an :authority with a port: passes
      #|a CONNECT to a host and a port: passes
      #|host ORDERS.example.com:8080 for orders.example.com: passes
      #|host orders.example.com. for orders.example.com: passes
      #|a name of every token character: passes
      #|a tab in a value: passes
      #|a value beyond ASCII: passes
    ),
  )
}

///|
test "each request in the HTTP/2 guide's list of the requests smock refuses gets 400: a method that is not a token, a :path that is not a path or * with OPTIONS, a :path with a space, a control octet, DEL or an octet above 0x7E, an :authority that is not a valid Host, a CONNECT without a port, two host fields, a host that is not a valid Host or names another host, a name that is not a token, and a value with a control character other than tab, or DEL (docs/http2.md, Requests smock refuses; RFC 9113, sections 8.3.1 and 8.5)" {
  inspect(
    verdicts([
      head("an empty method", meth=""),
      head("a method with /", meth="GET/"),
      head("a path without /", target="users/1"),
      head("an absolute URI", target="http://users.example.com/users/1"),
      head("a fragment", target="/users/1#top"),
      head("* with GET", target="*"),
      head("a space in the path", target="/users 1"),
      head("a control octet in the path", target="/users\u{1}"),
      head("DEL in the path", target="/users\u{7f}"),
      head("an octet above 0x7E in the path", target="/caf\u{e9}"),
      head(
        "an :authority with a port that is not digits",
        authority=Some("users.example.com:http"),
      ),
      head("an :authority with an open bracket", authority=Some("[::1")),
      head(
        "a CONNECT without a port",
        meth="CONNECT",
        target="proxy.example.com",
        authority=Some("proxy.example.com"),
      ),
      head("two host fields", authority=None, headers=[
        ("host", "users.example.com"),
        ("host", "users.example.com"),
      ]),
      head("a host with a port that is not digits", authority=None, headers=[
        ("host", "users.example.com:http"),
      ]),
      head(
        "host users.example.com for orders.example.com",
        authority=Some("orders.example.com"),
        headers=[("host", "users.example.com")],
      ),
      head(
        "host orders.example.co for orders.example.com",
        authority=Some("orders.example.com"),
        headers=[("host", "orders.example.co")],
      ),
      head("a name with @", headers=[("x@y", "1")]),
      head("a name with a quote", headers=[("x\"y", "1")]),
      head("a control octet in a value", headers=[("x-list", "a\u{1}b")]),
      head("DEL in a value", headers=[("x-list", "a\u{7f}b")]),
      head("a control octet in the second field's value", headers=[
        ("accept", "*/*"),
        ("x-list", "a\u{1f}b"),
      ]),
    ]),
    content=(
      #|an empty method: 400
      #|a method with /: 400
      #|a path without /: 400
      #|an absolute URI: 400
      #|a fragment: 400
      #|* with GET: 400
      #|a space in the path: 400
      #|a control octet in the path: 400
      #|DEL in the path: 400
      #|an octet above 0x7E in the path: 400
      #|an :authority with a port that is not digits: 400
      #|an :authority with an open bracket: 400
      #|a CONNECT without a port: 400
      #|two host fields: 400
      #|a host with a port that is not digits: 400
      #|host users.example.com for orders.example.com: 400
      #|host orders.example.co for orders.example.com: 400
      #|a name with @: 400
      #|a name with a quote: 400
      #|a control octet in a value: 400
      #|DEL in a value: 400
      #|a control octet in the second field's value: 400
    ),
  )
}

///|
test "a content-length is read as the decimal number its digits give, leading zeros and all, and one that does not fit 32 bits is over every body limit, never read as a length a body limit could take (RFC 9110, section 8.6; docs/http2.md, Request bodies)" {
  // 10485760 is the default --body-limit (docs/running.md, Settings).
  let read = [
    "0", "1", "10485760", "10485761", "000000000000000000000000000010485760",
  ].map(digits => {
    "\{digits}: \{@serverparsers.declared_length(@utf8.encode(digits))}"
  })
  // #318's criterion: a length that does not fit 32 bits is over every
  // body limit. `--body-limit` is a 32-bit signed number, so no body limit
  // is above 2147483647. A reader that let the number overflow 64 bits
  // would read the last four as -9223372036854775808, 0, 10 and 0.
  let over = [
    "4294967296",
    "4294967297",
    "9223372036854775807",
    "9223372036854775808",
    "18446744073709551616",
    "18446744073709551626",
    "1" + "0".repeat(400),
  ].map(digits => {
    let length = @serverparsers.declared_length(@utf8.encode(digits))
    let shown = if digits.length() > 30 { "1 and 400 zeros" } else { digits }
    "\{shown}: over every body limit: \{length > 2147483647L}"
  })
  inspect(
    [..read, ..over].join("\n"),
    content=(
      #|0: 0
      #|1: 1
      #|10485760: 10485760
      #|10485761: 10485761
      #|000000000000000000000000000010485760: 10485760
      #|4294967296: over every body limit: true
      #|4294967297: over every body limit: true
      #|9223372036854775807: over every body limit: true
      #|9223372036854775808: over every body limit: true
      #|18446744073709551616: over every body limit: true
      #|18446744073709551626: over every body limit: true
      #|1 and 400 zeros: over every body limit: true
    ),
  )
}

///|
test "smock reads a content-length's digits until the length reaches 2^32, over every body limit: 4294967295 is read as itself, and 4294967296 or any longer length as 4294967296 (docs/http2.md, Request bodies, a finding that #318 takes to the maintainer)" {
  inspect(
    [
      "2147483648",
      "4294967295",
      "0004294967295",
      "4294967296",
      "4294967297",
      "42949672960",
      "18446744073709551626",
      "1" + "0".repeat(400),
    ]
    .map(digits => {
      let length = @serverparsers.declared_length(@utf8.encode(digits))
      let shown = if digits.length() > 30 { "1 and 400 zeros" } else { digits }
      "\{shown}: \{length}"
    })
    .join("\n"),
    content=(
      #|2147483648: 2147483648
      #|4294967295: 4294967295
      #|0004294967295: 4294967295
      #|4294967296: 4294967296
      #|4294967297: 4294967296
      #|42949672960: 4294967296
      #|18446744073709551626: 4294967296
      #|1 and 400 zeros: 4294967296
    ),
  )
}
