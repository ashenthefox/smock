// gRPC's `grpc-timeout` through the module's public interface: 1 to 8
// digits, then the unit, `H` hours, `M` minutes, `S` seconds, `m`
// milliseconds, `u` microseconds or `n` nanoseconds
// (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md), read
// as nanoseconds, saturated.

///|
/// What `value`, a `grpc-timeout` value, gives: its nanoseconds, or
/// `malformed`.
fn read(value : String) -> String {
  match @grpc.timeout_ns(value) {
    Some(nanoseconds) => nanoseconds.to_string()
    None => "malformed"
  }
}

///|
test "a timeout is 1 to 8 digits and a unit, read as nanoseconds" {
  let values = [
    "1H", "1M", "1S", "1m", "1u", "1n", "250m", "00000007S", "12345678u",
  ]
  inspect(
    values.map(value => "\{value}: \{read(value)}").join("\n"),
    content=(
      #|1H: 3600000000000
      #|1M: 60000000000
      #|1S: 1000000000
      #|1m: 1000000
      #|1u: 1000
      #|1n: 1
      #|250m: 250000000
      #|00000007S: 7000000000
      #|12345678u: 12345678000
    ),
  )
}

///|
test "eight digits of every unit are read without wrapping, and eight digits of hours saturate" {
  let values = [
    "99999999H", "99999999M", "99999999S", "99999999m", "99999999u", "99999999n",
  ]
  inspect(
    values.map(value => "\{value}: \{read(value)}").join("\n"),
    content=(
      #|99999999H: 9223372036854775807
      #|99999999M: 5999999940000000000
      #|99999999S: 99999999000000000
      #|99999999m: 99999999000000
      #|99999999u: 99999999000
      #|99999999n: 99999999
    ),
  )
}

///|
test "a timeout of 0, in any unit, is read" {
  for value in ["0m", "0H", "0n", "00000000S"] {
    inspect(read(value), content="0")
  }
}

///|
test "anything but 1 to 8 digits and one of H M S m u n is malformed" {
  let values = [
    "", "1", "m", "1x", "1h", "1s", "1ms", "123456789m", "-1m", "+1m", " 1m", "1m ",
    "1.5S", "1 m", "１m", "1M1",
  ]
  for value in values {
    guard read(value) == "malformed" else {
      fail("\{value} is read as \{read(value)}")
    }
  }
}

///|
/// What `value`, a `grpc-timeout` value, gives in milliseconds, or
/// `malformed`.
fn read_ms(value : String) -> String {
  match @grpc.timeout_ms(value) {
    Some(milliseconds) => milliseconds.to_string()
    None => "malformed"
  }
}

///|
test "a timeout in milliseconds is rounded up, so that a timeout above 0 is never 0 ms" {
  let values = [
    "250m", "5S", "1M", "1H", "1n", "1u", "999999n", "1000000n", "1000001n", "1500u",
    "0m", "0n", "0H",
  ]
  inspect(
    values.map(value => "\{value}: \{read_ms(value)}").join("\n"),
    content=(
      #|250m: 250
      #|5S: 5000
      #|1M: 60000
      #|1H: 3600000
      #|1n: 1
      #|1u: 1
      #|999999n: 1
      #|1000000n: 1
      #|1000001n: 2
      #|1500u: 2
      #|0m: 0
      #|0n: 0
      #|0H: 0
    ),
  )
}

///|
test "eight digits of every unit convert to milliseconds without wrapping, and eight digits of hours from their saturated nanoseconds" {
  let values = [
    "99999999H", "99999999M", "99999999S", "99999999m", "99999999u", "99999999n",
  ]
  inspect(
    values.map(value => "\{value}: \{read_ms(value)}").join("\n"),
    content=(
      #|99999999H: 9223372036855
      #|99999999M: 5999999940000
      #|99999999S: 99999999000
      #|99999999m: 99999999
      #|99999999u: 100000
      #|99999999n: 100
    ),
  )
}

///|
test "a malformed timeout has no milliseconds" {
  for value in ["", "1", "1x", "1ms", "123456789m", "-1m", "1.5S"] {
    guard read_ms(value) == "malformed" else {
      fail("\{value} is read as \{read_ms(value)}")
    }
  }
}
