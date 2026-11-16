// The buffers that an `Output` makes for its text, and the octet that the
// text may pass its limit by for a while. A whitebox test, since
// `decode_json` shows neither: it returns the text, which never takes more
// than the limit. Only the output's own `data` shows a buffer.

///|
/// Adds the buffer of `out` to `made` when it is not the last of them.
fn note_buffer(out : Output, made : Array[FixedArray[Byte]]) -> Unit {
  if !physical_equal(out.data, made[made.length() - 1]) {
    made.push(out.data)
  }
}

///|
/// The lengths of the buffers that an output makes, the one it starts with
/// first: an output with the limit `limit` and room for `size_hint`
/// octets, into which `limit` octets are written, `chunk` at a time, and
/// then the `{` of an object whose braces are to come off
/// (`Output::wrapped`), which takes the text one octet past the limit.
fn buffers_made(
  limit~ : Int32,
  size_hint~ : Int32,
  chunk~ : Int32,
) -> Array[Int32] raise DecodeError {
  let out = Output::new(size_hint~, limit~)
  let made = [out.data]
  let octets = Bytes::make(chunk, b'x')
  while out.length < limit {
    let left = limit - out.length
    if chunk == 1 {
      out.write_byte(b'x')
    } else if left < chunk {
      out.write_bytes(octets[:left])
    } else {
      out.write_bytes(octets[:])
    }
    note_buffer(out, made)
  }
  let _ = out.wrapped()
  out.write_byte(b'{')
  note_buffer(out, made)
  made.map(buffer => buffer.length())
}

///|
/// The buffers of `buffers_made` for a text written an octet at a time,
/// and the octets they take in all.
fn buffers_shown(limit : Int32, size_hint : Int32) -> String raise DecodeError {
  let made = buffers_made(limit~, size_hint~, chunk=1)
  let mut sum = 0
  for length in made {
    sum += length
  }
  let lengths = made.map(length => length.to_string()).join(", ")
  "limit \{limit}, room for \{size_hint}: \{lengths}; \{sum} in all"
}

///|
test "the text's buffers double from the room it starts with, and the one that would hold the limit is the last: it holds the limit and the octet that the text may pass it by, so no buffer follows it" {
  inspect(
    [
      buffers_shown(1000, 0),
      buffers_shown(1000, 300),
      buffers_shown(1000, 999),
      // Room for the limit or more, or a size hint under 0, is the last
      // buffer from the start.
      buffers_shown(1000, 1000),
      buffers_shown(1000, 5000),
      buffers_shown(1000, -1),
      // Nearly three times the limit: the largest buffer under the limit
      // is two octets short of it.
      buffers_shown(1026, 1),
      // No text may be printed, and the one octet is made: the one limit
      // whose buffers are not under three times it.
      buffers_shown(0, 0),
    ].join("\n"),
    content=(
      #|limit 1000, room for 0: 0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1001; 2024 in all
      #|limit 1000, room for 300: 300, 600, 1001; 1901 in all
      #|limit 1000, room for 999: 999, 1001; 2000 in all
      #|limit 1000, room for 1000: 1001; 1001 in all
      #|limit 1000, room for 5000: 1001; 1001 in all
      #|limit 1000, room for -1: 1001; 1001 in all
      #|limit 1026, room for 1: 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 1027; 3074 in all
      #|limit 0, room for 0: 1; 1 in all
    ),
  )
}

///|
test "the text's buffers take under three times the limit together, and only the last holds the limit: for each limit from 1 to 130, each room from none to past the limit, and a text written one, three or 64 octets at a time" {
  let mut faults = 0
  let first = []
  for limit in 1..<=130 {
    for size_hint in 0..<=(limit + 1) {
      for chunk in [1, 3, 64] {
        let made = buffers_made(limit~, size_hint~, chunk~)
        let mut sum = 0
        let mut holding = 0
        for length in made {
          sum += length
          if length >= limit {
            holding += 1
          }
        }
        if made[made.length() - 1] != limit + 1 ||
          holding != 1 ||
          sum >= 3 * limit {
          faults += 1
          if first.length() < 3 {
            let lengths = made.map(length => length.to_string()).join(", ")
            first.push(
              "limit \{limit}, room for \{size_hint}, \{chunk} at a time: \{lengths}",
            )
          }
        }
      }
    }
  }
  inspect(
    "\{faults} with a fault\{first.map(fault => "\n" + fault).join("")}",
    content="0 with a fault",
  )
}

///|
test "the text may pass the limit by one octet after `wrapped` and never by two, however many objects are wrapped, so its buffer never holds more than the limit and one octet" {
  let out = Output::new(size_hint=0, limit=10)
  out.write_bytes(b"01234567")
  // An object whose braces are to come off, and in it, at the limit,
  // another one.
  let _ = out.wrapped()
  out.write_bytes(b"{a")
  let _ = out.wrapped()
  out.write_byte(b'{')
  let next = try out.write_byte(b'}') catch {
    err => "error: \{err}"
  } noraise {
    _ => "written"
  }
  inspect(
    "\{out.length} octets in a buffer of \{out.data.length()}, and the next: \{next}",
    content="11 octets in a buffer of 11, and the next: error: the decoded message passes the limit of 10 octets",
  )
}

///|
test "an object with a member keeps every octet it has when its braces come off, so a text that it leaves one octet past the limit is refused then, by `unwrap` itself: no octet need follow the object to be refused in its place" {
  let out = Output::new(size_hint=0, limit=10)
  out.write_bytes(b"0123")
  // An object whose braces are to come off, with a member: its `}` is the
  // octet past the limit, and its `{` becomes a comma. Through
  // `decode_json` only an Any that is the whole message ends so
  // (limits_test.mbt): anywhere else an octet follows the object.
  let at = out.wrapped()
  out.write_bytes(b"{\"a\":1}")
  let unwrapped = try out.unwrap(at) catch {
    err => "error: \{err}"
  } noraise {
    _ => "kept"
  }
  inspect(
    "\{out.length} octets, and when the braces come off: \{unwrapped}",
    content="11 octets, and when the braces come off: error: the decoded message passes the limit of 10 octets",
  )
}
