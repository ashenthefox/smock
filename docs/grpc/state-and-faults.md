# State, deadlines and Faults

This document says how a gRPC Stub shares its Mock's Scenarios,
Variables and Data buckets with the Mock's HTTP Stubs, and picks among
weighted `responses`. It then says how a call's deadline cuts a Stub's
delay short, and what a client sees for each Fault and for each reset or
refusal of smock's HTTP/2 limits. It is part of the [gRPC
guide](../grpc.md), and assumes its [gRPC Stubs](../grpc.md#grpc-stubs).
The examples use a Mock `greeter` that serves gRPC's helloworld.proto, as
in the guide's [quick start](../grpc.md#quick-start). Where an answer
shows `smock-mock: greeter; via=default`, `greeter` is a lone Mock, which
is the Default Mock.

## Contents

- [State over gRPC](#state-over-grpc)
  - [Scenarios](#scenarios)
  - [Variables](#variables)
  - [Data buckets](#data-buckets)
  - [Weighted responses](#weighted-responses)
- [Deadlines](#deadlines)
  - [A client that resets at its deadline](#a-client-that-resets-at-its-deadline)
  - [Resets and the connection's defences](#resets-and-the-connections-defences)
- [Faults](#faults)
  - [HTTP/2's resets and refusals](#http2s-resets-and-refusals)

## State over gRPC

A gRPC Stub takes part in its Mock's state as an HTTP Stub does. Its
`scenario` clause requires and moves a
[Scenario](../definition-files/scenarios.md#scenarios), its `variables`
write [Variables](../definition-files/variables.md#variables), its
`dataWrites` write [Data
buckets](../definition-files/data-buckets.md#data-buckets), and its
templates read all three. Templates see the request message as `body`, in
the JSON form the Stubs see ([The call the Stubs
see](../grpc.md#the-call-the-stubs-see)), so `${body.name}` reads the
message's `name`.

A Mock has one state for its HTTP requests and its gRPC calls. A call reads
what a request of the same Session wrote, and a request reads what a call
wrote. A call's Session comes from its `baggage` metadata, as a request's
comes from its `baggage` header
([Sessions](metadata-and-status.md#sessions)). Another Session, or a call
without one, has its own state.

### Scenarios

A call moves a Scenario when its Stub is chosen, as a request does, whatever
then happens to the reply: an error, a delay, a deadline or [smock's own
failure](unmatched-and-refused-calls.md#smocks-own-failures). This "create,
then get" flow tells the two calls apart by the metadata `x-op`:

```yaml
stubs:
  - id: get-missing
    mock: greeter
    request: { path: /helloworld.Greeter/SayHello, headers: { x-op: get } }
    scenario: { name: greeting, requires: Started }
    response: { grpc: { status: NOT_FOUND, message: no greeting yet } }
  - id: create
    mock: greeter
    request: { path: /helloworld.Greeter/SayHello, headers: { x-op: create } }
    scenario: { name: greeting, moveTo: Created }
    response: { template: true, json: { message: "Created a greeting for ${body.name}" } }
  - id: get
    mock: greeter
    request: { path: /helloworld.Greeter/SayHello, headers: { x-op: get } }
    scenario: { name: greeting, requires: Created }
    response: { template: true, json: { message: "Hello ${body.name}" } }
  - id: reset
    mock: greeter
    request: { method: POST, path: /greeting/reset }
    scenario: { name: greeting, moveTo: Started }
    response: { status: 204 }
```

A first `get` call gets NOT_FOUND `no greeting yet`. After a `create`
call, a `get` call gets `{"message": "Hello Tom"}`, and an HTTP Stub that
requires `Created` answers too. `POST /greeting/reset` over HTTP moves
the Scenario back, and the next `get` call gets NOT_FOUND again. The Journal
entry of each call shows how it moved the Scenario in its `scenario`, as
for a request.

### Variables

A call's `variables` are written before its reply renders, and its reply
reads them, as on HTTP:

```yaml
stubs:
  - id: hello
    mock: greeter
    request: { path: /helloworld.Greeter/SayHello }
    variables:
      calls: "${add(vars.calls ?? 0, 1)}"
      last: "${body.name}"
    response:
      template: true
      json: { message: "Hello ${body.name}, call ${vars.calls}: ${vars.greeting ?? 'no greeting'}" }
  - id: set-greeting
    mock: greeter
    request: { method: PUT, path: /greeting }
    variables: { greeting: "${body.text}" }
    response: { status: 204 }
```

In one Session, a first call gets `Hello Tom, call 1: no greeting`. After
`PUT /greeting` with `{"text": "welcome back"}` over HTTP, the next call
gets `Hello Ann, call 2: welcome back`, and an HTTP Stub that reads
`${vars.last}` reads `Ann`. The Admin API reads and sets a Session's
Variables whoever wrote them.

### Data buckets

A call's `dataWrites` write the Session's copies of its Mock's Data buckets,
which the Mock's HTTP Stubs read and write too, a [CRUD
Stub](../definition-files/crud-stubs.md#crud-stubs) included. A CRUD Stub
never answers a gRPC call, but its bucket is the one the gRPC Stubs use:

```yaml
data:
  - { mock: greeter, name: greetings, key: name, json: [] }
stubs:
  - id: greet
    mock: greeter
    request: { path: /helloworld.Greeter/SayHello, headers: { x-op: greet } }
    dataWrites:
      - { op: append, bucket: greetings, value: { name: "${body.name}", note: over gRPC } }
    response: { template: true, json: { message: "${len(data.greetings)} greetings" } }
  - id: find
    mock: greeter
    request: { path: /helloworld.Greeter/SayHello, headers: { x-op: find } }
    response:
      template: true
      json: { message: "${find(data.greetings, 'name', body.name).note ?? 'no greeting'}" }
  - id: greetings
    mock: greeter
    crud: { bucket: greetings, path: /greetings }
```

After a `greet` call for Tom, `GET /greetings/Tom` over HTTP answers
`{"name":"Tom","note":"over gRPC"}`. After `POST /greetings` with
`{"name":"Ann","note":"over HTTP"}`, a `find` call for Ann gets
`{"message": "over HTTP"}`. A write that cannot be applied, and writes
that would pass the state bound, get
[smock's own failures](unmatched-and-refused-calls.md#smocks-own-failures).

### Weighted responses

A Stub with `responses` picks one for each call, by weight, as on HTTP
([Several responses](../definition-files/responses.md#several-responses)).
Each may be a reply or an error, so a Stub can fail one call in ten:

```yaml
responses:
  - { weight: 9, json: { message: Hello } }
  - { weight: 1, grpc: { status: UNAVAILABLE, message: try again } }
```

The Journal entry's `responseIndex` says which response a call got, and
`--seed` or `fault.seed` replays the picks
([Seeds](../definition-files/faults.md#seeds)).

## Deadlines

A client gives a call its time in `grpc-timeout`
([Timeouts](unmatched-and-refused-calls.md#timeouts)). smock counts the
call's deadline from the arrival of its HEADERS. A call without
`grpc-timeout` has no deadline. Neither has a call whose timeout is longer
than the longest delay smock can give, 2^31-1 ms, about 24.8 days, such as
`99999999H`: no delay can outlast it.

smock watches the deadline only while a Stub's delay runs
([Faults](#faults)). When the delay would end after the deadline, the call
ends at the deadline instead, as a gRPC server ends a call whose deadline
passes. smock sends [Trailers-Only](metadata-and-status.md#trailers-only)
DEADLINE_EXCEEDED with the fixed `grpc-message` `deadline exceeded`. Take a
Stub whose `fault` is `{delay: {fixed: 3000}}`. A call with `grpc-timeout:
5S` gets its reply after 3 s, and a call with `grpc-timeout: 1S` gets this
about 1 s after its HEADERS:

```text
:status: 200
content-type: application/grpc
grpc-status: 4
grpc-message: deadline exceeded
smock-mock: greeter; via=default
date: Sat, 14 Nov 2026 07:00:00 GMT
```

- A call without a delay is served, whatever its deadline. Once the
  reply's HEADERS are out, the reply finishes as planned, however long its
  message takes to send.
- A timeout of 0, in any unit, such as `0m`, is accepted. Its deadline is
  the arrival of the HEADERS, so a call with a delay gets
  DEADLINE_EXCEEDED at once, and a call without one is served.
- The Journal records the call when it ends at its deadline, with the HTTP
  status 200 and the `grpcStatus` `DEADLINE_EXCEEDED`. Scenario moves,
  Variables and data writes stand, as after any delay: they are made
  before the delay begins.
- The request metrics count the call under its Mock and Stub, as any call
  that reached a Stub.

smock adds no timer for a deadline: the delay's wait ends at the earlier
of its own end and the deadline.

### A client that resets at its deadline

Clients that keep deadlines, such as grpc-go, grpc-java and grpcurl with
`-max-time`, reset the stream with `CANCEL` at their own deadline. A
client puts the time it has left in `grpc-timeout` when it builds the
HEADERS. So smock's deadline comes about one transit after the client's,
about when the client's reset arrives: either can come first.

smock records such a reset as DEADLINE_EXCEEDED too. A client reset that
arrives while a delay runs past the deadline, at most 100 ms before the
deadline, ends the call's Journal entry as if smock had ended the call at
its deadline. So the entry does not depend on which comes first.

A call that the client cancels earlier during a delay, or that has no
deadline, ends there, as any HTTP/2 stream does
([Streams that wait](../http2.md#streams-that-wait)). Its entry keeps the
HTTP status and the `grpcStatus` that its Stub's reply planned.

### Resets and the connection's defences

The defences of an HTTP/2 connection count two kinds of client reset
([Defences](../http2.md#defences)). A reset of a stream that smock has not
finished answering counts toward the Rapid Reset bound, and a reset of a
stream that has closed counts among the frames that do no work. Past
either bound, the connection gets GOAWAY `ENHANCE_YOUR_CALM`.

A client that keeps deadlines resets every call that times out. So two
kinds of reset count toward neither bound:

- A client reset that smock records as DEADLINE_EXCEEDED, as above: one
  that arrives at most 100 ms before the deadline, while the delay runs
  past it.
- The first reset of a call that smock ended at its deadline with
  DEADLINE_EXCEEDED.

So a client whose calls time out against a slow Stub keeps its
connection, however many calls time out. For the second kind, smock keeps
the stream IDs of the calls it ended at their deadlines until their resets
arrive. It keeps at most `--http2-max-concurrent-streams` of them per
connection, and drops the oldest first, since a client that read the
answer before its own deadline sends no reset.

Each stream gets this once. Every other reset counts as on any HTTP/2
stream: a second reset of the same stream, a reset of a call without a
deadline, and a reset that arrives more than 100 ms before the deadline.

## Faults

A gRPC Stub's `fault` may give a delay and a [connection
Fault](../definition-files/faults.md#connection-faults), each drawn as on
HTTP, with its `probability`. smock decides them as for an HTTP request,
with the same draws, so [`fault.seed` and
`--seed`](../definition-files/faults.md#seeds) replay them. A connection
Fault takes its [HTTP/2 form](../http2.md#faults), and sends no
`content-length`:

| Fault | On a gRPC call | The client sees |
|---|---|---|
| delay | Waits before the reply's HEADERS, on the call's stream alone: the other calls of the connection are answered meanwhile. The call's deadline can cut it short ([Deadlines](#deadlines)). | The reply, later; or DEADLINE_EXCEEDED |
| `reset` | Once the call has arrived in full, RST_STREAM `INTERNAL_ERROR` on the call's stream alone. The other calls of the connection go on. | INTERNAL |
| `partial` | The reply's HEADERS and the first half of its framed message, rounded down, then RST_STREAM `INTERNAL_ERROR`. A reply with no message, such as an error, sends the HEADERS it would send before its trailers, without the status fields and without ending the stream, then the reset. | INTERNAL |
| `close` | GOAWAY `NO_ERROR`, then the connection closes. | UNAVAILABLE, for every call in flight on the connection |

A Stub that resets the calls of one tenant leaves the other calls of the
channel be:

```yaml
stubs:
  - id: broken
    mock: greeter
    request:
      path: /helloworld.Greeter/SayHello
      headers: { x-tenant: broken }
    response:
      json: { message: never sent }
    fault: { connection: { kind: reset } }
```

A call with `x-tenant: broken` fails with INTERNAL. grpc-go, and so
grpcurl, reports it with the message `stream terminated by RST_STREAM
with error code: INTERNAL_ERROR`, and a call that `partial` ends the same
way. The next call on the same channel, to another Stub, gets its reply.

`close` ends every call on the connection, not just the Stub's. A gRPC
client sends its calls to one server over one connection, many at once,
so each call in flight then fails with UNAVAILABLE, and the client opens
a new connection for the next. Use `reset` to fail one call alone.
grpcurl prints a call that `close` ended as:

```text
ERROR:
  Code: Unavailable
  Message: closing transport due to: connection error: desc = "error reading from server: EOF", received prior goaway: code: NO_ERROR
```

- **Probabilistic errors.** For a call that fails with a gRPC status some of
  the time, such as UNAVAILABLE one call in ten, give the Stub weighted
  `responses`, one of them with a `grpc` status ([Status and
  message](metadata-and-status.md#status-and-message)). That is no
  connection Fault: the call gets the status itself, with its message.
- **A delay first.** A Fault with a delay comes once the delay is over, as
  on HTTP/2. A delay holds back whatever the call gets from its Stub: its
  reply, its error, its Fault, or [smock's own
  failure](unmatched-and-refused-calls.md#smocks-own-failures) when the Stub
  cannot serve its content, such as INTERNAL `template failed`. A call that
  no Stub matched gets UNIMPLEMENTED at once.
- **The deadline first.** A delay that the call's deadline cuts short
  never ends, so its connection Fault never comes: the call gets
  DEADLINE_EXCEEDED, and the connection stays open.
- **What `partial` sends.** The HEADERS of the answer the call would get:
  its initial metadata, and `smock-mock` when the Default Mock answered. Its
  status, its message, its details and its trailing metadata never go out. A
  reply that smock cannot send, such as one whose rendered message does not
  fit the output type, sends smock's own HEADERS, with none of the Stub's
  metadata. So does a reply whose HEADERS are too large to send ([Metadata
  size](metadata-and-status.md#metadata-size)), and so does [smock's own
  failure](unmatched-and-refused-calls.md#smocks-own-failures) when the Stub
  cannot serve its content.
- **The Journal.** The entry of a call that `reset` or `close` ended has
  no `status` and no `grpcStatus`, since no status went out. A `partial`
  one keeps both, as planned, or INTERNAL when smock sent its own HEADERS
  in place of the Stub's reply. An entry has the Fault in `fault`; a call
  whose deadline came first has none.

### HTTP/2's resets and refusals

smock's [HTTP/2 limits and defences](../http2.md#limits-and-timeouts) reset
or refuse a stream, or end a connection, whatever the request. A gRPC
client derives a status from each, as gRPC's HTTP/2 protocol says:

| What smock does | The client sees |
|---|---|
| RST_STREAM `REFUSED_STREAM`, for a stream past `--http2-max-concurrent-streams` | UNAVAILABLE. smock never began the call, so gRPC retries it on its own, without a retry policy. |
| RST_STREAM `CANCEL`, for a call whose request is late past the read timeout, or a stream whose window stays at zero past the write timeout | CANCELLED |
| RST_STREAM `ENHANCE_YOUR_CALM`, for a header list over twice `--header-size-limit` as received | RESOURCE_EXHAUSTED |
| `:status` 431, for a header list over `--header-size-limit` or with more fields than `--header-count-limit` | UNKNOWN |
| `:status` 400, for a request HTTP/1.1's rules refuse | INTERNAL |
| GOAWAY, after one of the [defences](../http2.md#defences) | The calls in flight on the connection end, and later calls get UNAVAILABLE. |
