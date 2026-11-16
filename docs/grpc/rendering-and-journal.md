# Rendering, the Journal and the metrics

This document says how `smock render` and the Admin render operation show
what a gRPC Stub answers, without a client, and what the Journal, the
request metrics and the `mockoon` log format record of each call. It is
part of the [gRPC guide](../grpc.md), and assumes its [gRPC
Stubs](../grpc.md#grpc-stubs) and the JSON form of a message ([Messages as
JSON](messages.md)). Its `smock render` command reads the `defs` directory
of the guide's [quick start](../grpc.md#quick-start).

## Contents

- [Rendering a gRPC Stub](#rendering-a-grpc-stub)
  - [The sample's message](#the-samples-message)
  - [What the rendering shows](#what-the-rendering-shows)
- [The Journal and the metrics](#the-journal-and-the-metrics)

## Rendering a gRPC Stub

`smock render` and the Admin render operation ([Rendering a
template](../definition-files/templates.md#rendering-a-template)) show what
a Stub answers, without a client. A gRPC Stub renders as a call to its
method. The Stub decides this, not the sample: the sample's `method` and its
`Content-Type` are checked only as conditions, as a call's are, and the
rendering lists them among the conditions the sample fails. The rendering of
a gRPC Stub encodes and decodes the sample's message, and encodes the reply,
as smock does for a call, so it shows what a call would get. An HTTP Stub
renders as a request, whatever the sample's `Content-Type`.

For the `hello-unknown` Stub of [Error
details](metadata-and-status.md#error-details), with `sample.json` holding

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
checks it against the input type of the Stub's method, and normalises it as
it normalises a Stub's conditions ([Conditions on the
message](messages.md#conditions-on-the-message)). So a field may be named by
its proto name, and an enum by its number. A value that smock never prints
in that form is refused, such as a Duration of `"1.5s"` ([Printed
forms](messages.md#printed-forms)). smock then reads the message as it reads
a call's ([The request message as
JSON](messages.md#the-request-message-as-json)), so a field without presence
that the sample leaves out is there at its default, as in a call. An empty
body is the empty message.

A body that is not such a message is refused with every problem, each at its
JSON Pointer in the message. So is a message whose JSON takes more than
`--body-limit` once read, as a call's would be ([The body
limit](unmatched-and-refused-calls.md#the-body-limit)). The Admin render
operation uses the limit of the smock that serves it. `smock render`, which
takes no `--body-limit`, uses the default, 10 MiB. `smock render` exits with
status 1, and the Admin render operation answers 400 `invalid_request`. For
the `hello` Stub of [gRPC Stubs](../grpc.md#grpc-stubs) and the body
`{"nmae": "Tom"}`:

```text
smock render: the sample request's body must be a helloworld.HelloRequest as JSON, the message that the method of the gRPC Stub "hello" takes: /nmae is not a field of helloworld.HelloRequest
```

A sample whose message would be refused for its values is refused the same
way ([The values a message may
print](unmatched-and-refused-calls.md#the-values-a-message-may-print)). The
sample is JSON, so the problem gives the octets it encodes to, which the
bound follows. A field written at its default, such as `"f1": 0`, encodes to
no octet. For a Stub `load` and a sample of 619 empty rows of a message with
60 fields:

```text
smock render: the sample request's body must be a wide.Table as JSON, the message that the method of the gRPC Stub "load" takes: encodes to 1238 octets and holds more than 37720 values as JSON once decoded, the most for a call's message of that size
```

The sample's binary metadata, a header field whose name ends with `-bin`,
loses its padding, as a call's does ([Request
metadata](metadata-and-status.md#request-metadata)).

### What the rendering shows

The rendering shows the reply as JSON, never its protobuf bytes:

- `response.body` is the reply message as JSON, as written or rendered.
  It is empty for an error, which has no message.
- `response.headers` is the initial metadata.
- `response.grpc` is how the reply ends. `status` is the gRPC status's
  name. `message` is the message as written or rendered, before smock
  percent-encodes it, or null. `trailers` is the trailing metadata, and
  `details` the error details as JSON, each with its `@type`.
- `response.status` stays 200, the HTTP status of every gRPC reply.

smock encodes a templated reply, once rendered, with the output type, as it
does for a call. A reply that does not fit shows the
[Trailers-Only](metadata-and-status.md#trailers-only) INTERNAL a call gets,
with the message `template failed`, no metadata, and the reason
in `templateError`. So does a rendered detail that does not fit its type,
and a template that fails. A write that cannot be applied shows INTERNAL
`data write failed` ([smock's own
failures](unmatched-and-refused-calls.md#smocks-own-failures)).

The rendering leaves out what a call adds on the wire, such as
`content-type` and the Default Mock's `smock-mock` field. It does not check
the size of the reply's metadata ([Metadata
size](metadata-and-status.md#metadata-size)), and it decides no deadline and
no Fault.

## The Journal and the metrics

The Journal records each call that reaches the Stubs, matched or not, and
each call answered from its HEADERS, with an empty body ([Calls answered
from their
HEADERS](unmatched-and-refused-calls.md#calls-answered-from-their-headers)).
Its entry shows the method `POST`, the call's `:path` as its target, the
version `HTTP/2`, the metadata as headers, `-bin` values unpadded ([Request
metadata](metadata-and-status.md#request-metadata)), and the request message
as JSON as its body. The body's `size` counts the octets the call's DATA
frames brought, as received, and `truncated` says whether the JSON was cut
at `--journal-body-limit`.

The entry's `grpcStatus` is the name of the gRPC status the call got. That
is the status of the Stub's reply, `OK` unless its `grpc` names another, or
the status smock answered with instead. For example, it is `UNIMPLEMENTED`
for an unmatched call, and `INTERNAL` or `RESOURCE_EXHAUSTED` for [smock's
own failures](unmatched-and-refused-calls.md#smocks-own-failures). Its
`status` stays the HTTP status, 200 for every answer smock sends a call, as
gRPC sends them: a client learns of an error from `grpc-status`, not from
`:status`. The entry of an HTTP request has no `grpcStatus`, nor has the
entry of a call that a `reset` or `close` Fault ended
([Faults](state-and-faults.md#faults)).

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
([Request metrics](../admin-api.md#request-metrics)). No metric and no label
gives the gRPC status: only the Journal records it. Each call counts and is
recorded as follows:

| The call | The request metrics | The Journal |
|---|---|---|
| A Stub answered it, with its reply, its error, [smock's own failure](unmatched-and-refused-calls.md#smocks-own-failures) or DEADLINE_EXCEEDED ([Deadlines](state-and-faults.md#deadlines)) | Under its Mock and Stub, `stub="ephemeral"` for an Ephemeral Stub, as an HTTP request | An entry, with the Stub |
| No Stub matched it ([Unmatched calls](unmatched-and-refused-calls.md#unmatched-calls)), or it was answered from its HEADERS ([Calls answered from their HEADERS](unmatched-and-refused-calls.md#calls-answered-from-their-headers)) | Under its Mock with `stub=""`, `mock=""` when its Host reaches no Mock, and as an unmatched request | An entry, with its Near miss when it has one, in the unmatched list too |
| A built-in service of its Mock answered it ([Reflection](services-and-connections.md#reflection), [Health](services-and-connections.md#health)) | Under its Mock with `stub=""`, not as an unmatched request | None |
| The [protocol checks](unmatched-and-refused-calls.md#protocol-checks-and-limits) refused it | As a rejected request, with `mock=""` and `stub=""`, not as an unmatched request | None |

So, for a Mock, `stub=""` counts its unmatched calls and the answers of
its built-in services, and `smock_unmatched_requests_total` tells them
apart. Health probes every few seconds and reflection's round trips would
otherwise fill the Journal and evict the calls that tests verify.

In the `mockoon` log format, a call that a Stub answered, or that no Stub
matched, gets a `Transaction recorded` line, with `POST`, the method's
path and the HTTP status 200, as an HTTP/2 request does
([Logs](../http2.md#logs)). An `Error while serving the content: …` line
comes before it when the Stub's template or data write failed. The
`Transaction recorded` line carries no gRPC status. A call that a
built-in service answered, or that the protocol checks refused, gets no
line.
