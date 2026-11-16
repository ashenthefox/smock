# LLM API errors

This part of the [Definition-file reference](../definition-files.md)
describes the errors a Stub can give for an LLM API: a mid-stream error,
which the field `error` of `llm` declares, and an error in place of the
reply, such as a 429, which is an ordinary response with the vendor's
error body. It builds on [LLM responses](llm-responses.md), which
describes `llm`, streams, chunks and timing.

## Contents

- [Mid-stream errors](#mid-stream-errors)
- [Errors before the reply](#errors-before-the-reply)
  - [Retries](#retries)
  - [A 401 without a key](#a-401-without-a-key)
  - [A 429 with Retry-After](#a-429-with-retry-after)
  - [A 529 when overloaded](#a-529-when-overloaded)

## Mid-stream errors

`error` cuts a stream short with the API's own error, after part of the
text, so a test can check how its client handles a model that fails
mid-reply, such as an overloaded one. This Stub sends `Hello`, then an
error:

```yaml
mocks:
  - name: openai
stubs:
  - id: cut-short
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
        error:
          after: 5
          type: server_error
          message: The server had an error while processing your request. Sorry about that!
```

The fields of `error`:

| Field | Value | When left out |
|---|---|---|
| `after` | how many code points of the text come before the error, an integer from 0 | 0 |
| `type` | the error's type: non-empty text, or for `anthropic-messages` one of Anthropic's error types | required |
| `code` | in place of `type`, for `openai-responses` only: the error's code, non-empty text | required |
| `message` | the error's message, non-empty text, a template with `template: true` | required |

- **What is sent.** A request with `stream: true` gets the reply's opening
  events, then the text's pieces up to exactly `after` code points, the
  piece that holds the cut ending there, then the error. The stream ends
  there. No tool call, closing event or end marker follows, so the client
  sees an interrupted stream.
- **Chat's form.** For `openai-chat`, the stream opens with the opening
  chunk, and the error is a `data:` line of its own, in place of a chunk:
  `{"error":{"message":…,"type":…,"param":null,"code":null}}`. No closing
  chunk, usage chunk or `[DONE]` follows
  ([Streams](llm-responses.md#streams)).
- **Messages' form.** For `anthropic-messages`, the stream opens with
  `message_start`, and the error is an event named `error`: `event: error`,
  then `data: {"type":"error","error":{"type":…,"message":…}}`. When `after`
  is above 0, the text block's `content_block_start` and its
  `content_block_delta` events come before it; at 0, no `content_block_*`
  event is sent. No `content_block_stop`, `tool_use` block, `message_delta`
  or `message_stop` follows ([Messages
  streams](llm-apis.md#messages-streams)).
- **Responses' form.** For `openai-responses`, the stream opens with
  `response.created` and `response.in_progress`, and the error is an event
  named `error`: `event: error`, then `data:
  {"type":"error","code":…,"message":…,"param":null,"sequence_number":…}`,
  whose `sequence_number` is one more than the event before it. When `after`
  is above 0, the message item's `response.output_item.added` and
  `response.content_part.added` and its `response.output_text.delta` events
  come before it; at 0, no item is sent. No `.done` event, function call
  item, `response.completed` or `response.incomplete` follows ([The
  Responses stream](llm-apis.md#the-responses-stream)).
- **Counted in code points.** `after` counts code points of the text, not
  pieces, so the cut stays where it is when `chunkSize` or `chunks` changes.
  `after: 0` sends the error right after Chat's opening chunk,
  `response.in_progress` or `message_start`. An empty element of
  [`chunks`](llm-responses.md#chunks) counts 0 code points: one before the
  cut is sent, and the text stops at the piece that reaches `after`. An
  `after` past the end of a text as written is a load error.
- **With templates.** With [`template:
  true`](llm-responses.md#templates-in-llm-replies), `message` is a text
  template, such as `Overloaded: ${body.model}`, rendered for each request.
  `after`, `type` and `code` are never templates. A templated text is known
  only once it is rendered, so an `after` past its end is no load error:
  when the rendered text is shorter than `after`, the error follows the
  whole text. A message that renders empty is sent empty.
- **Waits.** The error waits as a next piece would: `first` when no piece
  came before it, and `interval` otherwise
  ([Timing](llm-responses.md#timing)).
- **Only streams.** A request that does not stream gets the ordinary
  reply, whole, so one Stub serves both. smock keeps no table of statuses:
  an error in place of the whole reply is an ordinary response
  ([Errors before the reply](#errors-before-the-reply)).
- **Status and Journal.** The status is the Stub's, 200 here, sent before
  the stream starts. The [Journal](../admin-api.md#the-journal) entry has
  that status, and is committed before the last event, the error, as for
  [`events`](responses.md#server-sent-events).
- **What openai-python does.** It raises `APIError` on Chat's error frame,
  from `create(stream=True)` and from the `chat.completions.stream()`
  helper, with the message, and the `error` object as its `body`. It raises
  nothing on the Responses `error` event: `responses.create(stream=True)`
  and the `responses.stream()` helper yield it, after the events before it,
  as a `ResponseErrorEvent` with its `code`, `message` and `param`. So a
  client reads it from the stream, as below. The stream then ends without
  `response.completed`, and the helper's `get_final_response()` raises
  `RuntimeError`, as on an [incomplete
  reply](llm-apis.md#incomplete-replies). With `max_retries` at its default
  it does not retry either: the status was 200. Checked with openai-python
  3.36.1, and the Responses `error` event with 3.37.0.
- **What anthropic-sdk-python does.** It picks its error class by the
  HTTP status, which is 200 on a stream. So on any `event: error` it
  raises `APIStatusError` with `status_code` 200, never `OverloadedError`,
  and the type is in the body's `error.type`: the exception's `body` is
  the event's data. It raises from `messages.create(stream=True)` and from
  the `messages.stream()` helper, after the events and the text before
  the error. With `max_retries` at its default it does not retry. Checked
  with anthropic-sdk-python 2.1.0.
- **Per API.** `openai-chat` and `anthropic-messages` give `type`, and
  `openai-responses` gives `code`, as each API names it. So the other one
  is a load error that names the member to give, and a Stub that moves to
  another `api` renames it there. Anthropic's `type` is one of its
  documented error types: `invalid_request_error`,
  `authentication_error`, `billing_error`, `permission_error`,
  `not_found_error`, `conflict_error`, `request_too_large`,
  `rate_limit_error`, `api_error`, `timeout_error` and
  `overloaded_error`. An OpenAI `type` or `code` is any non-empty text.
- `type` on `openai-responses` or `code` on another API, another
  Anthropic type, an empty `type`, `code` or `message`, an `after` that is
  not an integer from 0 or that passes the end of a text as written, and an
  unknown field of `error` are load errors.

A request for `gpt-6-astra` with `stream: true` gets this stream, which
[`smock render`](templates.md#rendering-a-template) shows with `--seed 7`
and `--time 2026-10-23T00:00:00Z`. The second piece, `"o! H"` without the
error, ends at the cut:

```text
data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"Hell"},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"o"},"logprobs":null,"finish_reason":null}]}

data: {"error":{"message":"The server had an error while processing your request. Sorry about that!","type":"server_error","param":null,"code":null}}

```

With `api: openai-responses`, `path: /v1/responses`, and
`code: server_error` in place of `type`, a Responses request for
`gpt-6-astra` with `stream: true` gets `response.created`,
`response.in_progress`, the message item's two opening events and the
deltas `"Hell"` and `"o"`, then this, with the same seed and time:

```text
event: error
data: {"type":"error","code":"server_error","message":"The server had an error while processing your request. Sorry about that!","param":null,"sequence_number":6}

```

openai-python yields that event, so a client that streams looks for it:

```python
stream = client.responses.create(model="gpt-6-astra", input="Hello!", stream=True)
for event in stream:
    if event.type == "error":
        print(event.code, event.message)
```

## Errors before the reply

`llm` declares a reply that succeeds, or one that a
[mid-stream error](#mid-stream-errors) cuts short. An error that comes in
place of the reply, such as a 429 or a 529, is an ordinary response with
the vendor's error body. Each vendor has one shape:

- OpenAI: `{"error": {"message", "type", "param", "code"}}`. All four
  members are present, and `param` and `code` may be `null`. A 429 or a
  503 may carry `Retry-After`, in seconds. Every reply carries an
  `x-request-id` header.
- Anthropic: `{"type": "error", "error": {"type", "message"},
  "request_id"}`. Every reply carries a `request-id` header, with the same
  id as `request_id`. Some 429s carry `retry-after`. The error's `type`
  follows the status:

  | Status | `error.type` |
  |---|---|
  | 400 | `invalid_request_error` |
  | 401 | `authentication_error` |
  | 402 | `billing_error` |
  | 403 | `permission_error` |
  | 404 | `not_found_error` |
  | 409 | `conflict_error` |
  | 413 | `request_too_large` |
  | 429 | `rate_limit_error` |
  | 500 | `api_error` |
  | 504 | `timeout_error` |
  | 529 | `overloaded_error` |

smock adds no request-id header to an ordinary response, only to an
`llm` reply, so the recipes below write one. Their messages and ids are
examples. The SDKs choose the error they raise by the status, such as
`RateLimitError` for a 429, and keep the body in it.

### Retries

The official SDKs, openai-python and anthropic-sdk-python, retry a
request that gets 408, 409, 429 or any 5xx, twice by default, so one call
can make three requests. Before each retry they wait out the reply's
`Retry-After`: openai-python up to 120 s, and it does not retry when asked
to wait longer. Without one, they back off from about half a second. Both
obey `x-should-retry`: with `false`, they do not retry, whatever the
status. So that a test sees each error once and does not wait, either:

- build the client with `max_retries=0`, such as
  `OpenAI(base_url="http://localhost:8080/v1", api_key="test", max_retries=0)`
  or `Anthropic(base_url="http://localhost:8080", api_key="test", max_retries=0)`;
- or send `x-should-retry: "false"` in the Stub's headers. Quote it: a
  header value is a string, and YAML reads a bare `false` as a boolean.

Each retry is a request of its own: it matches a Stub, takes a draw from
the Stub's random source, and gets its own Journal entry.

### A 401 without a key

smock ignores `Authorization`, `x-api-key` and `anthropic-version`, as it
ignores every header a Stub does not list, so any key works, such as
`api_key="test"`. A test that needs a 401 adds an ordinary Stub with a
`headers` condition, declared before the Stubs it guards:

```yaml
mocks:
  - name: openai
stubs:
  - id: no-key
    mock: openai
    request:
      headers: { Authorization: { $exists: false } }
    response:
      status: 401
      headers: { x-request-id: req_eTuAaXsuWSSRENWrCE3JNEi7 }
      json:
        error:
          message: Incorrect API key provided.
          type: invalid_request_error
          param: null
          code: invalid_api_key
  - id: hello
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
```

Anthropic's API takes its key in `x-api-key` or in `Authorization`, so
its Stub checks both:

```yaml
- id: no-key
  mock: anthropic
  request:
    headers:
      x-api-key: { $exists: false }
      Authorization: { $exists: false }
  response:
    status: 401
    headers: { request-id: req_KEdIon5S7matgpJr8lPWEQTb }
    json:
      type: error
      error: { type: authentication_error, message: Invalid API key. }
      request_id: req_KEdIon5S7matgpJr8lPWEQTb
```

To refuse every key but the test's own, write a condition such as
`{ $not: "Bearer sk-test" }` in place of `{ $exists: false }`. Both SDKs
raise `AuthenticationError` for a 401, and neither retries it
([Retries](#retries)).

### A 429 with Retry-After

```yaml
mocks:
  - name: openai
stubs:
  - id: rate-limited
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 429
      headers:
        Retry-After: "20"
        x-request-id: req_5K5eWPUAGI1WXJRVsFgWLtIw
        x-should-retry: "false"
      json:
        error:
          message: Rate limit reached for requests.
          type: rate_limit_error
          param: null
          code: slow_down
```

Both SDKs retry a 429 twice by default, as they retry 408, 409 and every
5xx, after waiting out its `Retry-After`, openai-python up to 120 s
([Retries](#retries)). Both obey `x-should-retry: "false"`, so
openai-python raises `RateLimitError` at once. Without it, the call would
wait 20 s twice and raise only after the third 429. `max_retries=0` on the
client does the same for every Stub. Anthropic's 429 has the `error.type`
`rate_limit_error`.

To rate-limit one call in ten, give the 429 beside an `llm` reply in
[weighted responses](responses.md#several-responses):

```yaml
- id: chat
  mock: openai
  request: { method: POST, path: /v1/chat/completions }
  responses:
    - weight: 9
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
    - weight: 1
      status: 429
      headers:
        Retry-After: "1"
        x-request-id: req_5K5eWPUAGI1WXJRVsFgWLtIw
        x-should-retry: "false"
      json:
        error:
          message: Rate limit reached for requests.
          type: rate_limit_error
          param: null
          code: slow_down
  fault: { seed: 7 }
```

With its retries on, an SDK would retry the 429 and most likely get the
reply, so the code under test would not see it. `x-should-retry: "false"`
keeps the 429 for the code under test, and `fault.seed` gives the 429 to
the same calls on every run.

### A 529 when overloaded

Anthropic answers 529 when its API is overloaded:

```yaml
mocks:
  - name: anthropic
stubs:
  - id: overloaded
    mock: anthropic
    request: { method: POST, path: /v1/messages }
    response:
      status: 529
      headers: { request-id: req_5J4ymbACTcA49ramAi1T8pGa }
      json:
        type: error
        error: { type: overloaded_error, message: Overloaded }
        request_id: req_5J4ymbACTcA49ramAi1T8pGa
```

A 529 is a 5xx, so both SDKs retry it twice by default, as they retry 408,
409 and 429, after waiting out a `Retry-After`, openai-python up to 120 s.
Both obey `x-should-retry: "false"` in the Stub's headers
([Retries](#retries)). With `Anthropic(base_url="http://localhost:8080",
api_key="test", max_retries=0)`, anthropic-sdk-python raises
`OverloadedError` at once. OpenAI's counterpart is a 503, with `type:
service_unavailable_error` and `code: server_is_overloaded`, which may carry
`Retry-After`. openai-python raises `InternalServerError` for it.
