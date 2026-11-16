# LLM responses

This part of the [Definition-file reference](../definition-files.md)
describes LLM responses and the fields of `llm`, with the form of OpenAI
Chat Completions (`openai-chat`), which its examples use. Three documents
build on it, and the [Contents](#contents) lists them: [Tool calls and
agent loops](llm-tool-calls.md), [The OpenAI Responses and Anthropic
Messages APIs](llm-apis.md) and [LLM API errors](llm-errors.md).

A response can give `llm` in place of a body, to stand in for an LLM API
in tests of code that calls one, such as an agent or a chat feature. It
declares the reply by what it says, and smock writes it in that API's wire
form, so an official SDK reads it as it reads the vendor's reply. This Stub
answers OpenAI Chat Completions requests:

```yaml
mocks:
  - name: openai
stubs:
  - id: hello
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
```

An SDK reaches it through its base URL, such as
`OpenAI(base_url="http://localhost:8080/v1", api_key="test")` in
openai-python, which sends `POST /v1/chat/completions`. The request decides
the form of the reply: with `stream: true` it gets a [stream](#streams), and
otherwise one JSON body. A request for `gpt-6-astra` without `stream` gets
one `chat.completion` body, such as this one, which [`smock
render`](templates.md#rendering-a-template) shows with `--seed 7` and
`--time 2026-10-23T00:00:00Z`:

```json
{"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"message":{"role":"assistant","content":"Hello! How can I assist you today?","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
```

The fields of `llm`:

| Field | Value | When left out |
|---|---|---|
| `api` | `openai-chat`, OpenAI Chat Completions; `openai-responses`, [OpenAI Responses](llm-apis.md#openai-responses); or `anthropic-messages`, [Anthropic Messages](llm-apis.md#anthropic-messages) | required |
| `text` | the text of the reply | empty |
| `chunks` | the text as a list of at least one piece, in place of `text` | — |
| `chunkSize` | code points per piece of a stream, an integer from 1 to 1,000,000 | 4 |
| `toolCalls` | a list of [tool calls](llm-tool-calls.md#tool-calls), each `{name, arguments, id}` | none |
| `id` | the reply's id, sent as written | generated |
| `model` | the reply's model | the request's |
| `usage` | `{input, output}`, token counts, integers from 0 to 2^53-1 | both 0 |
| `stopReason` | a stop reason of the API, such as `length` | derived |
| `timing` | `{first, interval}`, the [waits of a stream](#timing), each a distribution of the [delay](faults.md#delays) | no waits |
| `error` | `{after, type, message}`, or `{after, code, message}` for `openai-responses`: a [mid-stream error](llm-errors.md#mid-stream-errors) | none |

- `api` names the API whose wire form the reply takes. It is required, and
  smock never infers it from the request's path, so a proxy or a base path
  of its own does not change the reply. The preset neither sets nor checks
  `request.path`: the Stub's conditions choose it, as for any Stub.
- An `openai-chat` reply is the assistant's message, with `text` as its
  `content`, or `""` when the text is empty, then its [tool
  calls](llm-tool-calls.md#tool-calls), and the [stop
  reason](#usage-and-stop-reasons) as its `finish_reason`. With tool calls
  and empty text, `content` is `null`. Its fields and their order follow the
  example of OpenAI's API reference, and so do its fixed values, such as
  `refusal: null` and `service_tier: "default"`. `usage` has the example's
  members, with the [declared counts](#usage-and-stop-reasons) and every
  other count 0. There is no `system_fingerprint`.
- An `openai-responses` reply is a Response object, with `text` in its
  message item and each tool call in a `function_call` item.
  [OpenAI Responses](llm-apis.md#openai-responses) says more.
- An `anthropic-messages` reply is a `message` object, with `text` in its
  text block and each tool call in a `tool_use` block.
  [Anthropic Messages](llm-apis.md#anthropic-messages) says more.
- smock sets `Content-Type: application/json`, or `text/event-stream` for
  a stream. A `Content-Type` the Stub gives is replaced, as for
  [`events`](responses.md#server-sent-events).
  smock also adds an `x-request-id` header, or `request-id` for
  `anthropic-messages`, unless the Stub gives its own.
  Other headers, such as a rate-limit header, are sent as written.
- The reply's id is generated with the vendor's prefix, unless `id` fixes
  it. `created`, or Responses' `created_at`, is the time smock received the
  request. `model` is the Stub's `model`, or else the request's. [Ids,
  seeds and time](#ids-seeds-and-time) says more.

An LLM response is a response like any other, and `llm` is for HTTP Stubs. A
[gRPC Stub](grpc.md#grpc-stubs) cannot give it, since a gRPC reply is a
protobuf message, not an LLM API's HTTP wire form ([A gRPC Stub's
fields](grpc.md#a-grpc-stubs-fields)). `status` is required, as on every
HTTP Stub. `llm` may stand in `response` or in any element of
[`responses`](responses.md#several-responses), so weighted responses can
answer one request in ten with an ordinary 429. Request conditions,
[templates](#templates-in-llm-replies), Faults, Ephemeral Stubs, the Journal
and [`smock render`](templates.md#rendering-a-template) work as for other
responses: a rendering shows the JSON body, or the events for a sample whose
body sets `stream: true`, with the ids and the waits its seed gives and its
time as `created`. A response gives at most one of `body`, `bodyFile`,
`json`, `events` and `llm`.

These are reported with the field's JSON Pointer:

- a missing or unknown `api`;
- an unknown field of `llm` or of its `usage`;
- a count that is not an integer from 0 to 2^53-1;
- a stop reason that is not a word of the API;
- the errors of [chunks](#chunks), of [tool
  calls](llm-tool-calls.md#tool-calls) and of a [mid-stream
  error](llm-errors.md#mid-stream-errors);
- a wait of `timing` that is not one distribution of the delay;
- a reply as written over the [size bound](#the-size-bound);
- `llm` beside another body;
- `llm` on a gRPC Stub, in `response` or in any element of `responses`.

`smock check` reports them, and so do startup and a reload, which keeps the
set served. An Ephemeral Stub with one of them gets 400 `invalid_stub`.

The wire forms follow the vendors' documents as they were read on
2026-10-22 and 2026-10-23. When a vendor changes its documented form, a
minor release may change what an existing `llm` Stub sends, with a
CHANGELOG entry. CI also reads smock's replies with the vendors' official
Python SDKs, at pinned versions, as applications call them. A change that
a newer version of an SDK brings to what an existing `llm` Stub sends
ships the same way.

## Contents

- [Streams](#streams)
- [Chunks](#chunks)
- [Timing](#timing)
- [Usage and stop reasons](#usage-and-stop-reasons)
- [Ids, seeds and time](#ids-seeds-and-time)
- [Tool calls and agent loops](llm-tool-calls.md)
- [LLM API errors](llm-errors.md)
- [Templates in LLM replies](#templates-in-llm-replies)
- [The size bound](#the-size-bound)
- [The OpenAI Responses and Anthropic Messages APIs](llm-apis.md)
- [Paths and compatible endpoints](#paths-and-compatible-endpoints)
- [Model lists and other paths](#model-lists-and-other-paths)
- [Prompts in the Journal](#prompts-in-the-journal)

## Streams

A request whose body is a JSON object with `stream: true` gets the reply as
[Server-Sent Events](responses.md#server-sent-events), as the vendor streams
it. Any other request gets the JSON reply: a body that is not JSON, no
`stream`, `stream: false`, or the string `"true"`. So one Stub serves both
kinds of call, and an SDK reads the reply with the parser it chose for its
own request. Only an `llm` response reads the request body for this; other
Stubs pay nothing. An `anthropic-messages` stream is a series of named
events, which [Messages streams](llm-apis.md#messages-streams) lists.

An `openai-chat` stream is a series of `chat.completion.chunk` objects.
Each one is one `data:` line of compact JSON, with no `event:` line, and
every chunk carries the reply's id, `created` and model. In order:

1. the opening chunk, whose `delta` gives `role: assistant` and an empty
   `content`, or a `null` one when [tool
   calls](llm-tool-calls.md#tool-calls) follow no text;
2. one chunk per piece of the text, whose `delta` gives the piece as
   `content`;
3. for each [tool call](llm-tool-calls.md#tool-calls), a chunk that opens
   it, then one chunk per piece of its arguments;
4. the closing chunk, whose `delta` is empty and whose `finish_reason` is
   the [stop reason](#usage-and-stop-reasons);
5. when the request asks for usage, the
   [usage chunk](#usage-and-stop-reasons), with no choice;
6. `data: [DONE]`.

There is no `obfuscation` field, no `system_fingerprint` and no SSE comment
line. The text is cut into pieces of 4 code points, the last one shorter,
unless `chunkSize` or `chunks` says otherwise ([Chunks](#chunks)). The
pieces join to exactly the text, and a piece never splits a code point, so
every `data:` line is valid UTF-8. Empty text with no tool call sends the
opening and closing chunks only. A [mid-stream
error](llm-errors.md#mid-stream-errors) ends the stream early, without the
closing chunk or `[DONE]`.

For the Stub above, a request for `gpt-6-astra` with `stream: true` gets
this stream, which `smock render` shows with the same seed and time:

```text
data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"Hell"},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"o! H"},"logprobs":null,"finish_reason":null}]}

  … "ow c", "an I", " ass", "ist ", "you ", "toda" …

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"y?"},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}

data: [DONE]

```

An `openai-responses` stream is a series of named events instead, each
with an `event:` line and a `sequence_number`, and no `[DONE]`:
[The Responses stream](llm-apis.md#the-responses-stream) lists them.

A stream travels as the events of an `events` response do:

- smock sends the head and every event before the first piece at once,
  then each later event after the wait its [`timing`](#timing) gives.
  Without `timing`, every event follows at once.
- To an HTTP/1.1 client the stream is sent with chunked framing, so the
  connection carries the next request. An HTTP/1.0 client gets it
  unframed, and smock closes the connection to end it.
- Over HTTP/2, the stream is an HTTP/2 stream of its own, sent as any
  event stream is: the HEADERS carry no `content-length`, each event goes
  out as DATA, and the DATA of the last event ends the HTTP/2 stream. A
  client that resets it ends the stream at once
  ([HTTP/2](../http2.md#server-sent-events)).
- A reply to `HEAD`, or with status 204 or 304, is the status and the
  headers alone, for the stream as for the JSON reply.
- smock plans the whole JSON body, or every event, before it applies
  [Faults](faults.md#faults). A delay holds back the status line of either.
  A `partial` Fault sends the first half of the events, rounded down, and
  does not end the stream; for the JSON reply, it sends half the body.
  `reset` and `close` are unchanged.
- The stream's [Journal](../admin-api.md#the-journal) entry is committed
  before its last event, as for `events`.
- A client that closes the connection mid-stream ends the stream: smock
  notices when it next writes an event, and the Journal keeps the
  request's entry. A [drain](../running.md#the-drain) on SIGTERM waits for a
  stream in progress, its waits included.

## Chunks

A stream sends the text in pieces, one chunk each. Two fields choose the
pieces, so a test can stream one code point at a time, or place a split
exactly where its parser might fail:

- `chunkSize` sets how many code points each piece holds: an integer from
  1 to 1,000,000, 4 by default. The last piece is shorter, and a size
  above the text's length sends the text as one piece.
- `chunks` gives the pieces themselves, in place of `text`: a list of at
  least one text. Each element is one piece, sent as its own chunk even
  when it is empty. The text is their join, which the JSON reply carries.
  `chunkSize` does not apply to `chunks`.

```yaml
- id: one-at-a-time
  mock: openai
  request:
    method: POST
    path: /v1/chat/completions
    headers: { X-Test-Case: one-at-a-time }
  response:
    status: 200
    llm: { api: openai-chat, text: 晴れです。, chunkSize: 1 }
- id: split-emoji
  mock: openai
  request:
    method: POST
    path: /v1/chat/completions
    headers: { X-Test-Case: split-emoji }
  response:
    status: 200
    llm:
      api: openai-chat
      chunks: ["Thumbs up: ", "", "👍", "🏽"]
```

The first Stub streams the content pieces `"晴"`, `"れ"`, `"で"`, `"す"`
and `"。"`. The second streams `"Thumbs up: "`, `""`, `"👍"` and `"🏽"`,
and its JSON reply's content is `"Thumbs up: 👍🏽"`.

- A piece never splits a code point, so every `data:` line is valid UTF-8,
  whatever the size. Pieces are counted in code points, not in characters
  as they show, so a piece may split a character made of several code
  points, such as a flag or an emoji with a skin tone. With `chunks`, a
  split can go between any two code points.
- An empty element of `chunks` is a piece like any other: it is sent as a
  chunk whose content is `""`.
- `text` beside `chunks`, an empty `chunks`, an element that is not a
  string, and a `chunkSize` that is not an integer from 1 to 1,000,000 are
  load errors.

## Timing

`timing` paces a stream, to test time to first token or how a UI shows a
slow reply. `first` is the wait before the first piece, and `interval` the
wait before each later one. Each takes one distribution of the
[delay](faults.md#delays) Fault, `fixed`, `uniform` or `lognormal`, in whole
milliseconds. This Stub waits about 400 ms before the first piece, and 15
to 40 ms before each later one:

```yaml
mocks:
  - name: openai
stubs:
  - id: slow-hello
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
        timing:
          first: { lognormal: { median: 400, sigma: 0.5 } }
          interval: { uniform: { min: 15, max: 40 } }
```

- **Where the waits go.** smock writes the head and every event before the
  first piece at once. It waits `first` before the first event that carries
  a piece, counted from the head, and `interval` before each later one. The
  events that open or close the reply, an item, a part, a [tool
  call](llm-tool-calls.md#tool-calls) or a block of an `anthropic-messages`
  stream follow the event before them at once. A piece of a tool call's
  arguments is a piece, and so is an empty element of [`chunks`](#chunks),
  so each waits as one. A reply with no piece, such as one with empty text,
  waits `first` before its first closing event: Chat's closing chunk,
  Responses' `response.output_text.done`, or the last function call's
  `response.function_call_arguments.done` when there is no message item, or
  Messages' `message_delta`. A [mid-stream
  error](llm-errors.md#mid-stream-errors) waits as a next piece would.
- **Responses' `completed_at`.** In an `openai-responses` stream, the
  `completed_at` of `response.completed` is the time smock received the
  request plus the stream's waits up to that event, in whole seconds, so a
  slow stream completes later than it was created. `created_at` stays the
  time received. A JSON reply has no wait, so its `completed_at` is the
  time received.
- **Either may be left out**, for no wait there. Without `timing`, a stream
  has no wait at all.
- **No `probability`.** Unlike a delay, a wait applies to every stream, so
  `probability` in `first` or `interval` is a load error, as is an unknown
  distribution, a negative wait or an unknown member of `timing`.
- **Draws.** Each wait is drawn on its own, in order, from the Stub's random
  source: from a generator of its own, seeded with the one draw every
  matched request takes XOR a fixed constant, which differs from the ids'
  one. So [`fault.seed` and `--seed`](faults.md#seeds) replay a slow run
  exactly, and adding `timing` changes no id, no Fault decision, no pick
  among `responses` and no helper output.
- **Only streams.** A JSON reply is written at once, whatever `timing`
  gives. A [delay](faults.md#delays) Fault still holds back the status line
  of either, before the stream's own waits.
- **Render.** [`smock render`](templates.md#rendering-a-template) shows each
  event's wait as its `delay`, drawn as for a request. With `--seed 7` and a
  sample that sets `stream: true`, the Stub above waits 824 ms before
  `"Hell"`, then 27, 20, 38, 19, 40, 38, 26 and 28 ms before the next eight
  pieces. The opening chunk, the closing chunk and `[DONE]` wait 0. The same
  Stub with `api: openai-responses` waits the same 1060 ms in all, so with
  `--time 2026-10-23T00:00:00Z` its `response.completed` gives
  `completed_at` 1792713601, one second after its `created_at`.

## Usage and stop reasons

`usage` declares the token counts the reply reports, and `stopReason` why
the reply ended. This Stub stands for a reply cut short by the token limit:

```yaml
mocks:
  - name: openai
stubs:
  - id: truncated
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: The weather in Paris is
        usage: { input: 31, output: 5 }
        stopReason: length
```

smock counts no tokens and estimates none: the reply reports the counts as
written. Each one is an integer from 0 to 2^53-1, 9007199254740991, and 0
when left out. An [`openai-responses`](llm-apis.md#openai-responses) reply
gives them as `input_tokens` and `output_tokens`, with `total_tokens` their
sum. An `anthropic-messages` reply gives them as `input_tokens` and
`output_tokens`, with no total and no cache counts. Its stream gives
`input_tokens` in `message_start`, with `output_tokens` 0, and
`output_tokens` in `message_delta`. An `openai-chat` reply gives `input` as
`prompt_tokens`, `output` as `completion_tokens`, and their sum as
`total_tokens`. The detail objects of OpenAI's example follow, every count
in them 0. A request for `gpt-6-astra` without `stream` gets this reply,
which `smock render` shows with `--seed 7` and `--time
2026-10-23T00:00:00Z`:

```json
{"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"message":{"role":"assistant","content":"The weather in Paris is","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"length"}],"usage":{"prompt_tokens":31,"completion_tokens":5,"total_tokens":36,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
```

The JSON reply always carries `usage`. An `openai-chat` [stream](#streams)
carries it only when the request asks for it, as the vendor's does:

- When the request's body sets `stream_options.include_usage` to `true`,
  every chunk carries `"usage":null`. After the closing chunk comes the
  usage chunk, whose `choices` is empty and whose `usage` gives the counts,
  then `data: [DONE]`. An SDK reads the counts from that last chunk.
- Any other stream has no `usage` member and no usage chunk. That includes
  `include_usage: false` and the string `"true"`.

The same request with `stream: true` and
`stream_options: { include_usage: true }` gets a stream that ends with
these events:

```text
  … "The ", "weat", "her ", "in P", "aris" …

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":" is"},"logprobs":null,"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"length"}],"usage":null}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[],"usage":{"prompt_tokens":31,"completion_tokens":5,"total_tokens":36,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}}}

data: [DONE]

```

`stopReason` is written in the word of the Stub's API:

- For `openai-chat` it is the `finish_reason`, one of `stop`, `length`,
  `tool_calls`, `content_filter` and `function_call`, which OpenAI
  deprecates. It goes in the JSON reply's `finish_reason` and in the
  closing chunk's.
- For `openai-responses`, which has no stop word, it is an incomplete
  reason, one of `max_output_tokens`, `max_messages`, `content_filter` and
  `steered`, which makes the reply
  [incomplete](llm-apis.md#incomplete-replies).
- For `anthropic-messages` it is the `stop_reason`, one of `end_turn`,
  `max_tokens`, `stop_sequence`, `tool_use`, `pause_turn`, `refusal` and
  `model_context_window_exceeded`. It goes in the JSON reply's
  `stop_reason` and in the stream's `message_delta`. `stop_sequence` and
  `refusal` each add a member to both
  ([Anthropic Messages](llm-apis.md#anthropic-messages)).
- Any word of the API may be written, whatever the reply holds. So a test
  can send `length` for a reply cut short, or `content_filter` for a
  filtered one.
- Left out, smock derives it from the reply: for `openai-chat`, `tool_calls`
  when the reply has [tool calls](llm-tool-calls.md#tool-calls) and `stop`
  otherwise; for `anthropic-messages`, `tool_use` when the reply has tool
  calls and `end_turn` otherwise. An `openai-responses` reply is then
  `completed`.
- A word that is not one of the API's, such as Anthropic's `end_turn` on
  `openai-chat`, or Chat's `length` on `openai-responses`, is a load error
  that lists the API's words. smock checks it when it loads the Stub, so a
  reply never carries a word its SDK does not know.

## Ids, seeds and time

smock generates ids for each reply: the reply's id, the id of each item the
reply holds and of each [tool call](llm-tool-calls.md#tool-calls), and a
request id, which it sends in a header. Each is the vendor's prefix and 24
characters from `A`-`Z`, `a`-`z` and `0`-`9`:

| API | Reply's id | Items and tool calls | Request-id header |
|---|---|---|---|
| `openai-chat` | `chatcmpl-` | tool call `call_` | `x-request-id: req_…` |
| `openai-responses` | `resp_` | message item `msg_`, function call `fc_`, its `call_id` `call_` | `x-request-id: req_…` |
| `anthropic-messages` | `msg_` | tool use `toolu_` | `request-id: req_…` |

- One reply has one id: the JSON reply and every event of the stream carry
  the same one.
- The ids come from the Stub's random source: from a generator of their own,
  seeded with the one draw every matched request takes XOR a fixed constant.
  So [`fault.seed` and `--seed`](faults.md#seeds) replay them, and an `llm`
  response changes no Fault decision, no pick among `responses` and no
  helper output.
- A seeded Stub's generator advances once per request the Stub matches,
  whatever the Session. So the n-th request it matches gets the same ids
  in every run. Which request is the n-th depends on the order the
  requests arrive in, such as when tests run in parallel. A test that
  must know an id in advance fixes it.
- `id` fixes the reply's id. smock sends it exactly as written, with no
  prefix, in the JSON reply and in every event of the stream. Fixing it
  changes no other id: the ids draw in a fixed order of slots, the reply's
  first, then the Responses message item's, then two for each tool call,
  and the request id's last. Every slot draws whether or not the Stub
  fixes its id, or its API uses it. So adding `id` to a Stub keeps the
  request ids of a recorded run, and a Stub that moves from `openai-chat`
  to `openai-responses` keeps the 24 characters of its reply's id and its
  request id.
- The Responses message item's `msg_` id and a function call item's `fc_`
  id are always generated: no field fixes them.
- `created`, and Responses' `created_at`, is the time smock received the
  request, in whole seconds since the Unix epoch: the time `now()` reads.
  In a rendering, it is the rendering's time.
- The reply's `model` is the Stub's `model` when given. Otherwise it is the
  request's `model` when that is a string, and otherwise the empty string,
  such as when the body is not JSON. `llm` adds no condition on the model,
  so one Stub answers every model. A Stub that should answer one model
  adds a body condition on it, as below.
- smock adds the request-id header to the JSON reply and to the stream,
  after the Stub's own header fields. openai-python and
  anthropic-sdk-python each read it as the reply's `_request_id`. A header
  the Stub gives under that name, in any case, takes its place: smock then
  sends the Stub's field alone. The request id still draws its slot, so no
  other id changes.

This Stub answers only requests for `gpt-6-astra`, and fixes the reply's
id, its model and its request id, so that a test can assert all three:

```yaml
mocks:
  - name: openai
stubs:
  - id: astra
    mock: openai
    request:
      method: POST
      path: /v1/chat/completions
      body: { json: { model: gpt-6-astra } }
    response:
      status: 200
      headers: { x-request-id: req_test_1 }
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
        id: chatcmpl-test-1
        model: gpt-6-astra-2026-10-01
```

A request for `gpt-6-astra` gets a reply that begins
`{"id":"chatcmpl-test-1","object":"chat.completion","created":…,"model":"gpt-6-astra-2026-10-01",`,
with `x-request-id: req_test_1`. A request for another model does not
match it.

## Templates in LLM replies

With [`template: true`](templates.md#templates), an LLM reply is rendered
for each request, so it can echo the request, or read a
[Variable](variables.md#variables) or a [Data
bucket](data-buckets.md#data-buckets). This Stub echoes the user's last
message:

```yaml
mocks:
  - name: openai
stubs:
  - id: echo
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      template: true
      llm:
        api: openai-chat
        text: 'You said: ${last(body.messages).content}'
```

A request whose last message is `Say "hi"`, a line break and `then stop`
gets a reply whose message has
`"content":"You said: Say \"hi\"\nthen stop"`. With `stream: true`, the
pieces are `You `, `said`, `: Sa`, `y \"h`, `i\"\nt`, `hen ` and `stop`,
as `smock render` shows with `--seed 7`.

- `text`, each element of `chunks`, `id`, `model`, each tool call's `name`,
  `id` and string `arguments`, and the
  [error's](llm-errors.md#mid-stream-errors) `message` are text templates.
  An object `arguments` is a [structured
  template](templates.md#structured-templates), whose members keep the types
  of what they insert. `api`, `stopReason`, `usage`, `chunkSize`, `timing`,
  and the error's `after`, `type` and `code` are never templates. Header
  values are templates, as in any response.
- smock renders the text whole for each request, then cuts it into
  pieces, so echoed text is cut like any other. Each element of `chunks`
  is rendered on its own and stays one piece. A tool call's arguments are
  rendered, then cut.
- These templates escape nothing. smock writes what they give into the
  JSON it builds, so a quote or a line break from the request is
  JSON-escaped on the wire, whatever the Stub's `Content-Type`. An object
  or an array in a text template needs `json(x)`, as in any text template.
- Helpers, such as `fake.uuid()`, draw in render order: the header values,
  then `id`, `model`, the text or each chunk in order, each tool call's
  `id`, `name` and `arguments`, then the error's `message`. So
  [`fault.seed`](faults.md#seeds) replays them, and adding an error changes
  nothing drawn before it. The generated ids draw from a generator of their
  own, so a helper changes none of them.
- The templates read `vars` and `data` as any response's do: after the
  Stub's [`variables`](variables.md#variables) and
  [`dataWrites`](data-buckets.md#writing-buckets-datawrites) have written,
  so the reply reads what they just did. A Scenario moves on an `llm` Stub
  as on any other. [Conversations of several
  turns](llm-tool-calls.md#conversations-of-several-turns) uses both.
- A syntax error is a load error at the field's JSON Pointer, such as
  `/stubs/0/response/llm/text`. Two tool calls whose ids insert nothing
  and are the same are a load error, as without templates. Ids that
  insert a value are compared after rendering.

This Stub's calls take the user's last message and the whole
conversation:

```yaml
- id: search
  mock: openai
  request: { method: POST, path: /v1/chat/completions }
  response:
    status: 200
    template: true
    llm:
      api: openai-chat
      toolCalls:
        - name: search
          arguments: { query: "${last(body.messages).content}", limit: "${body.limit ?? 5}" }
        - name: log
          arguments: '{"messages":${json(body.messages)}}'
```

For the request above, the first call's arguments are
`{"query":"Say \"hi\"\nthen stop","limit":5}`, and the second's
`{"messages":[{"role":"user","content":"Say \"hi\"\nthen stop"}]}`.

A template that fails to render, such as one that inserts a missing value,
gives the usual [500 `template
failed`](templates.md#missing-values-and-render-errors), with `at` under the
`llm` field, such as `"at":"/response/llm/text","message":"body.messages is
missing"`. Two tool call ids that render the same give it too. A streamed
request gets the 500, not a stream, since smock renders the whole reply
before it sends the head. Every template renders for every request, so an
error's `message` that fails gives the 500 to a request that does not stream
too.

The SDKs [retry](llm-errors.md#retries) a 500 twice by default. So one call
to a Stub whose template fails makes three requests, with three Journal
entries, and takes three draws from a seeded Stub's random source: the
requests after it get other ids and waits than in a run without the failure.
A test that expects the 500 builds its client with `max_retries=0`.

## The size bound

An LLM reply takes at most 1 MiB once encoded: its JSON body, or all the
events of its stream, with their `event:` and `data:` lines and blank lines,
in UTF-8. This is the bound of a [rendered
body](templates.md#missing-values-and-render-errors), counted on its own:
the strings that a template renders keep their own count.

A stream carries much more than its text. Each piece goes in an event of
its own, and every Chat chunk repeats the reply's id and model. At 4 code
points per piece, a stream of ASCII text reaches 1 MiB at about 20,000
characters for `openai-chat` and `openai-responses`, and at about 35,000
for `anthropic-messages`. A larger `chunkSize` lets a stream carry more.
The JSON reply carries the text once, so it holds almost 1 MiB of it.

- A reply as written is encoded when the files are loaded, both as the JSON
  reply and as the stream to a request whose body is
  `{"stream":true,"stream_options":{"include_usage":true}}`, with no model
  from the request. Either one over the bound is a load error at the `llm`
  field, which `smock check` reports, such as `/stubs/0/response/llm: the
  reply takes more than 1 MiB as a stream`. A [mid-stream
  error](llm-errors.md#mid-stream-errors) ends the stream early, so then the
  JSON reply can be the larger: a long text cut early loads, unless its JSON
  reply alone passes the bound.
- A reply can still pass the bound for one request. A template can insert a
  long value, in the text or in an error's `message`, and a long `model`
  from the request, or a setting that a Responses object copies, such as
  `tools`, goes into the reply. A Responses stream carries those settings
  three times. Such a request gets the [500 `template
  failed`](templates.md#missing-values-and-render-errors), with `at` at the
  `llm` field, and no stream: `"at":"/response/llm","message":"the reply
  takes more than 1 MiB as a stream"`. The SDKs
  [retry](llm-errors.md#retries) it, as any 500.
- smock stops encoding a reply as soon as it passes the bound, so a long
  echo costs no more than a reply of 1 MiB.

## Paths and compatible endpoints

The preset neither sets nor checks `request.path`. A Stub's conditions
decide which requests it answers, as for any Stub, and smock checks no
request against a vendor's schema. So `openai-chat` also stands in for
the services that offer Chat Completions to OpenAI's SDKs at paths of
their own. Give the Stub the service's path, and point the client's base
URL at smock with the same path, such as
`http://localhost:8080/v1beta/openai/` for Gemini:

| Service | Its base URL | The Stub's path |
|---|---|---|
| OpenAI | `https://api.openai.com/v1` | `/v1/chat/completions` |
| Gemini, OpenAI compatibility | `https://generativelanguage.googleapis.com/v1beta/openai/` | `/v1beta/openai/chat/completions` |
| Anthropic, OpenAI SDK compatibility | `https://api.anthropic.com/v1/` | `/v1/chat/completions` |
| Ollama, OpenAI compatibility | `http://localhost:11434/v1/` | `/v1/chat/completions` |

Gemini's own `generateContent` and Ollama's own `/api/chat` have other
wire forms, which `llm` does not write. `openai-responses` stands in the
same way for the Responses API, at `/v1/responses` under OpenAI's base URL,
or under Ollama's, whose OpenAI compatibility serves it too.

Azure OpenAI puts the deployment's name in the path. For
`model="my-gpt"`, openai-python's
`AzureOpenAI(azure_endpoint="http://localhost:8080", api_version="2024-10-21", api_key="test")`
sends `POST /openai/deployments/my-gpt/chat/completions?api-version=2024-10-21`.
A path pattern answers every deployment. The query does not count, since
the Stub lists no query parameter:

```yaml
mocks:
  - name: azure
stubs:
  - id: azure-chat
    mock: azure
    request:
      method: POST
      path: { pattern: "/openai/deployments/[^/]+/chat/completions" }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
```

The reply is in OpenAI's form. It has none of Azure's content-filter
members, such as `prompt_filter_results` and `content_filter_results`.

## Model lists and other paths

`llm` writes only the reply to a prompt. Ordinary `json` Stubs answer the
rest of an API, such as its model list, `GET /v1/models`. In OpenAI's
shape:

```yaml
- id: models
  mock: openai
  request: { method: GET, path: /v1/models }
  response:
    status: 200
    json:
      object: list
      data:
        - { id: gpt-6-astra, object: model, created: 1792713600, owned_by: system }
```

In Anthropic's shape:

```yaml
- id: models
  mock: anthropic
  request: { method: GET, path: /v1/models }
  response:
    status: 200
    json:
      data:
        - { type: model, id: claude-test, display_name: Claude Test, created_at: "2026-10-01T00:00:00Z", lifecycle: active }
      has_more: false
      first_id: claude-test
      last_id: claude-test
```

A request that no Stub matches gets smock's own `noMatch` reply, a 404 with
`{"error":"no Stub matched"}`, and a [Near
miss](matching.md#when-no-stub-matches) that names the closest Stub. A
client that reads the [vendor's error
body](llm-errors.md#errors-before-the-reply) needs a Stub that answers every
other path of the Mock with it. That is an ordinary Stub with no conditions,
not the [Default Mock](../definition-files.md#hosts-and-the-default-mock),
which answers the Hosts that no Mock lists. Leave out its `priority` and
declare it after the Mock's other Stubs, so that it is tried last: a Stub
without a priority is tried after every Stub with one, and among those in
declaration order ([Which Stub answers](matching.md#which-stub-answers)).

```yaml
mocks:
  - name: openai
stubs:
  - id: chat
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
  - id: other-paths
    mock: openai
    response:
      status: 404
      template: true
      headers: { x-request-id: req_eTuAaXsuWSSRENWrCE3JNEi7 }
      json:
        error:
          message: Invalid URL (${method} ${path})
          type: invalid_request_error
          param: null
          code: null
```

openai-python raises `NotFoundError` for it, and does not
[retry](llm-errors.md#retries) it. For Anthropic, the body is
`{"type":"error","error":{"type":"not_found_error","message":"Not
found"},"request_id":"req_…"}`, with the same id in `request-id`.

With such a Stub, every request of the Mock matches. None has a Near miss,
and `GET /v1/journal/unmatched` lists none of them. The Journal names the
Stub that answered each request, so a test finds stray calls by that
Stub's id.

## Prompts in the Journal

An LLM request carries the whole conversation, and often the tools'
schemas, so its body often passes 4 KiB. The
[Journal](../admin-api.md#the-journal) keeps the first 4 KiB of each body by
default, and the entry's body then says `truncated: true`. A test that
reads prompts from the Journal raises `--journal-body-limit`
(`SMOCK_JOURNAL_BODY_LIMIT`), such as `--journal-body-limit 1048576`. Each
entry then takes more of the Journal's byte bound. Conditions and
templates always read the whole body.
