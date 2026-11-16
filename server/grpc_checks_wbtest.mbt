// What a message that does not decode is refused with, by the error its
// decoding raised.

///|
test "a message whose decoded JSON holds more values than a message of its size may print is refused with RESOURCE_EXHAUSTED, and the answer names the most it may hold and its octets" {
  let shown = (refusal : CallRefusal) => {
    "\{refusal.http_status()} \{refusal.status()}: \{refusal.message()}"
  }
  inspect(
    [
      shown(decoding_refusal(@protobuf.TooManyValues(limit=7), 3)),
      // The other decoding refusals say nothing of the message's size.
      shown(decoding_refusal(@protobuf.TooLarge(limit=7), 3)),
      shown(decoding_refusal(@protobuf.DecodeError(position=0, message="x"), 3)),
    ].join("\n"),
    content=(
      #|b"200" RESOURCE_EXHAUSTED: the decoded request message holds more than 7 values, the most for a message of 3 octets
      #|b"200" RESOURCE_EXHAUSTED: the decoded request message is over the body limit
      #|b"200" INTERNAL: the request message cannot be decoded
    ),
  )
}
