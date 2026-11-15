// The JSON text that `decode_json` prints, bounded by the limit it is
// given. What is printed is counted as it is printed, with what the
// decoder holds meanwhile to print it, and printing stops with `TooLarge`
// as soon as the two pass the limit. So a message of a few octets whose
// JSON would be far larger, such as a list of empty messages each printed
// with every field at its default, costs no more than the limit.

///|
/// The octets the decoder counts for each view of the input that it holds
/// to print a message beyond one a field, until it has printed it: a run
/// of records of a repeated field that does not follow the field's last
/// one, and each record of a singular message field after its first. Also
/// for each entry of a map, and each string key, until it has printed the
/// map. About what such a view costs in memory, its slot in an array
/// included.
let held_view : Int32 = 48

///|
/// The octets the decoder counts for each entry of a map beside its view,
/// until it has printed the map: its key, as a number, and its place in
/// the map's order.
let held_entry : Int32 = 16

///|
/// The limit of an output that only the size of what it prints bounds, as
/// for a value of a Definition file printed as `decode_json` prints it.
let unbounded : Int32 = 0x7FFF_FFFF

///|
/// JSON text being printed, which may take at most `limit` octets with
/// what the decoder holds meanwhile (`Output::hold`).
priv struct Output {
  /// The text so far, at the start of `data`, which never grows past the
  /// most the text may take.
  mut data : FixedArray[Byte]
  /// The length of the text so far.
  mut length : Int32
  /// The most octets the text, with what is held, may take.
  limit : Int32
  /// What the decoder holds, in octets, as `Output::hold` counts it.
  mut held : Int32
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
  { data: FixedArray::make(capacity, b'\x00'), length: 0, limit, held: 0, }
}

///|
/// Makes room for `count` more octets, or raises `TooLarge` when they
/// would take the text, with what is held, past the limit.
fn Output::reserve(self : Output, count : Int32) -> Unit raise DecodeError {
  // The most the text may still take.
  let room = self.limit - self.held - self.length
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
  if self.length >= self.data.length() || self.length + self.held >= self.limit {
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
/// Counts `octets` more as held, or raises `TooLarge` when the text, with
/// what is held, would pass the limit: what the decoder holds until it
/// lets it go (`Output::release_to`).
fn Output::hold(self : Output, octets : Int32) -> Unit raise DecodeError {
  if octets > self.limit - self.held - self.length {
    raise TooLarge(limit=self.limit)
  }
  self.held += octets
}

///|
/// Lets go of what was held since `held` was what `Output::held` held.
fn Output::release_to(self : Output, held : Int32) -> Unit {
  self.held = held
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
