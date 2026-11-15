// The testee of protobuf's conformance suite (README.md): protobuf's
// conformance_test_runner starts it with the path of the Descriptor set of
// the suite's messages, then writes requests to its stdin and reads its
// responses from its stdout, each a message in protobuf's binary encoding
// after its length, 4 octets in little-endian order. It answers until its
// stdin ends.

///|
/// Ends the process with `code`, through `moonbitlang/x`'s supported exit,
/// as cmd/smock does.
fn exit(code : Int32) -> Unit {
  @sys.exit(code)
}

///|
async fn main {
  let args = @env.args()
  guard args.length() == 2 else {
    eprintln("usage: protobuf-conformance <Descriptor set>")
    exit(2)
    return
  }
  let set = @protobuf.read_descriptor_set(@fs.read_file(args[1]).binary()[:]) catch {
    error => {
      eprintln("protobuf-conformance: \{args[1]}: \{error}")
      exit(1)
      return
    }
  }
  while read_frame() is Some(request) {
    write_frame(answer(set, request[:]))
  }
}

///|
/// The next request from stdin, without its length, or `None` once stdin
/// ends.
async fn read_frame() -> Bytes? {
  let length = @stdio.stdin.read_exactly(4) catch {
    @io.ReaderClosed => return None
    error => raise error
  }
  let length = length[0].to_int() |
    (length[1].to_int() << 8) |
    (length[2].to_int() << 16) |
    (length[3].to_int() << 24)
  Some(@stdio.stdin.read_exactly(length))
}

///|
/// Writes `response` to stdout, after its length.
async fn write_frame(response : Bytes) -> Unit {
  let length = response.length()
  let framed = FixedArray::make(4 + length, b'\x00')
  for i in 0..<4 {
    framed[i] = (length >> (8 * i)).to_byte()
  }
  framed.blit_from_bytes(4, response, 0, length)
  @stdio.stdout.write(framed.unsafe_reinterpret_as_bytes())
}
