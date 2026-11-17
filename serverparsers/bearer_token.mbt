// The Admin API's bearer token: how a request carries it, and whether it is
// the token smock was given. Every operation of the Admin API but the
// probes and the metrics needs `Authorization: Bearer <token>`, and a
// missing or wrong token gets 401 (docs/admin-api.md, "Authentication");
// `server` answers that once these have read the request.

///|
/// The token of the request's `Authorization: Bearer <token>` field. A
/// request has none without exactly one Authorization field, or when the
/// field uses another scheme.
pub fn bearer_token(request : @http1.Request) -> BytesView? {
  let fields = request.headers.filter(header => {
    header.name.to_lower() == "authorization"
  })
  guard fields is [field] else { return None }
  let value = field.value[:]
  let scheme = "bearer"
  guard value.length() > scheme.length() &&
    value[scheme.length()] is (b' ' | b'\t') else {
    return None
  }
  for i, c in scheme {
    let byte = value[i]
    let lower = if byte >= b'A' && byte <= b'Z' { byte + 32 } else { byte }
    if lower.to_int() != c.to_int() {
      return None
    }
  }
  let mut start = scheme.length()
  while start < value.length() && value[start] is (b' ' | b'\t') {
    start += 1
  }
  if start == value.length() {
    None
  } else {
    Some(value[start:])
  }
}

///|
/// Whether `given` is `token`, compared in constant time: the time taken
/// depends on the length of `token` only, never on how much of `given`
/// matches it.
pub fn same_token(token : Bytes, given : BytesView) -> Bool {
  let mut difference = token.length() ^ given.length()
  for i, byte in token {
    let other = if given.length() == 0 {
      0
    } else {
      given[i % given.length()].to_int()
    }
    difference = difference | (byte.to_int() ^ other)
  }
  difference == 0
}
