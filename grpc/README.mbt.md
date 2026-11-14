# smock/grpc

gRPC's wire rules for MoonBit: the content type of gRPC calls, the 5-octet
prefix that frames each message, gRPC's seventeen status codes with their
names, the percent-encoding of a status message, and the rules of reply
metadata. smock serves gRPC unary calls with it, beside
`smock/protobuf`, which encodes the messages. The module does no I/O and
depends only on `moonbitlang/core`. It builds for every MoonBit target and
is tested on native and `wasm-gc`.

## Content type

A gRPC call is an HTTP/2 request whose `content-type` is
`application/grpc`, alone or followed by `+` or `;`. The text after `+`, up
to any `;`, is the call's content subtype, which names the codec of its
messages: none, or `proto`, for protobuf.

- `@grpc.content_subtype(value)` gives the subtype of a call whose
  `content-type` has the value `value`, empty when there is none, or `None`
  when the value makes no gRPC call. It copies nothing.
- `@grpc.content_type` is `application/grpc`, the content type of replies.

```mbt check
///|
test "tell a gRPC call by its content type" {
  guard @grpc.content_subtype(b"application/grpc+proto;v=1"[:]) is Some(subtype) else {
    fail("not a call")
  }
  inspect(subtype == b"proto"[:], content="true")
  guard @grpc.content_subtype(b"application/grpc;v=1"[:]) is Some(none) else {
    fail("not a call")
  }
  inspect(none.length(), content="0")
  inspect(
    @grpc.content_subtype(b"application/grpc-web"[:]) is None,
    content="true",
  )
}
```

## Messages

The body of a gRPC call, and the body of its reply, are messages, each
after a 5-octet prefix: a flag octet, 1 when the message is
compressed, then the message's length in 4 octets, big-endian
([gRPC over HTTP/2](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md)).

- `@grpc.next_message(body)` gives the message at the start of `body`,
  with its flag and the octets after it, or tells how the body ends:
  `Done` when nothing is left, `InPrefix` when it ends inside a prefix, and
  `InMessage(length~)` when it ends inside a message. It copies nothing.
- `@grpc.frame(message)` frames a message, uncompressed.

```mbt check
///|
test "take the one message of a call's body" {
  // HelloRequest { name: "Tom" }, framed.
  let body = b"\x00\x00\x00\x00\x05\x0a\x03Tom"
  guard @grpc.next_message(body[:]) is Message(flag~, message~, rest~) else {
    fail("no message")
  }
  inspect(flag, content="b'\\x00'")
  inspect(message.length(), content="5")
  inspect(@grpc.next_message(rest) is Done, content="true")
}

///|
test "a body that ends early is told apart" {
  inspect(@grpc.next_message(b"\x00\x00\x00"[:]) is InPrefix, content="true")
  debug_inspect(
    @grpc.next_message(b"\x00\x00\x00\x00\x05\x0a"[:]),
    content="InMessage(length=5)",
  )
}

///|
test "frame a reply's message" {
  inspect(
    @grpc.frame(b"\x0a\x03Tom"[:]) == b"\x00\x00\x00\x00\x05\x0a\x03Tom",
    content="true",
  )
}
```

## Status codes

`@grpc.Status` has gRPC's seventeen status codes
([Status codes](https://grpc.github.io/grpc/core/md_doc_statuscodes.html)),
from `Ok`, 0, to `Unauthenticated`, 16. `code()` gives the number that
`grpc-status` carries, and `name()` the name, such as `NOT_FOUND`.
`Status::from_code` and `Status::from_name` read them back.

```mbt check
///|
test "a status by its number and by its name" {
  let status = @grpc.Status::NotFound
  inspect(status.code(), content="5")
  inspect(status.name(), content="NOT_FOUND")
  debug_inspect(@grpc.Status::from_name("INTERNAL"), content="Some(Internal)")
  debug_inspect(@grpc.Status::from_code(17), content="None")
}
```

## Status messages

A reply's status message goes in `grpc-message`, percent-encoded, so that
any Unicode text fits in an HTTP/2 field value.
`@grpc.percent_encode(text)` gives that value: the text's UTF-8 octets,
each from 0x20 to 0x7E other than `%` as it is, and every other octet as
`%` and two upper-case hex digits. A space at either end becomes `%20`
too, since HTTP/2 refuses a field value with a space at either end.

```mbt check
///|
test "percent-encode a status message" {
  inspect(
    @grpc.percent_encode(" try again ☺ ") == b"%20try again %E2%98%BA%20",
    content="true",
  )
}
```

## Metadata

A reply's metadata, in its HEADERS and its trailers, follows gRPC's
grammar. A name holds one or more of `0-9`, `a-z`, `_`, `-` and `.`, and
gRPC keeps `content-type`, `te` and every name that starts with `grpc-` for
itself. The value of ASCII metadata holds characters from 0x20 to 0x7E.
Binary metadata has a name that ends with `-bin`, and its value is
standard base64, padded or not, which gRPC sends without its padding.

- `@grpc.is_metadata_name(name)` tells a name of the grammar, given in
  lower case; `@grpc.is_reserved_name(name)` one that gRPC keeps.
- `@grpc.is_binary_name(name)` tells the name of binary metadata.
- `@grpc.is_ascii_value(value)` tells the value of ASCII metadata.
- `@grpc.unpadded_base64(value)` gives the value of binary metadata without
  its padding, or `None` when it is not base64. It copies nothing.

```mbt check
///|
test "check reply metadata" {
  inspect(@grpc.is_metadata_name("x-trace"), content="true")
  inspect(@grpc.is_metadata_name("x(trace)"), content="false")
  inspect(@grpc.is_reserved_name("grpc-foo"), content="true")
  inspect(@grpc.is_ascii_value("caf\u{e9}"), content="false")
  inspect(@grpc.is_binary_name("trace-bin"), content="true")
  guard @grpc.unpadded_base64("AAE=") is Some(value) else { fail("not base64") }
  inspect(value, content="AAE")
  inspect(@grpc.unpadded_base64("AA=") is None, content="true")
}
```
