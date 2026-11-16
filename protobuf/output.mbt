// The JSON text that `decode_json` and `decode_canonical_json` print,
// bounded by the limit each is given. What is printed is counted as it is
// printed, and printing stops with `TooLarge` as soon as it passes the
// limit. So the text of a message of a few octets whose JSON would be far
// larger, such as a list of empty messages each printed with every field
// at its default, takes no more than the limit. The buffers that the text
// grows through take more than the text: each is twice the last, until
// the next would hold the limit and is the last one instead, of the limit
// and the octet that the text may pass it by while an Any's object is
// printed (`Output::reserve`, `Output::wrapped`). Together they take up to
// four times a text that has outgrown the first, and under three times
// the limit. What the decoder holds meanwhile to print the message, views
// of the input beyond one a field, is counted too, against the same limit
// on its own.
//
// The JSON values printed are counted as well, against a bound that
// follows the size of the message (`values_bound`), and printing stops
// with `TooManyValues` before the value that would pass it. Parsed, a
// value costs far more memory than its text takes, and a field printed at
// its default costs the message no octet, so the octets of the JSON alone
// let a small message grow into a large tree.

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
/// The JSON values that a message of any size may print: the floor of
/// `values_bound`.
let values_floor : Int32 = 32768

///|
/// The JSON values that a message may print more for each of its octets.
let values_per_octet : Int32 = 4

///|
/// The most JSON values that a message of `octets` octets may print:
/// `values_floor`, and `values_per_octet` more for each octet, or
/// `unbounded` when that passes it. A value is every JSON value of the
/// text: each object, array, string, number, `true`, `false` and `null`,
/// the whole message being one; a member's name is none.
fn values_bound(octets : Int32) -> Int32 {
  if octets > (unbounded - values_floor) / values_per_octet {
    unbounded
  } else {
    values_floor + values_per_octet * octets
  }
}

///|
/// JSON text being printed, which may take at most `limit` octets and hold
/// at most `most_values` JSON values, while what the decoder holds
/// meanwhile may take at most `limit` octets too (`Output::hold`).
priv struct Output {
  /// The text so far, at the start of `data`, which never grows past
  /// `limit` and one octet, the most the text may ever take.
  mut data : FixedArray[Byte]
  /// The length of the text so far.
  mut length : Int32
  /// The most octets the text may take, and what is held.
  limit : Int32
  /// The most octets the text may take for now: `limit`, and one more from
  /// `Output::wrapped` until an object's braces next come off
  /// (`Output::unwrap`).
  mut most : Int32
  /// Where the room that the text has now ends: at the end of `data`, or
  /// at `most` when that comes first. `Output::reserve` makes more.
  mut room : Int32
  /// What the decoder holds, in octets, as `Output::hold` counts it.
  mut held : Int32
  /// The JSON values printed so far, the message that is printed being
  /// one, as `Output::count_value` counts them.
  mut values : Int32
  /// The most JSON values the text may hold.
  most_values : Int32
}

///|
/// An output with no text yet, bounded by `limit`, with room for
/// `size_hint` octets of text, or for all the text may ever take when
/// `size_hint` is `limit` or more. Its text may hold at most `most_values`
/// JSON values, the value that is printed into it being the first: any
/// number when none is given.
fn Output::new(
  size_hint~ : Int32,
  limit~ : Int32,
  most_values~ : Int32 = unbounded,
) -> Output {
  // Below the largest Int32, so that the text may pass it by an octet for
  // a while (`Output::wrapped`).
  let limit = if limit < 0 {
    0
  } else if limit > 0x7FFF_FFFE {
    0x7FFF_FFFE
  } else {
    limit
  }
  // The last buffer from the start, as `Output::reserve` makes it.
  let capacity = if size_hint < 0 || size_hint >= limit {
    limit + 1
  } else {
    size_hint
  }
  {
    data: FixedArray::make(capacity, b'\x00'),
    length: 0,
    limit,
    most: limit,
    room: if capacity < limit {
      capacity
    } else {
      limit
    },
    held: 0,
    values: 1,
    most_values,
  }
}

///|
/// Counts one more JSON value, a member of an object or an element of an
/// array that is printed next, or raises `TooManyValues` when the text
/// already holds the most it may: before anything of the value is written.
fn Output::count_value(self : Output) -> Unit raise DecodeError {
  if self.values >= self.most_values {
    raise TooManyValues(limit=self.most_values)
  }
  self.values += 1
}

///|
/// Makes room for `count` more octets of text, or raises `TooLarge` when
/// they would take it past the limit.
fn Output::reserve(self : Output, count : Int32) -> Unit raise DecodeError {
  if count > self.most - self.length {
    raise TooLarge(limit=self.limit)
  }
  let needed = self.length + count
  if needed > self.data.length() {
    // Twice the last, or what is needed when that is more. A buffer that
    // would hold the limit is the last: it holds the octet past the limit
    // too, which the text may take for a while (`Output::wrapped`), so
    // that no other is made after it.
    let doubled = if self.data.length() >= self.limit / 2 {
      self.limit
    } else {
      2 * self.data.length()
    }
    let size = if doubled > needed { doubled } else { needed }
    let data = FixedArray::make(
      if size >= self.limit {
        self.limit + 1
      } else {
        size
      },
      b'\x00',
    )
    data.unsafe_blit(0, self.data, 0, self.length)
    self.data = data
    self.bound(self.most)
  }
}

///|
/// Lets the text take at most `most` octets for now, and sets the room it
/// has by that and by the buffer.
fn Output::bound(self : Output, most : Int32) -> Unit {
  self.most = most
  self.room = if self.data.length() < most { self.data.length() } else { most }
}

///|
/// Writes `value`. It tests the room, not the buffer's length: the buffer
/// may hold an octet more than the text may take for now.
fn Output::write_byte(self : Output, value : Byte) -> Unit raise DecodeError {
  if self.length >= self.room {
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
/// Counts `octets` more as held, or raises `TooLarge` when what is held
/// would pass the limit: what the decoder holds until it lets it go
/// (`Output::release_to`).
fn Output::hold(self : Output, octets : Int32) -> Unit raise DecodeError {
  if octets > self.limit - self.held {
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
/// Where the object that is printed next starts, an object whose braces
/// `Output::unwrap` takes off once it is printed. Until an object's braces
/// next come off, the text may pass the limit by an octet: the `{` of this
/// object, which leaves the text when the object turns out empty.
fn Output::wrapped(self : Output) -> Int32 {
  self.bound(self.limit + 1)
  self.length
}

///|
/// Takes the braces off the object printed last, from `at`, as
/// `Output::wrapped` gave it, so that its members follow those of the
/// object it is printed in: its `{` becomes the comma before them, and an
/// empty object leaves only the `}` that ends the object it is printed in.
/// Raises `TooLarge` when the text then passes the limit.
fn Output::unwrap(self : Output, at : Int32) -> Unit raise DecodeError {
  if self.length - at == 2 {
    self.data[at] = b'}'
    self.length = at + 1
  } else {
    self.data[at] = b','
  }
  // The text keeps every octet it has now. An object printed around this
  // one, whose braces are still to come off, holds this one's member, so
  // its `{` becomes a comma.
  self.bound(self.limit)
  if self.length > self.limit {
    raise TooLarge(limit=self.limit)
  }
}

///|
/// The text printed so far.
fn Output::to_bytes(self : Output) -> Bytes {
  Bytes::from_array(self.data[0:self.length])
}
