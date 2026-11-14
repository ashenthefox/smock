// The well-known types that ProtoJSON prints in forms of their own,
// Timestamp, Duration, FieldMask, the wrappers and Empty, decoded into
// smock's decoded form through the public interface. The set and the
// messages are protoc's, built from fixtures/protobuf/wellknown/ and
// protobuf's files beside it (scripts/gen-protobuf-fixtures.sh), so the
// codec is never checked against itself.

///|
test "the ticket's example: a Timestamp 1.5 s after the epoch and a Duration of 1.5 s" {
  inspect(
    decoded(wellknown_set, "wellknown.Lease", fixture(lease)),
    content=(
      #|{"createdAt":"1970-01-01T00:00:01.500Z","ttl":"1.500s"}
    ),
  )
}
