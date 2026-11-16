# Responses

This document is part of the [Definition-file
reference](../definition-files.md). It describes what a matched Stub sends
back: its status, headers and body, inline, from a body file that serves
byte ranges, as Server-Sent Events or as JSON, and several responses picked
at random by weight. [LLM responses](llm-responses.md),
[templates](templates.md) and [Faults](faults.md) have documents of their
own.

A Stub's `response` has a `status`, `headers`, and a body. A Stub can give
several responses to pick from instead ([Several
responses](#several-responses)). `status` is required, except on a [gRPC
Stub](grpc.md#grpc-stubs), whose reply has none: it gives `grpc` instead,
the gRPC status and message its reply ends with ([The status of a gRPC
reply](grpc.md#the-status-of-a-grpc-reply)). A gRPC Stub's `headers` are its
reply's initial metadata, under gRPC's rules ([gRPC reply
metadata](grpc.md#grpc-reply-metadata)).

`headers` maps each header name to a string or to an array of strings.
An array sends one field per value, in order, where the name stands.
This sends two `Set-Cookie` fields:

```json
"headers": { "Set-Cookie": ["session=abc; Path=/; HttpOnly", "theme=dark; Path=/"] }
```

An array is never empty. `Content-Type` takes one string. Names are
compared case-insensitively, so `Set-Cookie` and `set-cookie` cannot both
be given; give the name an array instead. In a YAML flow sequence a comma
ends a value. Write a value that has one, such as a cookie's `Expires`,
in block style or in quotes. smock sets `Content-Length` from the body;
`Content-Length`, `Transfer-Encoding` and `Connection` cannot be given,
nor can `Smock-Mock`, which smock adds when the Default Mock answers.

Over HTTP/2, header names go out in lower case, and spaces and tabs around
a value are trimmed. `Keep-Alive`, `Upgrade`, `Proxy-Connection` and `TE`
are left out, since HTTP/2 forbids them in a response (RFC 9113, section
8.2.2); over HTTP/1.1 they are sent as written. A 2xx to an HTTP/2 CONNECT
has no `content-length` and no body. See [HTTP/2](../http2.md#responses).

smock sends a `Date` header with the current time on every final
response, such as `Date: Thu, 22 Oct 2026 14:37:10 GMT`, and none on an
interim `100 Continue`. A Stub may give its own `Date`,
in any case, such as a fixed one for testing a client's caching. smock
then sends that one as written and adds none.

The body is either inline, as text in UTF-8:

```json
"response": { "status": 200, "body": "{\"id\":1}" }
```

or read from a body file, by its path relative to the [body-file
subdirectory](../definition-files.md):

```json
"response": {
  "status": 200,
  "headers": { "Content-Type": "application/json" },
  "bodyFile": "users/1.json"
}
```

serves the bytes of `files/users/1.json` exactly as they are. The path
cannot leave the body-file subdirectory, and none of its names may start
with `.`. A path that breaks this rule, or names a file that does not
exist, is reported with the file and JSON Pointer of the `bodyFile`, by
`smock check` and when `smock serve` starts.

## Contents

- [Range requests](#range-requests)
- [Server-Sent Events](#server-sent-events)
- [JSON bodies](#json-bodies)
- [Several responses](#several-responses)

## Range requests

A body file serves byte ranges, so that clients that resume downloads or
stream media can be tested against smock. Nothing in the Definition file
turns this on. A response serves ranges when:

- its status is 200;
- its body is a body file, and `template` is off;
- its headers give neither `Content-Range` nor `Accept-Ranges`.

```yaml
- id: get-video
  mock: media
  request: { method: GET, path: /video.mp4 }
  response:
    status: 200
    headers: { Content-Type: video/mp4 }
    bodyFile: video.mp4
```

For a `video.mp4` of 1000 bytes:

- `Range: bytes=0-99` gets 206 Partial Content, with
  `Content-Range: bytes 0-99/1000`, `Accept-Ranges: bytes` and the first
  100 bytes.
- `Range: bytes=1000-` gets 416 Range Not Satisfiable, with
  `Content-Range: bytes */1000` and no body.
- A request without `Range` gets the whole file with 200 and
  `Accept-Ranges: bytes`.

smock serves a single byte range, and reads the `Range` field by the
grammar of RFC 9110:

- `first-last`, `first-` and `-suffix` (the last `suffix` bytes) are
  taken. The unit `bytes` is compared case-insensitively.
- A last position at or past the end means the end. A suffix longer than
  the file selects the whole file, with 206.
- A first position at or past the end, or a suffix of 0, cannot be
  satisfied: 416, with `Content-Range: bytes */<length>` and no body.
- A number too large to hold is past the end. As a first position, the
  range cannot be satisfied; as a last position, it means the end; as a
  suffix, it selects the whole file.
- The Stub's headers stay on the 206 and the 416, and smock adds its
  fields after them. The 416 carries no `Accept-Ranges`.

These get the whole body with 200 and `Accept-Ranges: bytes`, as RFC 9110
lets a server ignore `Range`:

- several ranges, such as `bytes=0-99,200-299`;
- more than one `Range` field;
- a malformed field, such as `bytes=100-99`, whose last position is below
  its first;
- another unit, such as `items=0-9`;
- any `If-Range`. smock has no validators, such as `ETag`, so RFC 9110
  says to ignore `Range` then;
- an empty body file.

Only a GET is served a range, since RFC 9110 defines range handling for
GET only. A `HEAD` ignores `Range`, and its 200 still carries
`Accept-Ranges: bytes`. A Stub with `method: GET` still does not answer
`HEAD`. Other methods get the response as written, without
`Accept-Ranges`.

Some Stubs are left alone, so that partial responses written by hand keep
working:

- a Stub that gives status 206, or a `Content-Range` header of its own;
- a Stub that gives `Accept-Ranges` itself, such as `Accept-Ranges: none`.
  It serves no ranges, and keeps its own value.

With [`responses`](#several-responses), the response picked decides.
[Ephemeral Stubs](../admin-api.md#sessions-and-ephemeral-stubs) have no body
files, so they never serve ranges.

A [delay](faults.md#delays) applies to a 206 or a 416 as to any response. A
`partial` [connection Fault](faults.md#connection-faults) sends the head of
the 206, with its `Content-Length`, and the first half of the range. The
[Journal](../admin-api.md#the-journal) records the status sent: 206 or 416.
`smock render` and the Admin render operation apply the same rule to the
sample's `Range` header ([Rendering a
template](templates.md#rendering-a-template)).

## Server-Sent Events

Instead of a body, a response can stream `events`, to mock a streaming API:

```json
"response": {
  "status": 200,
  "headers": { "Cache-Control": "no-cache" },
  "events": [
    { "data": "first" },
    { "delay": 250, "event": "update", "id": "2", "data": "line 1\nline 2" }
  ]
}
```

smock sends the status and the headers at once, always with
`Content-Type: text/event-stream`: a `Content-Type` the Stub gives is
replaced. Then, for each event, it waits the event's `delay` (in
milliseconds, counted from the previous event or, for the first one, from
the headers; 0 by default) and writes the event:

```text
data: first

event: update
id: 2
data: line 1
data: line 2

```

- `data` is required. Each of its lines becomes its own `data:` line.
- `event` (the event type) and `id` are written only when given. Each is
  one line, and `id` has no NUL characters.
- The stream ends after the last event. To an HTTP/1.1 client it is sent
  with chunked framing, so the connection carries the next request. An
  HTTP/1.0 client gets it unframed, and smock closes the connection to end
  it.
- A response with no body, to a `HEAD` request or with status 204 or 304,
  is the status and the headers alone. smock sends them at once and waits
  for no event.
- While a stream waits, smock serves every other connection. A client that
  closes the connection mid-stream ends that stream: smock notices when it
  next writes an event. Until then, which an event's long delay can put off,
  the stream keeps its connection, and a [drain](../running.md#the-drain) on
  SIGTERM waits for it as for any stream in progress. smock does not watch
  the connection meanwhile, since a client may close its sending side once
  its request is sent and still read the stream. A client that keeps the
  connection open but stops reading is cut by the [write
  timeout](../running.md#the-write-timeout): when the write of an event
  makes no progress for `--write-timeout-ms`, smock closes the connection.
- Over HTTP/2, each event stream is an HTTP/2 stream of its own, so one
  connection can carry several at once, and its other HTTP/2 streams are
  answered meanwhile. The HEADERS carry `content-type: text/event-stream`
  and no `content-length`. Each event goes out as DATA, split where the
  client's frame size or flow-control windows require, and the DATA of the
  last event ends the HTTP/2 stream. A response with no body is its HEADERS
  alone. A client that resets the HTTP/2 stream ends the event stream at
  once, without waiting for the next event, and its request is in the
  Journal, as one whose client disconnects is
  ([HTTP/2](../http2.md#server-sent-events)).

## JSON bodies

A body can also be given as JSON, with `json`: any JSON value. smock sends
it as compact JSON in UTF-8, with `Content-Type: application/json` unless
`headers` gives a Content-Type:

```json
"response": { "status": 200, "json": { "id": 1, "price": 9.90 } }
```

sends `{"id":1,"price":9.9}`. smock writes every number itself, in the
shortest form that reads back as the same 64-bit float: `9.90` is sent as
`9.9` and `1e3` as `1000`, and an integer beyond 2^53 keeps its digits. When
the exact bytes matter, use `body`. A response gives at most one of `body`,
`bodyFile`, `json`, `events` and [`llm`](llm-responses.md#llm-responses),
and an event gives exactly one of `data` and `json`, which is sent as one
`data:` line of compact JSON.

## Several responses

A Stub can give `responses`, a list of responses with weights, instead of
`response`. Each matched request gets one of them, picked at random. This
Stub answers about one request in ten with a 503:

```yaml
- id: get-prices
  mock: market
  request: { method: GET, path: /prices }
  responses:
    - { weight: 9, status: 200, json: { price: 101 } }
    - { weight: 1, status: 503, headers: { Retry-After: "5" }, json: { error: unavailable } }
  fault: { seed: 7 }
```

- A Stub gives exactly one of `response` and `responses`.
- `responses` holds 1 to 100 responses, in the order written. Each is a
  response as `response` gives it, with its own status, headers, body,
  body file, `json`, events or `llm`, `grpc` and `template`, plus
  `weight`. On a gRPC Stub, `responses` can mix replies and errors, so
  that one call in ten fails
  ([The status of a gRPC reply](grpc.md#the-status-of-a-grpc-reply)).
- `weight` is an integer from 1 to 1,000,000, by default 1. A response is
  picked with the probability of its weight over the sum of the weights:
  9 and 1 give the 200 to nine requests in ten.
- The request conditions, the `fault` and the `scenario` clause stay one
  per Stub, whichever response is picked.
- A problem in a response is reported at its JSON Pointer, with the
  response's index counted from 0, such as `/stubs/0/responses/1/json`. A
  template that fails for a request points at the field within the Stub
  the same way, such as `"at":"/responses/1/json/id"`.
- An [Ephemeral Stub](../admin-api.md#sessions-and-ephemeral-stubs) can give
  `responses` too, with inline bodies only: `bodyFile` is refused in any
  of them.
- The [shadow warning](../definition-files.md#a-stub-that-can-never-match),
  the Near miss and the traffic metrics look at the request conditions
  only, never at the responses.

The pick takes nothing from the Stub's random source beyond the one draw
every matched request takes (see [The random source and the time of a
request](template-helpers.md#the-random-source-and-the-time-of-a-request)):
it draws from a generator of its own, seeded with that draw XOR a fixed
constant. It draws a number
below the sum of the weights, each equally likely, and takes the response
whose share of the running total holds it, in the order written. So the
Fault decisions and the helper output for a seed are the same with
`responses` as with `response`, and [`fault.seed` and
`--seed`](faults.md#seeds) replay the picks as they replay the Faults. A
Stub with `response` takes no pick.

The [Journal](../admin-api.md#the-journal) records which response each
request got, as `responseIndex`, its index from 0. It is null for a Stub
with `response` or `crud`, for a request that no Stub matched, and when no
response was picked because a value of the Stub's
[`variables`](variables.md#variables) failed to render, a [data
write](data-buckets.md#when-a-write-fails) failed, or [the state
bound](variables.md#the-state-bound) refused its writes. `smock render` and
the Admin render operation show the index the seed picks, and `--response
<i>` (the Admin API's `response=<i>`) renders the response at index `i`
([Rendering a template](templates.md#rendering-a-template)).
