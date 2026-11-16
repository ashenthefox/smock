// gRPC's `grpc-timeout`, the time a client gives a call: 1 to 8 digits,
// then the unit, `H` hours, `M` minutes, `S` seconds, `m` milliseconds,
// `u` microseconds or `n` nanoseconds
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md).

///|
/// The largest number of nanoseconds an `Int64` holds, about 292 years:
/// what a longer timeout saturates at.
let max_nanoseconds : Int64 = 0x7FFF_FFFF_FFFF_FFFFL

///|
/// The timeout that `value`, the value of a `grpc-timeout` field, gives, in
/// nanoseconds, or `None` when it is malformed: when it is not 1 to 8 ASCII
/// digits followed by one of `H`, `M`, `S`, `m`, `u` and `n`, with nothing
/// before or after. A timeout of 0 is read, in any unit. Eight digits of
/// hours are more nanoseconds than an `Int64` holds, so a timeout saturates
/// at `0x7FFF_FFFF_FFFF_FFFF` rather than wrap; every other unit fits.
pub fn timeout_ns(value : StringView) -> Int64? {
  let digits = value.length() - 1
  if digits < 1 || digits > 8 {
    return None
  }
  let mut number = 0L
  for i in 0..<digits {
    let c = value[i].to_int()
    if c < '0'.to_int() || c > '9'.to_int() {
      return None
    }
    number = number * 10L + (c - '0'.to_int()).to_int64()
  }
  let unit : Int64 = match value[digits].to_int() {
    0x48 => 3_600_000_000_000L // H
    0x4D => 60_000_000_000L // M
    0x53 => 1_000_000_000L // S
    0x6D => 1_000_000L // m
    0x75 => 1_000L // u
    0x6E => 1L // n
    _ => return None
  }
  if number > max_nanoseconds / unit {
    return Some(max_nanoseconds)
  }
  Some(number * unit)
}

///|
/// The timeout that `value`, the value of a `grpc-timeout` field, gives, in
/// whole milliseconds, or `None` when it is malformed, as `timeout_ns`
/// reads it. It is rounded up, so that a timeout above 0 is never 0 ms: a
/// nanosecond is 1 ms, and so is a millisecond. A timeout of 0 is 0 ms.
/// Eight digits of hours convert from the nanoseconds they saturate at,
/// 9,223,372,036,855 ms; every other unit converts exactly before it is
/// rounded.
pub fn timeout_ms(value : StringView) -> Int64? {
  guard timeout_ns(value) is Some(nanoseconds) else { return None }
  // Divided before it is rounded, since adding first would overflow at
  // the saturated value.
  let milliseconds = nanoseconds / 1_000_000L
  if nanoseconds % 1_000_000L > 0L {
    Some(milliseconds + 1L)
  } else {
    Some(milliseconds)
  }
}
