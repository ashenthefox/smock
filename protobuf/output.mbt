// The JSON text that `decode_json` prints, bounded by the limit it is
// given. What is printed is counted as it is printed, and printing stops
// with `TooLarge` as soon as it passes the limit. So a message of a few
// octets whose JSON would be far larger, such as a list of empty messages
// each printed with every field at its default, costs no more than the
// limit.

///|
/// The limit of an output that only the size of what it prints bounds, as
/// for a value of a Definition file printed as `decode_json` prints it.
let unbounded : Int32 = 0x7FFF_FFFF

///|
/// JSON text being printed, which may take at most `limit` octets.
priv struct Output {
  /// The text so far, at the start of `data`, which never grows past the
  /// most the text may take.
  mut data : FixedArray[Byte]
  /// The length of the text so far.
  mut length : Int32
  /// The most octets the text may take.
  limit : Int32
}

///|
/// An output with no text yet, bounded by `limit`, with room for
/// `size_hint` octets of text, or `limit` when it is smaller.
fn Output::new(size_hint~ : Int32, limit~ : Int32) -> Output {
  let limit = if limit < 0 { 0 } else { limit }
  let capacity = if size_hint < 0 || size_hint > limit {
    limit
  } else {
    size_hint
  }
  { data: FixedArray::make(capacity, b'\x00'), length: 0, limit, }
}

///|
/// Makes room for `count` more octets, or raises `TooLarge` when they
/// would take the text past the limit.
fn Output::reserve(self : Output, count : Int32) -> Unit raise DecodeError {
  // The most the text may still take.
  let room = self.limit - self.length
  if count > room {
    raise TooLarge(limit=self.limit)
  }
  let needed = self.length + count
  if needed > self.data.length() {
    // Doubled, but never past the most the text may take.
    let most = self.length + room
    let doubled = if self.data.length() > most / 2 {
      most
    } else {
      2 * self.data.length()
    }
    let data = FixedArray::make(
      if doubled > needed {
        doubled
      } else {
        needed
      },
      b'\x00',
    )
    data.unsafe_blit(0, self.data, 0, self.length)
    self.data = data
  }
}

///|
/// Writes `value`.
fn Output::write_byte(self : Output, value : Byte) -> Unit raise DecodeError {
  if self.length >= self.data.length() || self.length >= self.limit {
    self.reserve(1)
  }
  self.data[self.length] = value
  self.length += 1
}

///|
/// Writes `octets`.
fn Output::write_bytes(
  self : Output,
  octets : BytesView,
) -> Unit raise DecodeError {
  self.reserve(octets.length())
  for octet in octets {
    self.data[self.length] = octet
    self.length += 1
  }
}

///|
/// Writes `text`, which is ASCII, as numbers print, an octet a code unit.
fn Output::write_ascii(self : Output, text : String) -> Unit raise DecodeError {
  self.reserve(text.length())
  for i in 0..<text.length() {
    self.data[self.length] = text[i].to_byte()
    self.length += 1
  }
}

///|
/// Takes the braces off the object printed last, from `at`, so that its
/// members follow those of the object it is printed in: its `{` becomes
/// the comma before them, and an empty object leaves only the `}` that
/// ends the object it is printed in.
fn Output::unwrap_object(self : Output, at : Int32) -> Unit {
  if self.length - at == 2 {
    self.data[at] = b'}'
    self.length = at + 1
  } else {
    self.data[at] = b','
  }
}

///|
/// The text printed so far.
fn Output::to_bytes(self : Output) -> Bytes {
  Bytes::from_array(self.data[0:self.length])
}
