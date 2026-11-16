# Unmatched calls, smock's own failures and protocol checks

Some answers to a gRPC call come from smock itself, not from a Stub. This
document says what a call gets when no gRPC Stub matches it, or when it
cannot reach one, with the Near miss that smock sends; what it gets when
smock cannot serve its Stub's content; why smock never compresses; and
which calls gRPC's rules make smock refuse before they reach the Stubs,
with the timeouts, the body limit and the decoder's limits. It is part of
the [gRPC guide](../grpc.md), and assumes the Mock's Descriptor set, the
set ([Building a set](../grpc.md#building-a-set)), and its [gRPC
Stubs](../grpc.md#grpc-stubs). Its examples call a Mock `greeter` that
serves gRPC's helloworld.proto, as in the guide's [quick
start](../grpc.md#quick-start).

## Contents

- [Unmatched calls](#unmatched-calls)
  - [Calls answered from their HEADERS](#calls-answered-from-their-headers)
  - [The Near miss trailer](#the-near-miss-trailer)
- [smock's own failures](#smocks-own-failures)
- [Compression](#compression)
- [Protocol checks and limits](#protocol-checks-and-limits)
  - [The order of the checks](#the-order-of-the-checks)
  - [Timeouts](#timeouts)
  - [The body limit](#the-body-limit)
  - [The decoder's limits](#the-decoders-limits)

## Unmatched calls

A call that no gRPC Stub on its method matches gets UNIMPLEMENTED, the
status gRPC servers give a method they do not serve. smock sends it as
[Trailers-Only](metadata-and-status.md#trailers-only): one HEADERS block
that ends the stream, with `:status` 200, `content-type: application/grpc`,
`grpc-status: 12` and the fixed `grpc-message` `no Stub matched`. Take a
lone Mock, which is the Default Mock, with one Stub for Tom:

```yaml
mocks:
  - name: greeter
    grpc:
      descriptorSet: greeter.binpb
stubs:
  - id: hello
    mock: greeter
    request:
      path: /helloworld.Greeter/SayHello
      body: { json: { name: Tom } }
    response:
      json: { message: Hello Tom }
```

A call with `{"name": "Ann"}` then gets:

```text
:status: 200
content-type: application/grpc
grpc-status: 12
grpc-message: no Stub matched
smock-mock: greeter; via=default
smock-near-miss: hello; failed=body
date: Sat, 14 Nov 2026 07:00:00 GMT
```

`smock-mock` is there because the Default Mock answered, as on HTTP. The
message never changes, so a test that checks it stays stable.

The Mock's `noMatch` applies to HTTP requests only. Its status and its
headers never reach a gRPC call.

The Journal records an unmatched call with the HTTP status 200, the
`grpcStatus` `UNIMPLEMENTED`, and its full Near miss: each condition that
the closest Stub failed, with what it expects and what the call sent. The
call is in the unmatched list, `GET /v1/journal/unmatched`, and the
request metrics count it as an unmatched request of its Mock.

### Calls answered from their HEADERS

A call that cannot reach a gRPC Stub gets UNIMPLEMENTED as soon as its
HEADERS arrive, without waiting for its message, so the client does not
wait for a timeout. Each case has its own fixed `grpc-message`:

| The call | `grpc-message` |
|---|---|
| No Mock lists its Host, and there is no Default Mock | `no Mock for this Host` |
| Its Mock has no set | `the Mock has no Descriptor set` |
| Its `:path` is not `/service/method`, or names no method of the set | `unknown method` |
| Its method streams | `streaming methods are not served yet` |

The answer is Trailers-Only, as for a call that no Stub matched. When the
client is still sending its request, RST_STREAM `NO_ERROR` follows the
answer and tells it to stop. So with the Mock and Stub of
[Unmatched calls](#unmatched-calls), a call to
`/helloworld.Greeter/SayGoodbye`, a method that helloworld.proto lacks,
gets:

```text
:status: 200
content-type: application/grpc
grpc-status: 12
grpc-message: unknown method
smock-mock: greeter; via=default
smock-near-miss: hello; failed=path,body
date: Sat, 14 Nov 2026 07:00:00 GMT
```

then RST_STREAM `NO_ERROR` if the call has not ended. A client reports
`Code: Unimplemented` with the message.

The call is still an unmatched call of its Mock. The Journal records it
with an empty body, whose `size` counts the octets that had arrived, and
with its Near miss when it has one. It is in the unmatched list, and the
request metrics count it as unmatched. A call whose Host reaches no Mock
is counted under `mock=""`.

smock looks the call up again when its request ends. A call that a reload
has left without a gRPC Stub to reach by then gets the same answer, then,
with the octets of its message as its body's `size`
([Reloads](../grpc.md#reloads)).

### The Near miss trailer

The Near miss is the gRPC Stub of the call's Mock that failed the fewest
conditions, the one tried first on a tie, as on HTTP ([When no Stub
matches](../definition-files/matching.md#when-no-stub-matches)). The call's
Session's [Ephemeral gRPC Stubs](../grpc.md#ephemeral-grpc-stubs) count, and
are tried first, but not one whose method a reload took away. A Stub on
another method fails the `path` condition, so a call to a method that no
Stub is on, or that the set lacks, has a Near miss too. smock sends it in
the `smock-near-miss` field of the answer, in the form of the HTTP
`Smock-Near-Miss` header: the Stub's ID, then the conditions it failed. With
a Stub that requires the metadata `x-tenant: acme`, a call without it gets:

```text
smock-near-miss: hello; failed=header:x-tenant
```

The field is ASCII only. The Stub ID and the names in it, such as a
metadata name, are percent-encoded where they hold anything other than the
characters of an HTTP token. It never carries what a condition expects or
what the call sent: the Journal entry has those.

A gRPC client reads the field as trailing metadata, as it reads every field
of a Trailers-Only answer. grpcurl prints it with `-v`, among the response
trailers.

A call has no Near miss, and its answer no `smock-near-miss` field, when
its Host reaches no Mock, or its Mock has no gRPC Stub, which a Mock
without a set never has. An HTTP Stub is never a call's Near miss, even
one whose path pattern takes the call's path.

## smock's own failures

smock's own HTTP answers never reach a gRPC call. An HTTP request whose Stub
cannot serve its content gets a 500 or a 507 with a JSON body ([Missing
values and render
errors](../definition-files/templates.md#missing-values-and-render-errors)).
A gRPC call gets Trailers-Only instead: one HEADERS block that ends the
stream, with `:status` 200, `content-type: application/grpc`, its
`grpc-status`, a fixed ASCII `grpc-message`, `smock-mock` when the Default
Mock answered, and `date`. None of the Stub's metadata, trailers or details
go out with it.

| What fails | `grpc-status` | `grpc-message` | In the Journal entry |
|---|---|---|---|
| A template of the Stub: its reply, its message, its metadata, its details, a `variables` value, or a `dataWrites` key or value. Also a rendered metadata value that breaks gRPC's rules ([Reply metadata](metadata-and-status.md#reply-metadata)), a rendered reply that does not fit the output type ([The reply](messages.md#the-reply)), and a rendered detail that does not fit its type ([Error details](metadata-and-status.md#error-details)) | 13, INTERNAL | `template failed` | `templateError` |
| A write of the Stub's `dataWrites` cannot be applied ([When a write fails](../definition-files/data-buckets.md#when-a-write-fails)) | 13, INTERNAL | `data write failed` | `dataError` |
| The Stub's writes, Variables and data writes together, would pass the bound on per-Session state ([The state bound](../definition-files/variables.md#the-state-bound)) | 8, RESOURCE_EXHAUSTED | `state limit reached` | `grpcStatus` only |
| A block of the reply's metadata is too large to send ([Metadata size](metadata-and-status.md#metadata-size)) | 13, INTERNAL | `reply metadata too large` | `templateError` |

So a call whose `variables` value reads `${body.missing.name}` gets:

```text
:status: 200
content-type: application/grpc
grpc-status: 13
grpc-message: template failed
smock-mock: greeter; via=default
date: Sat, 14 Nov 2026 07:00:00 GMT
```

and its Journal entry has the HTTP status 200, the `grpcStatus`
`INTERNAL` and the same `templateError` as an HTTP request would get:

```json
{ "stub": "variables", "status": 200, "grpcStatus": "INTERNAL",
  "templateError": { "at": "/variables/who", "message": "body.missing.name is missing" } }
```

smock answers INTERNAL since the fault is the mock's own: UNKNOWN would
say that the application threw. RESOURCE_EXHAUSTED is gRPC's status for a
server out of resources, and the refused writes count in
`smock_state_writes_refused_total`, as on HTTP.

The rest is as on HTTP. A `variables` value or a `dataWrites` key or value
that fails to render, a write that cannot be applied, and writes past the
state bound write nothing, Variables included, and no response is picked. A
reply that fails once picked keeps the writes made before it. The Scenario
move stands. The Stub's delay holds the answer back, and the call's deadline
can cut it short ([Deadlines](state-and-faults.md#deadlines)). The Stub's
connection Fault ends the call as it would end the Stub's reply, and a
`partial` one sends smock's own HEADERS
([Faults](state-and-faults.md#faults)). The request metrics count the call
under its Mock and Stub. The `mockoon` log format writes its error line, and
its `Transaction recorded` line gives `responseStatus` 200.

## Compression

smock never decompresses a message and never compresses a reply, so a
compressed request cannot use up its memory. gRPC clients send their
messages uncompressed unless told otherwise.

A message's flag says whether it is compressed: 0 for a message as it is,
1 for a compressed one, with the compression that `grpc-encoding` names.

- A message with flag 0 is served, whatever `grpc-encoding` says. So a
  client that announces `grpc-encoding: gzip` but sends its message as it
  is gets its reply.
- A message with flag 1 and a `grpc-encoding` other than `identity`, such
  as `gzip`, gets UNIMPLEMENTED, as gRPC's rules of compression ask of a
  server that does not take that compression. The answer carries
  `grpc-accept-encoding: identity`, which tells the client to send its
  messages uncompressed, and a message that names the compression
  received, percent-encoded, and `identity`:

  ```text
  :status: 200
  content-type: application/grpc
  grpc-status: 12
  grpc-message: the grpc-encoding gzip is not served, only identity
  grpc-accept-encoding: identity
  date: Sat, 14 Nov 2026 07:00:00 GMT
  ```

- A message with flag 1 and no `grpc-encoding`, or `identity`, breaks
  gRPC's rules, and gets INTERNAL.
- Any other flag gets INTERNAL.

smock checks the flag as soon as the message's prefix arrives. A reply
never carries `grpc-encoding`, and its message always has flag 0. A
client's `grpc-accept-encoding` changes nothing.

## Protocol checks and limits

smock refuses a call that gRPC's rules refuse before the call reaches the
Stubs, and answers it as gRPC servers answer it. The answer is
[Trailers-Only](metadata-and-status.md#trailers-only), with `:status` 200,
its gRPC status and a fixed `grpc-message`. Two answers get another
`:status`, as grpc-go answers them: 405 for a method other than `POST`, and
400 for a malformed `grpc-timeout`. Both carry `grpc-status: 13` (INTERNAL).
Two messages name what the call sent: the encoding of a compressed message,
and the numbers of a message whose JSON holds too many values.

| The call | Checked | `:status` | gRPC status | `grpc-message` |
|---|---|---|---|---|
| Its method is not `POST` | on HEADERS | 405 | INTERNAL | `the method must be POST` |
| Its subtype is neither none nor `proto` ([Other subtypes](../grpc.md#other-subtypes)) | on HEADERS | 200 | UNIMPLEMENTED | `only the proto content subtype is served` |
| Its `grpc-timeout` is malformed ([Timeouts](#timeouts)) | on HEADERS | 400 | INTERNAL | `the grpc-timeout is malformed` |
| Its body is over `--body-limit` ([The body limit](#the-body-limit)) | as soon as it shows | 200 | RESOURCE_EXHAUSTED | `the request is over the body limit` |
| A message's flag is neither 0 nor 1 | on the message's prefix | 200 | INTERNAL | `a message flag is neither 0 nor 1` |
| A message is compressed, with no `grpc-encoding` or with `identity` ([Compression](#compression)) | on the message's prefix | 200 | INTERNAL | `a compressed message needs a grpc-encoding other than identity` |
| A message is compressed with another `grpc-encoding` ([Compression](#compression)) | on the message's prefix | 200 | UNIMPLEMENTED | `the grpc-encoding gzip is not served, only identity`, with the encoding received |
| The request ends inside a message's prefix | at the end | 200 | INTERNAL | `the request ends inside a message prefix` |
| The request ends inside a message | at the end | 200 | INTERNAL | `the request ends inside a message` |
| The request has no message | at the end | 200 | UNIMPLEMENTED | `the request has no message` |
| The request has more than one message | at the end | 200 | UNIMPLEMENTED | `the request has more than one message` |
| Its message does not parse, or holds a value that smock cannot print | at the end | 200 | INTERNAL | `the request message cannot be decoded` |
| Its message's JSON passes `--body-limit` as smock prints it ([The decoder's limits](#the-decoders-limits)) | at the end, as soon as it shows | 200 | RESOURCE_EXHAUSTED | `the decoded request message is over the body limit` |
| Its message's JSON holds more values than a message of its size may print ([The values a message may print](#the-values-a-message-may-print)) | at the end, as soon as it shows | 200 | RESOURCE_EXHAUSTED | `the decoded request message holds more than 108768 values, the most for a message of 19000 octets`, with the two numbers of the call |

A message is the 5-octet prefix, a flag and a length, then the octets
the length announces. A message of zero octets, `00 00 00 00 00`, is one
message, with every field at its default, so a call to a method that
takes `google.protobuf.Empty` is served. A unary method takes exactly one
message, so a request with none or with several is refused, as gRPC
libraries refuse it.

A message does not parse, as protobuf's parsers refuse it, when:

- It holds a proto3 string that is not UTF-8.
- It holds field number 0 or one above 2^29-1, or wire type 6 or 7.
- A varint, a fixed-size value or a length is cut short, a packed field
  included.
- A group's end tag names another field, or the message ends inside a
  group.
- Its messages nest deeper than 100
  ([The decoder's limits](#the-decoders-limits)).
- It lacks a proto2 required field ([proto2
  types](messages.md#proto2-types)).

smock cannot print:

- A Timestamp, a Duration or a FieldMask path out of its range or form
  ([Well-known types](messages.md#well-known-types)).
- A Value that holds no value, NaN or an infinity ([JSON
  values](messages.md#json-values-struct-value-listvalue-and-nullvalue)).
- An Any whose type the set lacks ([Any](messages.md#any)).
- A value of a type that it does not serve, of an editions file or a
  MessageSet ([What is not served](messages.md#what-is-not-served)).

A refused call never reaches the Stubs. It is not in the Journal, it
moves no Scenario, and the request metrics count it as a rejected
request, with `mock=""` and `stub=""`, not as an unmatched request. When
smock refuses a call before the client has sent all of its request,
RST_STREAM `NO_ERROR` follows the answer and tells the client to stop
sending. Frames that still arrive on that stream are ignored. A call
whose request has ended gets the answer alone. So a `GET` with
`content-type: application/grpc` gets:

```text
:status: 405
content-type: application/grpc
grpc-status: 13
grpc-message: the method must be POST
date: Sat, 14 Nov 2026 07:00:00 GMT
```

then RST_STREAM `NO_ERROR` if the call has not ended.

smock does not check `te: trailers`. gRPC clients send it, but grpc-go
does not require it, and a mock should accept every real client, so a
call without it is served.

### The order of the checks

A call that breaks several rules gets the answer of the first check it
fails. On its HEADERS, smock makes six checks, in this order:

1. It makes its checks of every HTTP/2 request. A header list over
   `--header-size-limit` or with more fields than `--header-count-limit`
   gets 431, and a request that HTTP/1.1's rules refuse gets 400, with no
   gRPC status ([Ports and detection](../grpc.md#ports-and-detection)).
2. It checks the method, which must be `POST`.
3. It checks the subtype.
4. It checks each `grpc-timeout`.
5. It checks the body limit, by `content-length`.
6. It looks up the call's Mock, its set and its method ([Calls answered from
   their HEADERS](#calls-answered-from-their-headers)).

So a `PUT` with `content-type: application/grpc+json` gets 405, and a
call with a malformed `grpc-timeout` to a method that the set lacks gets
400. Each message's prefix is checked as it arrives, first by the length
it announces, then by its flag. Once the request has ended, smock looks
the call's Mock and method up again, then checks that the body ends after
a whole message, then that it holds exactly one, then decodes it.

### Timeouts

A client gives a call its time in `grpc-timeout`: 1 to 8 digits, then
the unit, `H` hours, `M` minutes, `S` seconds, `m` milliseconds, `u`
microseconds or `n` nanoseconds, such as `250m` or `5S`. Any other value
is malformed, and gets 400 with INTERNAL: `1x`, `1.5S`, `250ms`, nine
digits, a sign, a space. Eight digits of any unit are read, `99999999H`
included, and so is a timeout of 0 in any unit, such as `0m`. Of several
`grpc-timeout` fields, each must be well formed.

A well-formed timeout gives the call its deadline
([Deadlines](state-and-faults.md#deadlines)).

### The body limit

`--body-limit`, 10 MiB by default, bounds a call's body, the 5-octet
prefix of each message included. A body over it gets RESOURCE_EXHAUSTED,
the status gRPC gives a message over a server's limit, with `:status`
200, instead of the 413 that an HTTP request gets
([Request bodies](../http2.md#request-bodies)). smock answers as soon as the
excess shows, before it reads the rest:

- On HEADERS, when `content-length` declares more octets than the limit.
- On a message's prefix, when the length it announces takes the body
  over the limit, before any octet of the message arrives.
- On a DATA frame, when the octets received pass the limit. smock keeps
  none of them.

So with `--body-limit 32`, a call whose framed message takes 32 octets
passes, and a prefix that announces 28 octets gets RESOURCE_EXHAUSTED at
once, then RST_STREAM `NO_ERROR`. The message's JSON must fit within the
limit too, so a small limit refuses messages that a body of its size can
hold ([The decoder's limits](#the-decoders-limits)).

`--header-size-limit` bounds a call's header list, as it bounds an HTTP
request's, and also each block of a reply's metadata: a reply over it, or
over the client's own limit, gets INTERNAL `reply metadata too large`
([Metadata size](metadata-and-status.md#metadata-size)).

`--body-limit` also bounds the JSON that smock decodes a message into.
The values of that JSON have a bound of their own, which follows the size
of the message ([The decoder's limits](#the-decoders-limits)).

### The decoder's limits

A small message can ask a decoder for far more than its size. smock
bounds what decoding a call's message may cost, so that its JSON, once
decoded, costs no more than the largest JSON body an HTTP request may
send:

- **Nesting.** Messages may nest 100 deep. That is the default of
  protobuf's C++ and Java parsers. Each nested message is a level, and so
  is each group, each map entry and the message an Any holds. So each
  object in a Struct takes three levels, for the Struct, its entry and
  the Value, and each list in a Value takes two, for the ListValue and
  the Value. A message nested deeper does not parse, and gets INTERNAL.
- **Lengths.** smock checks every length against the octets left before
  it reads the value, and allocates nothing for a length it has not
  checked. A length that runs past its message, or past the message that
  holds it, makes the message not parse, and gets INTERNAL.
- **The JSON.** smock counts the JSON as it prints it, and stops as soon
  as the JSON passes `--body-limit`: the call gets RESOURCE_EXHAUSTED
  `the decoded request message is over the body limit`. A field without
  presence prints at its default, so an empty element of a list of
  messages, 2 octets, prints every field of its type. Without the limit,
  a 10 MiB message could print gigabytes.
- **The JSON's values.** smock counts the JSON values it prints too, and
  stops before the one that would pass what a message of that size may
  print: 32,768 values, and 4 more for each octet of the message. The call
  gets RESOURCE_EXHAUSTED, with the two numbers in its `grpc-message`. [The
  values a message may print](#the-values-a-message-may-print) says what
  counts as a value, and which messages pass.
- **What smock holds to print it.** smock keeps notes of a message until
  it has printed that message. It notes each place where the records of a
  list do not follow the list's last ones, each record of a message field
  after its first, and each map entry. It counts 48 octets for a note, 64
  for a map entry, and 48 more for a map entry with a string key, and
  these too may take at most `--body-limit`. A message as clients encode
  it needs few such notes. One of 10 MiB whose records alternate between
  two lists gets RESOURCE_EXHAUSTED.

So once smock has decoded a call's message, the call holds it once as it
came, and once as JSON, each within `--body-limit`. While smock decodes
the message, the call holds more. The buffers that the JSON's text grows
through may take up to three times `--body-limit`, as the list below
explains, and the notes that smock holds to print the message up to one
more. For example, a message of 10 MiB of empty `Item`s in a
`repeated Item items`, where an `Item` has a string, a list and a map,
would print 160 MiB of JSON. smock answers RESOURCE_EXHAUSTED once the
JSON passes 10 MiB, in well under a second. Such a call, like an HTTP
request with a body of 10 MiB, holds tens of MiB at once.

When a condition, a template or a Near miss reads the message, smock
parses its JSON, and the parsed values cost more memory than the text.
The cost follows the Mock's own field and enum names, so it is a range.
The ranges below were measured with field names of up to 29 characters
and enum names of up to 40, for a call whose JSON smock parses once:

- A value costs about 100 octets of memory, `true` and `false` less, and
  an empty object or map about 110 more. Each octet of the JSON text
  costs about 5 more.
- The 32,768 values that a message of any size may print cost 3 to
  16 MiB. smock decodes and matches one call at a time, so calls at once
  do not add this up.
- A message of 64 KiB may print 294,912 values, which cost 34 to
  112 MiB. The most is for empty maps whose JSON just fits
  `--body-limit`. It is about 26 times the most that a JSON body of
  64 KiB costs an HTTP request, which is for deeply nested arrays.
- smock parses the JSON twice when a condition and a template both read
  the message: once for the conditions, which the Near miss shares, and
  once for the templates. It holds both sets of parsed values at once.
  So a call to a Stub that matches on the message and renders its reply
  from it costs 1.5 to 1.9 times as much. That is up to about 24 MiB for
  the 32,768 values, and up to about 194 MiB for a message of 64 KiB. An
  HTTP request pays the same way when a condition and a template both
  read its JSON body.
- smock never parses the JSON of a refused call. Such a call costs the
  text that smock printed before the bound, and the buffers that the
  text grew through. The buffer starts at twice the message's size and
  doubles as the text grows, up to `--body-limit` and one octet. At its
  peak, a call may hold every buffer the text grew through. So the text
  costs up to four times its size, and at most about three times
  `--body-limit`, 30 MiB by default. The message itself, and the notes
  that smock holds to print it, come on top of that. The example of
  [The values a message may print](#the-values-a-message-may-print),
  9,500 empty elements of 60 `int64` fields, costs 2.4 MiB. For empty
  elements of 120 enum fields, with field names of 29 characters and
  enum names of 40, a message of up to 2 KB costs up to about 11 MiB.
  One of up to 10 KB costs up to about 20 MiB. The cost steps: where a
  slightly larger message saves the buffer one doubling, the cost
  halves. So a message of 1,382 octets costs up to about 11 MiB, one of
  1,384 up to about 6 MiB, and one of 2,000 up to about 8 MiB.
- The text of a served call grows through the same buffers, whatever
  reads the message, and smock then copies the text out of the last
  one. So a served call's text costs up to about five times its size
  once it outgrows its first buffer, and at most about four times
  `--body-limit`, 40 MiB by default. For example, a message of 544
  octets that prints 2.4 MB of JSON costs about 9 MiB when no
  condition, template or Near miss reads it. The costs of a parsed
  call, above, include this one.
- Near `--body-limit` the JSON's octets are the bound that counts. The
  JSON of a call may then cost hundreds of MiB once parsed, as the JSON
  body of an HTTP request of that size may, and more than 1 GiB when
  smock parses it twice.

So the bounds hold a call's cost down, and a small message can still cost
far more memory than its size
([The values a message may print](#the-values-a-message-may-print)). For
a small Pod, lower `--body-limit`
([Limits and timeouts](../http2.md#limits-and-timeouts)): the JSON's octets
bound its values too.

#### The values a message may print

Once parsed, JSON costs memory by its values more than by its octets. A
field without presence prints at its default and costs the message no
octet. So a small message could print JSON that fits `--body-limit` and
still costs thousands of times the message's size to hold. For example,
a list of 9,500 empty elements of a message with 60 `int64` fields takes
19,000 octets. A message that holds only that list would print 4.5 MB of
JSON that holds 579,502 values.

smock bounds the values by the size of the message:

- A **value** is every JSON value of the decoded text: each object,
  array, string, number, `true`, `false` and `null`. The whole message is
  one. A member's name is none. So `{"name":"","sizes":[]}` holds 3.
- A message of N octets, without its 5-octet prefix, may print at most
  **32,768 + 4 × N** values: 32,768 for a message of any size, and 4 more
  for each octet. An empty message may print 32,768 values, one of 1 KiB
  36,864, and one of 1 MiB 4,227,072. The example above may print
  108,768.
- A call past the bound gets RESOURCE_EXHAUSTED, as one whose JSON passes
  `--body-limit` does: Trailers-Only, not journaled, counted as rejected
  traffic. smock stops printing at the bound. So its `grpc-message` gives
  the bound and the message's octets, not the values the message holds:
  `the decoded request message holds more than 108768 values, the most
  for a message of 19000 octets`.
- The bound applies whatever the Mock's Stubs read. A Mock whose Stubs
  read only the metadata refuses the same messages.
- Whichever bound the JSON passes first, as smock prints it, answers.
  For a small message that is the values. For a message of a few hundred
  KB or more it is `--body-limit`, with `the decoded request message is
  over the body limit`.

A value that a message sends takes an octet or more, so the values a
message sends never number more than its octets. Only fields printed at
their default can take a message past the bound. Those are the fields
without presence, an empty list or map among them. A message field, a
member of a oneof and a proto3 `optional` field have presence, and print
only when the message holds them
([The request message as JSON](messages.md#the-request-message-as-json)). In
practice the bound refuses long lists of wide, almost empty messages.

An element of a list that prints f fields, and takes n octets with its
tag and its length, prints f + 1 values and allows 4 × n. So a list
passes at any length, until `--body-limit`, when n is at least
(f + 1) / 4. Otherwise it passes up to about 32,766 / (f + 1 − 4 × n)
elements:

| The elements | Octets each | Pass at any length | Wider elements |
|---|---|---|---|
| default-constructed, with no field set | 2 | up to 7 printed fields | up to about 32,766 / (f − 7) of them: 10,922 of 10 fields, 2,520 of 20, 618 of 60 |
| with one small field set, such as a bool or a small number | 4 | up to 15 printed fields | up to about 32,766 / (f − 15) of them: 728 of 60 fields |
| with a name of 8 characters | 12 | up to 47 printed fields | up to about 32,766 / (f − 47) of them: 2,520 of 60 fields |

A list whose field number is 16 or more has a tag of 2 octets, so each
of its elements takes one octet more, and allows 4 more values.

So a list of thousands of default-constructed or almost empty wide
messages is refused, and so is a large sparse grid of wide cells. A wide
element can have a field set and still be almost empty: 1,000 rows of 60
fields with one small number each are refused. No flag changes the bound
or turns it off, and `--body-limit` does not move it. To send such a
list, set fields in the elements, since each octet sent allows four more
values, such as one field in every cell of a grid. Or send fewer
elements, or split the call.

The octets are counted as sent. A client that writes every zero, or
writes a list unpacked, sends more octets for the same message, and
passes where the message as generated code encodes it is refused.

So the bound is a price in octets, not a cap on what a call may cost.
Each octet that a client sends allows 4 more values, whatever the octet
carries, and an octet of padding counts as any other. The list of the
example above is refused in a message of 19,000 octets. It is served in
a message of 136,684 octets, where an unknown field of zeros takes the
rest. Its JSON then costs about 78 MiB once parsed, as it would without
the bound, or about 142 MiB when a condition and a template both read
it. So the bound sets how many octets a client must send for the values
smock prints. It does not stop a message from costing far more memory
than its size:
[The decoder's limits](#the-decoders-limits) gives the costs.

To count a message's values, count the values of its JSON:
`jq '[..] | length'` does it for a JSON text. The Journal shows the JSON
of a served message, cut at `--journal-body-limit`, 4,096 octets by
default, so raise that limit to count a large message there. Keep
`--journal-max-bytes` well above the JSON's size too. An entry also
counts its request line and headers, a few hundred octets or more. The
entry of an unmatched call holds the JSON again when its Near miss shows
a body condition, and then counts up to three times the JSON's size. The
Journal evicts at once an entry that takes more than the bound.
smock never shows the JSON of a refused message, so count such a message
with protobuf's own printer, told to print the fields without presence.
In Python, with protobuf 5.26 or later:

```python
from google.protobuf import json_format


def values(json):
    if isinstance(json, dict):
        return 1 + sum(values(member) for member in json.values())
    if isinstance(json, list):
        return 1 + sum(values(element) for element in json)
    return 1


decoded = json_format.MessageToDict(
    message, always_print_fields_with_no_presence=True
)
print(values(decoded), "values from", message.ByteSize(), "octets")
```

A [rendering](rendering-and-journal.md#the-samples-message) refuses a sample
past the bound too.
