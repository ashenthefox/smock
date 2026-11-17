///|
/// The testee reads a case's input in both modes, and answers with one line
/// of JSON. The values come from `@yaml.parse`'s documentation: its first
/// example document, read the same in both modes; and `enabled: yes`, which
/// the safe subset refuses with the message it shows, while the YAML 1.2 core
/// schema of the mode for OpenAPI documents reads `yes` as a string.
test "a case's answer gives what each mode reads, or its refusal" {
  inspect(
    answer("2SXE", @utf8.encode("mock: users\nhosts: [users.example]\n")),
    content=(
      #|{"case":"2SXE","safe":{"value":{"mock":"users","hosts":["users.example"]}},"openapi":{"value":{"mock":"users","hosts":["users.example"]}}}
    ),
  )
  inspect(
    answer("9KAX", @utf8.encode("enabled: yes")),
    content=(
      #|{"case":"9KAX","safe":{"error":{"pointer":"/enabled","message":"\"yes\" may be read as a boolean; quote this value"}},"openapi":{"value":{"enabled":"yes"}}}
    ),
  )
}

///|
/// smock reads a Definition file and an OpenAPI document only as UTF-8
/// (definitions/read.mbt and importopenapi/document.mbt refuse one that is
/// not, before the parser sees it), so the testee skips such an input in
/// both modes. 0xFF is never part of UTF-8 (RFC 3629, section 1).
test "an input that is not UTF-8 is skipped in both modes" {
  inspect(
    answer("bad", b"a: \xFF"),
    content=(
      #|{"case":"bad","safe":{"skipped":"not valid UTF-8"},"openapi":{"skipped":"not valid UTF-8"}}
    ),
  )
}
