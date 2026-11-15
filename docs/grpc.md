# gRPC

A Mock can stand in for a gRPC service. It names the service's
Descriptor set, the compiled form of its `.proto` files, and smock reads
and checks the set when it loads the Definition files. Its gRPC Stubs then
answer unary calls, on the plain port over h2c and on the TLS port over
h2, beside HTTP. So one smock can stand in for a system's HTTP and gRPC
dependencies at once, with one Journal, and Sessions, Scenarios,
Variables and Data buckets shared between them.

This guide shows a first call and says which requests are gRPC calls.
It then says how to build a set, what the Mock's `grpc` field holds and
what a gRPC Stub can hold. It shows the JSON form of a call's message
and of a reply, the metadata of a call and of a reply, and how a reply
gives its status, message, trailers and error details. It says what an
unmatched call gets, how a call's deadline meets a Stub's delay, why
smock never compresses, and which status each Fault gives a client. It
says what the Journal and the metrics record of a call, how a Mock
answers server reflection and gRPC's health service, which calls gRPC's
rules refuse, how gRPC's channels meet smock's connection limits and its
drain, and what smock does not serve. The
[Definition-file reference](definition-files.md#grpc) describes the
Mock's `grpc` field and gRPC Stubs field by field.

## Contents

- [Quick start](#quick-start)
- [Ports and detection](#ports-and-detection)
  - [Other subtypes](#other-subtypes)
  - [Requests that are not gRPC calls](#requests-that-are-not-grpc-calls)
- [Building a set](#building-a-set)
  - [Self-contained sets](#self-contained-sets)
  - [What smock checks](#what-smock-checks)
  - [What smock keeps](#what-smock-keeps)
  - [One set per Mock](#one-set-per-mock)
  - [Memory](#memory)
- [The Mock's `grpc` field](#the-mocks-grpc-field)
  - [The call's Mock](#the-calls-mock)
- [gRPC Stubs](#grpc-stubs)
  - [A path that names no method](#a-path-that-names-no-method)
  - [Ephemeral gRPC Stubs](#ephemeral-grpc-stubs)
- [How smock serves a call](#how-smock-serves-a-call)
  - [Reloads](#reloads)
  - [The call the Stubs see](#the-call-the-stubs-see)
  - [The request message as JSON](#the-request-message-as-json)
  - [Well-known types](#well-known-types)
  - [JSON values: Struct, Value, ListValue and NullValue](#json-values-struct-value-listvalue-and-nullvalue)
  - [Any](#any)
  - [Conditions on the message](#conditions-on-the-message)
  - [Printed forms](#printed-forms)
  - [The reply](#the-reply)
  - [proto2 types](#proto2-types)
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
- [State over gRPC](#state-over-grpc)
  - [Scenarios](#scenarios)
  - [Variables](#variables)
  - [Data buckets](#data-buckets)
  - [Weighted responses](#weighted-responses)
- [Unmatched calls](#unmatched-calls)
  - [Calls answered from their HEADERS](#calls-answered-from-their-headers)
  - [The Near miss trailer](#the-near-miss-trailer)
- [smock's own failures](#smocks-own-failures)
- [Rendering a gRPC Stub](#rendering-a-grpc-stub)
  - [The sample's message](#the-samples-message)
  - [What the rendering shows](#what-the-rendering-shows)
- [Deadlines](#deadlines)
  - [A client that resets at its deadline](#a-client-that-resets-at-its-deadline)
  - [Resets and the connection's defences](#resets-and-the-connections-defences)
- [Compression](#compression)
- [Faults](#faults)
  - [HTTP/2's resets and refusals](#http2s-resets-and-refusals)
- [The Journal and the metrics](#the-journal-and-the-metrics)
- [Built-in services](#built-in-services)
  - [Reflection](#reflection)
  - [Health](#health)
- [Protocol checks and limits](#protocol-checks-and-limits)
  - [The order of the checks](#the-order-of-the-checks)
  - [Timeouts](#timeouts)
  - [The body limit](#the-body-limit)
  - [The decoder's limits](#the-decoders-limits)
- [Connections](#connections)
  - [Idle channels](#idle-channels)
  - [Keepalive PINGs](#keepalive-pings)
  - [The drain](#the-drain)
- [What smock does not serve](#what-smock-does-not-serve)

## Quick start

Build the Descriptor set of gRPC's
[helloworld.proto](https://github.com/grpc/grpc/blob/master/examples/protos/helloworld.proto)
and googleapis'
[error_details.proto](https://github.com/googleapis/googleapis/blob/master/google/rpc/error_details.proto),
whose `ErrorInfo` an error below carries, into the body-file subdirectory
of a definitions directory, with protoc
([Building a set](#building-a-set)):

```sh
mkdir -p defs/files google/rpc
curl -fsSL -o helloworld.proto \
  https://raw.githubusercontent.com/grpc/grpc/master/examples/protos/helloworld.proto
curl -fsSL -o google/rpc/error_details.proto \
  https://raw.githubusercontent.com/googleapis/googleapis/master/google/rpc/error_details.proto
protoc --include_imports -o defs/files/greeter.binpb \
  helloworld.proto google/rpc/error_details.proto
```

Write a Mock that names the set, and two gRPC Stubs on the method
`SayHello`, in `defs/greeter.yaml`:

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb   # in the body-file subdirectory, like a bodyFile
      reflection: true               # off unless turned on
      health: true                   # off unless turned on
stubs:
  - id: hello-tom
    mock: greeter
    request:
      path: /helloworld.Greeter/SayHello      # names a unary method of the set
      headers: { x-tenant: acme }             # metadata, as headers
      body: { json: { name: Tom } }           # the message as ProtoJSON
    response:
      headers: { x-served-by: smock }         # initial metadata
      json: { message: Hello Tom }            # encoded with the output type
  - id: hello-unknown
    mock: greeter
    request:
      path: /helloworld.Greeter/SayHello
    response:
      template: true
      grpc:
        status: NOT_FOUND
        message: no user called ${body.name}
        trailers: { x-trace: abc }
        details:
          - "@type": type.googleapis.com/google.rpc.ErrorInfo   # a type of the set
            reason: USER_UNKNOWN
            domain: greeter.svc
```

The Mock answers calls for the Host `greeter.svc`. It turns on
[reflection](#reflection), so tools find its services and types, and the
[health service](#health). The first Stub answers Tom of the tenant
`acme`. The second answers every other call with NOT_FOUND, a message that
names the user, a trailer and an error detail.

Serve it, and call the method over h2c on the plain port, here with
[grpcurl](https://github.com/fullstorydev/grpcurl). Its `-authority`
gives the call's Host, which chooses the Mock, and it finds the method's
types through reflection:

```sh
SMOCK_ADMIN_TOKEN=change-me smock serve --dir defs
grpcurl -plaintext -authority greeter.svc -H 'x-tenant: acme' \
  -d '{"name":"Tom"}' localhost:8080 helloworld.Greeter/SayHello
```

```json
{
  "message": "Hello Tom"
}
```

A call for Ann gets the second Stub's error. grpcurl's `-format-error`
prints its status, its message and its detail:

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

Without reflection, give grpcurl the same set with `-protoset`, and it
reads the types from there:

```sh
grpcurl -plaintext -authority greeter.svc -protoset defs/files/greeter.binpb \
  -H 'x-tenant: acme' -d '{"name":"Tom"}' localhost:8080 helloworld.Greeter/SayHello
```

The same call goes to the TLS port over h2. Leave out `-plaintext`, and
add `-insecure` while smock serves its self-signed certificate:

```sh
grpcurl -insecure -authority greeter.svc -H 'x-tenant: acme' \
  -d '{"name":"Tom"}' localhost:8443 helloworld.Greeter/SayHello
```

The Journal records each call, with the request message as JSON:

```sh
curl -H "Authorization: Bearer change-me" -d '{}' localhost:9090/v1/journal/query
```

Tom's entry shows `POST`, the target `/helloworld.Greeter/SayHello`, the
version `HTTP/2`, grpcurl's metadata as headers, the body
`{"name":"Tom"}`, the status 200 and the gRPC status `OK`. Ann's entry
shows the gRPC status `NOT_FOUND`. A call that no Stub matches gets
UNIMPLEMENTED, and the Journal records it as unmatched
([Unmatched calls](#unmatched-calls)).

CI runs every grpcurl command of this guide against smock, over h2c and
over TLS, and checks that grpcurl prints what the guide shows
(`scripts/check-grpcurl.sh`). It serves this example as written:
`scripts/grpcurl/definitions/greeter.yaml` is the file above, and its set
is built by this protoc command from the two `.proto` files committed in
`fixtures/protobuf/details/`, which CI rebuilds and compares on every
push (`scripts/gen-protobuf-fixtures.sh`).

## Ports and detection

smock serves gRPC on the ports that serve HTTP, beside HTTP. gRPC has no
port of its own:

- the plain port, over h2c: HTTP/2 without TLS, which grpcurl's
  `-plaintext` and a channel without credentials send;
- the TLS port, over h2: ALPN chooses HTTP/2 when the client offers `h2`,
  as gRPC clients do ([h2 on the TLS port](http2.md#h2-on-the-tls-port)).

`--tls-http2 off` also turns off gRPC over TLS. The TLS port then offers
`http/1.1` alone, so a gRPC client, which offers only `h2`, fails the
handshake with the `no_application_protocol` alert: grpcurl reports
`remote error: tls: no application protocol`. The plain port still serves
gRPC. The admin port never serves gRPC: it serves HTTP/1.1 only.

An HTTP/2 request is a gRPC call when its `content-type` is
`application/grpc`, alone or followed by `+` or `;`. The text after `+`,
up to any `;`, is the call's subtype. It names how the call's messages
are encoded, and no subtype means protobuf:

| `content-type` | The request |
|---|---|
| `application/grpc`, `application/grpc;v=1` | a gRPC call that smock serves |
| `application/grpc+proto`, `application/grpc+proto;v=1` | a gRPC call that smock serves |
| `application/grpc+json`, or any other subtype | a gRPC call that smock refuses ([Other subtypes](#other-subtypes)) |
| any other, such as `application/grpc-web` or `application/json`, or none | an HTTP request ([Requests that are not gRPC calls](#requests-that-are-not-grpc-calls)) |

smock compares the content type as sent, in its case, as grpc-go does.

smock's HTTP/2 checks of a request come first, whatever its content type
([Requests smock refuses](http2.md#requests-smock-refuses)). A request that
HTTP/1.1's rules refuse gets 400, and a header list over
`--header-size-limit` gets 431, with no gRPC status. A gRPC client reports
400 as INTERNAL and 431 as UNKNOWN, as gRPC reads answers that are not
gRPC.

### Other subtypes

smock encodes messages with protobuf only. A call with another subtype,
such as `application/grpc+json`, gets UNIMPLEMENTED as soon as its HEADERS
arrive. smock sends it as [Trailers-Only](#trailers-only): one HEADERS
block that ends the stream, with `:status` 200, `content-type: application/grpc`,
`grpc-status: 12` and the fixed `grpc-message`
`only the proto content subtype is served`. When the client is still
sending its request, RST_STREAM `NO_ERROR` follows and tells it to stop.

The call never reaches the Stubs. It is not in the Journal, and the
request metrics count it as a rejected request, with `mock=""` and
`stub=""`. A call whose method is not `POST` gets the method's answer,
405, instead ([Protocol checks and limits](#protocol-checks-and-limits)).

### Requests that are not gRPC calls

Every other request is an HTTP request. The Mock's HTTP Stubs answer it,
or its `noMatch` answer when none matches, as before:

- an HTTP/2 request with another content type, gRPC-Web's
  `application/grpc-web` included, or with none;
- every HTTP/1.1 request, one with `content-type: application/grpc`
  included. gRPC needs HTTP/2's trailers, so smock serves no gRPC over
  HTTP/1.1.

Such a request never matches a gRPC Stub, even on the path of a gRPC
method.

## Building a set

smock reads no `.proto` file and runs no protoc. It reads a Descriptor
set: a FileDescriptorSet in protobuf's binary encoding, which buf and
protoc write. Build it into the body-file subdirectory of your Definition
files, `files/` by default:

```sh
buf build -o defs/files/greeter.binpb
protoc --include_imports -o defs/files/greeter.binpb helloworld.proto
```

Then name it from the Mock:

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb
```

smock reads the set with the Definition files: `smock check` reads it, and
so do startup and each reload. A reload swaps the set in together with the
files, and a change to the set reloads them.

### Self-contained sets

A set must hold every file that its files import, the well-known types
such as `google/protobuf/timestamp.proto` included. `buf build` puts them
in by default. protoc puts them in only with `--include_imports`. Without
it, the set lacks the files that yours import, and `smock check` says
which:

```text
greeter.json: /mocks/0/grpc/descriptorSet: "orders.binpb": orders.proto imports common.proto, which is not in the set; build the set with protoc --include_imports, or with buf build
```

### What smock checks

Each problem with a set is a problem at the JSON Pointer of
`descriptorSet`, reported by `smock check`, at startup and on a reload.
A reload with a problem keeps serving the whole current definition set.
smock refuses a set when:

- the file is missing, or does not decode as a FileDescriptorSet;
- a file is in the set more than once;
- a file imports a file that is not in the set;
- a full name is defined twice, such as a message `shop.Order` in two
  files. An enum value's full name is in the scope of its enum's package
  or message, as protobuf scopes it, so two enums of one package cannot
  share a value name;
- a message uses a field number twice, or a field is in a oneof that its
  message does not have;
- a type that a field, a method or an extension names is not defined in
  the set;
- an extension's number is not one that its message declares for
  extensions, or is taken by another extension of the message;
- messages nest deeper than 100, or the full names of the set take more
  than 16 MiB. No set built from real `.proto` files comes near either.

buf and protoc never write a set with the other problems, but a set put
together by hand, or joined from two sets, can have them. smock checks
types only when every import is in the set and every name is defined
once, so a missing import gives one problem, not one for each type the
missing file defines.

### What smock keeps

smock keeps what it needs of each file: its name, package, syntax and
imports; its messages, nested ones included, with their fields, oneofs,
map entries and extension ranges; its enums and their values, aliases
included; its extensions and groups; and its services and methods.

It drops the rest, so it costs nothing:

- source info, the comments and positions that `buf build` keeps by
  default and that `protoc --include_source_info` adds;
- options, custom options included, except the three that change how
  messages are encoded: `map_entry`, `packed` and
  `message_set_wire_format`;
- fields that FileDescriptorSet does not define, such as the extensions
  that a Buf image adds to each file.

So a set built with `buf build -o` and its defaults, which is a Buf image
with source info, loads as it is. A Mock with [reflection](#reflection)
on also keeps each file as the set encodes it, without its source info,
so that reflection sends custom options and every other field as the set
holds them. Files written in proto2, in proto3 or in
an edition all load. gRPC Stubs serve the types of proto3 and proto2
files; a Stub whose method reaches a type of an editions file, or a
MessageSet, is a problem ([What is not served](#what-is-not-served)).

### One set per Mock

Each Mock names its own set, so two Mocks can hold two versions of one
package, to stand in for two versions of one service:

```yaml
mocks:
  - name: greeter-v1
    hosts: [v1.greeter.svc]
    grpc:
      descriptorSet: v1/greeter.binpb
  - name: greeter-v2
    hosts: [v2.greeter.svc]
    grpc:
      descriptorSet: v2/greeter.binpb
```

A Mock without `grpc` holds no set, and costs nothing more.

### Memory

smock holds each set decoded, with the definition set it belongs to, so
every replica holds it, for as long as it serves those Definition files.
A large set costs memory in each one. For example, a set of 4.8 MB, with
5,000 messages and 100,000 fields, takes about 40 MiB once loaded, and
about 0.15 s to load. Source info costs nothing once loaded, since smock
drops it.

A Mock with [reflection](#reflection) on also keeps each file of its set
as encoded, without source info, about as many octets as the set built
without source info: for the set of 4.8 MB above, built without source
info, about 4.8 MB more in each replica.

To keep a set small, build it from the files of the services your Mocks
stand in for, not from every file of a large repository: give protoc
only those files, or `buf build` their paths with `--path`.

## The Mock's `grpc` field

A Mock serves gRPC calls through its `grpc` field, an object with three
fields, each of which may be left out:

| Field | What it gives the Mock |
|---|---|
| `descriptorSet` | Its [Descriptor set](#building-a-set): the path of a set in the body-file subdirectory, with the rules of `bodyFile`. It stays inside the subdirectory, symlinks included, and none of its names starts with `.`. Its gRPC Stubs are checked against the set, and its calls are decoded and answered with it. |
| `reflection` | `true` turns on its built-in [server reflection](#reflection). `false` by default. |
| `health` | `true` turns on its built-in [health service](#health). `false` by default. |

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb
      reflection: true
      health: true
```

A Mock without a set has no method of its own: a call to it gets
UNIMPLEMENTED `the Mock has no Descriptor set` as soon as its HEADERS
arrive ([Calls answered from their HEADERS](#calls-answered-from-their-headers)),
unless its built-in services answer it. So `grpc: { health: true }`
alone serves the health service, and nothing else. With `grpc` or
without, a Mock's HTTP Stubs answer its HTTP requests as before. The
[Definition-file reference](definition-files.md#grpc) describes the field.

### The call's Mock

A call's `:authority` is its Host, and chooses its Mock, as it does for
any HTTP/2 request ([What a Stub sees](http2.md#what-a-stub-sees)): the
Mock whose `hosts` include it. grpcurl's `-authority` sets it, and so does
the target a gRPC channel is made for. When no Mock lists the Host, the
Default Mock answers the call, with its own set, and the answer carries
`smock-mock` with the Mock's name and `via=default`, as on HTTP. With
neither, the call gets UNIMPLEMENTED `no Mock for this Host`.

Each Mock decodes and answers its calls with its own set. So two Mocks
whose sets hold two versions of one package each serve their own version
([One set per Mock](#one-set-per-mock)):

```yaml
mocks:
  - name: greeter-v1
    default: true
    grpc:
      descriptorSet: v1/greeter.binpb
  - name: greeter-v2
    hosts: [v2.greeter.svc]
    grpc:
      descriptorSet: v2/greeter.binpb
```

A call with `-authority v2.greeter.svc` is decoded and answered with
version 2. A call to any other Host is decoded and answered with version
1, by the Default Mock.

## gRPC Stubs

A gRPC Stub is an ordinary Stub whose exact `path` names a method of its
Mock's set: `/`, the service's full name, `/` and the method's name, as a
gRPC call names it. It needs no `method`, since every gRPC call is a
`POST`, and no `status`:

```yaml
stubs:
  - id: hello
    mock: greeter
    request:
      path: /helloworld.Greeter/SayHello
      headers: { x-tenant: acme }
      body: { json: { name: Tom } }
    response:
      json: { message: Hello Tom }
```

- Its conditions are `headers`, on the call's metadata, and a `json`
  condition on the message
  ([Conditions on the message](#conditions-on-the-message)).
- Its reply is `json`, the reply message ([The reply](#the-reply)),
  `headers`, its initial metadata ([Reply metadata](#reply-metadata)),
  and `grpc`, the status, message, trailing metadata and error details
  the reply ends with ([Status and message](#status-and-message)).
  `template` and weighted `responses` work as on HTTP.
- `priority`, `scenario`, `variables`, `dataWrites` and `fault` work as
  on HTTP. A delay waits before the reply's HEADERS, and the call's
  deadline can cut it short ([Deadlines](#deadlines)). A connection Fault
  resets the call's stream, sends half the reply, or closes the
  connection ([Faults](#faults)).

Fields that make no sense for gRPC are problems when the files load:
`query` and `cookies` conditions, a body condition other than `json`, and
`status`, `body`, `bodyFile`, `events` and `llm` in a reply. So is a
`method` other than `POST`. Each problem says why:

```text
greeter.yaml: /stubs/0/request/query: makes no sense on a gRPC Stub: a gRPC call's path has no query
```

The
[Definition-file reference](definition-files.md#a-grpc-stubs-fields)
lists every field. A [CRUD Stub](definition-files.md#crud-stubs) is never
a gRPC Stub, whatever its path: it has no request path, so gRPC calls
never reach it.

### A path that names no method

A typo in a gRPC Stub's path, such as `/helloworld.Greeter/SayHelo`,
leaves an HTTP Stub, which gRPC calls never reach. Without `status`, it
fails to load, since an HTTP Stub's response needs one. With `status`,
`smock check` warns about it, since its path has the form of a gRPC
method, `/package.Service/Method`, but names no method of the set:

```text
greeter.yaml: /stubs/1/request/path: warning: the Stub "hello-typo" is an HTTP Stub that gRPC calls never reach: its path has the form of a gRPC method, /package.Service/Method, but the Mock's Descriptor set has no method helloworld.Greeter/SayHelo
```

The warning does not change the exit status
([A path that looks like a gRPC method](definition-files.md#a-path-that-looks-like-a-grpc-method)).

### Ephemeral gRPC Stubs

A test can add a gRPC Stub through the Admin API, as any
[Ephemeral Stub](../README.md#sessions-and-ephemeral-stubs). It is a gRPC
Stub when its path names a method of the Mock's set. This one makes the
calls of the Session `test-a` to the [quick start](#quick-start)'s Mock
fail with UNAVAILABLE:

```sh
curl -H "Authorization: Bearer change-me" \
  -H "baggage: smock-session=test-a" \
  -d '{"request": {"path": "/helloworld.Greeter/SayHello"}, "response": {"grpc": {"status": "UNAVAILABLE", "message": "try again"}}}' \
  localhost:9090/v1/mocks/greeter/stubs
grpcurl -plaintext -authority greeter.svc -H 'x-tenant: acme' \
  -H "baggage: smock-session=test-a" \
  -d '{"name":"Tom"}' localhost:8080 helloworld.Greeter/SayHello
```

```text
ERROR:
  Code: Unavailable
  Message: try again
```

The same call without the Session still gets the reply of the Stub from
the files, `{"message": "Hello Tom"}`.

- smock checks the Stub against the set, and normalises its `json`
  condition, as it does a Stub in a Definition file. One that does not fit
  gets 400 `invalid_stub`, whose message gives each problem with its JSON
  Pointer, as `smock check` gives it:

  ```json
  {"error":"invalid_stub","message":"/response/json/mesage: is not a field of helloworld.HelloReply","warnings":[]}
  ```

- It answers the calls of its Session before the gRPC Stubs from the
  files, and counts for their [Near miss](#the-near-miss-trailer). HTTP
  requests never reach it, and gRPC calls never reach an Ephemeral HTTP
  Stub.
- It is not read again at a reload ([Reloads](#reloads)). While the Mock's
  set does not have its method as a unary method, it answers no call, and
  a call to the method gets the answer from its HEADERS
  ([Calls answered from their HEADERS](#calls-answered-from-their-headers)).
  Once a reload brings the method back, it answers again.
- Its reply was encoded with the set served when it was added. After a
  reload, smock encodes it on each call, and a reply that no longer fits
  the output type gets INTERNAL `template failed`, with a `templateError`
  in the call's Journal entry that says why
  ([The reply](#the-reply)). Its [error details](#error-details) are
  encoded again the same way, and a detail whose type the new set lacks
  gets INTERNAL too.

## How smock serves a call

smock tells a gRPC call by its content type
([Ports and detection](#ports-and-detection)), and refuses a call that
gRPC's rules refuse as soon as it shows
([Protocol checks and limits](#protocol-checks-and-limits)). When the
call's HEADERS arrive, smock finds the call's Mock
([The call's Mock](#the-calls-mock)) and the method that the call's
`:path`, such as `/helloworld.Greeter/SayHello`, names in the Mock's set.
A call that cannot reach a gRPC Stub, since there is no such Mock, set or
unary method, is answered at once, without waiting for its message
([Calls answered from their HEADERS](#calls-answered-from-their-headers)).

When the call's request has ended, smock:

1. finds the call's Mock and its method again, from the Definition files
   it serves then;
2. takes the call's one message from its body, which must hold one;
3. decodes the message into JSON with the method's input type;
4. matches the call against the Mock's gRPC Stubs on that method;
5. encodes the reply with the method's output type, and sends it.

### Reloads

A changed set is reloaded with the Definition files, in one swap
([Building a set](#building-a-set)). A call is decoded, matched and
answered with the set served when its request ends. Steps 1 to 5 above
run with nothing in between, so a reload never decodes a call with one
version of a set and answers it with another.

A reload may come between a call's HEADERS and the end of its request.
The call is looked up again at the end, so it is served with the new
Definition files. When the reload has left the call without a gRPC Stub
to reach, such as a Mock whose set is gone or no longer has the method,
the call gets the answer its HEADERS would get then
([Calls answered from their HEADERS](#calls-answered-from-their-headers)).
A set that fails to load keeps the whole current definition set served.

A reload does not read [Ephemeral gRPC Stubs](#ephemeral-grpc-stubs)
again. One answers calls while the new set has its method as a unary
method, and its reply is encoded with the new output type.

### The call the Stubs see

A gRPC Stub sees a call as a request:

- the method is `POST`, and the path is the call's `:path`;
- the headers are the call's metadata, every field, `content-type` and
  `te` included, with `-bin` values unpadded
  ([Request metadata](#request-metadata));
- the body is the request message as compact JSON, with its fields in
  field-number order, each under its JSON name
  ([The request message as JSON](#the-request-message-as-json)). So the
  message `name: "Tom"` is `{"name":"Tom"}`.

A call is matched only against the gRPC Stubs on its method, never
against an HTTP Stub, even one whose conditions it meets: first its
Session's [Ephemeral gRPC Stubs](#ephemeral-grpc-stubs), then those of the
files, in the order Stubs are tried. A call that none of them matches
gets UNIMPLEMENTED ([Unmatched calls](#unmatched-calls)). A `json` body
condition matches the decoded message, as it matches a JSON body, once
smock has checked it against the input type and rewritten it into the
same form ([Conditions on the message](#conditions-on-the-message)):

```yaml
request:
  path: /helloworld.Greeter/SayHello
  body: { json: { name: Tom } }
```

The Journal, the Near miss, `bodyText` and templates see the same JSON,
so `${body.name}` in a templated reply reads the message's `name`.

### The request message as JSON

smock prints a request message in one form, the same for every client
that sends it. The fields come in field-number order, each under its JSON
name: its name in lowerCamelCase, such as `inStock` for `in_stock`, unless
the `.proto` file gives it a `json_name`. Each type prints as follows:

| Protobuf | JSON | Example |
|---|---|---|
| `int64`, `uint64`, `sint64`, `fixed64`, `sfixed64` | a number, exact at any size | `9223372036854775807` |
| `int32`, `uint32`, `sint32`, `fixed32`, `sfixed32` | a number | `-5` |
| `double` | a number, as smock's `json` replies write one | `0.1`, `1e+21` |
| `float` | a number, in the shortest form that reads back as the same 32-bit float | `9.99`, not `9.989999771118164` |
| `double` and `float` that are not numbers | the strings `"NaN"`, `"Infinity"` and `"-Infinity"` | `"NaN"` |
| `bool` | `true` or `false` | `true` |
| `string` | a string | `"Kyoto"` |
| `bytes` | a string of standard base64, with padding | `"AAH7/w=="` |
| an enum | the name of its value, the first name when aliases share the number, or the number of a value the enum does not define, for an open enum, as a proto3 enum is ([proto2 types](#proto2-types)) | `"ACTIVE"`, `7` |
| a message | an object in the same form | `{"city":"Kyoto"}` |
| a repeated field | an array of its values, in order | `["a","b"]` |
| a map | an object with a member per key, in key order; integer keys in decimal and bool keys as `"true"` and `"false"`, as strings | `{"1":3,"2":5,"10":1}` |
| a oneof | the member the message holds, under its own JSON name, and no other | `"word":"w"` |
| a proto2 group | an object, as a message | `"stop":[{"city":"Paris"}]` |
| a proto2 extension | its value, under its full name in brackets, among the fields in field-number order, only when the message holds it ([proto2 types](#proto2-types)) | `"[shop.priority]":3` |
| `google.protobuf.Timestamp` | a string of the date and time in UTC, with 0, 3, 6 or 9 fractional digits, then `Z` | `"1970-01-01T00:00:01.500Z"` |
| `google.protobuf.Duration` | a string of seconds, with 0, 3, 6 or 9 fractional digits, then `s` | `"1.500s"`, `"-0.250s"` |
| `google.protobuf.FieldMask` | a string of its paths in lowerCamelCase, joined by commas | `"userName,address.city"` |
| a wrapper, such as `google.protobuf.Int32Value` | the value it wraps, printed as its type is: `Int64Value` and `UInt64Value` as numbers, `FloatValue` as a `float`, `BytesValue` in base64 | `5`, `9.99`, `"Tom"` |
| `google.protobuf.Empty` | an empty object | `{}` |
| `google.protobuf.Struct` | an object of any JSON values, its members in key order | `{"age":42,"name":"Tom"}` |
| `google.protobuf.Value` | the JSON value it holds: `null`, a number, which prints as a `double` does, a string, `true` or `false`, an object or an array | `null`, `1.5`, `["x"]` |
| `google.protobuf.ListValue` | an array of any JSON values | `["Tom",null,7]` |
| `google.protobuf.NullValue` | `null` | `null` |
| `google.protobuf.Any` | an object of its type URL as `"@type"`, then the message it holds: its fields, or, for a well-known type with a form of its own, that form as `"value"` ([Any](#any)) | `{"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Tom"}` |

So the message `id: 9223372036854775807 price: 9.99 status: ACTIVE
address { city: "Kyoto" }` is:

```json
{"id":9223372036854775807,"price":9.99,"status":"ACTIVE","note":"","address":{"city":"Kyoto"}}
```

A condition matches it as written: `{price: 9.99, status: ACTIVE}` meets
it, and so does `{id: 9223372036854775807}`, since numbers are compared
exactly.

Which fields print depends on whether a field has presence:

- A field without presence, such as a plain proto3 `string` or `int32`,
  prints even when the message leaves it out, at its default: `0`,
  `false`, `""`, or an enum's value numbered 0. A repeated field prints
  `[]` and a map `{}`. So `{count: 0}`, `{name: ""}` and `{tags: []}`
  match a message that leaves `count`, `name` or `tags` out.
- A proto3 `optional` field, a member of a oneof, a message field and
  every singular field of a proto2 message print only when the message
  holds them, even at their default. So the condition
  `{maybeCount: {$exists: false}}` tells a message that leaves
  `maybe_count` out from one that holds 0.

smock reads a message as protobuf's parsers read it:

- The last value of a field wins.
- The values of a message field are merged: the last value of each of
  its fields wins, its repeated fields are joined, and its maps are
  merged.
- A member of a oneof replaces the member that came before it, so the
  JSON never holds two.
- A repeated number, bool or enum may come packed or not, and the records
  of a packed field are joined.
- A map entry without a key or a value takes the default. When a key
  comes twice, the last entry wins.
- Fields the type does not have, such as those a newer client sends, are
  skipped.

Each message gives one text. Its fields come in field-number order, and
its map entries in key order: integer keys by their value, bool keys
`false` then `true`, and string keys by their text, in the order of
Unicode code points. Neither depends on the order in which a client
encodes them. So a message reads the same in `bodyText`, the Journal and
the Near miss, whichever client sent it. The message
`tags: ["a", "b"] counts: {10: 1, 1: 3, 2: 5}` is always:

```json
{"tags":["a","b"],"counts":{"1":3,"2":5,"10":1}}
```

smock decodes requests, and answers with replies, of every type of a
proto3 or a proto2 file ([The reply](#the-reply),
[proto2 types](#proto2-types)). The types of editions files and
MessageSets are not served ([What is not served](#what-is-not-served)).

### Well-known types

protobuf's well-known types print in their ProtoJSON forms, as grpcurl
shows them, not as objects of their fields
([the table above](#the-request-message-as-json)). This section shows
Timestamp, Duration, FieldMask, the wrappers and Empty; the next two show
the types that hold any JSON value, and Any. With this message:

```proto
message Lease {
  google.protobuf.Timestamp created_at = 1;
  google.protobuf.Duration ttl = 2;
}
```

a call with a Timestamp 1.5 s after the epoch and a Duration of 1.5 s is
journaled as:

```json
{"createdAt":"1970-01-01T00:00:01.500Z","ttl":"1.500s"}
```

A Timestamp and a Duration print the fewest fractional digits of 0, 3, 6
and 9 that hold their nanoseconds: `"1s"`, `"1.500s"`, `"0.000120s"`,
`"0.000000001s"`. A negative Duration starts with `-`, such as `"-0.500s"`.

A field of a well-known type is a message field. It prints only when the
message holds it, and then even at its default: a Timestamp of the epoch
prints `"1970-01-01T00:00:00Z"`, a Duration of 0 `"0s"`, a FieldMask
without paths `""`, and an `Int32Value` that holds 0 prints `0`. So, on an
`Int32Value` field `count`, the condition `{count: {$exists: false}}`
tells a message that leaves `count` out from one that holds 0.

A condition on one of these types is written in its printed form
([Printed forms](#printed-forms)): `{ttl: "1.5s"}` is a problem that names
`"1.500s"`. A reply reads every form that ProtoJSON reads, offsets and
other fraction lengths included ([The reply](#the-reply)). A reply value
out of its type's range is a problem, or INTERNAL `template failed` when
the reply is templated.

A method's whole input or output may be a well-known type, too. A call
that sends `google.protobuf.Empty` is `{}`, and one that sends a
`google.protobuf.Duration` is the string, such as `"1.500s"`. A Stub's
`json` condition, and its reply, are then that value:

```yaml
- id: wait
  mock: leases
  request:
    path: /wellknown.Leases/Wait            # takes a google.protobuf.Duration
    body: { json: "1.500s" }
  response: {}                              # returns google.protobuf.Empty
```

A message whose Timestamp is outside the range from
0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z, whose Duration
is longer than 315,576,000,000 seconds either way or has seconds and
nanoseconds of opposite signs, or whose FieldMask has a path with no
lowerCamelCase form, such as `user__name`, cannot be printed, so it does
not decode: the call gets INTERNAL, as a message that does not parse
does.

### JSON values: Struct, Value, ListValue and NullValue

`google.protobuf.Struct`, `Value` and `ListValue` hold any JSON value, and
print as that value. A Struct is an object, its members in key order, as
a map's are. A ListValue is an array. A Value is `null`, a number, a
string, `true` or `false`, an object, which is a Struct, or an array,
which is a ListValue. A number prints as a `double` does: `3`, `1.5`,
`1e+21`. `google.protobuf.NullValue`, the enum of a Value's `null`, prints
as `null`. With this message:

```proto
message Document {
  google.protobuf.Struct labels = 1;
  google.protobuf.Value value = 2;
  google.protobuf.NullValue nothing = 4;
}
```

a call is journaled as:

```json
{"labels":{"count":3,"team":"core"},"value":["x",null],"nothing":null}
```

A NullValue field without presence prints `null` even when the message
leaves it out, as any field at its default does.

A condition on one of these types may hold any JSON value, with patterns
and operators in any place. A Struct's keys are data, as a map's are:
smock never rewrites them, and a key that starts with `$` is written
`$$`. A number is rewritten into the form a `double` prints, such as
`3` for `3.0`, and a NullValue's name, `NULL_VALUE`, or its number into
`null`.

In a reply, `null` sets a Value, a Struct's members and a ListValue's
elements included, to `null_value`, and a NullValue field to its one
value. It leaves any other field unset:

```yaml
response:
  json: { labels: { gone: null }, value: null, nothing: null }
```

A Value that holds no value, or a number that JSON has none for, NaN or
an infinity, cannot be printed, so a call whose message holds one does
not decode and gets INTERNAL, as protobuf's JSON printers refuse it.

### Any

A `google.protobuf.Any` holds a message of any type, with the type's URL,
such as `type.googleapis.com/helloworld.HelloRequest`. smock looks the
type up in the Mock's Descriptor set, by the full name after the URL's
last `/`, so the set must hold the file that defines it, as
`protoc --include_imports` puts it there when a file of the set imports
it. An Any prints as an object of the URL as `"@type"`, then the message
it holds: its fields, as any message prints, or, for a well-known type
with a form of its own, that form as `"value"`. An Any that holds an
Empty prints `"@type"` alone, and an empty Any prints `{}`.

So an Any that holds a `helloworld.HelloRequest` is journaled as:

```json
{"@type":"type.googleapis.com/helloworld.HelloRequest","name":"Tom"}
```

and one that holds a Duration of 1.5 s as:

```json
{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1.500s"}
```

A condition on an Any is written in the same form. smock checks its
other members against the type that `"@type"` names, and rewrites them as
in any condition. `"@type"` may be a pattern or an operator only when it
is the Any's only member. A reply is read in the same form, field names
in either spelling, and an Empty may also be given `"value": {}`, as
grpcurl prints it.

An Any whose type the set lacks cannot be printed. A call whose message
holds one gets INTERNAL, as a message that does not parse does. In a
condition or a static reply, it is a problem when the files load, and a
templated reply that names one gets INTERNAL `template failed`:

```text
documents.yaml: /stubs/0/request/body/json/@type: names the type missing.Greeting, which the Descriptor set does not define
```

### Conditions on the message

When the files load, smock checks each gRPC Stub's `json` condition
against the input type of its method, and rewrites it into the form in
which it prints a call's message. Matching a call then costs no more than
matching a JSON body. With this input type:

```proto
message Query {
  int64 user_id = 1;
  Status status = 2;
  float ratio = 3;
  map<int32, string> labels = 5;
  Profile profile = 7;
}

enum Status {
  option allow_alias = true;
  STATUS_UNSPECIFIED = 0;
  ACTIVE = 1;
  ENABLED = 1;
  SUSPENDED = 2;
}

message Profile {
  string display_name = 1;
  map<string, int32> scores = 2;
}
```

the condition `{user_id: 42, status: 1}` is matched as
`{"userId":42,"status":"ACTIVE"}`, so the call `user_id: 42 status: ACTIVE`
meets it. A Near miss in the Journal shows the condition in that form.

smock rewrites:

- a field's name in the `.proto` file into its JSON name: `user_id` into
  `userId`, at every depth;
- an enum's number, or an alias, into the first name of its number:
  `status: 1` and `status: ENABLED` into `status: ACTIVE`. A number that no
  value has stays a number, as smock prints it for an open enum, and is a
  problem for a closed enum, which never prints it
  ([proto2 types](#proto2-types));
- a `float`, or the value of a `google.protobuf.FloatValue`, into the
  nearest 32-bit float, in the form smock prints it:

  | Written | Matched as | Meets a call of |
  |---|---|---|
  | `ratio: 0.1` | `0.1` | `0.1` |
  | `ratio: 9.99` | `9.99` | `9.99` |
  | `ratio: 16777217` | `16777216` | `16777217`, which a float holds as 16777216 |

- an integer written with an exponent or a fraction of zeros, such as
  `1e3`, into its digits, `1000`;
- a NullValue's name or number into `null`, and a number that a Value
  holds into the form a `double` prints
  ([JSON values](#json-values-struct-value-listvalue-and-nullvalue)).

Map keys are data, never rewritten: `profile: {scores: {math_score: 90}}`
matches the key `math_score` as written, while `profile` and its field
`display_name` become `profile` and `displayName`. A key that starts with
`$` is written `$$`, as in any `json` condition. A Struct's keys are data
too, and an Any's members are checked against the type its `"@type"`
names ([Any](#any)).

An extension is written by its full name in brackets, as ProtoJSON writes
it, such as `"[shop.priority]": 3`, and the key stays as written
([proto2 types](#proto2-types)).

smock refuses, as a problem at the JSON Pointer of the value at fault:

- a key that names no field of the type at its place, a key in brackets
  that names no extension of the set that extends the type, and a field
  given by both its names in one object;
- a literal that is not a value of its field's type as smock prints it,
  and so can never match: an integer out of its type's range or with a
  fraction, an enum name the enum lacks, a `float` outside the float range,
  a string for a number or a number for a string, an array for a field
  that is not repeated, a map or a message that is not an object, and
  `null`, which smock prints only for a Value and a NullValue;
- a literal that ProtoJSON reads but smock never prints
  ([Printed forms](#printed-forms)).

Patterns and operators are allowed in any place. An operator's condition
is checked as the value in its place, and that of `$includes` and `$last`
on a repeated field as one of its elements, so
`history: {$includes: ENABLED}` becomes `history: {$includes: ACTIVE}`.

```text
users.yaml: /stubs/0/request/body/json/usr_id: is not a field of users.Query
users.yaml: /stubs/1/request/body/json/history/1: must be the name of a value of users.Status, or an integer from -2147483648 to 2147483647: the elements of the field history of users.Query have the type users.Status
```

Templates, `find`, `$each`, Variables and data writes read the call's
message as smock prints it, so they see JSON names only: `${body.userId}`
reads 42, and `${body.user_id}` is missing.

Two gRPC Stubs are compared once rewritten for the
[warning about a Stub that can never match](definition-files.md#a-stub-that-can-never-match).
So a gRPC Stub whose conditions include all of an earlier one's gets the
warning, however each spells them:

```text
users.yaml: /stubs/1: warning: the Stub "by-json-name" can never match: the Stub "by-proto-name" at users.yaml: /stubs/0 is tried first and matches every request this one would
```

### Printed forms

ProtoJSON reads some values in several forms, as smock reads a
[reply](#the-reply). smock prints each value in one form, so a condition
written in another form could never match. Rather than rewrite these, smock
refuses them when the files load, with the form to write:

| Field | Written | The problem suggests |
|---|---|---|
| An integer of any size, such as `int64` | `user_id: "42"` | `42` |
| `float` or `double` | `ratio: "0.1"` | `0.1` |
| `bytes`, in base64 without its padding | `token: "+/8"` | `"+/8="` |
| `bytes`, in URL-safe base64 | `token: "-_8="` | `"+/8="` |
| An integer map key not in decimal | `labels: {"007": seven}` | `"7"` |
| `google.protobuf.Duration` | `ttl: "1.5s"` | `"1.500s"` |
| `google.protobuf.Timestamp`, with an offset other than `Z` | `createdAt: "1970-01-01T09:00:01.500+09:00"` | `"1970-01-01T00:00:01.500Z"` |
| `google.protobuf.Timestamp`, with other fractional digits | `createdAt: "1970-01-01T00:00:01.5Z"` | `"1970-01-01T00:00:01.500Z"` |

```text
users.yaml: /stubs/0/request/body/json/user_id: must be written 42, as smock prints it: the field user_id of users.Query has the type int64
users.yaml: /stubs/1/request/body/json/labels/007: must be written "7", as smock prints it: the keys of the map field labels of users.Query have the type int32
leases.yaml: /stubs/0/request/body/json/ttl: must be written "1.500s", as smock prints it: the field ttl of wellknown.Lease has the type google.protobuf.Duration
```

The same holds for bytes whose base64 has bits after its last octet, such
as `"QR=="`, which smock prints `"QQ=="`, for an integer key such as
`"-0"` or `"1e3"`, and for a wrapper's value as for its type's: an
`Int64Value` written `"42"` names `42`. A FieldMask's paths are data,
which smock does not check against any type, so its printed form is the
one ProtoJSON reads: lowerCamelCase paths, joined by commas.

### The reply

A gRPC Stub's reply is `json`, the reply message, read as ProtoJSON reads
JSON, so a reply that grpcurl or another tool printed can be pasted as it
is:

| Field | In `json` |
|---|---|
| Any field | Its name as the `.proto` file spells it, such as `user_id`, or its JSON name, such as `userId`. Giving both in one object is a problem. |
| `int32`, `sint32`, `sfixed32`, `uint32`, `fixed32` | A number or a string, in its type's range: `7` or `"7"`. An exponent or a fraction of zeros is fine, such as `1e3` or `"100.0"`. |
| `int64`, `sint64`, `sfixed64`, `uint64`, `fixed64` | The same, exact at any size: `"9223372036854775807"`, or the number, whose digits smock keeps. |
| `float`, `double` | A number or a string, or `"NaN"`, `"Infinity"` or `"-Infinity"`. A `float` is rounded to the nearest 32-bit float, and one beyond its range is a problem. |
| `bool` | `true` or `false`. |
| `string` | A string. |
| `bytes` | A string in base64, standard or URL-safe, with or without its padding. |
| An enum | The name of a value, such as `ACTIVE`, or a number, which may name no value, as an open enum allows. A closed enum, as a proto2 enum is, takes only the numbers it defines. |
| A message | An object. |
| A repeated field | An array. `null` in it is a problem, but in a list of Values or NullValues. |
| A map | An object whose keys are the map's keys as strings: integers in decimal, such as `"-1"`, and `"true"` and `"false"`. A `null` value is a problem, but in a map of Values or NullValues. |
| A oneof | One of its members. Two members in one object are a problem, but a member that is `null` does not count. |
| A proto2 group | An object, as for a message. |
| A proto2 extension | Its full name in brackets, such as `"[shop.priority]": 3`. It must name an extension of the set that extends the type. |
| `google.protobuf.Timestamp` | A string in RFC 3339 form, with 0 to 9 fractional digits, then `Z` or an offset such as `+09:00`: `"1970-01-01T09:00:01.5+09:00"`. From 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z, once the offset is taken off. |
| `google.protobuf.Duration` | A string of seconds, with 0 to 9 fractional digits, then `s`: `"1.5s"`, `"-0.25s"`. At most `315576000000.999999999s` either way. |
| `google.protobuf.FieldMask` | A string of paths in lowerCamelCase, joined by commas: `"userName,address.city"`. An underscore in it is a problem. |
| A wrapper | The value it wraps, as its type reads it: `5` or `"5"` for an `Int64Value`. |
| `google.protobuf.Empty` | `{}`. |
| `google.protobuf.Struct` | An object of any JSON values. |
| `google.protobuf.Value` | Any JSON value, `null` included. |
| `google.protobuf.ListValue` | An array of any JSON values, `null` included. |
| `google.protobuf.NullValue` | `null`, or its name `NULL_VALUE`, or its number. |
| `google.protobuf.Any` | An object of `"@type"`, a type URL that names a type of the set, and the message it holds ([Any](#any)). |

`null` leaves a field unset, but sets a Value or a NullValue field
([JSON values](#json-values-struct-value-listvalue-and-nullvalue)). A key
that names no field is a problem. A Stub without `json` answers an empty
message, with every field at its default.

The reply's output type may be any message of a proto3 or a proto2 file,
with any of these fields, a well-known type such as
`google.protobuf.Timestamp` included, whose value is then the whole
`json`, such as `json: "1970-01-01T00:00:01.5Z"`. A Stub on a method whose
output type reaches a type of an editions file or a MessageSet, through
its fields or its extensions, is a problem at its `path`
([proto2 types](#proto2-types)).

A reply without `template` is read and encoded once, when the files load.
A reply that is not a message of the output type is a problem at the JSON
Pointer of its first value at fault, which `smock check` reports:

```text
replies.yaml: /stubs/0/response/json/tags/1: cannot be null: it is an element of the repeated field tags of replies.User
```

A reply with `template: true` is rendered as JSON, its values escaped as
in any `json` template, then read and encoded on each call. One that is
not a message of the output type gets Trailers-Only INTERNAL with the
message `template failed`, and the call's Journal entry says why in
`templateError`, at the JSON Pointer of the value at fault within the
Stub:

```json
{
  "at": "/response/json/userId",
  "message": "must be an integer from -9223372036854775808 to 9223372036854775807: the field user_id of replies.User has the type int64"
}
```

smock encodes the reply as protoc encodes it: fields in field-number
order; a field without presence left out at its default, while a message
field, a member of a oneof, a proto3 `optional` field and every singular
field of a proto2 message are written whenever they are set; repeated
scalars of a proto3 message packed, unless the field says
`packed = false`, and those of a proto2 message packed only when the
field says `packed = true`; map entries sorted by key, each with its
key and its value; extensions among the fields in field-number order;
and groups between their start and end tags. It sends what a gRPC server
sends:

- HEADERS with `:status` 200, `content-type: application/grpc`, the
  Stub's `headers`, its initial metadata
  ([Reply metadata](#reply-metadata)), `smock-mock` when the Default Mock
  answered, and `date`;
- one DATA frame with the reply message, framed;
- trailers with `grpc-status: 0`, `grpc-message` when the Stub gives
  a message ([Status and message](#status-and-message)), and its
  `grpc.trailers`, its trailing metadata, which end the stream.

A reply larger than the client's flow-control windows goes out as the
client widens them, and the trailers follow it.

### proto2 types

gRPC Stubs serve the types of proto2 files as they serve those of proto3
files, with proto2's own rules. With this file:

```proto
syntax = "proto2";

package shipping;

message Order {
  required int64 id = 1;
  optional string note = 2;
}
```

a call to a method that takes an `Order`, with `id` 7 and no `note`, is
journaled as `{"id":7}`, and a call without `id` gets INTERNAL.

- **Presence.** Every singular field of a proto2 message has presence. It
  prints only when the message holds it, even at its default, and a reply
  writes it whenever the reply gives it, `0`, `false` and `""` included.
  Repeated fields and maps still print `[]` and `{}`. So
  `{note: {$exists: false}}` tells a call without a note from one with an
  empty note. A field's `default` option never shows, since a field the
  message leaves out does not print.
- **Required fields.** A request message that lacks a required field, at
  any depth, does not parse, as protobuf's parsers refuse it. The call
  gets Trailers-Only INTERNAL `the request message cannot be decoded`,
  never reaches the Stubs, and counts as a rejected request
  ([Protocol checks and limits](#protocol-checks-and-limits)). A
  static reply that lacks one is a problem at the JSON Pointer of the
  message that lacks it:

  ```text
  shipping.yaml: /stubs/0/response/json: lacks the required field id of shipping.Order
  ```

  A templated reply that lacks one gets INTERNAL `template failed`, and
  its Journal entry's `templateError` says the same.
- **Closed enums.** An enum of a proto2 file is closed: a number it does
  not define is kept as an unknown field, as protobuf keeps it, so it
  never prints. A singular field keeps the value it had, a repeated field
  leaves the number out, a map leaves the entry out, and a oneof keeps the
  member it had. Matching never sees such a number, so a condition that
  names one is a problem, and so is a reply that gives one:

  ```text
  shipping.yaml: /stubs/0/request/body/json/state: must be the name or the number of a value of shipping.State: the field state of shipping.Parcel has the type shipping.State
  ```

- **Packing.** A reply packs the repeated numbers, bools and enums of a
  proto2 message only when the field says `packed = true`, as protoc
  does. A request may send them packed or not, as for proto3.
- **Text.** A proto2 string need not be UTF-8. One that is not prints
  with U+FFFD for each bad sequence, as smock reads header values: the
  octets `61 c3 28 62` print as `"a�(b"`. Two map keys that print alike
  are one key, and the last entry wins.
- **Groups.** A group is a message field that protobuf delimits with a
  start tag and an end tag instead of a length. smock prints, matches and
  writes it as a message, under the JSON name of its field:
  `repeated group Stop = 2 { optional string city = 3; }` prints as
  `"stop":[{"city":"Paris"}]`, groups nested in groups included. A group
  whose end tag names another field, or that the message ends inside,
  does not parse, as protobuf's parsers refuse it: the call gets
  INTERNAL `the request message cannot be decoded`.

#### Extensions

An extension that the set declares, at the top level of a file or in a
message, is found by the type it extends and its field number, within the
Mock's set. It prints under its full name in brackets, as ProtoJSON
writes it, among the message's fields in field-number order, and only when
the message holds it, a repeated one too. A number in an extension range
that no extension of the set has is an unknown field, and is skipped.
With this file:

```proto
syntax = "proto2";

package shop;

message Order {
  optional int64 id = 1;
  extensions 100 to 199;
}

extend Order {
  optional int32 priority = 100;
}
```

a call whose `Order` has `id` 7 and `priority` 3 is journaled as
`{"id":7,"[shop.priority]":3}`, and meets the condition
`{"[shop.priority]": 3}`. A reply may set the same key,
`json: {id: 7, "[shop.priority]": 3}`, and is encoded as protoc encodes
it. An extension declared in a message is named by its full name too,
such as `[shop.Gift.gift]` for an extension `gift` declared in
`shop.Gift`. Templates read one with brackets:
`${body['[shop.priority]']}`.

A key in brackets, in a condition or a reply, must name an extension of
the set that extends the type at its place:

```text
shop.yaml: /stubs/0/request/body/json/[shop.urgency]: is not an extension of shop.Order: the Descriptor set has no extension shop.urgency
shop.yaml: /stubs/1/request/body/json/[shop.priority]: is not an extension of shop.Itinerary: shop.priority extends shop.Order
```

An extension follows the syntax of the file that declares it. One that a
proto3 file declares, as a custom option is, holds UTF-8 strings and
packs its repeated numbers, though the message it extends is proto2.

#### What is not served

Three kinds of type are not served, each a problem at the `path` of a
Stub whose method's input or output type is, or reaches, one through its
fields or its extensions:

- a type of an editions file, such as a file with `edition = "2023"`, an
  enum included. Editions come in a later spec;
- a type that an extension declared in an editions file extends, since
  what such an extension is depends on features that smock does not read;
- a MessageSet, a message with the option `message_set_wire_format`,
  whose extensions use another wire form.

```text
shipping.yaml: /stubs/0/request/path: the input type labels.Label is not served yet: labels.proto, which defines it, is an editions file, and editions come in a later spec
shipping.yaml: /stubs/1/request/path: the input type shipping.Crate is not served: shipping.Bag, a type it reaches, is a MessageSet, whose extensions use another wire form, and smock serves no MessageSet types
```

The check is per method, so a set whose editions files and MessageSets no
Stub's method reaches loads quietly. A call to such a method never reaches
a Stub: it gets UNIMPLEMENTED ([Unmatched calls](#unmatched-calls)), or
INTERNAL when its message is, or holds, a value of such a type, which
smock does not decode.

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

`header.NAME` gives a name's first value, and a condition holds when one
of its values meets it. The Journal records the metadata as the entry's
headers, in the order received
([The Journal and the metrics](#the-journal-and-the-metrics)).

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

A call carries its [Session](../README.md#sessions-and-ephemeral-stubs)
in its `baggage` metadata, as an HTTP request carries it in its `baggage`
header: in the `smock-session` member, or wherever `--session-header` and
`--session-member` say. There is no key of gRPC's own. With grpcurl:

```sh
grpcurl -plaintext -authority greeter.svc -H 'x-tenant: acme' \
  -H "baggage: smock-session=test-a" \
  -d '{"name":"Tom"}' localhost:8080 helloworld.Greeter/SayHello
```

The Session scopes a call as it scopes an HTTP request: its
[Ephemeral gRPC Stubs](#ephemeral-grpc-stubs), its state of each
Scenario, its Variables, its copies of the Data buckets and its Journal.
Each call reads its own metadata, so the calls of two Sessions on one
channel keep their state and their Journal apart, as two tests that share
a gRPC client do. An Admin API call names its Session the same way, so
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
rendered value as it checks one as written: a value outside 0x20 to 0x7E,
a tab included, or a `-bin` value that is not base64 gets Trailers-Only
INTERNAL `template failed`, and the Journal entry's `templateError` says
why:

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
error, error details. A Stub's reply, or each of its `responses`, gives
them in `grpc`: `status` ([The status](#the-status)), `message`
([The message](#the-message)), `trailers`
([Reply metadata](#reply-metadata)) and `details`
([Error details](#error-details)). smock sends them in the reply's last
block of header fields, whose size is bounded
([Metadata size](#metadata-size)), or in its only one
([Trailers-Only](#trailers-only)). The
[Definition-file reference](definition-files.md#the-status-of-a-grpc-reply)
describes the field. With weighted `responses`, a dependency can fail one
call in ten:

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

- each octet from 0x20 to 0x7E, other than `%`, stays as it is;
- every other octet becomes `%` and two upper-case hex digits;
- a space at either end becomes `%20`, since HTTP/2 refuses a field value
  with a space at either end.

So `try again ☺` goes out as `try again %E2%98%BA`, and gRPC's own test
message, `"\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"`,
as:

```text
grpc-message: %09%0Atest with whitespace%0D%0Aand Unicode BMP %E2%98%BA and non-BMP %F0%9F%98%88%09%0A
```

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
`grpc.details`, each in ProtoJSON with `@type`
([gRPC error details](definition-files.md#grpc-error-details)):

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
its details, each packed in an Any, encodes it itself, and sends it in
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
`grpc-status` and `grpc-message`, so the two never disagree. grpcurl
decodes it with `-format-error`, here for the [quick start](#quick-start)'s
Mock:

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
without it. A client that decodes the details needs their types too.
grpcurl finds them through [reflection](#reflection), or in the same set
given with `-protoset`; without them, it prints each detail's bytes in
base64.

- A type the set lacks is a problem when the files load, at the detail's
  `@type`. Any message type of the set can be a detail, and a detail type
  goes through the checks of a method's types, so a type of an editions
  file and a MessageSet are problems.
- Each detail is read as ProtoJSON reads an Any, as a reply is read
  ([The reply](#the-reply)): `retry_delay` or `retryDelay`, and a
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
- smock's own answers, such as UNIMPLEMENTED with its Near miss trailer,
  are sent as they are.

`smock check` and `smock render` take `--header-size-limit` too, and its
variable `SMOCK_HEADER_SIZE_LIMIT`, so they load a directory as
`smock serve` does. Give them the limit `smock serve` gets.

### Trailers-Only

An error without initial metadata goes out as Trailers-Only, as gRPC
servers send it: one HEADERS block that ends the stream, with no DATA and
no trailers after it. Its fields are, in order:

- `:status: 200`;
- `content-type: application/grpc`;
- `grpc-status`, the status's code;
- `grpc-message`, when the reply gives a message;
- `grpc-status-details-bin`, when the reply gives
  [error details](#error-details);
- smock's own fields: `smock-mock` when the Default Mock answered, and
  `smock-near-miss` for an [unmatched call](#unmatched-calls);
- the trailing metadata, the Stub's `grpc.trailers`;
- `date`.

```text
:status: 200
content-type: application/grpc
grpc-status: 14
grpc-message: try again %E2%98%BA
date: Sat, 14 Nov 2026 07:00:00 GMT
```

No gRPC reply carries `content-length` or `grpc-encoding`: smock never
compresses a reply ([Compression](#compression)). A gRPC client reads every field of a Trailers-Only
answer as trailing metadata.

## State over gRPC

A gRPC Stub takes part in its Mock's state as an HTTP Stub does. Its
`scenario` clause requires and moves a
[Scenario](definition-files.md#scenarios), its `variables` write
[Variables](definition-files.md#variables), its `dataWrites` write
[Data buckets](definition-files.md#data-buckets), and its templates read
all three. Templates see the request message as `body`, in the JSON form
the Stubs see ([The call the Stubs see](#the-call-the-stubs-see)), so
`${body.name}` reads the message's `name`.

A Mock has one state for its HTTP requests and its gRPC calls. A call
reads what a request of the same Session wrote, and a request reads what
a call wrote. A call's Session comes from its `baggage` metadata, as a
request's comes from its `baggage` header ([Sessions](#sessions)).
Another Session, or a call without one, has its own state.

### Scenarios

A call moves a Scenario when its Stub is chosen, as a request does,
whatever then happens to the reply: an error, a delay, a deadline or
[smock's own failure](#smocks-own-failures). This "create, then get" flow
tells the two calls apart by the metadata `x-op`:

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

A call's `dataWrites` write the Session's copies of its Mock's Data
buckets, which the Mock's HTTP Stubs read and write too, a
[CRUD Stub](definition-files.md#crud-stubs) included. A CRUD Stub never
answers a gRPC call, but its bucket is the one the gRPC Stubs use:

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
[smock's own failures](#smocks-own-failures).

### Weighted responses

A Stub with `responses` picks one for each call, by weight, as on HTTP
([Several responses](definition-files.md#several-responses)). Each may be
a reply or an error, so a Stub can fail one call in ten:

```yaml
responses:
  - { weight: 9, json: { message: Hello } }
  - { weight: 1, grpc: { status: UNAVAILABLE, message: try again } }
```

The Journal entry's `responseIndex` says which response a call got, and
`--seed` or `fault.seed` replays the picks
([Seeds](definition-files.md#seeds)).

## Unmatched calls

A call that no gRPC Stub on its method matches gets UNIMPLEMENTED, the
status gRPC servers give a method they do not serve. smock sends it as
[Trailers-Only](#trailers-only): one HEADERS block that ends the stream,
with `:status` 200, `content-type: application/grpc`, `grpc-status: 12`
and the fixed `grpc-message` `no Stub matched`. Take a lone Mock, which is
the Default Mock, with one Stub for Tom:

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
([Reloads](#reloads)).

### The Near miss trailer

The Near miss is the gRPC Stub of the call's Mock that failed the fewest
conditions, the one tried first on a tie, as on HTTP
([When no Stub matches](definition-files.md#when-no-stub-matches)). The
call's Session's [Ephemeral gRPC Stubs](#ephemeral-grpc-stubs) count, and
are tried first, but not one whose method a reload took away. A
Stub on another method fails the `path` condition, so a call to a method
that no Stub is on, or that the set lacks, has a Near miss too. smock
sends it in the `smock-near-miss` field of the answer, in the form of the
HTTP `Smock-Near-Miss` header: the Stub's ID, then the conditions it
failed. With a Stub that requires the metadata `x-tenant: acme`, a call
without it gets:

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
without a set never has. An HTTP Stub is never a call's Near miss, even one whose
path pattern takes the call's path.

## smock's own failures

smock's own HTTP answers never reach a gRPC call. An HTTP request whose
Stub cannot serve its content gets a 500 or a 507 with a JSON body
([Missing values and render errors](definition-files.md#missing-values-and-render-errors)).
A gRPC call gets Trailers-Only instead: one HEADERS block that ends the
stream, with `:status` 200, `content-type: application/grpc`, its
`grpc-status`, a fixed ASCII `grpc-message`, `smock-mock` when the Default
Mock answered, and `date`. None of the Stub's metadata, trailers or
details go out with it.

| What fails | `grpc-status` | `grpc-message` | In the Journal entry |
|---|---|---|---|
| A template of the Stub: its reply, its message, its metadata, its details, a `variables` value, or a `dataWrites` key or value. Also a rendered metadata value that breaks gRPC's rules ([Reply metadata](#reply-metadata)), a rendered reply that does not fit the output type ([The reply](#the-reply)), and a rendered detail that does not fit its type ([Error details](#error-details)) | 13, INTERNAL | `template failed` | `templateError` |
| A write of the Stub's `dataWrites` cannot be applied ([When a write fails](definition-files.md#when-a-write-fails)) | 13, INTERNAL | `data write failed` | `dataError` |
| The Stub's writes, Variables and data writes together, would pass the bound on per-Session state ([The state bound](definition-files.md#the-state-bound)) | 8, RESOURCE_EXHAUSTED | `state limit reached` | `grpcStatus` only |
| A block of the reply's metadata is too large to send ([Metadata size](#metadata-size)) | 13, INTERNAL | `reply metadata too large` | `templateError` |

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

The rest is as on HTTP. A `variables` value or a `dataWrites` key or
value that fails to render, a write that cannot be applied, and writes
past the state bound write nothing, Variables included, and no response
is picked. A reply that fails once picked keeps the writes made before
it. The Scenario move stands. The Stub's delay holds the answer back, and
the call's deadline can cut it short ([Deadlines](#deadlines)). The
Stub's connection Fault ends the call as it would end the Stub's reply,
and a `partial` one sends smock's own HEADERS ([Faults](#faults)). The
request metrics count the call under its Mock and Stub. The `mockoon` log
format writes its error line, and its `Transaction recorded` line gives
`responseStatus` 200.

## Rendering a gRPC Stub

`smock render` and the Admin render operation
([Rendering a template](definition-files.md#rendering-a-template)) show
what a Stub answers, without a client. A gRPC Stub renders as a call to
its method. The Stub decides this, not the sample: the sample's `method`
and its `Content-Type` are checked only as conditions, as a call's are,
and the rendering lists them among the conditions the sample fails. An
HTTP Stub renders as a request, whatever the sample's `Content-Type`.

For the `hello-unknown` Stub of [Error details](#error-details), with
`sample.json` holding

```json
{"path": "/helloworld.Greeter/SayHello", "body": "{\"name\": \"Ann\"}"}
```

this command shows the reply a call for Ann gets:

```sh
smock render --dir defs hello-unknown --request sample.json | jq -c .response
```

```json
{"status":200,"headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false},"events":null,"grpc":{"status":"NOT_FOUND","message":"no user called Ann","trailers":[{"name":"x-trace","value":"abc"}],"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"USER_UNKNOWN","domain":"greeter.svc"}]}}
```

### The sample's message

The sample's `body` is the request message as JSON, in a string. smock
checks it against the input type of the Stub's method, and normalises it
as it normalises a Stub's conditions
([Conditions on the message](#conditions-on-the-message)): a field may be
named by its proto name, and an enum by its number. A value that smock
never prints in that form is refused, such as a Duration of `"1.5s"`
([Printed forms](#printed-forms)). smock then reads the message as it
reads a call's ([The request message as JSON](#the-request-message-as-json)),
so a field without presence that the sample leaves out is there at its
default, as in a call. An empty body is the empty message.

A body that is not such a message is refused with every problem, each at
its JSON Pointer in the message. So is a message whose JSON takes more
than `--body-limit` once read, as a call's would be
([The body limit](#the-body-limit)): the Admin render operation uses the
limit of the smock that serves it, and `smock render`, which takes no
`--body-limit`, the default, 10 MiB. `smock render` exits with status 1,
and the Admin render operation answers 400 `invalid_request`.
For the [quick start](#quick-start)'s `hello` Stub and the body
`{"nmae": "Tom"}`:

```text
smock render: the sample request's body must be a helloworld.HelloRequest as JSON, the message that the method of the gRPC Stub "hello" takes: /nmae is not a field of helloworld.HelloRequest
```

The sample's binary metadata, a header field whose name ends with `-bin`,
loses its padding, as a call's does ([Request metadata](#request-metadata)).

### What the rendering shows

The rendering shows the reply as JSON, never its protobuf bytes:

- `response.body` is the reply message as JSON, as written or rendered.
  It is empty for an error, which has no message.
- `response.headers` is the initial metadata.
- `response.grpc` is how the reply ends: `status`, the gRPC status's
  name; `message`, as written or rendered, before smock percent-encodes
  it, or null; `trailers`, the trailing metadata; and `details`, the error
  details as JSON, each with its `@type`.
- `response.status` stays 200, the HTTP status of every gRPC reply.

smock encodes a templated reply, once rendered, with the output type, as
it does for a call. A reply that does not fit shows the Trailers-Only
INTERNAL a call gets, with the message `template failed`, no metadata,
and the reason in `templateError`. So does a rendered detail that does
not fit its type, and a template that fails. A write that cannot be
applied shows INTERNAL `data write failed`
([smock's own failures](#smocks-own-failures)).

The rendering leaves out what a call adds on the wire, such as
`content-type` and the Default Mock's `smock-mock` field. It does not
check the size of the reply's metadata ([Metadata size](#metadata-size)),
and it decides no deadline and no Fault.

## Deadlines

A client gives a call its time in `grpc-timeout`
([Timeouts](#timeouts)). smock counts the call's deadline from the arrival
of its HEADERS. A call without `grpc-timeout` has no deadline. Neither has
a call whose timeout is longer than the longest delay smock can give,
2^31-1 ms, about 24.8 days, such as `99999999H`: no delay can outlast it.

smock watches the deadline only while a Stub's delay runs
([Faults](#faults)). When the delay would end after the deadline, the call
ends at the deadline instead, as a gRPC server ends a call whose deadline
passes. smock sends [Trailers-Only](#trailers-only) DEADLINE_EXCEEDED with
the fixed `grpc-message` `deadline exceeded`. So with a Stub whose `fault`
is `{delay: {fixed: 3000}}`, a call with `grpc-timeout: 5S` gets its reply
after 3 s, and a call with `grpc-timeout: 1S` gets this about 1 s after
its HEADERS:

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
HEADERS, so smock's deadline comes about one transit after the client's,
about when the client's reset arrives: either can come first.

smock records such a reset as DEADLINE_EXCEEDED too. A client reset that
arrives while a delay runs past the deadline, at most 100 ms before the
deadline, ends the call's Journal entry as if smock had ended the call at
its deadline. So the entry does not depend on which comes first.

A call that the client cancels earlier during a delay, or that has no
deadline, ends there, as any HTTP/2 stream does
([Streams that wait](http2.md#streams-that-wait)). Its entry keeps the
HTTP status and the `grpcStatus` that its Stub's reply planned.

### Resets and the connection's defences

The defences of an HTTP/2 connection count two kinds of client reset
([Defences](http2.md#defences)). A reset of a stream that smock has not
finished answering counts toward the Rapid Reset bound, and a reset of a
stream that has closed counts among the frames that do no work. Past
either bound, the connection gets GOAWAY `ENHANCE_YOUR_CALM`.

A client that keeps deadlines resets every call that times out, so these
resets count toward neither bound:

- a client reset that smock records as DEADLINE_EXCEEDED, as above: one
  that arrives at most 100 ms before the deadline, while the delay runs
  past it;
- the first reset of a call that smock ended at its deadline with
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

## Faults

A gRPC Stub's `fault` may give a delay and a
[connection Fault](definition-files.md#connection-faults), each drawn as
on HTTP, with its `probability`. smock decides them as for an HTTP
request, with the same draws, so
[`fault.seed` and `--seed`](definition-files.md#seeds) replay them. A
connection Fault takes its [HTTP/2 form](http2.md#faults), and sends no
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

- **Probabilistic errors.** For a call that fails with a gRPC status
  some of the time, such as UNAVAILABLE one call in ten, give the Stub
  weighted `responses`, one of them with a `grpc` status
  ([Status and message](#status-and-message)). That is no connection
  Fault: the call gets the status itself, with its message.
- **A delay first.** A Fault with a delay comes once the delay is over,
  as on HTTP/2. A delay holds back whatever the call gets from its Stub:
  its reply, its error, its Fault, or
  [smock's own failure](#smocks-own-failures) when the Stub cannot serve
  its content, such as INTERNAL `template failed`. A call that no Stub
  matched gets UNIMPLEMENTED at once.
- **The deadline first.** A delay that the call's deadline cuts short
  never ends, so its connection Fault never comes: the call gets
  DEADLINE_EXCEEDED, and the connection stays open.
- **What `partial` sends.** The HEADERS of the answer the call would get:
  its initial metadata, and `smock-mock` when the Default Mock answered.
  Its status, its message, its details and its trailing metadata never go
  out. A reply that smock cannot send, such as one whose rendered message
  does not fit the output type, sends smock's own HEADERS, with none of
  the Stub's metadata, and so does a reply whose HEADERS are too large to
  send ([Metadata size](#metadata-size)) and
  [smock's own failure](#smocks-own-failures) when the Stub cannot serve
  its content.
- **The Journal.** The entry of a call that `reset` or `close` ended has
  no `status` and no `grpcStatus`, since no status went out. A `partial`
  one keeps both, as planned, or INTERNAL when smock sent its own HEADERS
  in place of the Stub's reply. An entry has the Fault in `fault`; a call
  whose deadline came first has none.

### HTTP/2's resets and refusals

smock's [HTTP/2 limits and defences](http2.md#limits-and-timeouts) reset
or refuse a stream, or end a connection, whatever the request. A gRPC
client derives a status from each, as gRPC's HTTP/2 protocol says:

| What smock does | The client sees |
|---|---|
| RST_STREAM `REFUSED_STREAM`, for a stream past `--http2-max-concurrent-streams` | UNAVAILABLE. smock never began the call, so gRPC retries it on its own, without a retry policy. |
| RST_STREAM `CANCEL`, for a call whose request is late past the read timeout, or a stream whose window stays at zero past the write timeout | CANCELLED |
| RST_STREAM `ENHANCE_YOUR_CALM`, for a header list over twice `--header-size-limit` as received | RESOURCE_EXHAUSTED |
| `:status` 431, for a header list over `--header-size-limit` or with more fields than `--header-count-limit` | UNKNOWN |
| `:status` 400, for a request HTTP/1.1's rules refuse | INTERNAL |
| GOAWAY, after one of the [defences](http2.md#defences) | The calls in flight on the connection end, and later calls get UNAVAILABLE. |

## The Journal and the metrics

The Journal records each call that reaches the Stubs, matched or not, and
each call answered from its HEADERS, with an empty body
([Calls answered from their HEADERS](#calls-answered-from-their-headers)).
Its entry shows the method `POST`, the call's `:path` as its target, the
version `HTTP/2`, the metadata as headers, `-bin` values unpadded
([Request metadata](#request-metadata)), and the request message as JSON
as its body. The body's `size` counts the octets the call's DATA frames
brought, as received, and `truncated` says whether the JSON was cut at
`--journal-body-limit`.

The entry's `grpcStatus` is the name of the gRPC status the call got:
the status of the Stub's reply, `OK` unless its `grpc` names another, or
the status smock answered with instead, such as `UNIMPLEMENTED` for an
unmatched call, or `INTERNAL` or `RESOURCE_EXHAUSTED` for
[smock's own failures](#smocks-own-failures). Its `status` stays the HTTP
status, 200 for every answer smock sends a call, as gRPC sends them: a
client learns of an error from `grpc-status`, not from `:status`. The
entry of an HTTP request has no `grpcStatus`, nor has the entry of a call
that a `reset` or `close` Fault ended ([Faults](#faults)).

Journal queries, verification and the unmatched list take calls as they
take HTTP requests. A filter gives the Mock, the method `POST`, the path
that names the gRPC method, and metadata as headers, `-bin` values
without their padding, as the entries hold them:

```json
{
  "filter": {
    "mock": "greeter",
    "method": "POST",
    "path": "/helloworld.Greeter/SayHello",
    "headers": { "x-tenant": "acme" }
  }
}
```

The request metrics, `smock_requests_total`,
`smock_request_duration_seconds` and `smock_unmatched_requests_total`,
count calls with the labels they give HTTP requests, `mock` and `stub`
([the README's metrics](../README.md#run)). No metric and no label gives
the gRPC status: only the Journal records it. Each call counts and is
recorded as follows:

| The call | The request metrics | The Journal |
|---|---|---|
| A Stub answered it, with its reply, its error, [smock's own failure](#smocks-own-failures) or DEADLINE_EXCEEDED ([Deadlines](#deadlines)) | Under its Mock and Stub, `stub="ephemeral"` for an Ephemeral Stub, as an HTTP request | An entry, with the Stub |
| No Stub matched it ([Unmatched calls](#unmatched-calls)), or it was answered from its HEADERS ([Calls answered from their HEADERS](#calls-answered-from-their-headers)) | Under its Mock with `stub=""`, `mock=""` when its Host reaches no Mock, and as an unmatched request | An entry, with its Near miss when it has one, in the unmatched list too |
| A built-in service of its Mock answered it ([Reflection](#reflection), [Health](#health)) | Under its Mock with `stub=""`, not as an unmatched request | None |
| The [protocol checks](#protocol-checks-and-limits) refused it | As a rejected request, with `mock=""` and `stub=""`, not as an unmatched request | None |

So, for a Mock, `stub=""` counts its unmatched calls and the answers of
its built-in services, and `smock_unmatched_requests_total` tells them
apart. Health probes every few seconds and reflection's round trips would
otherwise fill the Journal and evict the calls that tests verify.

In the `mockoon` log format, a call that a Stub answered, or that no Stub
matched, gets a `Transaction recorded` line, with `POST`, the method's
path and the HTTP status 200, as an HTTP/2 request does
([Logs](http2.md#logs)), after an `Error while serving the content: …`
line when its Stub's template or data write failed. The line carries no
gRPC status. A call that a built-in service answered, or that the
protocol checks refused, gets no line.

## Built-in services

A Mock can answer gRPC's server reflection and its standard health
service itself, with no Stub. Each is off unless the Mock turns it on
([The Mock's `grpc` field](#the-mocks-grpc-field)), and a Mock that does
not turn them on pays nothing for them. Their answers are counted in the
request metrics under their Mock, and are not recorded in the Journal
([The Journal and the metrics](#the-journal-and-the-metrics)).

### Reflection

Tools such as grpcurl and Postman find a server's services and their
types through gRPC's
[server reflection](https://github.com/grpc/grpc/blob/master/doc/server-reflection.md).
Turn it on with the Mock's `grpc.reflection`, and they need no local copy
of the Mock's set:

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

A call then needs no `-protoset`, as in the [quick start](#quick-start):

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
- A Mock that does not turn reflection on has no reflection service. A
  call to it is a call to a method the set lacks, which gets UNIMPLEMENTED
  `unknown method` from its HEADERS, and grpcurl says `server does not
  support the reflection API`.

#### One request per call

Reflection's method, `ServerReflectionInfo`, is bidirectional streaming,
and smock serves no streaming method yet. So smock answers one request
per call: it reads the first request message as soon as it has arrived
whole, sends one response message and the OK trailers, then RST_STREAM
`NO_ERROR` if the client is still sending. Messages after the first are
not read. Clients open a new call for their next request, as grpcurl,
grpc-go and grpc-python do, so every command works.

The [protocol checks](#protocol-checks-and-limits) come first, as for any
call, and a first message that does not decode as a reflection request
gets INTERNAL `the request message cannot be decoded`.

#### A Stub wins

As for [health](#health), a call goes to the Stubs, not to the service,
when the Mock has a gRPC Stub on its path. Reflection's method streams, and a gRPC
Stub on a streaming method is a problem, so no Stub can be on it today.

#### In the Journal and the metrics

Reflection answers are not recorded in the Journal: each grpcurl command
makes one or more reflection calls, which would otherwise evict the calls
that tests verify. The request metrics count each under its Mock with
`stub=""`, and not as an unmatched request. In the `mockoon` log format,
they get no line.

#### Memory

With reflection on, the Mock keeps each file of its set as the set
encodes it, without its source info, beside the set's decoded model, so
that answers carry every field and option as the set holds them. This
costs about as much memory as the set built without source info, in
every replica ([Memory](#memory)). A Mock without reflection keeps
nothing more.

### Health

Clients and proxies that health-check a gRPC server call gRPC's
[health service](https://github.com/grpc/grpc/blob/master/doc/health-checking.md),
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
| `Watch` | It streams, so it gets UNIMPLEMENTED `streaming methods are not served yet` from its HEADERS, as a streaming method of a set does ([Calls answered from their HEADERS](#calls-answered-from-their-headers)), but it is not journaled, as no health answer is. |

- The set need not hold `health.proto`. smock embeds the descriptor of
  gRPC's
  [health.proto](https://github.com/grpc/grpc-proto/blob/master/grpc/health/v1/health.proto),
  and decodes and encodes the service's messages with it. A set that
  holds the file has `grpc.health.v1.Health` among its services, so the
  service says SERVING for itself too.
- `descriptorSet` may be left out. A Mock with `grpc: { health: true }`
  alone has no service of its own: `Check` says SERVING for `""` and
  gives NOT_FOUND for every other name, and `List` gives `""` alone.
- The [protocol checks](#protocol-checks-and-limits) come first, as for
  any call. A `Check` of `""` may send a message of zero octets.
- The service answers on the plain and TLS ports alike, through the
  Default Mock too, with `smock-mock` in its answer.
- smock's own probes stay on the admin port. Kubernetes reads `/readyz`,
  not the health service.

#### During the drain

Once SIGTERM starts the drain, every answer of `Check` and `List` says
NOT_SERVING, for every name, an unknown one included. Health-checking
clients then move away before smock stops, while the calls in flight
finish ([The drain](http2.md#the-drain)). `/readyz` fails from the same
moment.

#### A Stub wins

A call to a health method goes to the Stubs, not to the service, when
the Mock has a gRPC Stub on that path: one in a Definition file, or an
Ephemeral one of the call's Session. So a Scenario can make the service
NOT_SERVING:

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

## Protocol checks and limits

smock refuses a call that gRPC's rules refuse before the call reaches
the Stubs, and answers it as gRPC servers answer it. The answer is
[Trailers-Only](#trailers-only), with `:status` 200, its gRPC status and
a fixed `grpc-message`, except for two that get another `:status`, as
grpc-go answers them: 405 for a method other than `POST`, and 400 for a
malformed `grpc-timeout`. Both carry `grpc-status: 13` (INTERNAL).

| The call | Checked | `:status` | gRPC status | `grpc-message` |
|---|---|---|---|---|
| Its method is not `POST` | on HEADERS | 405 | INTERNAL | `the method must be POST` |
| Its subtype is neither none nor `proto` ([Other subtypes](#other-subtypes)) | on HEADERS | 200 | UNIMPLEMENTED | `only the proto content subtype is served` |
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

A message is the 5-octet prefix, a flag and a length, then the octets
the length announces. A message of zero octets, `00 00 00 00 00`, is one
message, with every field at its default, so a call to a method that
takes `google.protobuf.Empty` is served. A unary method takes exactly one
message, so a request with none or with several is refused, as gRPC
libraries refuse it.

A message does not parse, as protobuf's parsers refuse it, when it holds a
proto3 string that is not UTF-8, field number 0 or one above 2^29-1, wire
type 6 or 7, a varint, a fixed-size value or a length cut short, a packed
field included, a group whose end tag names another field or that it ends
inside, or messages nested deeper than 100
([The decoder's limits](#the-decoders-limits)), or when it lacks a proto2
required field
([proto2 types](#proto2-types)). smock cannot print a Timestamp, a
Duration or a FieldMask path out of its range or form
([Well-known types](#well-known-types)), a Value that holds no value, NaN
or an infinity
([JSON values](#json-values-struct-value-listvalue-and-nullvalue)), an
Any whose type the set lacks ([Any](#any)), or a value of a type that it
does not serve, of an editions file or a MessageSet
([What is not served](#what-is-not-served)).

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
fails. On its HEADERS, smock checks, in this order:

1. smock's checks of every HTTP/2 request: a header list over
   `--header-size-limit` or with more fields than `--header-count-limit`
   gets 431, and a request that HTTP/1.1's rules refuse gets 400, with no
   gRPC status ([Ports and detection](#ports-and-detection));
2. the method, which must be `POST`;
3. the subtype;
4. each `grpc-timeout`;
5. the body limit, by `content-length`;
6. the call's Mock, its set and its method
   ([Calls answered from their HEADERS](#calls-answered-from-their-headers)).

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
([Deadlines](#deadlines)).

### The body limit

`--body-limit`, 10 MiB by default, bounds a call's body, the 5-octet
prefix of each message included. A body over it gets RESOURCE_EXHAUSTED,
the status gRPC gives a message over a server's limit, with `:status`
200, instead of the 413 that an HTTP request gets
([Request bodies](http2.md#request-bodies)). smock answers as soon as the
excess shows, before it reads the rest:

- on HEADERS, when `content-length` declares more octets than the limit;
- on a message's prefix, when the length it announces takes the body
  over the limit, before any octet of the message arrives;
- on a DATA frame, when the octets received pass the limit. smock keeps
  none of them.

So with `--body-limit 32`, a call whose framed message takes 32 octets
passes, and a prefix that announces 28 octets gets RESOURCE_EXHAUSTED at
once, then RST_STREAM `NO_ERROR`. The message's JSON must fit within the
limit too, so a small limit refuses messages that a body of its size can
hold ([The decoder's limits](#the-decoders-limits)).

`--header-size-limit` bounds a call's header list, as it bounds an HTTP
request's, and also each block of a reply's metadata: a reply over it, or
over the client's own limit, gets INTERNAL `reply metadata too large`
([Metadata size](#metadata-size)).

`--body-limit` also bounds the JSON that smock decodes a message into
([The decoder's limits](#the-decoders-limits)).

### The decoder's limits

A small message can ask a decoder for far more than its size. smock
bounds what decoding a call's message may cost, so that a gRPC call costs
no more than the largest JSON body an HTTP request may send:

- **Nesting.** Messages may nest 100 deep, the default of protobuf's C++
  and Java parsers. Each nested message is a level, and so is each group,
  each map entry and the message an Any holds. So each object in a Struct
  takes three levels, for the Struct, its entry and the Value, and each
  list in a Value takes two, for the ListValue and the Value. A message
  nested deeper does not parse, and gets INTERNAL.
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
- **What smock holds to print it.** smock keeps a note of each place in
  the message where the records of a list do not follow the list's last
  ones, of each record of a message field after its first, and of each
  map entry, until it has printed the message that holds them. It counts
  48 octets for a note, 64 for a map entry, and 48 more for a map entry
  with a string key, and these too may take at most `--body-limit`. A
  message as clients encode it needs few such notes. One of 10 MiB whose
  records alternate between two lists gets RESOURCE_EXHAUSTED.

So a call holds its message once as it came, and once as JSON, each
within `--body-limit`. For example, a message of 10 MiB of empty `Item`s
in a `repeated Item items`, where an `Item` has a string, a list and a
map, would print 160 MiB of JSON. smock answers RESOURCE_EXHAUSTED once
the JSON passes 10 MiB, in well under a second. Such a call, like an
HTTP request with a body of 10 MiB, holds tens of MiB at once. For a
small Pod, lower `--body-limit`
([Limits and timeouts](http2.md#limits-and-timeouts)).

## Connections

A gRPC client sends its calls to a server over one HTTP/2 connection,
many at once, and keeps the connection open between calls. smock serves
it as any HTTP/2 connection, under the same limits, timeouts and
defences ([Limits and timeouts](http2.md#limits-and-timeouts)), with no
rule of gRPC's own. What a client sees when one of them resets a call or
ends the connection is in
[HTTP/2's resets and refusals](#http2s-resets-and-refusals).

### Idle channels

A connection with no call in progress gets GOAWAY `NO_ERROR` once it has
been idle for `--idle-timeout-ms`, 60 s by default, then closes
([Timeouts](http2.md#timeouts)). A PING does not restart the idle
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
([Frames that do no work](http2.md#frames-that-do-no-work)). A PING
counts among them, beyond one for each HEADERS or DATA frame that smock
has sent on the connection, and a connection whose client sends more
than 100 such frames in any one second gets GOAWAY `ENHANCE_YOUR_CALM`.
A keepalive every few seconds, or a PING for each frame received, as
clients that estimate their bandwidth send, stays far below it.

smock has no ping-strike policy of gRPC's own. gRPC servers may close a
connection whose client pings more often than they allow, while smock
answers such a client as long as it keeps under the bound above. Test a
client's keepalive against such a policy with the real server.

### The drain

On SIGTERM, smock drains each connection in two steps, as it drains any
HTTP/2 connection ([The drain](http2.md#the-drain)):

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
`/readyz` fails, so clients that health-check smock, and Kubernetes,
send no more calls to it. The connection closes once no call is in
progress. At `--drain-timeout-ms`, calls still in progress are cut, and
their clients see UNAVAILABLE ([Run](../README.md#run)).

## What smock does not serve

smock serves gRPC unary calls. These are not served, each with what a
client or a Definition file gets instead:

| Not served | Instead |
|---|---|
| Streaming methods: client, server and bidirectional streaming. They are planned for R3, a later release. | A call to one gets UNIMPLEMENTED `streaming methods are not served yet` as soon as its HEADERS arrive ([Calls answered from their HEADERS](#calls-answered-from-their-headers)), and a Stub on one is a problem at its `path`. Reflection, which streams, answers one request per call ([One request per call](#one-request-per-call)), and health's `Watch` gets UNIMPLEMENTED. |
| gRPC-Web and the Connect protocol. | Their requests are HTTP requests, which the Mock's HTTP Stubs answer ([Requests that are not gRPC calls](#requests-that-are-not-grpc-calls)). |
| Compression. | A compressed message gets UNIMPLEMENTED, with `grpc-accept-encoding: identity`, and replies are never compressed ([Compression](#compression)). |
| Encodings other than protobuf, such as `application/grpc+json`. | UNIMPLEMENTED, as soon as the call's HEADERS arrive ([Other subtypes](#other-subtypes)). |
| Types of editions files, and MessageSets. Editions come in a later spec. | A Stub whose method reaches one is a problem at its `path`, and a call whose message is, or holds, a value of one gets INTERNAL ([What is not served](#what-is-not-served)). |
| Protobuf replies encoded beforehand, such as a body file of protobuf octets. | `body` and `bodyFile` are problems on a gRPC Stub: its reply is `json`, which smock encodes with the output type ([gRPC Stubs](#grpc-stubs)). |
| Stubs generated from a set, as `smock import-openapi` generates them from an OpenAPI document, and replies made up from a type. | Write gRPC Stubs by hand. A Stub without `json` answers an empty message ([The reply](#the-reply)). |
| Descriptor sets uploaded through the Admin API, and a list of a Mock's services in it. | A set is a file of the body-file subdirectory, read with the Definition files ([Building a set](#building-a-set)). Reflection lists a Mock's services ([Reflection](#reflection)). |
| A port of gRPC's own. | gRPC shares the plain and TLS ports with HTTP ([Ports and detection](#ports-and-detection)). |
| gRPC on the admin port. | The admin port serves the Admin API, over HTTP/1.1 only. |
| gRPC over HTTP/1.1. | A request with a gRPC content type over HTTP/1.1 is an HTTP request: gRPC needs HTTP/2's trailers ([Requests that are not gRPC calls](#requests-that-are-not-grpc-calls)). |
| Forwarding calls to the Mock's Upstream, the real service. | smock answers every call itself. A call that no Stub matches gets UNIMPLEMENTED ([Unmatched calls](#unmatched-calls)). |
| A metric label for the gRPC status. | The Journal records each call's gRPC status ([The Journal and the metrics](#the-journal-and-the-metrics)). |
