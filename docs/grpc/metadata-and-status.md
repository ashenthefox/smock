# Metadata and status

This document says how a gRPC Stub sees a call's metadata, the Session it
names included, and sends a reply's initial and trailing metadata. It
then says how a reply ends: the gRPC status, the message and the error
details that the Stub's `grpc` field gives, the bound on each block of a
reply's metadata, and [Trailers-Only](#trailers-only), the one block that
an error without initial metadata goes out in. It is part of the [gRPC
guide](../grpc.md), and assumes its [gRPC Stubs](../grpc.md#grpc-stubs)
and the Mock's Descriptor set, the set ([Building a
set](../grpc.md#building-a-set)), in which error details are looked up.
The grpcurl and curl commands call the smock of the guide's [quick
start](../grpc.md#quick-start): its Mock `greeter`, and its Admin API with
the token `change-me`.

## Contents

- [Metadata](#metadata)
  - [Request metadata](#request-metadata)
  - [Sessions](#sessions)
  - [Reply metadata](#reply-metadata)
- [Status and message](#status-and-message)
  - [The status](#the-status)
  - [The message](#the-message)
  - [Error details](#error-details)
  - [Metadata size](#metadata-size)
  - [Trailers-Only](#trailers-only)

## Metadata

gRPC's metadata is HTTP/2's header fields. A call sends its metadata in
its HEADERS, and smock shows it to the Stubs as the request's headers,
none hidden ([Request metadata](#request-metadata)), the `baggage` field
that names the call's [Session](#sessions) included. A reply sends
initial metadata in its HEADERS and trailing metadata in its trailers,
which a gRPC Stub gives in `headers` and `grpc.trailers`
([Reply metadata](#reply-metadata)). Each block of a reply's metadata is
bounded ([Metadata size](#metadata-size)).

### Request metadata

A call's metadata reaches the Stubs as its headers, every field, none
hidden. That includes the fields gRPC sets itself, such as
`content-type`, `te`, `grpc-timeout` and `user-agent`. Each field line is
one value, as on HTTP, so a name sent twice has two values. `headers`
conditions and `header.NAME` in templates see every field, with names in
lower case, as HTTP/2 sends them:

```yaml
request:
  path: /helloworld.Greeter/SayHello
  headers:
    authorization: { pattern: "Bearer .+" }
    x-tenant: acme
response:
  template: true
  headers: { x-request-id: "${header.x-request-id ?? 'none'}" }
  json: { message: Hello }
```

`header.NAME` gives a name's first value, and a condition holds when one of
its values meets it. The Journal records the metadata as the entry's
headers, in the order received ([The Journal and the
metrics](rendering-and-journal.md#the-journal-and-the-metrics)).

Binary metadata, whose name ends with `-bin`, holds base64. gRPC lets a
client send it with or without its padding, and a server must take both.
smock takes the padding off, so padded and unpadded clients look alike:

- A call's `-bin` value loses the `=` that end each comma-separated
  element, and keeps the commas, since a proxy may join repeated fields
  with them. So `AAE=` becomes `AAE`, and `AAA=,BBB=` becomes `AAA,BBB`.
  smock never decodes these values, and does not check that they are
  base64.
- An exact `headers` condition on a `-bin` field of a gRPC Stub loses its
  padding when the files load, in each element, inside `$not` too. So
  `trace-bin: "AAE="` and `trace-bin: AAE` are the same condition, and
  both meet calls that send `AAE=` or `AAE`.
- A pattern condition sees the unpadded value, so write it without the
  padding: `{ pattern: "[A-Za-z0-9+/]+" }` meets a value of one element,
  whether the call sent it padded or not.
- The Journal stores the unpadded value, and a Journal filter must give it
  so: `{"headers": {"trace-bin": "AAE"}}` finds the calls that sent `AAE=`
  or `AAE`, and `"AAE="` finds none of them. smock does not rewrite
  filters, since they also meet HTTP requests, whose `-bin` headers it
  stores as received.

Only gRPC calls lose the padding. An HTTP request's `-bin` header, and an
HTTP Stub's condition on one, stay as written.

### Sessions

A call carries its [Session](../admin-api.md#sessions-and-ephemeral-stubs)
in its `baggage` metadata, as an HTTP request carries it in its `baggage`
header: in the `smock-session` member, or wherever `--session-header` and
`--session-member` say. There is no key of gRPC's own. With grpcurl:

```sh
grpcurl -plaintext -authority greeter.svc -H 'x-tenant: acme' \
  -H "baggage: smock-session=test-a" \
  -d '{"name":"Tom"}' localhost:8080 helloworld.Greeter/SayHello
```

The Session scopes a call as it scopes an HTTP request. It scopes its
[Ephemeral gRPC Stubs](../grpc.md#ephemeral-grpc-stubs), its state of each
Scenario, its Variables, its copies of the Data buckets and its Journal.
Each call reads its own metadata, so the calls of two Sessions on one
channel keep their state and their Journal apart, as two tests that share
a gRPC client do. An Admin API call names its Session the same way. So
a test reads its own calls from the Journal:

```sh
curl -H "Authorization: Bearer change-me" -H "baggage: smock-session=test-a" \
  -d '{}' localhost:9090/v1/journal/query
```

### Reply metadata

A gRPC reply carries metadata in two places. A gRPC Stub's `headers` are
its initial metadata, sent in the reply's HEADERS, and its
`grpc.trailers` are its trailing metadata, sent in its trailers after
`grpc-status`, `grpc-message` and `grpc-status-details-bin`. Both take the
shape of an HTTP Stub's
`headers`: a value by name, or an array of values, each sent as a field of
its own:

```yaml
response:
  headers: { x-served-by: smock }
  grpc:
    status: NOT_FOUND
    trailers: { x-trace: abc, x-tag: [a, b], trace-bin: "AAE=" }
```

A call to this Stub gets HEADERS, then trailers that end the stream:

```text
HEADERS
  :status: 200
  content-type: application/grpc
  x-served-by: smock
  date: Sat, 14 Nov 2026 07:00:00 GMT
TRAILERS
  grpc-status: 5
  x-trace: abc
  x-tag: a
  x-tag: b
  trace-bin: AAE
```

gRPC's rules for metadata apply to both, and `smock check` reports each
problem at its JSON Pointer:

- A name holds only `0-9`, `a-z`, `_`, `-` and `.` once in lower case.
  smock sends it in lower case, so `X-Trace` goes out as `x-trace`. Two
  names that differ only in case are a problem.
- gRPC keeps `content-type`, `te` and every name that starts with `grpc-`
  for itself, and HTTP/2 forbids `keep-alive`, `proxy-connection` and
  `upgrade`. None of them can be given, nor the fields smock sets itself
  (`content-length`, `transfer-encoding`, `connection` and `smock-mock`).
  So a gRPC Stub that gives a Content-Type is a problem: smock always
  sends `content-type: application/grpc`.
- A value holds only characters from 0x20 to 0x7E, space and printable
  ASCII. Other text goes in binary metadata.
- Binary metadata has a name that ends with `-bin`. Its value is written
  in standard base64, padded or not, and smock sends it without its
  padding, as gRPC servers do: `"AAE="` goes out as `AAE`. A value that
  is not base64 is a problem.

```text
greeter.yaml: /stubs/0/response/headers/grpc-foo: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
greeter.yaml: /stubs/0/response/grpc/trailers/x-note: must hold only characters from 0x20 to 0x7E: other values go in a field whose name ends with -bin, in base64
```

As with every field smock sends over HTTP/2, the spaces at either end of
a value are trimmed when it is sent.

With `template: true`, the values of both are text templates, rendered as
header values are: the control characters they render become spaces, and
tabs stay. Trailer values render after the message. smock checks a
rendered value as it checks one as written. A value outside 0x20 to 0x7E,
a tab included, or a `-bin` value that is not base64 gets
[Trailers-Only](#trailers-only) INTERNAL `template failed`, and the
Journal entry's `templateError` says why:

```json
{
  "at": "/response/grpc/trailers/x-trace",
  "message": "the rendered value holds U+00E9, and gRPC metadata values hold only characters from 0x20 to 0x7E"
}
```

A rendered `-bin` value loses its padding too.

An error whose reply has initial metadata is sent as HEADERS with it,
then trailers with the status, the message and the trailing metadata, as
the example above shows. An error without initial metadata is sent as
[Trailers-Only](#trailers-only). `smock-mock`, which smock adds when the
Default Mock answers, does not count as initial metadata.

## Status and message

A gRPC Stub's reply ends with a gRPC status, `OK` unless its `grpc` gives
another, and may carry a status message, trailing metadata and, for an
error, error details. A Stub's reply, or each of its `responses`, gives them
in `grpc`: `status` ([The status](#the-status)), `message` ([The
message](#the-message)), `trailers` ([Reply metadata](#reply-metadata)) and
`details` ([Error details](#error-details)). smock sends them in the reply's
last block of header fields, whose size is bounded ([Metadata
size](#metadata-size)), or in its only one
([Trailers-Only](#trailers-only)). The [Definition-file
reference](../definition-files/grpc.md#the-status-of-a-grpc-reply) describes
the field. With weighted `responses`, a dependency can fail one call in ten:

```yaml
stubs:
  - id: hello-flaky
    mock: greeter
    request: { path: /helloworld.Greeter/SayHello }
    responses:
      - { weight: 9, json: { message: Hello } }
      - { weight: 1, grpc: { status: UNAVAILABLE, message: "try again ☺" } }
```

About one call in ten then gets UNAVAILABLE, and a gRPC client reports it
with the message `try again ☺`. The others get `{"message": "Hello"}`.
grpcurl prints such an error as:

```text
ERROR:
  Code: Unavailable
  Message: try again ☺
```

The Journal records each call with the status it got, `OK` or
`UNAVAILABLE`, as its `grpcStatus`, and the HTTP status 200.

### The status

`status` is a name of one of gRPC's seventeen status codes. smock sends
its code in `grpc-status`:

| Name | Code | Name | Code |
|---|---|---|---|
| `OK` | 0 | `RESOURCE_EXHAUSTED` | 8 |
| `CANCELLED` | 1 | `FAILED_PRECONDITION` | 9 |
| `UNKNOWN` | 2 | `ABORTED` | 10 |
| `INVALID_ARGUMENT` | 3 | `OUT_OF_RANGE` | 11 |
| `DEADLINE_EXCEEDED` | 4 | `UNIMPLEMENTED` | 12 |
| `NOT_FOUND` | 5 | `INTERNAL` | 13 |
| `ALREADY_EXISTS` | 6 | `UNAVAILABLE` | 14 |
| `PERMISSION_DENIED` | 7 | `DATA_LOSS` | 15 |
| | | `UNAUTHENTICATED` | 16 |

The name is written in upper case, as gRPC writes it. Any other text is a
problem at `status`, which lists the names. The status is never a
template, even with `template: true`.

A status other than `OK` is an error. A unary call gets a reply message or
an error, never both, so an error that also gives `json` is a problem at
its `json`. A gRPC Stub cannot set an HTTP status: every answer to a gRPC
call has `:status` 200, and the client reads the outcome from
`grpc-status`.

### The message

`message` is any Unicode text. smock sends it in `grpc-message`,
percent-encoded, as gRPC's protocol requires, and a gRPC client decodes it
back. smock encodes the text's UTF-8:

- Each octet from 0x20 to 0x7E, other than `%`, stays as it is.
- Every other octet becomes `%` and two upper-case hex digits.
- A space at either end becomes `%20`, since HTTP/2 refuses a field value
  with a space at either end.

So `try again ☺` goes out as `try again %E2%98%BA`. gRPC's own test
message, `"\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"`,
goes out as:

```text
grpc-message: %09%0Atest with whitespace%0D%0Aand Unicode BMP %E2%98%BA and non-BMP %F0%9F%98%88%09%0A
```

A lone surrogate, such as U+D800 with no low surrogate after it, has no
UTF-8 form, so smock encodes U+FFFD in its place: it goes out as
`%EF%BF%BD`.

With `template: true`, the message is a text template, rendered after the
reply message, in the same rendering, so it can name what the call asked
for:

```yaml
response:
  template: true
  grpc: { status: NOT_FOUND, message: "no user called ${body.name}" }
```

The control characters it renders, such as a line break, are kept, then
percent-encoded, unlike a header value's, which become spaces. A message
that fails to render gets INTERNAL `template failed`, like any template
failure, and the Journal entry's `templateError` points at
`/response/grpc/message`.

A reply with `OK` may give a message too. It goes in the trailers, after
`grpc-status: 0`, though most clients ignore the message of a call that
succeeded.

### Error details

gRPC's richer error model lets an error carry details, such as
`google.rpc.ErrorInfo`, `RetryInfo` or `BadRequest` from googleapis'
[error_details.proto](https://github.com/googleapis/googleapis/blob/master/google/rpc/error_details.proto),
which clients that use the model read. A gRPC Stub's error gives them in
`grpc.details`, each in ProtoJSON with `@type` ([gRPC error
details](../definition-files/grpc.md#grpc-error-details)):

```yaml
stubs:
  - id: hello-unknown
    mock: greeter
    request: { path: /helloworld.Greeter/SayHello }
    response:
      template: true
      grpc:
        status: NOT_FOUND
        message: no user called ${body.name}
        trailers: { x-trace: abc }
        details:
          - "@type": type.googleapis.com/google.rpc.ErrorInfo
            reason: USER_UNKNOWN
            domain: greeter.svc
```

smock builds `google.rpc.Status` from the reply's status, its message and
its details, each packed in an Any. It encodes it itself, and sends it in
`grpc-status-details-bin`, in base64 without padding. A call for Ann gets
Trailers-Only:

```text
:status: 200
content-type: application/grpc
grpc-status: 5
grpc-message: no user called Ann
grpc-status-details-bin: CAUSEm5vIHVzZXIgY2FsbGVkIEFubhpHCih0eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5ycGMuRXJyb3JJbmZvEhsKDFVTRVJfVU5LTk9XThILZ3JlZXRlci5zdmM
x-trace: abc
date: Sat, 14 Nov 2026 07:00:00 GMT
```

The status in `grpc-status-details-bin` has the code and the message of
`grpc-status` and `grpc-message`, so the two never disagree. grpcurl decodes
it with `-format-error`, here for the [quick
start](../grpc.md#quick-start)'s Mock:

```sh
grpcurl -plaintext -authority greeter.svc -H 'x-tenant: acme' -format-error \
  -d '{"name":"Ann"}' localhost:8080 helloworld.Greeter/SayHello
```

```text
{
  "code": 5,
  "message": "no user called Ann",
  "details": [
    {
      "@type": "type.googleapis.com/google.rpc.ErrorInfo",
      "domain": "greeter.svc",
      "reason": "USER_UNKNOWN"
    }
  ]
}
```

A detail's type is looked up in the Mock's set, by the name after the
last `/` of its `@type`. So the set must hold the file that defines it,
and the files that file imports. Build it with googleapis' files on the
import path, beside your own:

```sh
protoc --include_imports -I . -I googleapis -o greeter.binpb \
  helloworld.proto google/rpc/error_details.proto
```

The set need not hold `google/rpc/status.proto`: smock encodes the status
without it. A client that decodes the details needs their types too. grpcurl
finds them through [reflection](services-and-connections.md#reflection), or
in the same set given with `-protoset`; without them, it prints each
detail's bytes in base64.

- A type the set lacks is a problem when the files load, at the detail's
  `@type`. Any message type of the set can be a detail, and a detail type
  goes through the checks of a method's types, so a type of an editions
  file and a MessageSet are problems.
- Each detail is read as ProtoJSON reads an Any, as a reply is read
  ([The reply](messages.md#the-reply)): `retry_delay` or `retryDelay`, and a
  Duration such as `"1.5s"`. A detail that does not fit its type is a
  problem at the value at fault.
- Only an error gives details: details with `OK` are a problem, since gRPC
  sends them only with an error. An empty `details` sends no status.
- Details as written are encoded once, when the files load. With
  `template: true`, each detail is a structured template, rendered after
  the trailing metadata, then encoded, and a `@type` written without
  `${` is looked up when the files load. A detail that fails to render,
  or does not fit its type once rendered, gets Trailers-Only INTERNAL
  `template failed`, and the Journal entry's `templateError` says why:

  ```json
  {
    "at": "/response/grpc/details/0/retryDelay",
    "message": "must be a duration from \"-315576000000.999999999s\" to \"315576000000.999999999s\": seconds, with at most 9 fractional digits, then \"s\", such as \"1.500s\": the field retry_delay of google.rpc.RetryInfo has the type google.protobuf.Duration"
  }
  ```

- `grpc-status-details-bin` counts toward the size of the block it goes
  out in ([Metadata size](#metadata-size)).
- The Journal records the call's `grpcStatus`, not its details.

### Metadata size

A reply goes out in blocks of header fields: its HEADERS, then its
trailers, or one [Trailers-Only](#trailers-only) block. smock counts each
block as RFC 7541 counts a header list, the way HTTP/2 counts
SETTINGS_MAX_HEADER_LIST_SIZE: each field's name and value, in octets,
plus 32. smock's own fields count too: `:status`, `content-type`,
`grpc-status`, `grpc-message` once percent-encoded,
`grpc-status-details-bin`, `smock-mock` and `date`. So the Trailers-Only
answer of `try again ☺` takes 275 octets:

| Field | Octets |
|---|---|
| `:status: 200` | 7 + 3 + 32 = 42 |
| `content-type: application/grpc` | 12 + 16 + 32 = 60 |
| `grpc-status: 14` | 11 + 2 + 32 = 45 |
| `grpc-message: try again %E2%98%BA` | 12 + 19 + 32 = 63 |
| `date: Sat, 14 Nov 2026 07:00:00 GMT` | 4 + 29 + 32 = 65 |

Each block may take at most `--header-size-limit`, 16 KiB by default, the
flag that also bounds request heads:

- A static reply, without `template: true`, with a larger block is a
  problem when the files load, at the reply's JSON Pointer. The load
  counts `date` at its 29 octets, and leaves out `smock-mock`, which only
  an answer of the Default Mock to a Host of another Mock carries.

  ```text
  greeter.yaml: /stubs/0/response: the reply's Trailers-Only block would take 20730 bytes, over --header-size-limit, 16384: each block of a gRPC reply's metadata counts as RFC 7541 counts a header list, each field's name and value plus 32, smock's own fields included
  ```

- `smock check` warns about a static reply with a block over 8 KiB: gRPC
  lets a client limit each block to that size, so such a client fails
  the call.

  ```text
  greeter.yaml: /stubs/0/response: warning: the reply's Trailers-Only block would take 9466 bytes, over 8192, the size gRPC lets a client limit each block of a reply's metadata to: such a client fails the call
  ```

- smock counts the blocks of each reply it sends before it sends any of
  them, once a templated reply is rendered. A block over
  `--header-size-limit`, or over the SETTINGS_MAX_HEADER_LIST_SIZE that
  the client advertised, would make the client fail the call in its
  framing layer. So the call gets Trailers-Only INTERNAL `reply metadata
  too large` instead, and its Journal entry records INTERNAL and says
  why in `templateError`, at the reply's JSON Pointer:

  ```json
  {
    "at": "/response",
    "message": "the reply's trailers would take 4179 bytes, over the 1024 that the client allows in its SETTINGS_MAX_HEADER_LIST_SIZE"
  }
  ```

  A static reply can get this too: from a client that advertised a small
  SETTINGS_MAX_HEADER_LIST_SIZE, or when `smock-mock` takes its block
  over the flag.
- smock's own answers, such as UNIMPLEMENTED with its [Near miss
  trailer](unmatched-and-refused-calls.md#the-near-miss-trailer), are sent
  as they are.

`smock check` and `smock render` take `--header-size-limit` too, and its
variable `SMOCK_HEADER_SIZE_LIMIT`, so they load a directory as
`smock serve` does. Give them the limit `smock serve` gets.

### Trailers-Only

An error without initial metadata goes out as Trailers-Only, as gRPC
servers send it: one HEADERS block that ends the stream, with no DATA and
no trailers after it. Its fields are, in order:

- `:status: 200`.
- `content-type: application/grpc`.
- `grpc-status`, the status's code.
- `grpc-message`, when the reply gives a message.
- `grpc-status-details-bin`, when the reply gives
  [error details](#error-details).
- smock's own fields: `smock-mock` when the Default Mock answered, and
  `smock-near-miss` for an [unmatched
  call](unmatched-and-refused-calls.md#unmatched-calls).
- The trailing metadata, the Stub's `grpc.trailers`.
- `date`.

```text
:status: 200
content-type: application/grpc
grpc-status: 14
grpc-message: try again %E2%98%BA
date: Sat, 14 Nov 2026 07:00:00 GMT
```

No gRPC reply carries `content-length` or `grpc-encoding`: smock never
compresses a reply
([Compression](unmatched-and-refused-calls.md#compression)). A gRPC client
reads every field of a Trailers-Only answer as trailing metadata.
