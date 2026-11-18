// The name a TLS client asks for by SNI, read from its ClientHello before
// OpenSSL sees it, so that the name can choose the certificate the
// connection starts with. The ClientHello is sent in the clear, and OpenSSL
// works on bytes the server hands it, so the bytes read here go to OpenSSL
// unchanged afterwards: no C callback is needed (ADR 0001). Anything that
// is not a well-formed ClientHello reads as no name, and OpenSSL then
// fails the handshake as it would anyway.

///|
/// What the first bytes from a TLS client tell about the name it asks for.
pub enum ClientHello {
  /// More bytes are needed to tell.
  Incomplete
  /// The host name of the ClientHello's server_name extension (RFC 6066,
  /// section 3), if it has one. Also `None` for bytes that are not a TLS
  /// ClientHello.
  ServerName(String?)
}

///|
/// The most bytes read while looking for the end of the ClientHello. More
/// read as no name: OpenSSL then decides what they are.
const MAX_CLIENT_HELLO = 65536

///|
/// Reads the ClientHello at the start of `data`, the bytes a client has
/// sent so far. The ClientHello may span several TLS records, and a record
/// several reads.
///
/// A record of the handshake type with an empty fragment, which a client
/// must not send (RFC 8446, section 5.1), is skipped. OpenSSL 4.1.0 skips
/// up to 32 of them in a row and goes on with the handshake, so a refusal
/// here, which reads as no name, would give such a client the default
/// certificate instead of the one its name chooses. OpenSSL refuses the
/// 33rd in a row (unexpected_message), whatever certificate the name chose.
///
/// A reading costs steps in line with the octets in `data`, however the
/// client splits them into records (#388). It walks each record's header
/// once to find where the ClientHello ends, and copies none of it until it
/// is whole. A ClientHello in one record is then read where it lies; one
/// that spans several records is copied once, its records walked a second
/// time. `client_hello_cost` counts both.
pub fn read_client_hello(data : BytesView) -> ClientHello {
  read(data, ClientHelloCost::new())
}

///|
/// What one reading of the ClientHello costs, in steps that do not depend
/// on the machine (#388). `server` reads the ClientHello again each time
/// more octets arrive.
pub struct ClientHelloCost {
  /// The TLS records whose headers the reading walked, as often as it
  /// walked them.
  mut records : Int32
  /// The octets of the ClientHello it copied.
  mut copied : Int32
}

///|
/// What `read_client_hello` costs for `data`. For tests: `server` does not
/// call it.
pub fn client_hello_cost(data : BytesView) -> ClientHelloCost {
  let cost = ClientHelloCost::new()
  let _ = read(data, cost)
  cost
}

///|
/// Nothing counted yet.
fn ClientHelloCost::new() -> ClientHelloCost {
  { records: 0, copied: 0, }
}

///|
/// `read_client_hello`, counting what it costs in `cost`.
fn read(data : BytesView, cost : ClientHelloCost) -> ClientHello {
  // That many octets or more read as no name, whatever they hold.
  if data.length() >= MAX_CLIENT_HELLO {
    return ServerName(None)
  }
  // The octets of the handshake messages in the records walked so far, and
  // the first four of them, the handshake header: the message's type (1 for
  // ClientHello) and its length in 3 bytes, before its body.
  let mut gathered = 0
  let mut header = 0
  let mut pos = 0
  for ;; {
    // The next record: its content type (22 for a handshake), its version
    // in 2 bytes and the length of its fragment in 2 bytes.
    if pos >= data.length() {
      return Incomplete
    }
    if data[pos] != b'\x16' {
      return ServerName(None)
    }
    if pos + 5 > data.length() {
      return Incomplete
    }
    let end = pos + 5 + uint16(data, pos + 3)
    if end > data.length() {
      return Incomplete
    }
    cost.records += 1
    // The header's octets in this fragment, while it lacks some.
    let mut at = pos + 5
    while gathered < 4 && at < end {
      header = (header << 8) | data[at].to_int()
      gathered += 1
      at += 1
    }
    gathered += end - at
    pos = end
    if gathered >= 4 {
      if header >> 24 != 1 {
        return ServerName(None)
      }
      let length = 4 + (header & 0xffffff)
      if gathered >= length {
        return ServerName(server_name(body(data, length, cost)))
      }
    }
  }
}

///|
/// The body of the handshake message whose `length` octets, its 4-octet
/// header first, the records at the start of `data` hold. It is read where
/// it lies when the first record holds it whole, and is otherwise copied
/// from the records' fragments, once.
fn body(data : BytesView, length : Int32, cost : ClientHelloCost) -> BytesView {
  if uint16(data, 3) >= length {
    return data[9:5 + length]
  }
  let message = FixedArray::make(length, b'\x00')
  // The octets of the message copied so far. The last record may hold more
  // octets after it.
  let mut copied = 0
  let mut pos = 0
  while copied < length {
    cost.records += 1
    let fragment = uint16(data, pos + 3)
    let count = @cmp.minimum(fragment, length - copied)
    message.blit_from_bytesview(copied, data[pos + 5:pos + 5 + count])
    cost.copied += count
    copied += count
    pos += 5 + fragment
  }
  message.unsafe_reinterpret_as_bytes()[4:]
}

///|
/// The host name in the server_name extension of a ClientHello body, if
/// any.
fn server_name(hello : BytesView) -> String? {
  // The legacy version (2 bytes) and the random (32 bytes), then the
  // session ID, the cipher suites and the compression methods, each after
  // its length.
  let mut pos = 34
  for length_size in [1, 2, 1] {
    if pos + length_size > hello.length() {
      return None
    }
    let length = if length_size == 1 {
      hello[pos].to_int()
    } else {
      uint16(hello, pos)
    }
    pos += length_size + length
  }
  // The extensions, after their length. A ClientHello may have none.
  if pos + 2 > hello.length() {
    return None
  }
  let end = pos + 2 + uint16(hello, pos)
  if end > hello.length() {
    return None
  }
  pos += 2
  while pos + 4 <= end {
    let kind = uint16(hello, pos)
    let length = uint16(hello, pos + 2)
    pos += 4
    if pos + length > end {
      return None
    }
    if kind == 0 {
      return host_name(hello[pos:pos + length])
    }
    pos += length
  }
  None
}

///|
/// The host name in the server_name extension's list of names, if any.
fn host_name(list : BytesView) -> String? {
  if list.length() < 2 {
    return None
  }
  let end = 2 + uint16(list, 0)
  if end > list.length() {
    return None
  }
  let mut pos = 2
  while pos + 3 <= end {
    let kind = list[pos]
    let length = uint16(list, pos + 1)
    pos += 3
    if pos + length > end {
      return None
    }
    // Name type 0 is host_name, the only one defined.
    if kind == b'\x00' && length > 0 {
      return Some(@utf8.decode_lossy(list[pos:pos + length]))
    }
    pos += length
  }
  None
}

///|
/// The big-endian 16-bit number at `pos` in `data`.
fn uint16(data : BytesView, pos : Int32) -> Int32 {
  (data[pos].to_int() << 8) | data[pos + 1].to_int()
}
