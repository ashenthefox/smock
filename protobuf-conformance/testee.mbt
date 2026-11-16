// The testee's answer to a request of protobuf's conformance suite: a
// ConformanceRequest in, a ConformanceResponse out, each read and written
// with smock/protobuf's wire reader and writer, by the field numbers of
// protobuf's conformance/conformance.proto. The message the request holds
// is decoded and encoded with smock/protobuf's codec, from the Descriptor
// set of the suite's messages.

///|
/// The bound on the JSON that the testee prints for a message, in octets:
/// far above the JSON of any message of the suite.
const JSON_LIMIT : Int32 = 67108864

///|
/// The message a request holds, in the form it is given in.
priv enum Payload {
  /// No message: a request without its payload.
  Missing
  /// protobuf's binary encoding, `protobuf_payload`: its own octets, not a
  /// view of the request's, so that an error's octet counts from its start.
  Binary(Bytes)
  /// JSON text, `json_payload`.
  Json(BytesView)
  /// A form smock does not have, by its name: JSPB or protobuf's text
  /// format.
  Unsupported(String)
}

///|
/// What a ConformanceRequest asks, as far as the testee reads it.
priv struct Request {
  /// The message to decode.
  mut payload : Payload
  /// The number of the WireFormat to answer in: 1 for protobuf's binary
  /// encoding, 2 for JSON, 3 for JSPB and 4 for protobuf's text format.
  mut output : UInt64
  /// The full name of the message's type, such as
  /// `protobuf_test_messages.proto3.TestAllTypesProto3`.
  mut message_type : String
}

///|
/// A ConformanceResponse: the message in the form asked for, or why there
/// is none.
priv enum Response {
  /// The input is not a message of its type.
  ParseError(String)
  /// The message cannot be written in the form asked for.
  SerializeError(String)
  /// The request cannot be answered, whatever its message.
  RuntimeError(String)
  /// The message in protobuf's binary encoding.
  Binary(Bytes)
  /// The message as JSON text.
  Json(Bytes)
  /// The request asks for a form smock does not have.
  Skipped(String)
}

///|
/// Answers `request`, a ConformanceRequest in protobuf's binary encoding,
/// with a ConformanceResponse in the same encoding, decoding and encoding
/// the message it holds with the types of `set`.
fn answer(set : @protobuf.DescriptorSet, request : BytesView) -> Bytes {
  let response = respond(set, read_request(request)) catch {
    why => RuntimeError("the request is not a ConformanceRequest: \{why}")
  }
  response.to_bytes()
}

///|
/// Reads the fields of a ConformanceRequest that the testee needs, as
/// protobuf reads them: the last of the payload's oneof members wins.
fn read_request(input : BytesView) -> Request raise @protobuf.DecodeError {
  let request = { payload: Missing, output: 0, message_type: "", }
  let reader = @protobuf.Reader(input)
  while !reader.at_end() {
    match reader.tag() {
      1 => {
        reader.expect(Len)
        request.payload = Binary(reader.length_delimited().to_owned())
      }
      2 => {
        reader.expect(Len)
        request.payload = Json(reader.length_delimited())
      }
      7 => {
        reader.expect(Len)
        reader.length_delimited() |> ignore
        request.payload = Unsupported("JSPB")
      }
      8 => {
        reader.expect(Len)
        reader.length_delimited() |> ignore
        request.payload = Unsupported("protobuf's text format")
      }
      3 => {
        reader.expect(Varint)
        request.output = reader.varint()
      }
      4 => {
        reader.expect(Len)
        request.message_type = @utf8.decode_lossy(reader.length_delimited())
      }
      _ => reader.skip()
    }
  }
  request
}

///|
/// The response to `request`.
///
/// A request that gives or asks for a form smock does not have, JSPB or
/// protobuf's text format, is skipped, and so is a message of a type of an
/// editions file, which smock/protobuf does not decode or encode yet.
/// Otherwise the message is decoded and encoded with smock/protobuf:
///
/// - Binary to JSON: `decode_canonical_json`. Its error is a parse error,
///   since smock/protobuf raises one error for bytes that are not the
///   message and for a value that ProtoJSON cannot print.
/// - JSON to binary: `@json.parse`, as smock reads a gRPC reply's JSON, then
///   `encode_json`. Their errors are parse errors.
/// - Binary to binary: binary to JSON, then JSON to binary, whose error is a
///   serialize error.
/// - JSON to JSON: JSON to binary, then binary to JSON, whose error is a
///   serialize error.
fn respond(set : @protobuf.DescriptorSet, request : Request) -> Response {
  if request.payload is Unsupported(form) {
    return Skipped("smock does not read \{form}")
  }
  let binary_output = match request.output {
    1 => true
    2 => false
    3 => return Skipped("smock does not write JSPB")
    4 => return Skipped("smock does not write protobuf's text format")
    format => return RuntimeError("no output format of number \{format}")
  }
  guard set.find_message(request.message_type) is Some(message) else {
    return RuntimeError(
      "the Descriptor set has no message type \{request.message_type}",
    )
  }
  if message.syntax is Editions {
    return Skipped(
      "smock/protobuf does not decode or encode \{message.full_name} yet: it is a type of an editions file",
    )
  }
  match request.payload {
    Binary(input) => {
      let json = @protobuf.decode_canonical_json(
        set,
        message,
        input[:],
        limit=JSON_LIMIT,
      ) catch {
        error => return ParseError(error.to_string())
      }
      if !binary_output {
        return Json(json)
      }
      let json = @json.parse(@utf8.decode(json)) catch {
        error =>
          return RuntimeError(
            "smock/protobuf printed JSON that does not parse: \{error}",
          )
      }
      Binary(set.encode_json(message, json)) catch {
        error => SerializeError(error.to_string())
      }
    }
    Json(text) => {
      let json = @json.parse(@utf8.decode(text)) catch {
        error => return ParseError(error.to_string())
      }
      let binary = set.encode_json(message, json) catch {
        error => return ParseError(error.to_string())
      }
      if binary_output {
        return Binary(binary)
      }
      Json(
        @protobuf.decode_canonical_json(
          set,
          message,
          binary[:],
          limit=JSON_LIMIT,
        ),
      ) catch {
        error => SerializeError(error.to_string())
      }
    }
    // An unsupported form is skipped above.
    Missing | Unsupported(_) => RuntimeError("the request holds no message")
  }
}

///|
/// The response as a ConformanceResponse in protobuf's binary encoding: the
/// member of its oneof `result` that it is.
fn Response::to_bytes(self : Response) -> Bytes {
  let (field, value) = match self {
    ParseError(why) => (1, @utf8.encode(why))
    RuntimeError(why) => (2, @utf8.encode(why))
    Binary(message) => (3, message)
    Json(text) => (4, text)
    Skipped(why) => (5, @utf8.encode(why))
    SerializeError(why) => (6, @utf8.encode(why))
  }
  let writer = @protobuf.Writer()
  writer.tag(field, Len)
  writer.length_delimited(value[:])
  writer.to_bytes()
}
