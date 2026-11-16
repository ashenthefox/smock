# gRPC in Definition files

This document of the [Definition-file reference](../definition-files.md)
describes, field by field, what gRPC adds to Definition files: the Mock's
`grpc` field and gRPC Stubs.

A Mock can stand in for a gRPC service. It names the service's Descriptor
set, the compiled form of its `.proto` files, with `grpc`. smock reads and
checks the set with the Definition files, and its [gRPC Stubs](#grpc-stubs)
answer unary calls, on the plain port over h2c and on the TLS port over h2.
`grpc` can also turn on gRPC's [health service](#the-health-service) and its
server [reflection](#reflection). The [gRPC guide](../grpc.md), with its
documents in `docs/grpc/`, shows a first call, says which requests are gRPC
calls, how to build a set and what smock checks in it, and how smock serves
a call and answers it: the JSON form of its message, its metadata,
deadlines, Faults, the Journal and the metrics, gRPC's protocol checks and
connections, and what smock does not serve.

## Contents

- [Descriptor sets](#descriptor-sets)
- [The health service](#the-health-service)
- [Reflection](#reflection)
- [gRPC Stubs](#grpc-stubs)
  - [A gRPC Stub's fields](#a-grpc-stubs-fields)
  - [Ephemeral gRPC Stubs](#ephemeral-grpc-stubs)
- [The status of a gRPC reply](#the-status-of-a-grpc-reply)
- [gRPC reply metadata](#grpc-reply-metadata)
- [gRPC error details](#grpc-error-details)
- [gRPC Stub conditions](#grpc-stub-conditions)

## Descriptor sets

A Descriptor set is a FileDescriptorSet in protobuf's binary encoding.
Build it with protoc or buf, with every file it imports, into the body-file
subdirectory:

```sh
protoc --include_imports -o defs/files/greeter.binpb helloworld.proto
buf build -o defs/files/greeter.binpb
```

Then name it from the Mock:

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb
```

- `grpc` is an object with three fields, `descriptorSet`, `health`
  ([The health service](#the-health-service)) and `reflection`
  ([Reflection](#reflection)). Each may be left out.
- `descriptorSet` is a path relative to the body-file subdirectory, with
  the rules of `bodyFile`: it stays inside the subdirectory, symlinks
  included, and none of its names starts with `.`.
- smock reads no `.proto` file and runs no protoc. Fields of the set that
  smock does not use, such as source info, options and Buf's image
  extensions, are skipped, so a set built with `buf build`'s defaults
  works as it is.
- The set is a body file. It is read and decoded when the Definition files
  load: by `smock check`, at startup and on each
  [reload](../definition-files.md#reloading), which swaps it in together
  with the files. It counts in the definition set digest, and a change to it
  reloads the definitions.
- A set that is missing, or that does not decode, is a problem at
  `descriptorSet`. The message says where the set breaks:

  ```text
  greeter.json: /mocks/0/grpc/descriptorSet: "greeter.binpb": not a Descriptor set, a FileDescriptorSet in protobuf's binary encoding: octet 8: a length of 80 runs past the end of the input, which has 23 octets left
  ```

- The set must be self-contained: it holds every file its files import.
  A file it lacks is a problem at `descriptorSet` too, as are a file
  that the set holds twice, a name defined twice, and a type that the
  set names but does not define. Each problem is reported on its own
  ([What smock checks](../grpc.md#what-smock-checks)):

  ```text
  greeter.json: /mocks/0/grpc/descriptorSet: "orders.binpb": orders.proto imports common.proto, which is not in the set; build the set with protoc --include_imports, or with buf build
  ```

  A reload with such a problem keeps serving the current definition set.
- Each Mock names its own set, so two Mocks can hold two versions of one
  service. A Mock without `grpc` holds no set. Each set is held decoded,
  so a large set costs memory in every replica
  ([Memory](../grpc.md#memory)).

## The health service

`grpc.health`, a boolean, `false` by default, turns on the Mock's
built-in health service, gRPC's `grpc.health.v1.Health`, which clients
and proxies that health-check a gRPC server call:

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb
      health: true
```

- `Check` says SERVING for `""` and for each service of the Mock's set,
  and gives NOT_FOUND for other names. `List` gives the status of `""`
  and of each service. `Watch`, which streams, gets UNIMPLEMENTED.
- Once SIGTERM starts the drain, every answer says NOT_SERVING.
- The set need not hold `health.proto`, and `descriptorSet` may be left
  out: `grpc: { health: true }` alone serves health for `""`.
- A gRPC Stub on a health method, such as
  `/grpc.health.v1.Health/Check`, answers in the service's place, an
  Ephemeral one of the call's Session included. Such a Stub needs
  `health.proto` in the Mock's set, as any gRPC Stub needs its method.
- Health answers are not recorded in the Journal. They count in the
  request metrics under their Mock with `stub=""`.
- A Mock that does not turn health on has no health service: a call to
  it is a call to a method the set lacks.

The gRPC guide's [Health](../grpc/services-and-connections.md#health) has
the details, a Scenario that makes the service NOT_SERVING, and grpcurl's
commands.

## Reflection

`grpc.reflection`, a boolean, `false` by default, turns on the Mock's
built-in server reflection, gRPC's `grpc.reflection.v1` and its older
name `grpc.reflection.v1alpha`. Tools such as grpcurl and Postman then
list and describe the Mock's services without a local copy of its set:

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb
      reflection: true
      health: true
```

- It answers from the Mock's set: the set's services, and each file with
  the files it imports, as the set holds them, custom options included,
  without source info. A name the set lacks gets reflection's error
  NOT_FOUND.
- With `health` on, it lists `grpc.health.v1.Health` too, and describes
  it from the descriptor smock embeds, unless the set defines the package
  `grpc.health.v1` itself.
- It answers one request per call, and a client opens a new call for its
  next request, as grpcurl does.
- Reflection answers are not recorded in the Journal. They count in the
  request metrics under their Mock with `stub=""`.
- With reflection on, the Mock keeps each file of its set as encoded,
  without source info, beside the set's model. A Mock without it keeps
  nothing more ([Memory](../grpc.md#memory)).
- A Mock that does not turn reflection on has no reflection service: a
  call to it is a call to a method the set lacks.

The gRPC guide's
[Reflection](../grpc/services-and-connections.md#reflection) has the details
and grpcurl's commands.

## gRPC Stubs

A Stub whose exact `path` names a method of its Mock's set is a gRPC Stub.
The path is `/`, the service's full name, `/` and the method's name, as
gRPC calls name a method:

```yaml
stubs:
  - id: hello
    mock: greeter
    request: { path: /helloworld.Greeter/SayHello }
    response: { json: { message: Hello Tom } }
```

- Every other Stub is an HTTP Stub: a Stub of a Mock without a set, a Stub
  without an exact path or whose path names no method of the set, and
  every [CRUD Stub](crud-stubs.md#crud-stubs), which has no request path.
- The method must be unary. A Stub on a client-, server- or
  bidi-streaming method is a problem at its `path`. Streaming methods are
  planned for R3, a later release.
- A gRPC Stub's reply is `json`, the reply message, `headers`, its
  initial metadata, and `grpc`, the gRPC status, message, trailing
  metadata and error details it ends with
  ([The status of a gRPC reply](#the-status-of-a-grpc-reply),
  [gRPC reply metadata](#grpc-reply-metadata),
  [gRPC error details](#grpc-error-details)). It has no
  `status`: every gRPC reply has the HTTP status 200. `status` is
  required on HTTP Stubs only. smock adds no `Content-Type` for a gRPC
  Stub's `json`.
- `json` is read as ProtoJSON, so a reply pasted from grpcurl or another
  tool works: a field by its name in the `.proto` file or by its JSON
  name, enums by name or by number, 64-bit integers as numbers or
  strings, and bytes in base64. `null` leaves a field unset. No `json`
  answers an empty message, every field at its default. The
  [gRPC guide](../grpc/messages.md#the-reply) lists every form.
- When the files load, each `json` reply without `template` is read with
  the method's output type and encoded, once. A reply that is not a
  message of the type is a problem at the JSON Pointer of the value at
  fault: an unknown key, a value of the wrong type or out of its type's
  range, `null` in a repeated field, two members of one oneof, and both
  spellings of one field in one object. The first such value of each
  reply is reported:

  ```text
  greeter.yaml: /stubs/0/response/json/mesage: is not a field of helloworld.HelloReply
  ```

  A reply with `template: true` is read and encoded on each call, once it
  is rendered. One that is not a message of the type gets INTERNAL, and
  the call's Journal entry says why in `templateError`.
- HTTP requests never match a gRPC Stub, and a gRPC Stub is never their
  [Near miss](matching.md#when-no-stub-matches). An HTTP request is every
  request but a gRPC call, an HTTP/2 request whose `content-type` is
  `application/grpc`, alone or followed by `+` or `;` ([Ports and
  detection](../grpc.md#ports-and-detection)). So `POST
  /helloworld.Greeter/SayHello` over HTTP/1.1, or over HTTP/2 with
  `content-type: application/grpc-web`, goes to the Mock's HTTP Stubs, then
  gets its `noMatch` answer.
- A gRPC Stub and an HTTP Stub never
  [shadow](../definition-files.md#a-stub-that-can-never-match) each other.
- gRPC calls match gRPC Stubs only. A call sees the Stub as a `POST` to the
  method's path, with its metadata as headers and its message as JSON, so
  `headers` and `json` body conditions match it. A `json` condition is
  checked against the method's input type when the files load ([gRPC Stub
  conditions](#grpc-stub-conditions)). The [gRPC
  guide](../grpc.md#how-smock-serves-a-call) says how a call reaches a Stub,
  how smock prints the message as JSON ([The request message as
  JSON](../grpc/messages.md#the-request-message-as-json)), and how smock
  answers it.
- A call that no gRPC Stub on its method matches gets UNIMPLEMENTED, with
  the Mock's gRPC Stub that came closest in a `smock-near-miss` trailer,
  never the Mock's `noMatch` answer ([Unmatched
  calls](../grpc/unmatched-and-refused-calls.md#unmatched-calls)). So does a
  call to a method that the set lacks or that streams, and a call to a Mock
  without a set, as soon as its HEADERS arrive ([Calls answered from their
  HEADERS](../grpc/unmatched-and-refused-calls.md#calls-answered-from-their-headers)).
- A Stub of a Mock with a set whose exact `path` has the form of a gRPC
  method, `/package.Service/Method`, but names no method of the set, is an
  HTTP Stub that gRPC calls never reach. `smock check` warns about it ([A
  path that looks like a gRPC
  method](../definition-files.md#a-path-that-looks-like-a-grpc-method)).
- A gRPC Stub can be an Ephemeral Stub
  ([Ephemeral gRPC Stubs](#ephemeral-grpc-stubs)).
- A gRPC Stub requires and moves Scenarios, and reads and writes Variables
  and Data buckets, as an HTTP Stub does, and a Mock's HTTP requests and
  gRPC calls share them ([State over
  gRPC](../grpc/state-and-faults.md#state-over-grpc)). One that cannot serve
  its content, since a template fails, a data write cannot be applied or its
  writes would pass the state bound, gets smock's own failure in gRPC's
  form, never a 500 or a 507 ([smock's own
  failures](../grpc/unmatched-and-refused-calls.md#smocks-own-failures)).
- `smock render` and the Admin render operation render a gRPC Stub as a
  call, for a sample whose body is the request message as JSON
  ([Rendering a template](templates.md#rendering-a-template)).

### A gRPC Stub's fields

A gRPC Stub is an ordinary Stub, and most fields work as on HTTP. Those
that make no sense for gRPC are problems when the files load, at their
JSON Pointer, and so is a `method` other than `POST`:

| Field | On a gRPC Stub |
|---|---|
| `id`, `mock`, `priority` | As on every Stub. |
| `scenario`, `variables`, `dataWrites` | As on HTTP. |
| `fault.seed` | As on HTTP. |
| `fault.delay` | As on HTTP: it waits before the reply's HEADERS, and the call's deadline can cut it short ([Deadlines](../grpc/state-and-faults.md#deadlines)). |
| `fault.connection` | As on HTTP/2: `reset` and `partial` give the client INTERNAL, and `close` gives every call on the connection UNAVAILABLE ([Faults](../grpc/state-and-faults.md#faults)). |
| `request.method` | May be left out. When given, it must be `POST`, since every gRPC call is a POST. |
| `request.path` | The method's path, exact: `/`, the service's full name, `/` and the method's name. |
| `request.headers` | Conditions on the call's metadata. |
| `request.body` with `json` | A condition on the request message, checked against the input type ([gRPC Stub conditions](#grpc-stub-conditions)). |
| `request.query` | Makes no sense: a gRPC call's path has no query. |
| `request.cookies` | Makes no sense: a gRPC call sends metadata, which `headers` conditions match, not cookies. |
| `request.body` as text, or with `pattern`, `form` or `xml` | Makes no sense: the message is matched as JSON, with a `json` condition. |
| `response`, or `responses` with `weight` | As on HTTP. |
| `json` in a reply | The reply message. |
| `headers` in a reply | The initial metadata, under gRPC's rules ([gRPC reply metadata](#grpc-reply-metadata)). |
| `grpc` in a reply | The gRPC status, message, trailing metadata and error details ([The status of a gRPC reply](#the-status-of-a-grpc-reply), [gRPC reply metadata](#grpc-reply-metadata), [gRPC error details](#grpc-error-details)). |
| `template` in a reply | As on HTTP. |
| `status` in a reply | Makes no sense: every gRPC reply has the HTTP status 200, and `grpc.status` gives its gRPC status. |
| `body` or `bodyFile` in a reply | Makes no sense: the reply message is `json`, which smock encodes with the method's output type. |
| `events` in a reply | Makes no sense: a unary call gets one reply message, not an event stream. |
| `llm` in a reply | Makes no sense: an LLM reply is written in an LLM API's HTTP wire form. |
| `crud` | Never: a CRUD Stub is an HTTP Stub. |

Each problem says why:

```text
greeter.yaml: /stubs/0/request/query: makes no sense on a gRPC Stub: a gRPC call's path has no query
greeter.yaml: /stubs/0/request/method: must be POST on a gRPC Stub, or left out: a gRPC call is always a POST
```

Types of proto3 and proto2 files are served, proto2's required fields,
closed enums, packing, groups and extensions included ([proto2
types](../grpc/messages.md#proto2-types)). A condition or a reply gives an
extension under its full name in brackets, such as `"[shop.priority]": 3`.
Two kinds of type are never served by gRPC Stubs in this release, each a
problem at the Stub's `path`, per method, so a set may hold them for methods
that no Stub uses:

- A method whose input or output type comes from an editions file, or
  reaches a type, an enum included, of one, or one that an extension
  declared in an editions file extends. Editions come in a later spec.
- A method whose input or output type is, or reaches, a MessageSet, a
  message with the option `message_set_wire_format`, whose extensions use
  another wire form.

Every other type is served on both sides, with fields of every type:
scalars, enums, nested messages, `optional` fields, repeated fields, maps,
oneofs, and every well-known type, in its ProtoJSON form
([Well-known types](../grpc/messages.md#well-known-types)).

### Ephemeral gRPC Stubs

An [Ephemeral Stub](../admin-api.md#sessions-and-ephemeral-stubs) is a gRPC
Stub when its exact `path` names a method of its Mock's set, as a Stub in a
Definition file is. smock checks it against the set and normalises its
`json` condition, as it does when the files load, or refuses it with 400
`invalid_stub`, whose message gives each problem with its JSON Pointer:

```text
/response/json/mesage: is not a field of helloworld.HelloReply
```

It answers the calls of the Session that added it, before the Mock's gRPC
Stubs from the files, and counts for their [Near
miss](../grpc/unmatched-and-refused-calls.md#the-near-miss-trailer). HTTP
requests never reach it, and gRPC calls never reach an Ephemeral HTTP Stub.

An Ephemeral Stub is not read again at a
[reload](../definition-files.md#reloading):

- While the Mock's new set does not have its method as a unary method, or
  the Mock has no set, it answers no call, and a call to the method gets the
  answer its HEADERS get ([Calls answered from their
  HEADERS](../grpc/unmatched-and-refused-calls.md#calls-answered-from-their-headers)).
  It still belongs to its Session, and answers again once a reload brings
  the method back.
- Its reply was encoded with the set served when it was added. After a
  reload, smock encodes it again on each call. A reply that no longer
  fits the method's output type gets INTERNAL `template failed`, and the
  call's Journal entry says why in `templateError`.

## The status of a gRPC reply

A gRPC Stub's reply, or each of its `responses`, may give `grpc`: the gRPC
status the reply ends with, and a status message. This Stub fails about
one call in ten with UNAVAILABLE:

```yaml
stubs:
  - id: hello-flaky
    mock: greeter
    request: { path: /helloworld.Greeter/SayHello }
    responses:
      - { weight: 9, json: { message: Hello } }
      - { weight: 1, grpc: { status: UNAVAILABLE, message: "try again ☺" } }
```

- `grpc` is an object with four fields, `status`, `message`, `trailers`
  and `details`, all optional. A reply without it ends with `OK`, no
  message, no trailing metadata and no details. `trailers` is the reply's
  trailing metadata ([gRPC reply metadata](#grpc-reply-metadata)), and
  `details` its error details ([gRPC error details](#grpc-error-details)).
- `status` is a name of one of gRPC's seventeen status codes, from `OK`,
  0, to `UNAUTHENTICATED`, 16, as gRPC writes them: `OK`, `CANCELLED`,
  `UNKNOWN`, `INVALID_ARGUMENT`, `DEADLINE_EXCEEDED`, `NOT_FOUND`,
  `ALREADY_EXISTS`, `PERMISSION_DENIED`, `RESOURCE_EXHAUSTED`,
  `FAILED_PRECONDITION`, `ABORTED`, `OUT_OF_RANGE`, `UNIMPLEMENTED`,
  `INTERNAL`, `UNAVAILABLE`, `DATA_LOSS` and `UNAUTHENTICATED`. Another
  name, a lower-case one included, is a problem at `status`. It is `OK`
  when left out, and never a template.
- `message` is any Unicode text, which smock sends in `grpc-message`,
  percent-encoded, and which a gRPC client decodes back. With
  `template: true`, it is a text template, rendered after the reply
  message. The control characters it renders, such as a line break, are
  kept, not turned into spaces as in a header value.
- A status other than `OK` is an error, and a gRPC call gets a reply
  message or an error, never both. So an error that also gives `json` is a
  problem at its `json`:

  ```text
  greeter.yaml: /stubs/0/response/json: is not allowed with the gRPC status NOT_FOUND: a gRPC call gets a reply message or an error, never both
  ```

- An error without initial metadata goes out as Trailers-Only, one
  HEADERS block that ends the stream, as gRPC servers send it. An error
  with initial metadata goes out as HEADERS, then the trailers. A reply
  with `OK` goes out as HEADERS, the reply message in one DATA frame, then
  the trailers, which carry the status message, if it has one, and the
  trailing metadata.
- An HTTP Stub's response cannot give `grpc`: it is a problem at `grpc`,
  which says that the Stub's exact path names no method of its Mock's set.
- The Journal records the status a call got as its `grpcStatus`, while its
  HTTP status stays 200.

The [gRPC guide](../grpc/metadata-and-status.md#status-and-message) shows
what goes out on the wire and how smock percent-encodes a message.

## gRPC reply metadata

A gRPC Stub's `headers` are its reply's initial metadata, sent in its
HEADERS, and its `grpc.trailers` its trailing metadata, sent in its
trailers after the status and the message:

```yaml
stubs:
  - id: hello-missing
    mock: greeter
    request: { path: /helloworld.Greeter/SayHello }
    response:
      headers: { x-served-by: smock }
      grpc:
        status: NOT_FOUND
        trailers: { x-trace: abc, x-tag: [a, b], trace-bin: "AAE=" }
```

- Both map each name to a string or to a non-empty array of strings, as
  an HTTP Stub's `headers` do. An array sends one field per value, in
  order.
- A name, once in lower case, holds only `0-9`, `a-z`, `_`, `-` and `.`,
  as gRPC's grammar says. smock sends names in lower case. Two names that
  differ only in case are a problem.
- These names are problems in both: `content-type`, `te` and every name
  that starts with `grpc-`, which gRPC keeps for itself; `keep-alive`,
  `proxy-connection` and `upgrade`, which HTTP/2 forbids; and
  `content-length`, `transfer-encoding`, `connection` and `smock-mock`,
  which smock sets. So a gRPC Stub cannot give a Content-Type: smock
  always sends `content-type: application/grpc`.
- A value holds only characters from 0x20 to 0x7E, space and printable
  ASCII. A tab or any other character is a problem.
- A name that ends with `-bin` holds binary metadata. Its value is
  written in standard base64, padded or not, and smock sends it without
  its padding: `"AAE="` goes out as `AAE`. A value that is not base64 is
  a problem.
- Each problem is reported at its JSON Pointer:

  ```text
  greeter.yaml: /stubs/0/response/headers/grpc-foo: is reserved by gRPC, which keeps content-type, te and every name starting with grpc- for itself
  greeter.yaml: /stubs/0/response/grpc/trailers/trace-bin: must be standard base64, padded or not: a field whose name ends with -bin is binary
  ```

- With `template: true`, the values of both are text templates, rendered
  as header values are, with the control characters they render turned
  into spaces. Trailer values render after the message. smock checks
  the rendered values as it checks values as written, and drops the
  padding of a rendered `-bin` value. A rendered value that breaks the
  rules gets INTERNAL `template failed`, and the call's Journal entry says
  why in `templateError`, at the value's JSON Pointer.
- An error with initial metadata goes out as HEADERS with it, then
  trailers with the status, the message and the trailing metadata. An
  error without it goes out as Trailers-Only, with the trailing metadata
  in its one block. `smock-mock`, which smock adds when the Default Mock
  answers, does not count as initial metadata.
- Each block a reply goes out in, its HEADERS and its trailers, or its
  Trailers-Only block, may take at most `--header-size-limit`, counted as
  RFC 7541 counts a header list: each field's name and value plus 32 octets,
  smock's own fields included. A static reply with a larger block is a
  problem at the reply, and `smock check` warns about one with a block over
  8 KiB. A templated reply with a larger block once rendered, and any reply
  with a block over the client's own limit, gets INTERNAL `reply metadata
  too large`, and the call's Journal entry says why in `templateError`
  ([Metadata size](../grpc/metadata-and-status.md#metadata-size)).

The [gRPC guide](../grpc/metadata-and-status.md#reply-metadata) shows the
reply on the wire.

## gRPC error details

An error's reply may carry error details, such as `google.rpc.ErrorInfo`,
`RetryInfo` or `BadRequest` from googleapis' `error_details.proto`, for
clients that use gRPC's richer error model. A gRPC Stub gives them in
`grpc.details`:

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
        details:
          - "@type": type.googleapis.com/google.rpc.ErrorInfo
            reason: USER_UNKNOWN
            domain: greeter.svc
```

- `details` is an array. Each element is an Any in ProtoJSON: an object
  whose `@type` is a type URL, such as
  `type.googleapis.com/google.rpc.ErrorInfo`, beside the fields of the
  message it holds, or its form as `value` when its type is a well-known
  type with one. An object without `@type` is a problem.
- The type is the type of the Mock's set that the URL names after its last
  `/`. A type the set lacks is a problem at `@type`, so the set must hold
  the file that defines it, such as `google/rpc/error_details.proto`. Any
  message type of the set can be a detail.
- A detail type goes through the checks of a method's types: a type of an
  editions file, or one that reaches such a type, and a MessageSet are
  problems at `@type`.
- Each detail is read as a reply is: names in either spelling, enums by
  name or number, and a Duration such as `"1.5s"`. A detail that does not
  fit its type is a problem at the value at fault. smock reports the
  first problem of a reply's details.
- smock builds `google.rpc.Status` from the reply's status, its message
  and its details, each packed in an Any, and sends it in
  `grpc-status-details-bin`, in base64 without padding. So the status a
  client decodes never disagrees with `grpc-status`, and the set need not
  hold `google/rpc/status.proto`.
- Only an error gives details: details with `OK`, given or left out, are
  a problem at `details`, since gRPC sends them only with an error. An
  empty array sends no details.
- Details as written are encoded when the files load, and count toward
  the size of the block they go out in
  ([gRPC reply metadata](#grpc-reply-metadata)). With `template: true`,
  each detail is a structured template, rendered after the trailing
  metadata, then encoded. A `@type` written without `${` must still name a
  type of the set when the files load. A detail that fails to render, or
  does not fit its type once rendered, gets INTERNAL `template failed`,
  and the call's Journal entry says why in `templateError`, at the
  detail's JSON Pointer.
- The Journal records the call's status, not its details.

```text
greeter.yaml: /stubs/0/response/grpc/details/0/@type: names the type google.rpc.ErrorInfo, which the Descriptor set does not define
greeter.yaml: /stubs/1/response/grpc/details: is not allowed with the gRPC status OK: gRPC sends error details only with an error
```

The [gRPC guide](../grpc/metadata-and-status.md#error-details) shows how to
build a set with googleapis' types, and what a client decodes.

## gRPC Stub conditions

A gRPC Stub's `json` body condition is checked against the method's input
type when the files load, and rewritten into the form in which smock prints
a call's message, its decoded form ([The request message as
JSON](../grpc/messages.md#the-request-message-as-json)). So matching a call
costs nothing more than matching a JSON body:

```yaml
request:
  path: /users.Users/Find
  body: { json: { user_id: 42, status: 1 } }   # matched as { userId: 42, status: ACTIVE }
```

- Each key must name a field of the type at its place, by its name in the
  `.proto` file or its JSON name, and becomes its JSON name. A key that
  names no field is a problem, as is a field given by both its names in
  one object.
- A proto2 extension is given by its full name in brackets, such as
  `"[shop.priority]": 3`, which stays as written. A key in brackets that
  names no extension of the set, or one that extends another type, is a
  problem ([proto2 types](../grpc/messages.md#proto2-types)).
- Each literal must be a value of its field's type as smock prints it. A
  value that can never match is a problem: a number out of its type's
  range or with a fraction for an integer field, an enum name the enum
  lacks, a string for a number or a number for a string, an array for a
  field that is not repeated, and `null`, which a printed message never
  holds.
- An enum number or alias becomes the enum's first name for that number,
  such as `ACTIVE` for `1` or for its alias `ENABLED`. A number that no
  value has stays a number, as smock prints it for an open enum.
- A `float` literal, and a `google.protobuf.FloatValue`'s, is rounded to
  the nearest 32-bit float and kept in the form smock prints it, so
  `{ratio: 0.1}` matches a float of 0.1, and `16777217` becomes
  `16777216`, which is what a call of 16777217 prints. A `float` literal
  outside the float range is a problem.
- A value that ProtoJSON reads but smock never prints is a problem that
  names the printed form: a 64-bit integer written as a string, such as
  `"42"`, which suggests `42`; any number written as a string; bytes in
  URL-safe base64, without their padding, or with bits after their last
  octet; an integer map key that is not in decimal, such as `"007"`,
  which suggests `"7"`; a Duration with other fractional digits, such as
  `"1.5s"`, which suggests `"1.500s"`; and a Timestamp with an offset other
  than `Z`, such as `+09:00`, which suggests its time in UTC
  ([Well-known types](../grpc/messages.md#well-known-types)).
- A NullValue's name or number becomes `null`, and a number that a
  `google.protobuf.Value` holds is rewritten into the form a `double`
  prints.
- Map keys are data: they are never rewritten, `$$` for a key that starts
  with `$` included. So are a `google.protobuf.Struct`'s keys.
- An Any's `"@type"` must name a type of the Mock's set, and its other
  members are checked against that type
  ([Any](../grpc/messages.md#any)).
- Patterns and operators are allowed in any place. An operator's
  condition is checked as the value in its place, and the condition of
  `$includes` or `$last` on a repeated field as one of its elements.

Each problem is reported at the JSON Pointer of the value at fault:

```text
users.yaml: /stubs/0/request/body/json/usr_id: is not a field of users.Query
users.yaml: /stubs/1/request/body/json/user_id: must be written 42, as smock prints it: the field user_id of users.Query has the type int64
```

Templates, `find`, `$each`, Variables and data writes read the call's
message as smock prints it, so they see JSON names only: `${body.userId}`,
never `${body.user_id}`. Two gRPC Stubs' conditions are compared once
rewritten for the [warning about a Stub that can never
match](../definition-files.md#a-stub-that-can-never-match). The [gRPC
guide](../grpc/messages.md#conditions-on-the-message) has more examples.

A gRPC Stub's `headers` conditions read the call's metadata, every field.
An exact condition on a field whose name ends with `-bin` loses its
base64 padding when the files load, in each comma-separated element and
inside `$not`, as a call's `-bin` values lose theirs when it arrives. So
`trace-bin: "AAE="` meets calls that send `AAE=` or `AAE`. A pattern sees
the unpadded value. An HTTP Stub's conditions stay as written
([Request metadata](../grpc/metadata-and-status.md#request-metadata)).
