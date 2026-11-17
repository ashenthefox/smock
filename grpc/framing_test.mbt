// gRPC's message framing through the module's public interface: the
// 5-octet prefix, a flag and a 4-octet big-endian length, before each
// message (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md),
// read as a body arrives, in pieces split anywhere, with bodies that end
// inside a prefix or inside a message.

///|
/// What a deframer makes of a body fed in `pieces`: each prefix it reads,
/// as its flag, its message's length and the body's length through that
/// message, then how the body ends.
fn framing(pieces : Array[BytesView]) -> String {
  let deframer = @grpc.Deframer()
  let out = []
  for piece in pieces {
    let mut rest = piece
    while deframer.take(rest)
          is Prefix(flag~, length~, body_length~, rest=after) {
      out.push(
        "prefix: flag \{flag.to_int()}, \{length} octets, the body \{body_length} octets through them",
      )
      rest = after
    }
  }
  let ending = match deframer.ending() {
    Whole(messages~) => "ends after \{messages} messages"
    InPrefix => "ends inside a prefix"
    InMessage(length~) => "ends inside a message of \{length} octets"
  }
  out.push(ending)
  out.join("\n")
}

///|
/// What a deframer makes of `body` fed whole.
fn whole(body : Bytes) -> String {
  framing([body[:]])
}

///|
test "a message is a flag, its length in 4 octets big-endian, then its octets" {
  inspect(
    whole(b"\x00\x00\x00\x00\x05\x0a\x03Tom"),
    content=(
      #|prefix: flag 0, 5 octets, the body 10 octets through them
      #|ends after 1 messages
    ),
  )
}

///|
test "a body may hold several messages, empty ones and compressed ones included" {
  inspect(
    whole(b"\x00\x00\x00\x00\x00\x01\x00\x00\x00\x02ab\x00\x00\x00\x00\x01c"),
    content=(
      #|prefix: flag 0, 0 octets, the body 5 octets through them
      #|prefix: flag 1, 2 octets, the body 12 octets through them
      #|prefix: flag 0, 1 octets, the body 18 octets through them
      #|ends after 3 messages
    ),
  )
}

///|
test "an empty body holds no message" {
  inspect(whole(b""), content="ends after 0 messages")
  inspect(framing([]), content="ends after 0 messages")
}

///|
test "a body that ends inside a prefix, at any octet of it, is told apart" {
  let prefix = b"\x00\x00\x00\x00\x05"
  for n in 1..<5 {
    inspect(whole(prefix[0:n].to_owned()), content="ends inside a prefix")
  }
  inspect(
    whole(b"\x00\x00\x00\x00\x01a\x00\x00"),
    content=(
      #|prefix: flag 0, 1 octets, the body 6 octets through them
      #|ends inside a prefix
    ),
  )
}

///|
test "a body that ends inside a message gives the length its prefix announced" {
  inspect(
    whole(b"\x00\x00\x00\x00\x05\x0a\x03T"),
    content=(
      #|prefix: flag 0, 5 octets, the body 10 octets through them
      #|ends inside a message of 5 octets
    ),
  )
  inspect(
    whole(b"\x00\x00\x00\x00\x05"),
    content=(
      #|prefix: flag 0, 5 octets, the body 10 octets through them
      #|ends inside a message of 5 octets
    ),
  )
}

///|
test "a length past any body is read whole, as an unsigned number, as soon as its prefix arrives" {
  inspect(
    whole(b"\x00\x00\x00\x00\x01a\x00\xff\xff\xff\xff"),
    content=(
      #|prefix: flag 0, 1 octets, the body 6 octets through them
      #|prefix: flag 0, 4294967295 octets, the body 4294967306 octets through them
      #|ends inside a message of 4294967295 octets
    ),
  )
}

///|
test "a flag is passed on as it is, whatever its value" {
  inspect(
    whole(b"\x80\x00\x00\x00\x00\xff\x00\x00\x00\x00"),
    content=(
      #|prefix: flag 128, 0 octets, the body 5 octets through them
      #|prefix: flag 255, 0 octets, the body 10 octets through them
      #|ends after 2 messages
    ),
  )
}

///|
/// Bodies that use every way a body is framed or ends: messages of no
/// octet, of one and of several, compressed ones, other flags, and bodies
/// that end inside a prefix or inside a message.
let bodies : Array[Bytes] = [
  b"\x00\x00\x00\x00\x05\x0a\x03Tom", b"\x00\x00\x00\x00\x00\x01\x00\x00\x00\x02ab\x00\x00\x00\x00\x01c",
  b"\x00\x00\x00\x00\x00", b"\x02\x00\x00\x00\x03xyz\x00\x00\x00\x01\x00", b"\x00\x00\x00\x00\x01a\x00\x00",
  b"\x00\x00\x00\x01\x00abc", b"\x00\x00\x00\x00\x02ab\x00\xff\xff\xff\xff\x00",
]

///|
test "a body split in two at any octet is read as when it comes whole" {
  for body in bodies {
    let expected = whole(body)
    for i in 0..<=body.length() {
      let split = framing([body[:i], body[i:]])
      guard split == expected else {
        fail(
          "\{@hex.encode(body)} split at \{i}:\n\{split}\nwhole:\n\{expected}",
        )
      }
    }
  }
}

///|
test "a body that comes one octet at a time, or in three pieces split anywhere, is read as when it comes whole" {
  for body in bodies {
    let expected = whole(body)
    let octets = []
    for i in 0..<body.length() {
      octets.push(body[i:i + 1])
    }
    assert_eq(framing(octets), expected)
    for i in 0..<=body.length() {
      for j in i..<=body.length() {
        let split = framing([body[:i], body[i:j], body[j:]])
        guard split == expected else {
          fail("\{@hex.encode(body)} split at \{i} and \{j}:\n\{split}")
        }
      }
    }
  }
}

///|
test "framing a message gives flag 0, its length and its octets, which read back" {
  let framed = @grpc.frame(b"\x0a\x03Tom"[:])
  inspect(@hex.encode(framed), content="00000000050a03546f6d")
  inspect(@hex.encode(@grpc.frame(b""[:])), content="0000000000")
  inspect(
    whole(framed),
    content=(
      #|prefix: flag 0, 5 octets, the body 10 octets through them
      #|ends after 1 messages
    ),
  )
  // PROTOCOL-HTTP2, Requests: Message-Length is the message's length
  // "encoded as 4 byte unsigned integer (big endian)". So a message of 255
  // octets carries 00 00 00 ff; one of 256, the first length one octet
  // cannot hold, 00 00 01 00; and ones of 65,536 and 16,777,216, the first
  // lengths that need a third and a fourth octet, 00 01 00 00 and
  // 01 00 00 00. Each prefix starts with flag 0, after which the message
  // is as it is (Compressed-Flag).
  let out = []
  for length in [255, 256, 65_536, 16_777_216] {
    let message = Bytes::make(length, b'\x2a')
    let framed = @grpc.frame(message[:])
    assert_true(framed[@grpc.prefix_length:] == message[:])
    out.push("\{length} octets: \{@hex.encode(framed[:@grpc.prefix_length])}")
    out.push(whole(framed))
  }
  inspect(
    out.join("\n"),
    content=(
      #|255 octets: 00000000ff
      #|prefix: flag 0, 255 octets, the body 260 octets through them
      #|ends after 1 messages
      #|256 octets: 0000000100
      #|prefix: flag 0, 256 octets, the body 261 octets through them
      #|ends after 1 messages
      #|65536 octets: 0000010000
      #|prefix: flag 0, 65536 octets, the body 65541 octets through them
      #|ends after 1 messages
      #|16777216 octets: 0001000000
      #|prefix: flag 0, 16777216 octets, the body 16777221 octets through them
      #|ends after 1 messages
    ),
  )
}

///|
test "the messages that have arrived whole are counted as each one's last octet arrives, a message of zero octets as soon as its prefix does" {
  let deframer = @grpc.Deframer()
  let counts = []
  // HelloRequest { name: "Tom" }, an empty message, then a message cut
  // short, one octet at a time.
  let body = b"\x00\x00\x00\x00\x05\x0a\x03Tom\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02a"
  counts.push(deframer.whole_messages())
  for i in 0..<body.length() {
    let mut rest = body[i:i + 1]
    while deframer.take(rest) is Prefix(rest=after, ..) {
      rest = after
    }
    counts.push(deframer.whole_messages())
  }
  inspect(
    counts.map(count => count.to_string()).join(""),
    content="0000000000111112222222",
  )
  debug_inspect(deframer.ending(), content="InMessage(length=2)")
}
