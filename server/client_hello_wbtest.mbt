// Tests of the ClientHello reader, which reads the name a TLS client asks
// for by SNI (RFC 6066, section 3) before OpenSSL sees the handshake, so
// that the name chooses the certificate: a handshake whose SNI is one of the
// Hosts of a listed Mock gets that Mock's certificate, and one without SNI
// the default certificate (docs/running.md, "Certificates for single
// Mocks"). The ClientHellos are captured from a real client
// (client_hello_captures_wbtest.mbt), or derived from those here: sent in
// other records, grown, or with one length field changed.

///|
/// What the reader gives for `data`, the octets received so far, written
/// as its constructors read.
fn read(data : BytesView) -> String {
  match read_client_hello(data) {
    Incomplete => "Incomplete"
    ServerName(Some(name)) => "ServerName(Some(\"\{name}\"))"
    ServerName(None) => "ServerName(None)"
  }
}

///|
/// What the reader gives for each prefix of `data`, from none of its octets
/// to all of them, as runs of the prefix lengths that give the same: what
/// it gives as `data` arrives over TCP, however the reads split it.
fn read_prefixes(data : Bytes) -> String {
  let runs = []
  let mut start = 0
  let mut outcome = read(data[:0])
  for length in 1..<=data.length() {
    let next = read(data[:length])
    if next != outcome {
      runs.push((start, length - 1, outcome))
      start = length
      outcome = next
    }
  }
  runs.push((start, data.length(), outcome))
  runs
  .map(run => {
    let (first, last, outcome) = run
    if first == last {
      "\{first}: \{outcome}"
    } else {
      "\{first}..\{last}: \{outcome}"
    }
  })
  .join("\n")
}

///|
/// The handshake message of a capture: the fragment of its one record,
/// after the record's 5-octet header (RFC 8446, section 5.1).
fn message(capture : Bytes) -> Bytes {
  capture[5:].to_owned()
}

///|
/// `message` sent as TLS records of the handshake type (22) whose fragments
/// end at the offsets `ends` in `message`, and the last one at its end
/// (RFC 8446, section 5.1). Each record has the captures'
/// legacy_record_version, 0x0301, which that section allows in an initial
/// ClientHello.
fn records(message : Bytes, ends~ : Array[Int32] = []) -> Bytes {
  let out = Buffer()
  let mut start = 0
  for end in [..ends, message.length()] {
    let length = end - start
    out.write_bytes(b"\x16\x03\x01")
    out.write_byte((length >> 8).to_byte())
    out.write_byte((length & 0xff).to_byte())
    out.write_bytes(message[start:end])
    start = end
  }
  out.to_bytes()
}

///|
/// The `size`-octet big-endian number at `at` in `bytes`: a length field.
fn length_at(bytes : Bytes, at : Int32, size : Int32) -> Int32 {
  let mut value = 0
  for i in 0..<size {
    value = (value << 8) | bytes[at + i].to_int()
  }
  value
}

///|
/// `bytes` with the `size`-octet big-endian length field at `at` set to
/// `value`.
fn with_length(bytes : Bytes, at : Int32, size : Int32, value : Int32) -> Bytes {
  let out = bytes.to_array()
  for i in 0..<size {
    out[at + i] = ((value >> (8 * (size - 1 - i))) & 0xff).to_byte()
  }
  Bytes::from_array(out)
}

///|
/// `message` with its octets from `start` to `end` replaced by `octets`,
/// and each length field of `lengths`, an offset before `start` and a size
/// in octets, changed by as many octets as that adds or removes: the
/// lengths of the structures that hold the octets replaced.
fn resized(
  message : Bytes,
  start : Int32,
  end : Int32,
  octets : Bytes,
  lengths~ : Array[(Int32, Int32)],
) -> Bytes {
  let change = octets.length() - (end - start)
  let mut fields = message
  for length in lengths {
    let (at, size) = length
    fields = with_length(fields, at, size, length_at(fields, at, size) + change)
  }
  let out = Buffer()
  out.write_bytes(fields[:start])
  out.write_bytes(octets)
  out.write_bytes(fields[end:])
  out.to_bytes()
}

///|
test "a whole ClientHello from a real client reads as the name it asks for by SNI (RFC 6066, section 3; docs/running.md, Certificates for single Mocks)" {
  // The names are those the captures asked for with `-servername`.
  inspect(
    [read(tls13_sni[:]), read(tls12_sni[:])].join("\n"),
    content=(
      #|ServerName(Some("users.example.test"))
      #|ServerName(Some("orders.example.test"))
    ),
  )
}

///|
test "a ClientHello split across reads is incomplete until its last octet arrives, then reads as its name (RFC 8446, section 5.1: a record is complete once its length's octets follow its header)" {
  // Every split of a read is a prefix of what the client sent: the reader
  // is given all octets received so far after each read.
  inspect(
    read_prefixes(tls13_sni),
    content=(
      #|0..1609: Incomplete
      #|1610: ServerName(Some("users.example.test"))
    ),
  )
  inspect(
    read_prefixes(tls12_sni),
    content=(
      #|0..220: Incomplete
      #|221: ServerName(Some("orders.example.test"))
    ),
  )
}

///|
test "a ClientHello spread over two TLS records, split at any octet, reads as its name, and is incomplete until the last octet of the second arrives (RFC 8446, section 5.1: a handshake message may be fragmented across several records)" {
  // Every split of the message that leaves neither record empty, which
  // that section forbids for handshake records.
  let shown = (capture : Bytes) => {
    let message = message(capture)
    let outcomes = []
    for at in 1..<message.length() {
      let outcome = read(records(message, ends=[at])[:])
      if !outcomes.contains(outcome) {
        outcomes.push(outcome)
      }
    }
    "\{message.length() - 1} splits: \{outcomes.join(", ")}"
  }
  inspect(
    shown(tls13_sni),
    content=(
      #|1604 splits: ServerName(Some("users.example.test"))
    ),
  )
  inspect(
    shown(tls12_sni),
    content=(
      #|215 splits: ServerName(Some("orders.example.test"))
    ),
  )
  // Each of those two-record ClientHellos split across reads as well.
  let message = message(tls12_sni)
  let prefixes = []
  for at in 1..<message.length() {
    let runs = read_prefixes(records(message, ends=[at]))
    if !prefixes.contains(runs) {
      prefixes.push(runs)
    }
  }
  inspect(
    prefixes.join("\n--\n"),
    content=(
      #|0..225: Incomplete
      #|226: ServerName(Some("orders.example.test"))
    ),
  )
}

///|
test "a ClientHello without SNI reads as no name, so the handshake gets the default certificate (docs/running.md, Certificates for single Mocks), whether it arrives whole or split across reads" {
  inspect(
    read_prefixes(no_sni),
    content=(
      #|0..1564: Incomplete
      #|1565: ServerName(None)
    ),
  )
  // A ClientHello of an earlier TLS version may have no extensions at all
  // (RFC 8446, section 4.1.2: their presence shows by octets after
  // compression_methods). The TLS 1.2 capture cut after its compression
  // methods, at offset 97, its handshake length shortened to match.
  let message = message(tls12_sni)
  let without_extensions = resized(message, 97, message.length(), b"", lengths=[
    (1, 3),
  ])
  inspect(read(records(without_extensions)[:]), content="ServerName(None)")
}

///|
test "a ClientHello with a length field one octet past what holds it, or below the least RFC 6066 allows, reads as incomplete at the record and handshake lengths, which more octets may complete, and as no name at every other length field (RFC 8446, sections 4.1.2 and 5.1; RFC 6066, section 3)" {
  // At each length field, the smallest length past what the structure that
  // holds the field has left, the whole captures being the largest within
  // it. The offsets are the captures' layouts, in their handshake messages.
  // A field of one octet cannot reach past the ClientHello's end, so the
  // message is cut one octet short of what it counts instead, with the
  // handshake length shortened to match. A ClientHello whose lengths do
  // not fit cannot be decoded, so it holds no server_name to read; OpenSSL
  // then refuses it (RFC 8446, section 6.2, decode_error), whatever
  // certificate the reader chose.
  let tls13 = message(tls13_sni)
  let tls12 = message(tls12_sni)
  let end = tls13.length()
  let cases = [
    (
      "record: one octet more than was received",
      with_length(tls13_sni, 3, 2, end + 1),
    ),
    (
      "handshake: one octet more than the record holds",
      records(with_length(tls13, 1, 3, end - 4 + 1)),
    ),
    (
      "legacy_session_id: the message ends one octet before its 32 do",
      records(resized(tls13, 39 + 32 - 1, end, b"", lengths=[(1, 3)])),
    ),
    (
      "cipher_suites: one octet more than the message has left",
      records(with_length(tls13, 71, 2, end - 73 + 1)),
    ),
    (
      "compression_methods: the message ends before its one octet",
      records(resized(tls13, 134, end, b"", lengths=[(1, 3)])),
    ),
    (
      "extensions: one octet more than the message has left",
      records(with_length(tls13, 135, 2, end - 137 + 1)),
    ),
    (
      "key_share, an extension before server_name: one octet more than the extensions have left",
      records(with_length(tls13, 289, 2, end - 291 + 1)),
    ),
    (
      "server_name: one octet more than the extensions have left",
      records(with_length(tls13, 1562, 2, end - 1564 + 1)),
    ),
    (
      "server_name_list: one octet more than the extension holds",
      records(with_length(tls13, 1564, 2, 21 + 1)),
    ),
    (
      "HostName: one octet more than the list holds",
      records(with_length(tls13, 1567, 2, 18 + 1)),
    ),
    // RFC 6066 counts at least one octet in a HostName and one name in a
    // server_name_list: the TLS 1.2 capture's name, or its whole list, cut
    // out, with the lengths that hold it shortened to match. An empty
    // HostName names no host, so the handshake gets the default
    // certificate, as without SNI.
    (
      "HostName: empty",
      records(
        resized(tls12, 197, 216, b"", lengths=[
          (1, 3),
          (97, 2),
          (190, 2),
          (192, 2),
          (195, 2),
        ]),
      ),
    ),
    (
      "server_name_list: empty",
      records(
        resized(tls12, 194, 216, b"", lengths=[
          (1, 3),
          (97, 2),
          (190, 2),
          (192, 2),
        ]),
      ),
    ),
  ]
  inspect(
    cases.map(case => "\{case.0}: \{read(case.1[:])}").join("\n"),
    content=(
      #|record: one octet more than was received: Incomplete
      #|handshake: one octet more than the record holds: Incomplete
      #|legacy_session_id: the message ends one octet before its 32 do: ServerName(None)
      #|cipher_suites: one octet more than the message has left: ServerName(None)
      #|compression_methods: the message ends before its one octet: ServerName(None)
      #|extensions: one octet more than the message has left: ServerName(None)
      #|key_share, an extension before server_name: one octet more than the extensions have left: ServerName(None)
      #|server_name: one octet more than the extensions have left: ServerName(None)
      #|server_name_list: one octet more than the extension holds: ServerName(None)
      #|HostName: one octet more than the list holds: ServerName(None)
      #|HostName: empty: ServerName(None)
      #|server_name_list: empty: ServerName(None)
    ),
  )
}
