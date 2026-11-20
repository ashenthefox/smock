// The percent-encoding of a status message, as `grpc-message` carries it,
// through the module's public interface. The expected values are gRPC's
// own: the rule of its HTTP/2 protocol document
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md), and the
// message of its interop suite's `special_status_message` case with the
// value grpc-go's tests encode it to.

///|
/// `bytes`, octets 0x20 to 0x7E, as text.
fn ascii(bytes : Bytes) -> String {
  let out = StringBuilder()
  for octet in bytes {
    out.write_char(octet.to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
test "printable ASCII other than % stays as it is" {
  inspect(
    ascii(@grpc.percent_encode("no Stub matched")),
    content="no Stub matched",
  )
  let printable = StringBuilder()
  for code in 0x20..<=0x7E {
    if code != '%'.to_int() {
      printable.write_char(code.unsafe_to_char())
    }
  }
  // Without its leading space, which an end of the value cannot keep.
  let printable = printable.to_string()[1:].to_owned()
  inspect(ascii(@grpc.percent_encode(printable)) == printable, content="true")
}

///|
test "% and every octet outside 0x20 to 0x7E become %XX, in upper-case hex" {
  inspect(ascii(@grpc.percent_encode("100%")), content="100%25")
  inspect(
    ascii(@grpc.percent_encode("a\u{0}b\u{1f}c\u{7f}d")),
    content="a%00b%1Fc%7Fd",
  )
}

///|
test "gRPC's interop message, with controls, BMP and non-BMP characters, is encoded octet by octet in UTF-8" {
  inspect(
    ascii(
      @grpc.percent_encode(
        "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n",
      ),
    ),
    content="%09%0Atest with whitespace%0D%0Aand Unicode BMP %E2%98%BA and non-BMP %F0%9F%98%88%09%0A",
  )
  inspect(ascii(@grpc.percent_encode("é")), content="%C3%A9")
  // The first and the last code point of each length that RFC 3629's
  // table, in section 3, gives a UTF-8 sequence: U+0080 and U+07FF take
  // two octets, U+0800 and U+FFFF three, U+10000 and U+10FFFF four
  // (Python's UTF-8 encoder gives the same octets). The last two are
  // surrogate pairs in the text, D800 DC00 and DBFF DFFF (RFC 2781,
  // section 2.1), so each pair is one code point.
  let edges = [
    "\u{80}", "\u{7FF}", "\u{800}", "\u{FFFF}", "\u{10000}", "\u{10FFFF}",
  ]
  inspect(
    edges.map(text => ascii(@grpc.percent_encode("a\{text}b"))).join("\n"),
    content=(
      #|a%C2%80b
      #|a%DF%BFb
      #|a%E0%A0%80b
      #|a%EF%BF%BFb
      #|a%F0%90%80%80b
      #|a%F4%8F%BF%BFb
    ),
  )
}

///|
test "a space at either end becomes %20, and spaces inside stay" {
  inspect(ascii(@grpc.percent_encode(" try again ")), content="%20try again%20")
  inspect(ascii(@grpc.percent_encode("  two  ")), content="%20 two %20")
  inspect(ascii(@grpc.percent_encode(" ")), content="%20")
  inspect(ascii(@grpc.percent_encode("  ")), content="%20%20")
  inspect(
    ascii(@grpc.percent_encode("try again ☺")),
    content="try again %E2%98%BA",
  )
}

///|
test "an empty message stays empty" {
  inspect(@grpc.percent_encode("").length(), content="0")
}

///|
test "a lone surrogate, which UTF-8 cannot hold, is encoded as U+FFFD" {
  // docs/grpc/metadata-and-status.md, The message: "A lone surrogate, such
  // as U+D800 with no low surrogate after it, has no UTF-8 form, so smock
  // encodes U+FFFD in its place: it goes out as `%EF%BF%BD`." The
  // maintainer confirmed it on 2026-11-17 (#275). RFC 3629, section 3:
  // UTF-8 prohibits "encoding character numbers between U+D800 and U+DFFF".
  let high = (0xD83D).unsafe_to_char()
  let low = (0xDE08).unsafe_to_char()
  inspect(
    ascii(@grpc.percent_encode("a\{high}b\{low}c")),
    content="a%EF%BF%BDb%EF%BF%BDc",
  )
  // A high surrogate at the end, with nothing after it.
  inspect(ascii(@grpc.percent_encode("a\{high}")), content="a%EF%BF%BD")
  // U+DFFF, the last low surrogate, is one too; U+E000, the first code
  // point after the low surrogates, is a character UTF-8 holds in three
  // octets, EE 80 80 (RFC 3629, section 3; Python's UTF-8 encoder gives the
  // same), each of them percent-encoded as PROTOCOL-HTTP2's
  // Percent-Byte-Encoded says.
  let last_low = (0xDFFF).unsafe_to_char()
  inspect(ascii(@grpc.percent_encode("a\{last_low}")), content="a%EF%BF%BD")
  inspect(ascii(@grpc.percent_encode("a\u{E000}")), content="a%EE%80%80")
}
