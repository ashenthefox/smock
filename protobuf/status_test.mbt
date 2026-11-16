// google.rpc.Status, gRPC's richer error model, encoded with error details
// through the public interface. The set and the expected messages are
// protoc's, built from fixtures/protobuf/details/ with googleapis'
// status.proto (scripts/gen-protobuf-fixtures.sh), so the encoder is never
// checked against itself. The set holds error_details.proto, not
// status.proto.

///|
/// google.rpc.Status with `code`, `message` and `details`, encoded with the
/// details set, in hex, or the error that stops it.
fn status_of(code : Int32, message : String, details : Array[Json]) -> String {
  let set = hex_set(details_set)
  @hex.encode(set.encode_status(code, message, details[:])) catch {
    err => "error: \{err}"
  }
}

///|
test "the ticket's example: NOT_FOUND, its message and an ErrorInfo, as protoc encodes them" {
  assert_eq(
    status_of(5, "no user called Ann", [
      {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "reason": "USER_UNKNOWN",
        "domain": "greeter.svc",
      },
    ]),
    @hex.encode(fixture(error_info_status)),
  )
}

///|
test "a RetryInfo's Duration and a BadRequest's list are read as ProtoJSON reads them, in either spelling" {
  assert_eq(
    status_of(14, "try again", [
      {
        "@type": "type.googleapis.com/google.rpc.RetryInfo",
        "retryDelay": "1.5s",
      },
    ]),
    @hex.encode(fixture(retry_info_status)),
  )
  assert_eq(
    status_of(14, "try again", [
      {
        "@type": "type.googleapis.com/google.rpc.RetryInfo",
        "retry_delay": "1.500s",
      },
    ]),
    @hex.encode(fixture(retry_info_status)),
  )
  assert_eq(
    status_of(3, "the request is not valid", [
      {
        "@type": "type.googleapis.com/google.rpc.BadRequest",
        "fieldViolations": [
          { "field": "name", "description": "must not be empty" },
          {
            "reason": "NOT_A_NUMBER",
            "field": "version",
            "description": "must be a number",
          },
        ],
      },
    ]),
    @hex.encode(fixture(bad_request_status)),
  )
}

///|
test "details go in the order given, a map's entries sorted, and any type of the set is a detail; the message is UTF-8" {
  assert_eq(
    status_of(8, "try again ☺", [
      {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "reason": "QUOTA",
        "domain": "greeter.svc",
        "metadata": { "limit": "10", "burst": "2" },
      },
      {
        "@type": "type.googleapis.com/google.rpc.RetryInfo",
        "retryDelay": "30s",
      },
      {
        "@type": "type.googleapis.com/helloworld.HelloReply",
        "message": "later",
      },
    ]),
    @hex.encode(fixture(several_status)),
  )
}

///|
test "without details, the status holds its code and its message; an empty message is left out, and a lone surrogate is written as U+FFFD" {
  let high = (0xD800).unsafe_to_char()
  // Field 1, the code 14; field 2, "a" and U+FFFD.
  inspect(status_of(14, "a\{high}", []), content="080e120461efbfbd")
  inspect(status_of(13, "", []), content="080d")
}

///|
test "a detail that is not an Any of a type of the set is not encoded, with the JSON Pointer of the value at fault from the details" {
  let lines = [
    status_of(5, "", ["ErrorInfo"]),
    status_of(5, "", [{ "reason": "USER_UNKNOWN" }]),
    status_of(5, "", [{}]),
    status_of(5, "", [
      { "@type": "type.googleapis.com/google.rpc.ErrorInfo" },
      { "@type": "type.googleapis.com/google.rpc.Status" },
    ]),
    status_of(5, "", [{ "@type": "google.rpc.ErrorInfo" }]),
    status_of(5, "", [
      {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "reasons": "USER_UNKNOWN",
      },
    ]),
    status_of(5, "", [
      { "@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": 1.5 },
    ]),
  ]
  inspect(
    lines.join("\n"),
    content=(
      #|error: /0: must be an object: a detail is an Any, the fields of its message beside "@type"
      #|error: /0: must give "@type", the type URL of the detail's message, such as "type.googleapis.com/google.rpc.ErrorInfo"
      #|error: /0: must give "@type", the type URL of the detail's message, such as "type.googleapis.com/google.rpc.ErrorInfo"
      #|error: /1/@type: names the type google.rpc.Status, which the Descriptor set does not define
      #|error: /0/@type: must be a type URL: / and the full name of a type of the set at its end, such as "type.googleapis.com/helloworld.HelloRequest"
      #|error: /0/reasons: is not a field of google.rpc.ErrorInfo
      #|error: /0/retryDelay: must be a duration from "-315576000000.999999999s" to "315576000000.999999999s": seconds, with at most 9 fractional digits, then "s", such as "1.500s": the field retry_delay of google.rpc.RetryInfo has the type google.protobuf.Duration
    ),
  )
}
