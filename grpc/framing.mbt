// gRPC's messages on the wire: each message of a call or a reply is framed
// with a 5-octet prefix, a flag octet, 1 when the message is compressed,
// then the message's length in 4 octets, big-endian
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md). A body
// is read as it arrives, in pieces split anywhere, so that each prefix is
// known as soon as its last octet arrives.

///|
/// The length of a message's prefix, in octets.
pub let prefix_length : Int32 = 5

///|
/// Reads a body made of framed messages as its octets arrive, in pieces
/// split anywhere, a prefix included: it tells each prefix as soon as the
/// prefix is whole, then how the body ends. It keeps no octet of a
/// message, and at most one prefix.
///
/// ```mbt check
/// test {
///   let deframer = @grpc.Deframer()
///   // A message of 2 octets, its prefix split in two.
///   inspect(deframer.take(b"\x00\x00\x00"[:]) is All, content="true")
///   guard deframer.take(b"\x00\x02ab"[:]) is Prefix(length~, rest~, ..) else {
///     fail("no prefix")
///   }
///   inspect(length, content="2")
///   inspect(deframer.take(rest) is All, content="true")
///   debug_inspect(deframer.ending(), content="Whole(messages=1)")
/// }
/// ```
pub struct Deframer {
  /// The octets of the body taken so far.
  priv mut taken : Int64
  /// The octets of the prefix being read.
  priv prefix : FixedArray[Byte]
  /// How many octets of the prefix being read have been taken: 0 between
  /// messages and inside one.
  priv mut in_prefix : Int32
  /// The length of the message being read, as its prefix announced.
  priv mut length : UInt32
  /// How many octets of the message being read are still to come: 0
  /// between messages.
  priv mut left : Int64
  /// How many prefixes have been read whole.
  priv mut messages : Int32
}

///|
/// A deframer at the start of a body.
pub fn Deframer::Deframer() -> Deframer {
  {
    taken: 0L,
    prefix: FixedArray::make(prefix_length, b'\x00'),
    in_prefix: 0,
    length: 0,
    left: 0L,
    messages: 0,
  }
}

///|
/// What `Deframer::take` found in the octets it was given.
#derive(Eq, Debug)
pub(all) enum Taken {
  /// Every octet given is taken, and none of them ends a prefix.
  All
  /// The octets given end a message's prefix: the flag of the prefix, 0
  /// for a message as it is and 1 for a compressed one, though any octet
  /// is passed on; the length of the message, read whole, as an unsigned
  /// number; the length of the body through the end of the message, its
  /// prefixes included, which the body reaches once the message has
  /// arrived in full; and the octets given after the prefix, not taken
  /// yet.
  Prefix(
    flag~ : Byte,
    length~ : UInt32,
    body_length~ : Int64,
    rest~ : BytesView
  )
}

///|
/// Takes `data`, the next octets of the body, up to the end of the first
/// prefix they end, and tells that prefix with the octets after it, which
/// are to be taken next; or takes them all when they end no prefix. The
/// octets after the prefix are a view of `data`, so nothing is copied.
pub fn Deframer::take(self : Deframer, data : BytesView) -> Taken {
  let n = data.length()
  let mut i = 0
  while i < n {
    if self.left > 0L {
      let room = (n - i).to_int64()
      let part = if self.left < room { self.left } else { room }
      i += part.to_int()
      self.left -= part
      self.taken += part
      continue
    }
    self.prefix[self.in_prefix] = data[i]
    self.in_prefix += 1
    i += 1
    self.taken += 1L
    if self.in_prefix == prefix_length {
      self.in_prefix = 0
      let length = (self.prefix[1].to_uint() << 24) |
        (self.prefix[2].to_uint() << 16) |
        (self.prefix[3].to_uint() << 8) |
        self.prefix[4].to_uint()
      self.length = length
      self.left = length.to_uint64().reinterpret_as_int64()
      self.messages += 1
      return Prefix(
        flag=self.prefix[0],
        length~,
        body_length=self.taken + self.left,
        rest=data[i:],
      )
    }
  }
  All
}

///|
/// How many messages of the body have arrived whole so far: each counts
/// once its last octet is taken, and a message of zero octets once its
/// prefix is. A message is whole before the body ends, so a reader can take
/// the first message of a stream that the client keeps open.
pub fn Deframer::whole_messages(self : Deframer) -> Int32 {
  if self.left > 0L {
    self.messages - 1
  } else {
    self.messages
  }
}

///|
/// How a body ends, were it to end after the octets taken so far.
#derive(Eq, Debug)
pub(all) enum Ending {
  /// After the last octet of a message, or with no octet at all: the body
  /// holds `messages` messages, whole.
  Whole(messages~ : Int32)
  /// Inside a prefix.
  InPrefix
  /// Inside a message, whose prefix announced `length` octets, more than
  /// arrived.
  InMessage(length~ : UInt32)
}

///|
/// How the body ends, were it to end after the octets taken so far.
pub fn Deframer::ending(self : Deframer) -> Ending {
  if self.in_prefix > 0 {
    InPrefix
  } else if self.left > 0L {
    InMessage(length=self.length)
  } else {
    Whole(messages=self.messages)
  }
}

///|
/// `message` framed as it is, uncompressed: flag 0, its length, then its
/// octets.
pub fn frame(message : BytesView) -> Bytes {
  let length = message.length()
  let out = FixedArray::make(prefix_length + length, b'\x00')
  out[1] = (length >> 24).to_byte()
  out[2] = (length >> 16).to_byte()
  out[3] = (length >> 8).to_byte()
  out[4] = length.to_byte()
  out.blit_from_bytesview(prefix_length, message)
  out.unsafe_reinterpret_as_bytes()
}
