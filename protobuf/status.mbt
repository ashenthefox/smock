// google.rpc.Status, the message of gRPC's richer error model, which a gRPC
// server sends in the `grpc-status-details-bin` trailer: a status code, a
// status message and error details, each packed in an Any
// (https://github.com/googleapis/googleapis/blob/master/google/rpc/status.proto).
// It is encoded by field number, as protoc encodes it, so the set needs
// neither status.proto nor any.proto: only the types of the details.

///|
/// Encodes google.rpc.Status, as protoc encodes it, with `code`, its field
/// 1, `message`, its field 2, and `details`, its field 3: each detail
/// packed in an Any, in the order given. A code of 0 and an empty message
/// are left out, as fields at their defaults are. A surrogate of `message`
/// that is not part of a pair, which UTF-8 cannot hold, is written as
/// U+FFFD.
///
/// Each detail is an Any in ProtoJSON, as `encode_json` reads one: an
/// object whose `@type` is a type URL that names a type of this set,
/// beside the fields of the message it holds, or its form as `value`
/// when it is a well-known type that has one.
///
/// Raises `EncodeError`, at the JSON Pointer of the value at fault from
/// `details`, such as `/0/@type`, for a detail that is not such an Any: one
/// that is not an object, one without `@type`, one whose type URL names no
/// type of this set, and one whose members do not fit the type.
pub fn DescriptorSet::encode_status(
  self : DescriptorSet,
  code : Int32,
  message : String,
  details : ArrayView[Json],
) -> Bytes raise EncodeError {
  let writer = Writer()
  if code != 0 {
    writer.tag(1, Varint)
    // A negative int32 is written as its 64-bit two's complement.
    writer.varint(code.to_int64().reinterpret_as_uint64())
  }
  if message.length() > 0 {
    writer.tag(2, Len)
    writer.length_delimited(lossy_utf8(message))
  }
  for i, detail in details {
    let at = "/\{i}"
    guard detail is Object(members) else {
      raise EncodeError(
        pointer=at,
        message="must be an object: a detail is an Any, the fields of its message beside \"@type\"",
      )
    }
    guard members.contains("@type") else {
      raise EncodeError(
        pointer=at,
        message="must give \"@type\", the type URL of the detail's message, such as \"type.googleapis.com/google.rpc.ErrorInfo\"",
      )
    }
    let any = Writer()
    self.write_any(any, detail, 0) catch {
      error => raise nested(error, at)
    }
    writer.tag(3, Len)
    writer.length_delimited(any.to_bytes())
  }
  writer.to_bytes()
}

///|
/// The UTF-8 of `text`, with each surrogate that is not part of a pair,
/// which UTF-8 cannot hold, as U+FFFD.
fn lossy_utf8(text : String) -> Bytes {
  let n = text.length()
  let out = @buffer.Buffer(size_hint=n)
  let mut i = 0
  while i < n {
    let unit = text.unsafe_get(i).to_int()
    i += 1
    // The code point, from one code unit or a surrogate pair.
    let mut code = unit
    if unit >= 0xD800 && unit <= 0xDBFF {
      if i < n &&
        text.unsafe_get(i).to_int() >= 0xDC00 &&
        text.unsafe_get(i).to_int() <= 0xDFFF {
        code = 0x10000 +
          ((unit - 0xD800) << 10) +
          (text.unsafe_get(i).to_int() - 0xDC00)
        i += 1
      } else {
        code = 0xFFFD
      }
    } else if unit >= 0xDC00 && unit <= 0xDFFF {
      code = 0xFFFD
    }
    if code < 0x80 {
      out.write_byte(code.to_byte())
    } else if code < 0x800 {
      out.write_byte((0xC0 | (code >> 6)).to_byte())
      out.write_byte((0x80 | (code & 0x3F)).to_byte())
    } else if code < 0x10000 {
      out.write_byte((0xE0 | (code >> 12)).to_byte())
      out.write_byte((0x80 | ((code >> 6) & 0x3F)).to_byte())
      out.write_byte((0x80 | (code & 0x3F)).to_byte())
    } else {
      out.write_byte((0xF0 | (code >> 18)).to_byte())
      out.write_byte((0x80 | ((code >> 12) & 0x3F)).to_byte())
      out.write_byte((0x80 | ((code >> 6) & 0x3F)).to_byte())
      out.write_byte((0x80 | (code & 0x3F)).to_byte())
    }
  }
  out.to_bytes()
}
