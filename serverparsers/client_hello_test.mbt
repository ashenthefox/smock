// Tests of the ClientHello reader, which reads the name a TLS client asks
// for by SNI (RFC 6066, section 3) before OpenSSL sees the handshake, so
// that the name chooses the certificate: a handshake whose SNI is one of the
// Hosts of a listed Mock gets that Mock's certificate, and one without SNI
// the default certificate (docs/running.md, "Certificates for single
// Mocks"). The ClientHellos are captured from a real client
// (client_hello_captures_test.mbt), or derived from those here: sent in
// other records, grown, or with one length field changed.

///|
/// What the reader gives for `data`, the octets received so far, written
/// as its constructors read.
fn read(data : BytesView) -> String {
  match @serverparsers.read_client_hello(data) {
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
test "a record of the handshake type with an empty fragment, which a client must not send (RFC 8446, section 5.1), is skipped wherever it comes, as OpenSSL 4.1.0 skips it: the ClientHello around it reads as its name" {
  // OpenSSL 4.1.0's `s_server -servername users.example.test
  // -servername_fatal` went on with the handshake for each of these, and
  // with `-servername orders.example.test` for the TLS 1.2 capture, so it
  // read the name each capture asks for (with another -servername, it sent
  // unrecognized_name for each). It skips up to 32 empty records in a row
  // and refuses the 33rd (unexpected_message), whatever certificate the
  // name chose; the reader skips every one and leaves that to OpenSSL. A
  // record's position is an offset in the handshake message: `ends` holds
  // an offset once more for each empty record there.
  let shown = (capture : Bytes) => {
    let message = message(capture)
    let one_octet = []
    for at in 1..<message.length() {
      one_octet.push(at)
      one_octet.push(at)
    }
    one_octet.push(message.length())
    [
      ("an empty record first", records(message, ends=[0])),
      (
        "split inside the handshake header, at 2, an empty record between",
        records(message, ends=[2, 2]),
      ),
      (
        "split at 100, an empty record between",
        records(message, ends=[100, 100]),
      ),
      (
        "split at 100, 32 empty records between",
        records(message, ends=Array::make(33, 100)),
      ),
      (
        "split at 100, 33 empty records between",
        records(message, ends=Array::make(34, 100)),
      ),
      (
        "in records of one octet, each followed by an empty record",
        records(message, ends=one_octet),
      ),
      ("whole, then an empty record", capture + records(b"")),
    ]
    .map(case => "\{case.0}: \{read(case.1[:])}")
    .join("\n")
  }
  inspect(
    shown(tls13_sni),
    content=(
      #|an empty record first: ServerName(Some("users.example.test"))
      #|split inside the handshake header, at 2, an empty record between: ServerName(Some("users.example.test"))
      #|split at 100, an empty record between: ServerName(Some("users.example.test"))
      #|split at 100, 32 empty records between: ServerName(Some("users.example.test"))
      #|split at 100, 33 empty records between: ServerName(Some("users.example.test"))
      #|in records of one octet, each followed by an empty record: ServerName(Some("users.example.test"))
      #|whole, then an empty record: ServerName(Some("users.example.test"))
    ),
  )
  inspect(
    shown(tls12_sni),
    content=(
      #|an empty record first: ServerName(Some("orders.example.test"))
      #|split inside the handshake header, at 2, an empty record between: ServerName(Some("orders.example.test"))
      #|split at 100, an empty record between: ServerName(Some("orders.example.test"))
      #|split at 100, 32 empty records between: ServerName(Some("orders.example.test"))
      #|split at 100, 33 empty records between: ServerName(Some("orders.example.test"))
      #|in records of one octet, each followed by an empty record: ServerName(Some("orders.example.test"))
      #|whole, then an empty record: ServerName(Some("orders.example.test"))
    ),
  )
  // An empty record does not complete what came before it: OpenSSL waited
  // for more after the first 100 octets of the message and an empty
  // record, and the reader is incomplete until the last octet arrives.
  inspect(
    read_prefixes(records(message(tls12_sni), ends=[100, 100])),
    content=(
      #|0..230: Incomplete
      #|231: ServerName(Some("orders.example.test"))
    ),
  )
}

///|
test "a ClientHello followed by more octets in its last record reads as its name, as OpenSSL 4.1.0 reads a TLS 1.2 ClientHello so followed (RFC 8446, section 5.1: handshake messages may be coalesced into one record)" {
  // OpenSSL 4.1.0's `s_server -servername orders.example.test
  // -servername_fatal` went on with the handshake for both. The octets
  // after the ClientHello are a handshake header of certificate_verify
  // (15) with an empty body. A TLS 1.3 ClientHello so followed OpenSSL
  // refuses (unexpected_message: section 5.1 has a ClientHello end at a
  // record's end), whatever certificate the name chose.
  let message = message(tls12_sni) + b"\x0f\x00\x00\x00"
  inspect(
    [
      "in one record: \{read(records(message)[:])}",
      "in two records, split at 100: \{read(records(message, ends=[100])[:])}",
    ].join("\n"),
    content=(
      #|in one record: ServerName(Some("orders.example.test"))
      #|in two records, split at 100: ServerName(Some("orders.example.test"))
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
    // server_name_list, and a client's server_name extension holds that
    // list: the TLS 1.2 capture's name, its whole list, or the extension's
    // whole data cut out, with the lengths that hold it shortened to
    // match. An empty HostName names no host, so the handshake gets the
    // default certificate, as without SNI.
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
    (
      "server_name: empty",
      records(
        resized(tls12, 192, 216, b"", lengths=[(1, 3), (97, 2), (190, 2)]),
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
      #|server_name: empty: ServerName(None)
    ),
  )
  // The octets after a ClientHello are no part of it: its length fields
  // count within the handshake message's own length (section 4). A client
  // in middlebox compatibility mode may send a change_cipher_spec record
  // right after its ClientHello (RFC 8446, appendix D.4); each ClientHello
  // above, past the record and handshake lengths, reads the same with that
  // record after it.
  let change_cipher_spec = b"\x14\x03\x03\x00\x01\x01"
  inspect(
    cases[2:]
    .map(case => "\{case.0}: \{read((case.1 + change_cipher_spec)[:])}")
    .join("\n"),
    content=(
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
      #|server_name: empty: ServerName(None)
    ),
  )
}

///|
/// The most octets a TLS record's fragment holds: 2^14 (RFC 8446, section
/// 5.1).
const MAX_FRAGMENT = 16384

///|
/// `message`, a ClientHello whose extensions end it and whose extensions
/// length is at the offset `extensions`, grown with a padding extension
/// (RFC 7685: type 21, its data all zero octets) after its last one, and
/// sent in as few records as section 5.1 of RFC 8446 lets it, so that the
/// records take `received` octets in all.
fn grown(message : Bytes, extensions~ : Int32, received~ : Int32) -> Bytes {
  // Each record is a 5-octet header and at most MAX_FRAGMENT octets.
  let count = (received + MAX_FRAGMENT + 4) / (MAX_FRAGMENT + 5)
  let size = received - 5 * count
  let padding_length = size - message.length() - 4
  let padding = Buffer()
  padding.write_bytes(b"\x00\x15")
  padding.write_byte((padding_length >> 8).to_byte())
  padding.write_byte((padding_length & 0xff).to_byte())
  padding.write_bytes(Bytes::make(padding_length, b'\x00'))
  let grown = resized(
    message,
    message.length(),
    message.length(),
    padding.to_bytes(),
    lengths=[(1, 3), (extensions, 2)],
  )
  let ends = []
  for end = MAX_FRAGMENT; end < size; end = end + MAX_FRAGMENT {
    ends.push(end)
  }
  records(grown, ends~)
}

///|
test "the cap: a whole ClientHello that ends at the 65,535th octet received reads as its name, and once 65,536 octets have been received, every octet counted, the reader reads no name, so the handshake gets the default certificate (docs/running.md, Certificates for single Mocks)" {
  // The running guide (docs/running.md, Certificates for single Mocks):
  // "smock reads the SNI from the octets the client has sent so far, each
  // time more arrive. Once it has received 65,536 octets or more, counting
  // every octet received and not only the ClientHello's, it reads no name,
  // and the handshake gets the default certificate." The maintainer
  // confirmed that cap on 2026-11-17 (#275); RFC 8446 lets a ClientHello
  // reach 2^24 - 1 octets (section 4), so the cap is smock's own. The TLS
  // 1.3 capture is grown with a padding extension and sent in four records
  // of at most 2^14 octets each.
  let message = message(tls13_sni)
  let at_cap = grown(message, extensions=135, received=65535)
  let over_cap = grown(message, extensions=135, received=65536)
  // A client in middlebox compatibility mode that offers early data sends
  // a change_cipher_spec record right after its ClientHello (RFC 8446,
  // appendix D.4), so a read may bring it with the ClientHello's last
  // octets.
  let change_cipher_spec = b"\x14\x03\x03\x00\x01\x01"
  let shown = (what : String, data : Bytes) => {
    "\{what}, \{data.length()} octets: \{read(data[:])}"
  }
  inspect(
    [
      shown("grown to end at the 65,535th octet", at_cap),
      shown("its first octets but the last", at_cap[:65534].to_owned()),
      shown("grown to end at the 65,536th octet", over_cap),
      shown("its first octets but the last", over_cap[:65535].to_owned()),
      shown(
        "grown to end at the 65,535th octet, then change_cipher_spec",
        at_cap + change_cipher_spec,
      ),
      shown(
        "as captured, then change_cipher_spec",
        tls13_sni + change_cipher_spec,
      ),
    ].join("\n"),
    content=(
      #|grown to end at the 65,535th octet, 65535 octets: ServerName(Some("users.example.test"))
      #|its first octets but the last, 65534 octets: Incomplete
      #|grown to end at the 65,536th octet, 65536 octets: ServerName(None)
      #|its first octets but the last, 65535 octets: Incomplete
      #|grown to end at the 65,535th octet, then change_cipher_spec, 65541 octets: ServerName(None)
      #|as captured, then change_cipher_spec, 1616 octets: ServerName(Some("users.example.test"))
    ),
  )
}

///|
test "octets that are not a TLS handshake record, or a handshake message that is not a ClientHello, read as no name (RFC 8446: section 5.1, content type 22 is handshake; section 4, msg_type 1 is client_hello)" {
  inspect(
    [
      // Plain HTTP sent to the TLS port: its first octet, `G`, is no
      // content type of TLS.
      read(b"GET / HTTP/1.1\r\nHost: users.example.test\r\n\r\n"[:]),
      // The TLS 1.3 capture with its msg_type changed to 2, server_hello.
      read(records(with_length(message(tls13_sni), 0, 1, 2))[:]),
      // Its handshake header alone, in a record of its own: the msg_type
      // tells already, before its body arrives. OpenSSL 4.1.0's s_server
      // refused it at once (unexpected_message).
      read(records(with_length(message(tls13_sni), 0, 1, 2)[:4].to_owned())[:]),
    ].join("\n"),
    content=(
      #|ServerName(None)
      #|ServerName(None)
      #|ServerName(None)
    ),
  )
}

///|
/// What the reader costs for `data`, as `client_hello_cost` counts it: the
/// record headers it walks and the octets it copies (#388).
fn cost(data : BytesView) -> String {
  let cost = @serverparsers.client_hello_cost(data)
  "records walked \{cost.records}, octets copied \{cost.copied}"
}

///|
/// The handshake header of a ClientHello that announces 2^24 - 1 octets,
/// the most its 3-octet length counts (RFC 8446, section 4), so that no
/// octets received before the cap make it whole.
let endless_header : Bytes = b"\x01\xff\xff\xff"

///|
test "a reading of a ClientHello that is not whole yet walks each record's header once and copies none of its octets, however many records hold them, so that a client that paces it costs each reading steps in line with the octets received (#388)" {
  // #388's two inputs: a record of that header, then records of one octet
  // each, as many as come in before the cap; and a record whose fragment,
  // 2^14 octets (RFC 8446, section 5.1), starts with that header, then
  // records with an empty fragment. A client that sends one record per
  // read has the reader read each prefix of these.
  let one_octet = (count : Int32) => {
    records(
      endless_header + Bytes::make(count, b'\x00'),
      ends=Array::makei(count, i => 4 + i),
    )
  }
  let empty = (count : Int32) => {
    records(
      endless_header + Bytes::make(MAX_FRAGMENT - 4, b'\x00'),
      ends=Array::make(count, MAX_FRAGMENT),
    )
  }
  let shown = (what : String, data : Bytes) => {
    "\{what}, \{data.length()} octets: \{read(data[:])}, \{cost(data[:])}"
  }
  inspect(
    [
      shown("1 one-octet record", one_octet(1)),
      shown("10 one-octet records", one_octet(10)),
      shown("100 one-octet records", one_octet(100)),
      shown("1,000 one-octet records", one_octet(1000)),
      shown("10,921 one-octet records", one_octet(10921)),
      shown("1 empty record", empty(1)),
      shown("1,000 empty records", empty(1000)),
      shown("9,829 empty records", empty(9829)),
    ].join("\n"),
    content=(
      #|1 one-octet record, 15 octets: Incomplete, records walked 2, octets copied 0
      #|10 one-octet records, 69 octets: Incomplete, records walked 11, octets copied 0
      #|100 one-octet records, 609 octets: Incomplete, records walked 101, octets copied 0
      #|1,000 one-octet records, 6009 octets: Incomplete, records walked 1001, octets copied 0
      #|10,921 one-octet records, 65535 octets: Incomplete, records walked 10922, octets copied 0
      #|1 empty record, 16394 octets: Incomplete, records walked 2, octets copied 0
      #|1,000 empty records, 21389 octets: Incomplete, records walked 1001, octets copied 0
      #|9,829 empty records, 65534 octets: Incomplete, records walked 9830, octets copied 0
    ),
  )
}

///|
test "a reading of a whole ClientHello reads it where it lies when one record holds it, and otherwise walks its records a second time and copies it once, so that a ClientHello in one record costs one record's walk and no copy (#388: a ClientHello in one record costs no more than before)" {
  let tls13 = message(tls13_sni)
  let tls12 = message(tls12_sni)
  let shown = (what : String, data : Bytes) => {
    "\{what}, \{data.length()} octets: \{read(data[:])}, \{cost(data[:])}"
  }
  inspect(
    [
      shown("the TLS 1.3 capture, in one record", tls13_sni),
      shown("in two records, split at 100", records(tls13, ends=[100])),
      shown(
        "the TLS 1.2 capture, in records of one octet",
        records(tls12, ends=Array::makei(tls12.length() - 1, i => i + 1)),
      ),
      shown(
        "grown to end at the 65,535th octet, in four records",
        grown(tls13, extensions=135, received=65535),
      ),
      shown(
        "grown to end at the 65,536th octet",
        grown(tls13, extensions=135, received=65536),
      ),
    ].join("\n"),
    content=(
      #|the TLS 1.3 capture, in one record, 1610 octets: ServerName(Some("users.example.test")), records walked 1, octets copied 0
      #|in two records, split at 100, 1615 octets: ServerName(Some("users.example.test")), records walked 4, octets copied 1605
      #|the TLS 1.2 capture, in records of one octet, 1296 octets: ServerName(Some("orders.example.test")), records walked 432, octets copied 216
      #|grown to end at the 65,535th octet, in four records, 65535 octets: ServerName(Some("users.example.test")), records walked 8, octets copied 65515
      #|grown to end at the 65,536th octet, 65536 octets: ServerName(None), records walked 0, octets copied 0
    ),
  )
}
