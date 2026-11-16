# gRPC

A Mock can stand in for a gRPC service. It names the service's
Descriptor set, the compiled form of its `.proto` files, and smock reads
and checks the set when it loads the Definition files. Its gRPC Stubs then
answer unary calls, on the plain port over h2c and on the TLS port over
h2, beside HTTP. So one smock can stand in for a system's HTTP and gRPC
dependencies at once, with one Journal, and Sessions, Scenarios,
Variables and Data buckets shared between them.

This document shows a first call and says which requests are gRPC calls.
It then says how to build a set, what the Mock's `grpc` field holds, what
a gRPC Stub can hold and how smock serves a call, and what smock does not
serve. The [Definition-file
reference](definition-files/grpc.md#grpc-in-definition-files) describes the
Mock's `grpc` field and gRPC Stubs field by field.

The guide goes on in six more documents.
[Messages as JSON](grpc/messages.md) shows the JSON form of a call's
message and of a reply. [Metadata and status](grpc/metadata-and-status.md)
shows the metadata of a call and of a reply, and how a reply gives its
status, message, trailers and error details. [State, deadlines and
Faults](grpc/state-and-faults.md) says how a gRPC Stub shares its Mock's
state with HTTP Stubs, how a call's deadline meets a Stub's delay, and
which status each Fault gives a client. [Unmatched calls, smock's own
failures and protocol checks](grpc/unmatched-and-refused-calls.md) says
what an unmatched call gets, what a call gets when smock cannot serve its
Stub's content, why smock never compresses, and which calls gRPC's rules
refuse. [Rendering, the Journal and the
metrics](grpc/rendering-and-journal.md) says how `smock render` shows a
gRPC Stub's reply, and what the Journal and the metrics record of a call.
[Built-in services and connections](grpc/services-and-connections.md) says
how a Mock answers server reflection and gRPC's health service, and how
gRPC's channels meet smock's connection limits and its drain.

## Contents

In this document:

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
- [What smock does not serve](#what-smock-does-not-serve)

In the other documents:

- [Messages as JSON](grpc/messages.md)
  - [The request message as JSON](grpc/messages.md#the-request-message-as-json)
  - [Well-known types](grpc/messages.md#well-known-types)
  - [JSON values: Struct, Value, ListValue and NullValue](grpc/messages.md#json-values-struct-value-listvalue-and-nullvalue)
  - [Any](grpc/messages.md#any)
  - [Conditions on the message](grpc/messages.md#conditions-on-the-message)
  - [Printed forms](grpc/messages.md#printed-forms)
  - [The reply](grpc/messages.md#the-reply)
  - [proto2 types](grpc/messages.md#proto2-types)
- [Metadata and status](grpc/metadata-and-status.md)
  - [Metadata](grpc/metadata-and-status.md#metadata)
  - [Status and message](grpc/metadata-and-status.md#status-and-message)
- [State, deadlines and Faults](grpc/state-and-faults.md)
  - [State over gRPC](grpc/state-and-faults.md#state-over-grpc)
  - [Deadlines](grpc/state-and-faults.md#deadlines)
  - [Faults](grpc/state-and-faults.md#faults)
- [Unmatched calls, smock's own failures and protocol checks](grpc/unmatched-and-refused-calls.md)
  - [Unmatched calls](grpc/unmatched-and-refused-calls.md#unmatched-calls)
  - [smock's own failures](grpc/unmatched-and-refused-calls.md#smocks-own-failures)
  - [Compression](grpc/unmatched-and-refused-calls.md#compression)
  - [Protocol checks and limits](grpc/unmatched-and-refused-calls.md#protocol-checks-and-limits)
- [Rendering, the Journal and the metrics](grpc/rendering-and-journal.md)
  - [Rendering a gRPC Stub](grpc/rendering-and-journal.md#rendering-a-grpc-stub)
  - [The Journal and the metrics](grpc/rendering-and-journal.md#the-journal-and-the-metrics)
- [Built-in services and connections](grpc/services-and-connections.md)
  - [Built-in services](grpc/services-and-connections.md#built-in-services)
  - [Connections](grpc/services-and-connections.md#connections)

## Quick start

Build the Descriptor set of gRPC's
[helloworld.proto](https://github.com/grpc/grpc/blob/master/examples/protos/helloworld.proto)
and googleapis'
[error_details.proto](https://github.com/googleapis/googleapis/blob/master/google/rpc/error_details.proto),
whose `ErrorInfo` an error below carries, into the body-file subdirectory of
a definitions directory, with protoc ([Building a set](#building-a-set)):

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
[reflection](grpc/services-and-connections.md#reflection), so tools find its
services and types, and the [health
service](grpc/services-and-connections.md#health). The first Stub answers
Tom of the tenant `acme`. The second answers every other call with
NOT_FOUND, a message that names the user, a trailer and an error detail.

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
([Unmatched calls](grpc/unmatched-and-refused-calls.md#unmatched-calls)).

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

- The plain port serves it over h2c: HTTP/2 without TLS, which grpcurl's
  `-plaintext` and a channel without credentials send.
- The TLS port serves it over h2: ALPN chooses HTTP/2 when the client
  offers `h2`, as gRPC clients do
  ([h2 on the TLS port](http2.md#h2-on-the-tls-port)).

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

smock encodes messages with protobuf only. A call with another subtype, such
as `application/grpc+json`, gets UNIMPLEMENTED as soon as its HEADERS
arrive. smock sends it as
[Trailers-Only](grpc/metadata-and-status.md#trailers-only): one HEADERS
block that ends the stream, with `:status` 200, `content-type:
application/grpc`, `grpc-status: 12` and the fixed `grpc-message` `only the
proto content subtype is served`. When the client is still sending its
request, RST_STREAM `NO_ERROR` follows and tells it to stop.

The call never reaches the Stubs. It is not in the Journal, and the request
metrics count it as a rejected request, with `mock=""` and `stub=""`. A call
whose method is not `POST` gets the method's answer, 405, instead ([Protocol
checks and
limits](grpc/unmatched-and-refused-calls.md#protocol-checks-and-limits)).

### Requests that are not gRPC calls

Every other request is an HTTP request. The Mock's HTTP Stubs answer it,
or its `noMatch` answer when none matches, as before:

- An HTTP/2 request with another content type, gRPC-Web's
  `application/grpc-web` included, or with none, is an HTTP request.
- So is every HTTP/1.1 request, one with `content-type: application/grpc`
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

- The file is missing, or does not decode as a FileDescriptorSet.
- A file is in the set more than once.
- A file imports a file that is not in the set.
- A full name is defined twice, such as a message `shop.Order` in two
  files. An enum value's full name is in the scope of its enum's package
  or message, as protobuf scopes it. So two enums of one package cannot
  share a value name.
- A message uses a field number twice, or a field is in a oneof that its
  message does not have.
- A type that a field, a method or an extension names is not defined in
  the set.
- An extension's number is not one that its message declares for
  extensions, or is taken by another extension of the message.
- Messages nest deeper than 100, or the full names of the set take more
  than 16 MiB. No set built from real `.proto` files comes near either.

buf and protoc never write a set with the other problems, but a set put
together by hand, or joined from two sets, can have them. smock checks
types only when every import is in the set and every name is defined
once. So a missing import gives one problem, not one for each type the
missing file defines.

### What smock keeps

smock keeps what it needs of each file: its name, package, syntax and
imports. It keeps its messages, nested ones included, with their fields,
oneofs, map entries and extension ranges. It keeps its enums and their
values, aliases included, its extensions and groups, and its services and
methods.

It drops the rest, so it costs nothing:

- Source info: the comments and positions that `buf build` keeps by
  default and that `protoc --include_source_info` adds.
- Options, custom options included, except the three that change how
  messages are encoded: `map_entry`, `packed` and
  `message_set_wire_format`.
- Fields that FileDescriptorSet does not define, such as the extensions
  that a Buf image adds to each file.

So a set built with `buf build -o` and its defaults, which is a Buf image
with source info, loads as it is. A Mock with
[reflection](grpc/services-and-connections.md#reflection) on also keeps each
file as the set encodes it, without its source info, so that reflection
sends custom options and every other field as the set holds them. Files
written in proto2, in proto3 or in an edition all load. gRPC Stubs serve the
types of proto3 and proto2 files. A Stub whose method reaches a type of an
editions file, or a MessageSet, is a problem ([What is not
served](grpc/messages.md#what-is-not-served)).

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

A Mock with [reflection](grpc/services-and-connections.md#reflection) on
also keeps each file of its set as encoded, without source info. That takes
about as many octets as the set built without source info: for the set of
4.8 MB above, built without source info, about 4.8 MB more in each replica.

To keep a set small, build it from the files of the services your Mocks
stand in for, not from every file of a large repository: give protoc
only those files, or `buf build` their paths with `--path`.

## The Mock's `grpc` field

A Mock serves gRPC calls through its `grpc` field, an object with three
fields, each of which may be left out:

| Field | What it gives the Mock |
|---|---|
| `descriptorSet` | Its [Descriptor set](#building-a-set): the path of a set in the body-file subdirectory, with the rules of `bodyFile`. It stays inside the subdirectory, symlinks included, and none of its names starts with `.`. Its gRPC Stubs are checked against the set, and its calls are decoded and answered with it. |
| `reflection` | `true` turns on its built-in [server reflection](grpc/services-and-connections.md#reflection). `false` by default. |
| `health` | `true` turns on its built-in [health service](grpc/services-and-connections.md#health). `false` by default. |

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb
      reflection: true
      health: true
```

A Mock without a set has no method of its own. A call to it gets
UNIMPLEMENTED `the Mock has no Descriptor set` as soon as its HEADERS arrive
([Calls answered from their
HEADERS](grpc/unmatched-and-refused-calls.md#calls-answered-from-their-headers)),
unless its built-in services answer it. So `grpc: { health: true }` alone
serves the health service, and nothing else. With `grpc` or without, a
Mock's HTTP Stubs answer its HTTP requests as before. The [Definition-file
reference](definition-files/grpc.md#grpc-in-definition-files) describes the
field.

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
  ([Conditions on the message](grpc/messages.md#conditions-on-the-message)).
- Its reply is `json`, the reply message ([The
  reply](grpc/messages.md#the-reply)), `headers`, its initial metadata
  ([Reply metadata](grpc/metadata-and-status.md#reply-metadata)), and
  `grpc`, the status, message, trailing metadata and error details the reply
  ends with ([Status and
  message](grpc/metadata-and-status.md#status-and-message)). `template` and
  weighted `responses` work as on HTTP.
- `priority`, `scenario`, `variables`, `dataWrites` and `fault` work as on
  HTTP. A delay waits before the reply's HEADERS, and the call's deadline
  can cut it short ([Deadlines](grpc/state-and-faults.md#deadlines)). A
  connection Fault resets the call's stream, sends half the reply, or closes
  the connection ([Faults](grpc/state-and-faults.md#faults)).

Fields that make no sense for gRPC are problems when the files load:
`query` and `cookies` conditions, a body condition other than `json`, and
`status`, `body`, `bodyFile`, `events` and `llm` in a reply. So is a
`method` other than `POST`. Each problem says why:

```text
greeter.yaml: /stubs/0/request/query: makes no sense on a gRPC Stub: a gRPC call's path has no query
```

The [Definition-file
reference](definition-files/grpc.md#a-grpc-stubs-fields) lists every field.
A [CRUD Stub](definition-files/crud-stubs.md#crud-stubs) is never a gRPC
Stub, whatever its path: it has no request path, so gRPC calls never reach
it.

### A path that names no method

A typo in a gRPC Stub's path, such as `/helloworld.Greeter/SayHelo`,
leaves an HTTP Stub, which gRPC calls never reach. Without `status`, it
fails to load, since an HTTP Stub's response needs one. With `status`,
`smock check` warns about it, since its path has the form of a gRPC
method, `/package.Service/Method`, but names no method of the set:

```text
greeter.yaml: /stubs/1/request/path: warning: the Stub "hello-typo" is an HTTP Stub that gRPC calls never reach: its path has the form of a gRPC method, /package.Service/Method, but the Mock's Descriptor set has no method helloworld.Greeter/SayHelo
```

The warning does not change the exit status ([A path that looks like a gRPC
method](definition-files.md#a-path-that-looks-like-a-grpc-method)).

### Ephemeral gRPC Stubs

A test can add a gRPC Stub through the Admin API, as any
[Ephemeral Stub](admin-api.md#sessions-and-ephemeral-stubs). It is a gRPC
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
  gets 400 `invalid_stub`. Its message gives each problem with its JSON
  Pointer, as `smock check` gives it:

  ```json
  {"error":"invalid_stub","message":"/response/json/mesage: is not a field of helloworld.HelloReply","warnings":[]}
  ```

- It answers the calls of its Session before the gRPC Stubs from the files.
  It counts for their [Near
  miss](grpc/unmatched-and-refused-calls.md#the-near-miss-trailer). HTTP
  requests never reach it, and gRPC calls never reach an Ephemeral HTTP
  Stub.
- It is not read again at a reload ([Reloads](#reloads)). While the Mock's
  set does not have its method as a unary method, it answers no call, and a
  call to the method gets the answer from its HEADERS ([Calls answered from
  their
  HEADERS](grpc/unmatched-and-refused-calls.md#calls-answered-from-their-headers)).
  Once a reload brings the method back, it answers again.
- Its reply was encoded with the set served when it was added. After a
  reload, smock encodes it on each call, and a reply that no longer fits the
  output type gets INTERNAL `template failed`, with a `templateError` in the
  call's Journal entry that says why ([The
  reply](grpc/messages.md#the-reply)). Its [error
  details](grpc/metadata-and-status.md#error-details) are encoded again the
  same way, and a detail whose type the new set lacks gets INTERNAL too.

## How smock serves a call

smock tells a gRPC call by its content type ([Ports and
detection](#ports-and-detection)), and refuses a call that gRPC's rules
refuse as soon as it shows ([Protocol checks and
limits](grpc/unmatched-and-refused-calls.md#protocol-checks-and-limits)).
When the call's HEADERS arrive, smock finds the call's Mock ([The call's
Mock](#the-calls-mock)) and the method that the call's `:path`, such as
`/helloworld.Greeter/SayHello`, names in the Mock's set. A call that cannot
reach a gRPC Stub, since there is no such Mock, set or unary method, is
answered at once, without waiting for its message ([Calls answered from
their
HEADERS](grpc/unmatched-and-refused-calls.md#calls-answered-from-their-headers)).

When the call's request has ended, smock serves it in five steps:

1. It finds the call's Mock and its method again, from the Definition
   files it serves then.
2. It takes the call's one message from its body, which must hold one.
3. It decodes the message into JSON with the method's input type ([The
   request message as JSON](grpc/messages.md#the-request-message-as-json)).
4. It matches the call against the Mock's gRPC Stubs on that method.
5. It encodes the reply with the method's output type, and sends it
   ([The reply](grpc/messages.md#the-reply)).

### Reloads

A changed set is reloaded with the Definition files, in one swap
([Building a set](#building-a-set)). A call is decoded, matched and
answered with the set served when its request ends. Steps 1 to 5 above
run with nothing in between, so a reload never decodes a call with one
version of a set and answers it with another.

A reload may come between a call's HEADERS and the end of its request. The
call is looked up again at the end, so it is served with the new Definition
files. The reload may have left the call without a gRPC Stub to reach, such
as a Mock whose set is gone or no longer has the method. The call then gets
the answer its HEADERS would get at that time ([Calls answered from their
HEADERS](grpc/unmatched-and-refused-calls.md#calls-answered-from-their-headers)).
A set that fails to load keeps the whole current definition set served.

A reload does not read [Ephemeral gRPC Stubs](#ephemeral-grpc-stubs)
again. One answers calls while the new set has its method as a unary
method, and its reply is encoded with the new output type.

### The call the Stubs see

A gRPC Stub sees a call as a request:

- The method is `POST`, and the path is the call's `:path`.
- The headers are the call's metadata, every field, `content-type` and
  `te` included, with `-bin` values unpadded
  ([Request metadata](grpc/metadata-and-status.md#request-metadata)).
- The body is the request message as compact JSON, with its fields in
  field-number order, each under its JSON name ([The request message as
  JSON](grpc/messages.md#the-request-message-as-json)). So the message
  `name: "Tom"` is `{"name":"Tom"}`.

A call is matched only against the gRPC Stubs on its method, never against
an HTTP Stub, even one whose conditions it meets. Its Session's [Ephemeral
gRPC Stubs](#ephemeral-grpc-stubs) come first, then those of the files, in
the order Stubs are tried. A call that none of them matches gets
UNIMPLEMENTED ([Unmatched
calls](grpc/unmatched-and-refused-calls.md#unmatched-calls)). A `json` body
condition matches the decoded message, as it matches a JSON body. By then,
smock has checked it against the input type and rewritten it into the same
form ([Conditions on the
message](grpc/messages.md#conditions-on-the-message)):

```yaml
request:
  path: /helloworld.Greeter/SayHello
  body: { json: { name: Tom } }
```

The Journal, the Near miss, `bodyText` and templates see the same JSON,
so `${body.name}` in a templated reply reads the message's `name`.

## What smock does not serve

smock serves gRPC unary calls. These are not served, each with what a
client or a Definition file gets instead:

| Not served | Instead |
|---|---|
| Streaming methods: client, server and bidirectional streaming. They are planned for R3, a later release. | A call to one gets UNIMPLEMENTED `streaming methods are not served yet` as soon as its HEADERS arrive ([Calls answered from their HEADERS](grpc/unmatched-and-refused-calls.md#calls-answered-from-their-headers)), and a Stub on one is a problem at its `path`. Reflection, which streams, answers one request per call ([One request per call](grpc/services-and-connections.md#one-request-per-call)), and health's `Watch` gets UNIMPLEMENTED. |
| gRPC-Web and the Connect protocol. | Their requests are HTTP requests, which the Mock's HTTP Stubs answer ([Requests that are not gRPC calls](#requests-that-are-not-grpc-calls)). |
| Compression. | A compressed message gets UNIMPLEMENTED, with `grpc-accept-encoding: identity`, and replies are never compressed ([Compression](grpc/unmatched-and-refused-calls.md#compression)). |
| Encodings other than protobuf, such as `application/grpc+json`. | UNIMPLEMENTED, as soon as the call's HEADERS arrive ([Other subtypes](#other-subtypes)). |
| Types of editions files, and MessageSets. Editions come in a later spec. | A Stub whose method reaches one is a problem at its `path`, and a call whose message is, or holds, a value of one gets INTERNAL ([What is not served](grpc/messages.md#what-is-not-served)). |
| Protobuf replies encoded beforehand, such as a body file of protobuf octets. | `body` and `bodyFile` are problems on a gRPC Stub: its reply is `json`, which smock encodes with the output type ([gRPC Stubs](#grpc-stubs)). |
| Stubs generated from a set, as `smock import-openapi` generates them from an OpenAPI document, and replies made up from a type. | Write gRPC Stubs by hand. A Stub without `json` answers an empty message ([The reply](grpc/messages.md#the-reply)). |
| Descriptor sets uploaded through the Admin API, and a list of a Mock's services in it. | A set is a file of the body-file subdirectory, read with the Definition files ([Building a set](#building-a-set)). Reflection lists a Mock's services ([Reflection](grpc/services-and-connections.md#reflection)). |
| A port of gRPC's own. | gRPC shares the plain and TLS ports with HTTP ([Ports and detection](#ports-and-detection)). |
| gRPC on the admin port. | The admin port serves the Admin API, over HTTP/1.1 only. |
| gRPC over HTTP/1.1. | A request with a gRPC content type over HTTP/1.1 is an HTTP request: gRPC needs HTTP/2's trailers ([Requests that are not gRPC calls](#requests-that-are-not-grpc-calls)). |
| Forwarding calls to the Mock's Upstream, the real service. | smock answers every call itself. A call that no Stub matches gets UNIMPLEMENTED ([Unmatched calls](grpc/unmatched-and-refused-calls.md#unmatched-calls)). |
| A metric label for the gRPC status. | The Journal records each call's gRPC status ([The Journal and the metrics](grpc/rendering-and-journal.md#the-journal-and-the-metrics)). |
