// The rules of the metadata a gRPC reply carries in its HEADERS and its
// trailers, as gRPC's HTTP/2 protocol document gives them
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md): the
// grammar of a name, the names gRPC keeps for itself, the values of ASCII
// metadata, and binary metadata, whose name ends with `-bin` and whose
// value is base64, sent without padding.

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
