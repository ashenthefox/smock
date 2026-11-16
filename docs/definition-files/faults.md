# Faults

This document is part of the [Definition-file
reference](../definition-files.md).

A Stub can inject Faults, to test how a client handles slow and failing
calls. Its `fault` has a delay, a connection Fault, or both, and an optional
seed:

```json
{
  "id": "get-user",
  "mock": "users",
  "request": { "method": "GET", "path": "/users/1" },
  "response": { "status": 200, "body": "{\"id\":1}" },
  "fault": {
    "delay": { "lognormal": { "median": 80, "sigma": 0.6 }, "probability": 0.5 },
    "connection": { "kind": "close", "probability": 0.01 },
    "seed": 42
  }
}
```

## Delays

A `delay` makes smock wait before it writes the status line. Meanwhile it
keeps serving other connections. Over HTTP/2, it waits before the stream's
HEADERS and delays only that stream: the other streams of the connection are
answered meanwhile ([HTTP/2](../http2.md#streams-that-wait)). A gRPC call's
deadline can cut a delay short: the call then gets DEADLINE_EXCEEDED
([Deadlines](../grpc/state-and-faults.md#deadlines)). The delay is drawn
from one distribution, in whole milliseconds:

| Distribution | Delay |
|---|---|
| `"fixed": 100` | always 100 ms. |
| `"uniform": { "min": 50, "max": 150 }` | a whole number of milliseconds from `min` to `max`, both included, each equally likely. `min` must not exceed `max`. |
| `"lognormal": { "median": 80, "sigma": 0.6 }` | log-normal: half the delays are below `median`, and `sigma`, the standard deviation of the delay's natural logarithm, sets how long the tail of slow responses is. |

`probability`, from 0 to 1, is the share of matched requests that are
delayed. Without it, every matched request is.

## Connection Faults

A `connection` Fault makes a request fail at the connection level, instead
of getting its response:

- `reset`: smock reads the whole request, body included, then resets the
  connection (an RST) without writing anything. The client gets a
  connection-reset error, not an empty response. On the TLS port, smock
  sends no `close_notify` first. Should the operating system refuse the
  reset, smock logs an error (`cannot reset the connection`) and closes the
  connection with a FIN instead.
- `close`: smock reads the request, then closes the connection (a FIN)
  without writing anything.
- `partial`: smock writes the status line, the headers, with the
  `Content-Length` of the whole body, and the first half of the body, then
  closes the connection. The client sees a response cut short. For a 206 to
  a [Range request](responses.md#range-requests), the body is the range. For
  Server-Sent Events, the first half is the first half of the events,
  rounded down, each after its delay, and the event stream is not ended.
  - A response with no body bytes to halve, such as an empty body or a
    response to `HEAD`, would be whole that way. smock leaves out the empty
    line that ends its headers instead, so the client still sees it cut
    short.
  - A stream of Server-Sent Events to an HTTP/1.0 client ends when the
    connection closes, so a client cannot tell a partial one from a whole
    stream with fewer events.

Over HTTP/2, each kind takes its nearest form, so that it fails the request
on its stream, or the connection for `close`
([HTTP/2](../http2.md#faults)):

- `reset`: smock reads the whole request, body included, then resets its
  stream alone, with RST_STREAM and the error code `INTERNAL_ERROR`. The
  other streams of the connection go on.
- `close`: smock sends GOAWAY with `NO_ERROR`, naming the highest stream
  the client has opened, then closes the connection. Its other streams end
  with it: smock sends nothing more on them.
- `partial`: smock sends the HEADERS, with the `content-length` of the
  whole body, and the first half of the body, or of the events, then
  resets the stream with RST_STREAM `INTERNAL_ERROR`. A response with no
  body to halve sends its HEADERS without ending the stream, then the
  reset.

A gRPC call takes these HTTP/2 forms, with no `content-length`: `partial`
sends the first half of the framed reply message. A gRPC client sees
INTERNAL for `reset` and `partial`, and UNAVAILABLE for `close`, which ends
every call on the connection ([Faults](../grpc/state-and-faults.md#faults)).

`probability`, from 0 to 1, is the share of matched requests that fail;
without it, every matched request fails. A Stub with both a delay and a
connection Fault waits first, then fails.

A request that asks for `100 Continue` (`Expect: 100-continue`) gets it
before its body is read, as HTTP/1.1 requires of a client that waits for
it, and so before smock knows which Stub, and which Fault, applies. Its
`reset` or `close` then comes after that interim response, which is all
the client receives. smock sends `100 Continue` also when the body arrives
without waiting for it.

## Seeds

Each matched request draws whether its delay and its connection Fault
apply, and how long the delay is, and, for a Stub with
[`responses`](responses.md#several-responses), which response it gets.

- A Stub with a `seed`, from 0 to 9007199254740991, has its own generator.
  smock creates it when it loads the Definition files, and again from the
  seed when a [reload](../definition-files.md#reloading) swaps in a new
  definition set, and it advances once per request the Stub matches. An
  Ephemeral Stub with a seed gets its own generator when it is added, which
  a reload keeps. So the n-th request a seeded Stub matches gets the same
  Faults in every run, whatever requests other Stubs get, the same response
  among `responses`, the same [ids in an LLM
  reply](llm-responses.md#ids-seeds-and-time) and the same [waits of an LLM
  stream](llm-responses.md#timing). The generator is a fixed algorithm, the
  same on every platform.
- Stubs without a seed draw from the process generator, which they share.
  smock picks its seed at startup and logs it:

  ```json
  {"time":"2026-10-13T09:12:44.512Z","level":"info","msg":"random seed","seed":5126750341862113}
  ```

  To replay a run, start smock with that seed (`--seed`, `SMOCK_SEED`): the
  same requests in the same order then get the same Faults and the same
  responses.
