# Built-in services and connections

This document says how a Mock answers gRPC's server reflection and health
service, how to turn each on and how grpcurl uses them, and how a gRPC
channel meets smock's HTTP/2 connections: the idle timeout, keepalive
PINGs and the drain. It is part of the [gRPC guide](../grpc.md), and
assumes the [Mock's `grpc` field](../grpc.md#the-mocks-grpc-field) and its
Descriptor set, the set ([Building a set](../grpc.md#building-a-set)). The
grpcurl and protoc commands use the Mock `greeter` and the `defs`
directory of the guide's [quick start](../grpc.md#quick-start). The
[HTTP/2 guide](../http2.md) describes the limits that a connection is
served under.

## Contents

- [Built-in services](#built-in-services)
  - [Reflection](#reflection)
  - [Health](#health)
- [Connections](#connections)
  - [Idle channels](#idle-channels)
  - [Keepalive PINGs](#keepalive-pings)
  - [The drain](#the-drain)

## Built-in services

A Mock can answer gRPC's server reflection and its standard health service
itself, with no Stub. Each is off unless the Mock turns it on ([The Mock's
`grpc` field](../grpc.md#the-mocks-grpc-field)), and a Mock that does not
turn them on pays nothing for them. Their answers are counted in the request
metrics under their Mock, and are not recorded in the Journal ([The Journal
and the metrics](rendering-and-journal.md#the-journal-and-the-metrics)).

### Reflection

Tools such as grpcurl and Postman find a server's services and their types
through gRPC's [server
reflection](https://github.com/grpc/grpc/blob/master/doc/server-reflection.md).
Turn it on with the Mock's `grpc.reflection`, and they need no local copy of
the Mock's set:

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb
      reflection: true
      health: true
```

```sh
grpcurl -plaintext -authority greeter.svc localhost:8080 list
```

```text
grpc.health.v1.Health
helloworld.Greeter
```

```sh
grpcurl -plaintext -authority greeter.svc localhost:8080 describe helloworld.Greeter.SayHello
```

```text
helloworld.Greeter.SayHello is a method:
rpc SayHello ( .helloworld.HelloRequest ) returns ( .helloworld.HelloReply );
```

A call then needs no `-protoset`, as in the [quick
start](../grpc.md#quick-start):

```sh
grpcurl -plaintext -authority greeter.svc -H 'x-tenant: acme' \
  -d '{"name":"Tom"}' localhost:8080 helloworld.Greeter/SayHello
```

```json
{
  "message": "Hello Tom"
}
```

smock serves both versions of the service, `grpc.reflection.v1` and its
older name `grpc.reflection.v1alpha`, so older and newer tools work. It
answers from the Mock's set:

| Request | Answer |
|---|---|
| `list_services` | The services of every file of the set, in the order of the set, then `grpc.health.v1.Health` when health is on and the set does not define it. |
| `file_by_filename` | The file of that name, then each file it imports, at any depth, once each. |
| `file_containing_symbol` | The file that defines the symbol, with its imports. A symbol is any named element, by its full name: a message, a nested type, a field, an enum, an enum value, a service, a method or an extension. |
| `file_containing_extension` | The file that defines the extension of the type with the number, with its imports. |
| `all_extension_numbers_of_type` | The numbers of the extensions of the type in the set. |

- Files are sent as the set holds them, custom options included, without
  their source info, the comments and positions. So `describe` prints no
  comments.
- A name the set lacks gets reflection's `error_response` with
  NOT_FOUND (5), such as `symbol not found: helloworld.Missing`. A request
  that asks for nothing gets INVALID_ARGUMENT (3).
- Each response echoes the request in `original_request`, and gives the
  call's Host, its `:authority`, in `valid_host`.
- With `health` on, the health service is listed, and described from the
  descriptor of `health.proto` that smock embeds. When the Mock's set
  defines the package `grpc.health.v1` itself, it answers from the set
  instead, and the embedded descriptor is not used.
- The reflection services themselves are not listed: smock does not
  embed `reflection.proto`.
- `descriptorSet` may be left out. A Mock with `grpc: { reflection: true,
  health: true }` alone lists the health service only.
- A Mock that does not turn reflection on has no reflection service. A call
  to it is a call to a method the set lacks, which gets UNIMPLEMENTED
  `unknown method` from its HEADERS ([Calls answered from their
  HEADERS](unmatched-and-refused-calls.md#calls-answered-from-their-headers)),
  and grpcurl says `server does not support the reflection API`.

#### One request per call

Reflection's method, `ServerReflectionInfo`, is bidirectional streaming,
and smock serves no streaming method yet. So smock answers one request
per call. It reads the first request message as soon as it has arrived
whole, sends one response message and the OK trailers, then RST_STREAM
`NO_ERROR` if the client is still sending. Messages after the first are
not read. Clients open a new call for their next request, as grpcurl,
grpc-go and grpc-python do, so every command works.

The [protocol
checks](unmatched-and-refused-calls.md#protocol-checks-and-limits) come
first, as for any call, and a first message that does not decode as a
reflection request gets INTERNAL `the request message cannot be decoded`.

#### A Stub wins

As for [health](#health), a call goes to the Stubs, not to the service,
when the Mock has a gRPC Stub on its path. Reflection's method streams,
and a gRPC Stub on a streaming method is a problem, so no Stub can be on
it today.

#### In the Journal and the metrics

Reflection answers are not recorded in the Journal: each grpcurl command
makes one or more reflection calls, which would otherwise evict the calls
that tests verify. The request metrics count each under its Mock with
`stub=""`, and not as an unmatched request. In the `mockoon` log format,
they get no line.

#### Memory

With reflection on, the Mock keeps each file of its set as the set
encodes it, without its source info, beside the set's decoded model. So
answers carry every field and option as the set holds them. This
costs about as much memory as the set built without source info, in
every replica ([Memory](../grpc.md#memory)). A Mock without reflection keeps
nothing more.

### Health

Clients and proxies that health-check a gRPC server call gRPC's [health
service](https://github.com/grpc/grpc/blob/master/doc/health-checking.md),
`grpc.health.v1.Health`. Turn it on with the Mock's `grpc.health`:

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb
      health: true
```

smock then answers as gRPC's health servers do:

| Method | Answer |
|---|---|
| `Check` | SERVING for `""`, the server as a whole, and for each service of the Mock's set, such as `helloworld.Greeter`. NOT_FOUND with the message `unknown service` for any other name. |
| `List` | The status of `""` and of each service of the set, by name. |
| `Watch` | It streams, so it gets UNIMPLEMENTED `streaming methods are not served yet` from its HEADERS, as a streaming method of a set does ([Calls answered from their HEADERS](unmatched-and-refused-calls.md#calls-answered-from-their-headers)), but it is not journaled, as no health answer is. |

- The set need not hold `health.proto`. smock embeds the descriptor of
  gRPC's
  [health.proto](https://github.com/grpc/grpc-proto/blob/master/grpc/health/v1/health.proto),
  and decodes and encodes the service's messages with it. A set that holds
  the file has `grpc.health.v1.Health` among its services, so the service
  says SERVING for itself too.
- `descriptorSet` may be left out. A Mock with `grpc: { health: true }`
  alone has no service of its own: `Check` says SERVING for `""` and
  gives NOT_FOUND for every other name, and `List` gives `""` alone.
- The [protocol
  checks](unmatched-and-refused-calls.md#protocol-checks-and-limits) come
  first, as for any call. A `Check` of `""` may send a message of zero
  octets.
- The service answers on the plain and TLS ports alike, through the
  Default Mock too, with `smock-mock` in its answer.
- smock's own probes stay on the admin port. Kubernetes reads `/readyz`,
  not the health service.

#### During the drain

Once SIGTERM starts the drain, every answer of `Check` and `List` says
NOT_SERVING, for every name, an unknown one included. Health-checking
clients then move away before smock stops, while the calls in flight
finish ([The drain](../http2.md#the-drain)). `/readyz` fails from the same
moment.

#### A Stub wins

A call to a health method goes to the Stubs, not to the service, when
the Mock has a gRPC Stub on that path. The Stub may be one in a Definition
file, or an Ephemeral one of the call's Session. So a Scenario can make
the service NOT_SERVING:

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb
      health: true
stubs:
  - id: health-down
    mock: greeter
    scenario: { name: health, requires: down }
    request: { path: /grpc.health.v1.Health/Check }
    response: { json: { status: NOT_SERVING } }
  - id: health-up
    mock: greeter
    request: { path: /grpc.health.v1.Health/Check }
    response: { json: { status: SERVING } }
```

A test sets the Scenario `health` to `down` through the Admin API, and
`Check` then says NOT_SERVING.

- Such a Stub is a gRPC Stub like any other, so the Mock's set must hold
  `health.proto`. Build the set with it:

  ```sh
  protoc --include_imports -o defs/files/greeter.binpb \
    helloworld.proto grpc/health/v1/health.proto
  ```

- The call goes to the Stubs even when none of them matches it, and then
  gets UNIMPLEMENTED `no Stub matched`. So give one Stub without
  conditions, as `health-up` above.
- A Stub on one method leaves the others to the service: with the Stubs
  above, `List` is still the service's.
- A call that goes to the Stubs is journaled and counted as any call a
  Stub answers.

#### With grpcurl

grpcurl needs the service's schema. Turn [reflection](#reflection) on
as well, and grpcurl finds it there, from the descriptor smock embeds:

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb
      health: true
      reflection: true
```

```sh
grpcurl -plaintext -authority greeter.svc localhost:8080 grpc.health.v1.Health/Check
```

```json
{
  "status": "SERVING"
}
```

A name that is not a service of the set:

```sh
grpcurl -plaintext -authority greeter.svc -d '{"service": "nope.Svc"}' \
  localhost:8080 grpc.health.v1.Health/Check
```

```text
ERROR:
  Code: NotFound
  Message: unknown service
```

`grpc.health.v1.Health/List` prints the status of `""` and of
`helloworld.Greeter`.

Without reflection, give grpcurl `health.proto` instead:

```sh
mkdir -p grpc/health/v1
curl -fsSL -o grpc/health/v1/health.proto \
  https://raw.githubusercontent.com/grpc/grpc-proto/master/grpc/health/v1/health.proto
grpcurl -plaintext -authority greeter.svc -proto grpc/health/v1/health.proto \
  localhost:8080 grpc.health.v1.Health/Check
```

#### In the Journal and the metrics

Health answers are not recorded in the Journal: probes every few seconds
would otherwise evict the calls that tests verify. The request metrics
count each under its Mock with `stub=""`, and not as an unmatched
request. In the `mockoon` log format, they get no line.

## Connections

A gRPC client sends its calls to a server over one HTTP/2 connection, many
at once, and keeps the connection open between calls. smock serves it as any
HTTP/2 connection, under the same limits, timeouts and defences ([Limits and
timeouts](../http2.md#limits-and-timeouts)), with no rule of gRPC's own.
What a client sees when one of them resets a call or ends the connection is
in [HTTP/2's resets and
refusals](state-and-faults.md#http2s-resets-and-refusals).

### Idle channels

A connection with no call in progress gets GOAWAY `NO_ERROR` once it has
been idle for `--idle-timeout-ms`, 60 s by default, then closes
([Timeouts](../http2.md#timeouts)). A PING does not restart the idle
timeout, so a channel that sends keepalive PINGs while it has no call in
progress is closed all the same. A call in progress keeps the connection
open, however long its Stub's delay, and the timeout runs again from the
end of the last call.

A gRPC client takes such a GOAWAY as the end of the connection, not as an
error. No call fails: its channel goes idle, and its next call opens a
new connection. So a client's log that shows a GOAWAY and a new
connection after a quiet minute shows the idle timeout. Raise
`--idle-timeout-ms` to keep idle channels open longer.

### Keepalive PINGs

gRPC clients may send PINGs to check that a connection still works,
gRPC's keepalive, such as grpc-go's `keepalive.ClientParameters` or
grpc-java's `keepAliveTime`. smock answers each PING, under the bound it
keeps on frames that do no work
([Frames that do no work](../http2.md#frames-that-do-no-work)). A PING
counts among them, beyond one for each HEADERS or DATA frame that smock
has sent on the connection. A connection whose client sends more
than 100 such frames in any one second gets GOAWAY `ENHANCE_YOUR_CALM`.
A keepalive every few seconds, or a PING for each frame received, as
clients that estimate their bandwidth send, stays far below it.

smock has no ping-strike policy of gRPC's own. gRPC servers may close a
connection whose client pings more often than they allow, while smock
answers such a client as long as it keeps under the bound above. Test a
client's keepalive against such a policy with the real server.

### The drain

On SIGTERM, smock drains each connection in two steps, as it drains any
HTTP/2 connection ([The drain](../http2.md#the-drain)):

1. The connection gets GOAWAY `NO_ERROR`, then a PING. Its client opens
   no new call on it, and smock's listeners close. A call that the client
   starts from then on fails with UNAVAILABLE, gRPC's status for a server
   that shuts down, unless the channel has another server to send it to,
   such as another replica behind a Service.
2. A second GOAWAY names the last stream smock received. The calls up to
   it finish, their Stubs' delays included. Those above it never reach
   the Stubs, and the client sends them again, as calls the server never
   began.

From the moment SIGTERM arrives, the health service of every Mock that
turns it on says NOT_SERVING ([During the drain](#during-the-drain)), and
`/readyz` fails. So clients that health-check smock, and Kubernetes,
send no more calls to it. The connection closes once no call is in
progress. At `--drain-timeout-ms`, calls still in progress are cut, and
their clients see UNAVAILABLE ([The drain](../running.md#the-drain)).
