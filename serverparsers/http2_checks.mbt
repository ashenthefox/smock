// smock's own checks of a request that arrives on an HTTP/2 stream, made
// once its HEADERS have arrived and moonhttp has decoded them and checked
// them against RFC 9113's own field rules (docs/http2.md, "Requests smock
// refuses"): whether HTTP/1.1's rules refuse it, and the body length its
// `content-length` declares. They use no moonhttp type, only smock's own
// view of the request, `http1`'s public checks and `definitions`' Host
// normalisation (ADR 0006); `server` maps the stream's fields onto that view
// and refuses the stream.

///|
/// A body length longer than any `--body-limit`.
let too_long : Int64 = 0x1_0000_0000L

///|
/// The body length the `content-length` value `value` declares, `too_long`
/// for one longer than that. moonhttp has checked that `value` is digits
/// alone. smock reads them itself rather than take moonhttp's number, so
/// that a length too large for 32 bits cannot pass for a short one.
pub fn declared_length(value : Bytes) -> Int64 {
  let mut length = 0L
  for i in 0..<value.length() {
    length = length * 10L + (value[i].to_int() - 0x30).to_int64()
    if length >= too_long {
      return too_long
    }
  }
  length
}

///|
/// Whether HTTP/1.1's rules refuse the request, so that its stream gets 400
/// as a malformed request (RFC 9113, section 8.1.1), checked with the
/// HTTP/1.1 codec's own checks. `meth` is its `:method`, `target` its
/// `:path`, or for a CONNECT, which has no `:path`, its `:authority`;
/// `authority` its `:authority`, if any, and `headers` its regular fields,
/// with their names in lower case, as smock maps them. It is refused when:
///
/// - the method is not a token;
/// - `:path` is not an origin-form target, or `*` for OPTIONS, or holds an
///   octet outside 0x21 to 0x7E;
/// - for a CONNECT, which has no `:path`, as moonhttp sees to, its target,
///   `:authority`, is not in authority-form, a host and a port, as an
///   HTTP/1.1 CONNECT's target must be (RFC 9113, section 8.5);
/// - `:authority` is not a valid Host value;
/// - a field name is not a token, or a field value holds a control
///   character other than tab, or DEL;
/// - there is more than one `host` field, or its value is not a valid Host
///   value, or it names another host than `:authority` (section 8.3.1),
///   compared as Mock Hosts are: in any case, without the port or a
///   trailing dot.
///
/// moonhttp has already reset the streams that break RFC 9113's own field
/// rules, so names hold no upper case, and values no NUL, CR or LF.
pub fn is_malformed_http2_request(
  meth~ : String,
  target~ : String,
  authority~ : String?,
  headers~ : Array[(String, String)],
) -> Bool {
  if !@http1.is_token(meth) {
    return true
  }
  if meth == "CONNECT" {
    if !@http1.is_authority_form(target) {
      return true
    }
  } else if !(@http1.is_origin_or_asterisk_form(target, meth~) &&
    @http1.is_visible_ascii(target)) {
    return true
  }
  if authority is Some(authority) && !@http1.is_host_value(authority) {
    return true
  }
  let mut host : String? = None
  for header in headers {
    if !@http1.is_token(header.0) || !@http1.is_field_value(header.1) {
      return true
    }
    if header.0 == "host" {
      if host is Some(_) || !@http1.is_host_value(header.1) {
        return true
      }
      host = Some(header.1)
    }
  }
  // Only a request that names its Host twice pays for the comparison.
  if authority is Some(authority) && host is Some(host) {
    return @definitions.normalize_host(authority) !=
      @definitions.normalize_host(host)
  }
  false
}
