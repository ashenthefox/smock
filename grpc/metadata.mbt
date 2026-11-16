// The rules of the metadata a gRPC reply carries in its HEADERS and its
// trailers, as gRPC's HTTP/2 protocol document gives them
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md): the
// grammar of a name, the names gRPC keeps for itself, the values of ASCII
// metadata, and binary metadata, whose name ends with `-bin` and whose
// value is base64, sent without padding. A call's binary metadata loses
// its padding too, in each comma-separated element, so that padded and
// unpadded clients look alike.

///|
/// Whether `name`, a name in lower case, is a metadata name of gRPC's
/// grammar: one or more of `0-9`, `a-z`, `_`, `-` and `.`.
pub fn is_metadata_name(name : StringView) -> Bool {
  if name.length() == 0 {
    return false
  }
  for c in name {
    if !(c is ('0'..<='9' | 'a'..<='z' | '_' | '-' | '.')) {
      return false
    }
  }
  true
}

///|
/// Whether `name`, a metadata name, is one that gRPC keeps for itself, so
/// that no metadata may have it: `content-type`, `te`, or a name that
/// starts with `grpc-`, such as `grpc-status`.
pub fn is_reserved_name(name : StringView) -> Bool {
  name == "content-type" || name == "te" || name.has_prefix("grpc-")
}

///|
/// Whether `name`, a metadata name, is that of binary metadata: it ends
/// with `-bin`, and its value is written in base64.
pub fn is_binary_name(name : StringView) -> Bool {
  name.has_suffix("-bin")
}

///|
/// Whether `value` is the value of ASCII metadata: it holds only characters
/// from 0x20 to 0x7E, space and printable ASCII. It may be empty.
pub fn is_ascii_value(value : StringView) -> Bool {
  for c in value {
    if c < ' ' || c > '~' {
      return false
    }
  }
  true
}

///|
/// `value`, the value of binary metadata written in standard base64 (RFC
/// 4648, section 4), padded or not, without its padding, as gRPC sends
/// it; `None` when it is not base64. Bits after the last octet are not
/// checked, as gRPC's decoders do not check them. It copies nothing.
pub fn unpadded_base64(value : StringView) -> StringView? {
  let n = value.length()
  // The characters before the padding.
  let mut end = n
  while end > 0 && value[end - 1] == '=' {
    end -= 1
  }
  for i in 0..<end {
    if !(value[i] is ('A'..<='Z' | 'a'..<='z' | '0'..<='9' | '+' | '/')) {
      return None
    }
  }
  // A last group of one character holds no whole octet. Padding, when
  // given, fills the last group to four characters, and no more.
  if end % 4 == 1 || (end < n && (n % 4 != 0 || n - end > 2)) {
    return None
  }
  Some(value.exact_view(start=0, end~))
}

///|
/// `value`, the value of binary metadata as a call carries it, without the
/// padding that ends each of its comma-separated elements, the commas
/// kept: a proxy may join repeated fields with commas, so `AAA=,BBB=`
/// becomes `AAA,BBB`. Only the `=` right before a comma or at the end are
/// taken away, and the value is not checked as base64, nor decoded. It is
/// `value` itself, not a copy, when no element ends with `=`.
pub fn unpadded_elements(value : String) -> String {
  let n = value.length()
  // Most values have no padding to take away, and are kept as they are.
  let mut padded = false
  for i in 0..<n {
    if value[i] == '=' && (i + 1 == n || value[i + 1] == ',') {
      padded = true
      break
    }
  }
  guard padded else { return value }
  let out = StringBuilder(size_hint=n)
  // The start of the element being read, and the end of its characters
  // before any padding.
  let mut start = 0
  while start <= n {
    let mut end = start
    while end < n && value[end] != ',' {
      end += 1
    }
    let mut kept = end
    while kept > start && value[kept - 1] == '=' {
      kept -= 1
    }
    out.write_view(value.exact_view(start~, end=kept))
    if end < n {
      out.write_char(',')
    }
    start = end + 1
  }
  out.to_string()
}
