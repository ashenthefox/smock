# The OpenAI Responses and Anthropic Messages APIs

This part of the [Definition-file reference](../definition-files.md)
describes the wire form of an LLM response for `api: openai-responses`
and `api: anthropic-messages`: the JSON reply, the stream's events, tool
calls and stop reasons. It builds on [LLM responses](llm-responses.md),
which describes `llm` and its fields, `api` among them, the form of
`openai-chat`, and the chunks, timing and ids that every API shares.

## Contents

- [OpenAI Responses](#openai-responses)
  - [The Responses stream](#the-responses-stream)
  - [Function call items](#function-call-items)
  - [Incomplete replies](#incomplete-replies)
- [Anthropic Messages](#anthropic-messages)
  - [Messages streams](#messages-streams)
  - [Messages tool calls](#messages-tool-calls)

## OpenAI Responses

`api: openai-responses` answers OpenAI's Responses API with a Response
object. This Stub answers it at its path, `/v1/responses`:

```yaml
mocks:
  - name: openai
stubs:
  - id: hello
    mock: openai
    request: { method: POST, path: /v1/responses }
    response:
      status: 200
      llm:
        api: openai-responses
        text: Hi there! How can I assist you today?
        usage: { input: 37, output: 11 }
```

openai-python reaches it through the same base URL as Chat Completions,
`OpenAI(base_url="http://localhost:8080/v1", api_key="test")`. Then
`client.responses.create(model="gpt-6-astra", instructions="You are a
helpful assistant.", input="Hello!")` sends `POST /v1/responses`, and gets
this reply, which [`smock render`](templates.md#rendering-a-template) shows
with `--seed 7` and `--time 2026-10-23T00:00:00Z`:

```json
{"id":"resp_oniRcSDFUU6bnxe66XwQR5pl","object":"response","access_programs":null,"created_at":1792713600,"status":"completed","completed_at":1792713600,"error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":37,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48},"user":null,"metadata":{}}
```

- `output` holds the message item, with `text` as its `output_text`, or
  `""` when the text is empty. Its id is `msg_` and 24 generated
  characters. Each [tool call](#function-call-items) follows it as a
  `function_call` item. With tool calls and empty text, there is no
  message item.
- `usage` gives the [declared
  counts](llm-responses.md#usage-and-stop-reasons) as `input_tokens` and
  `output_tokens`, with `total_tokens` their sum.
- `created_at` and `completed_at` are the time smock received the
  request, in whole seconds. A [stream](#the-responses-stream)'s
  `completed_at` adds its waits.
- The Response object gives back the settings the request gave, copied as
  given: smock does not interpret them. They are `instructions`,
  `previous_response_id`,
  `tools`, `tool_choice`, `temperature`, `top_p`, `max_output_tokens`,
  `parallel_tool_calls`, `metadata`, `store`, `text`, `truncation`,
  `reasoning`, `user`, `safety_identifier`, `prompt_cache_key`,
  `top_logprobs`, `max_tool_calls` and `background`.
- A setting the request leaves out takes the value of OpenAI's examples,
  such as `tools: []` and `store: true`. The examples do not show the last
  five, so smock leaves them out too.
- `model` is the Stub's, or else the request's, as for every API.
  `service_tier` is always `default`, the examples' tier, and
  `conversation` is not copied.
- The other members, their order and their fixed values follow the
  examples of OpenAI's API reference, such as `error: null`,
  `access_programs: null` and `temperature: 1.0`.
- smock keeps no Responses state. `previous_response_id` is only copied, and
  a request with `background: true` gets this same reply, not a queued one.
  [Responses follow-ups](llm-tool-calls.md#responses-follow-ups) shows how
  Stubs answer a follow-up and `GET /v1/responses/{id}`.

### The Responses stream

A request with `stream: true` gets the reply as a stream of named events,
as OpenAI streams it. Each event has an `event:` line equal to its `type`,
and one `data:` line of compact JSON whose `sequence_number` counts from
0, one more each time. In order:

1. `response.created`, then `response.in_progress`, each with the Response
   object in progress: `status: "in_progress"`, `output: []`,
   `usage: null` and `completed_at: null`;
2. `response.output_item.added`, which opens the message item at
   `output_index` 0, with `status: "in_progress"` and no content;
3. `response.content_part.added`, which opens its `output_text` part,
   still empty;
4. one `response.output_text.delta` per piece of the text, whose `delta`
   is the piece;
5. `response.output_text.done` with the whole `text`, then
   `response.content_part.done` with the whole part and
   `response.output_item.done` with the whole item;
6. for each [tool call](#function-call-items), its `function_call` item
   at the next `output_index`: added, its arguments in pieces, then done;
7. `response.completed` with the whole Response object, or
   `response.incomplete` when the Stub writes a stop reason
   ([Incomplete replies](#incomplete-replies)).

No `data: [DONE]` follows. The text is cut into pieces as for every API
([Chunks](llm-responses.md#chunks)). Empty text with no tool call keeps the
message item and its part, with no delta. With tool calls, empty text gives
no message item, so steps 2 to 5 are left out. A [mid-stream
error](llm-errors.md#mid-stream-errors) ends the stream early with an
`error` event, without the item's closing events, the function call items or
`response.completed`. Every event carries the same `resp_` id, and the
events of an item the same item id. The Response object of the last event is
the JSON reply, but for its `completed_at`: the time smock received the
request plus the stream's waits up to that event, in whole seconds
([Timing](llm-responses.md#timing)). Without `timing`, that is the time
received.

For the `hello` Stub above, the same request with `stream: true` gets this
stream, which `smock render` shows with the same seed and time:

```text
event: response.created
data: {"type":"response.created","response":{"id":"resp_oniRcSDFUU6bnxe66XwQR5pl","object":"response","access_programs":null,"created_at":1792713600,"status":"in_progress","completed_at":null,"error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":0}

  … response.in_progress, with the same Response object …

event: response.output_item.added
data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"in_progress","role":"assistant","content":[]},"sequence_number":2}

event: response.content_part.added
data: {"type":"response.content_part.added","item_id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[],"logprobs":[]},"sequence_number":3}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","output_index":0,"content_index":0,"delta":"Hi t","sequence_number":4,"logprobs":[]}

  … "here", "! Ho", "w ca", "n I ", "assi", "st y", "ou t", "oday", "?" …

event: response.output_text.done
data: {"type":"response.output_text.done","item_id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","output_index":0,"content_index":0,"text":"Hi there! How can I assist you today?","sequence_number":14,"logprobs":[]}

event: response.content_part.done
data: {"type":"response.content_part.done","item_id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]},"sequence_number":15}

event: response.output_item.done
data: {"type":"response.output_item.done","output_index":0,"item":{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]}]},"sequence_number":16}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_oniRcSDFUU6bnxe66XwQR5pl","object":"response","access_programs":null,"created_at":1792713600,"status":"completed","completed_at":1792713600,"error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":37,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48},"user":null,"metadata":{}},"sequence_number":17}

```

openai-python reads it with `client.responses.create(..., stream=True)`,
which yields each event, or with the `client.responses.stream(...)` helper,
whose `get_final_response()` gives the Response that the JSON reply gives.

### Function call items

An `openai-responses` reply sends each [tool
call](llm-tool-calls.md#tool-calls) as a `function_call` item, after its
message item. This Stub answers the first turn of an agent loop, told apart
by the [last item of `input`](matching.md#operators-in-json-conditions):

```yaml
mocks:
  - name: openai
stubs:
  - id: ask-weather
    mock: openai
    request:
      method: POST
      path: /v1/responses
      body: { json: { input: { $last: { role: user } } } }
    response:
      status: 200
      llm:
        api: openai-responses
        text: Let me check.
        toolCalls:
          - name: get_weather
            arguments: { city: Paris }
        usage: { input: 31, output: 18 }
```

`client.responses.create(model="gpt-6-astra", input=[{"role": "user", "content": "Weather in Paris?"}])`
gets this reply, which `smock render` shows with `--seed 7` and
`--time 2026-10-23T00:00:00Z`:

```json
{"id":"resp_oniRcSDFUU6bnxe66XwQR5pl","object":"response","access_programs":null,"created_at":1792713600,"status":"completed","completed_at":1792713600,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Let me check.","annotations":[],"logprobs":[]}]},{"type":"function_call","id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","call_id":"call_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":31,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":18,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":49},"user":null,"metadata":{}}
```

- `output` holds the message item, then one item per tool call, in the
  order written, with the members of the "Functions" example of OpenAI's
  API reference: `type: function_call`, `id`, `call_id`, `name`,
  `arguments` and `status: completed`. `arguments` is a JSON string, as
  for `openai-chat`.
- With tool calls and empty text, there is no message item: `output`
  holds the function call items alone, and a stream sends no text event,
  even when `chunks` gives empty pieces. Empty text without tool calls
  keeps the message item.
- An item's `id` is `fc_` and 24 generated characters: no field fixes it.
  Its `call_id` is `call_` and 24 characters, the same ones an
  `openai-chat` reply gives the call, or the tool call's `id` as written.
  [Ids, seeds and time](llm-responses.md#ids-seeds-and-time) says more.
- A written stop reason makes the reply [incomplete](#incomplete-replies),
  and its message item with it. The function call items stay
  `completed`.

In a stream, each tool call's item follows the message item, at the next
`output_index`:

1. `response.output_item.added`, with the item, `arguments: ""` and
   `status: "in_progress"`;
2. one `response.function_call_arguments.delta` per piece of the
   arguments, with `item_id`, `output_index` and the piece as `delta`;
3. `response.function_call_arguments.done`, with the whole `arguments`;
4. `response.output_item.done`, with the whole item, whose `id` and
   `call_id` are those of its `added`.

The arguments are cut as the text is, into pieces of `chunkSize` code
points, 4 by default; `chunks` does not apply to them. Each piece waits as a
piece of the text does ([Timing](llm-responses.md#timing)). The closing
event's Response holds every item, as the JSON reply does. For the Stub
above, the same request with `stream: true` gets these events after the
message item's:

```text
event: response.output_item.added
data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","call_id":"call_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","arguments":"","status":"in_progress"},"sequence_number":11}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","output_index":1,"delta":"{\"ci","sequence_number":12}

  … "ty\":", "\"Par" …

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","output_index":1,"delta":"is\"}","sequence_number":15}

event: response.function_call_arguments.done
data: {"type":"response.function_call_arguments.done","item_id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","output_index":1,"arguments":"{\"city\":\"Paris\"}","sequence_number":16}

event: response.output_item.done
data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","call_id":"call_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"},"sequence_number":17}

  … response.completed, whose output holds both items …
```

Checked with openai-python 3.36.1: `client.responses.create()` gives each
call as a `ResponseFunctionToolCall` in `response.output`, and the
`client.responses.stream(...)` helper's `get_final_response()` builds the
same items from the stream. When the agent sends the call's output back, a
second Stub
answers it:

```yaml
- id: answer-weather
  mock: openai
  request:
    method: POST
    path: /v1/responses
    body: { json: { input: { $last: { type: function_call_output } } } }
  response:
    status: 200
    llm: { api: openai-responses, text: It is 18°C in Paris. }
```

[A Responses loop](llm-tool-calls.md#a-responses-loop) quotes the call's
output in the reply, and [Responses
follow-ups](llm-tool-calls.md#responses-follow-ups) answers a request that
sends only that output.

### Incomplete replies

The Responses API has no stop word. For `openai-responses`, `stopReason`
is an incomplete reason instead: `max_output_tokens`, `max_messages`,
`content_filter` or `steered`. A reply that writes one is incomplete. Its
`status` is `incomplete`, `incomplete_details` gives the reason,
`completed_at` is `null`, and its message item's `status` is `incomplete`
too. A [function call item](#function-call-items) stays `completed`. Left
out, the reply is `completed`. The vendor sends `steered` only
after a steer over its WebSocket mode, which smock does not serve, and
smock accepts it as any word of the API. This Stub stands for a reply cut
short by the token limit:

```yaml
mocks:
  - name: openai
stubs:
  - id: truncated
    mock: openai
    request: { method: POST, path: /v1/responses }
    response:
      status: 200
      llm:
        api: openai-responses
        text: The weather in Paris is
        usage: { input: 31, output: 5 }
        stopReason: max_output_tokens
```

The same request gets this reply:

```json
{"id":"resp_oniRcSDFUU6bnxe66XwQR5pl","object":"response","access_programs":null,"created_at":1792713600,"status":"incomplete","completed_at":null,"error":null,"incomplete_details":{"reason":"max_output_tokens"},"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"incomplete","role":"assistant","content":[{"type":"output_text","text":"The weather in Paris is","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":31,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":5,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":36},"user":null,"metadata":{}}
```

A stream of an incomplete reply ends with `response.incomplete`, whose
Response object is the JSON reply above, `completed_at` null included.
openai-python's `client.responses.stream(...)` helper raises
`RuntimeError` in `get_final_response()` when the stream ends without
`response.completed`, as it does with OpenAI's own incomplete streams. So a
client reads the `response.incomplete` event instead:

```python
with client.responses.stream(model="gpt-6-astra", input="Hello!") as stream:
    for event in stream:
        if event.type == "response.incomplete":
            reason = event.response.incomplete_details.reason
```

A Stub moves between `openai-chat` and `openai-responses` by changing `api`
alone, unless it writes a stop reason that the other API does not have, or a
[mid-stream error](llm-errors.md#mid-stream-errors). Chat's `length` on
`openai-responses` is a load error at `stopReason`, so rewrite or drop it,
and an error's `type` is a load error there, so rename it `code`. The
reply's id keeps its 24 characters, with the other API's prefix, and the
request id stays the same.

## Anthropic Messages

With `api: anthropic-messages`, the reply takes the form of Anthropic's
Messages API. This Stub answers its path, `POST /v1/messages`:

```yaml
mocks:
  - name: anthropic
stubs:
  - id: hello
    mock: anthropic
    request: { method: POST, path: /v1/messages }
    response:
      status: 200
      llm:
        api: anthropic-messages
        text: Hello!
        usage: { input: 12, output: 6 }
```

anthropic-sdk-python reaches it with
`Anthropic(base_url="http://localhost:8080", api_key="test")`. The base
URL has no `/v1`, since the SDK adds it. A request for `claude-test` gets
one `message` body, such as this one, which `smock render` shows with
`--seed 7` and `--time 2026-10-23T00:00:00Z`:

```json
{"id":"msg_oniRcSDFUU6bnxe66XwQR5pl","type":"message","role":"assistant","content":[{"type":"text","text":"Hello!"}],"model":"claude-test","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":6}}
```

- Its members and their order follow the replies in Anthropic's guide on
  working with messages. `content` holds the text block, with the text,
  then a `tool_use` block per [tool call](#messages-tool-calls). Empty text
  with no tool call gives an empty reply: `content` is `[]`, with no block.
- `usage` gives `input` as `input_tokens` and `output` as
  `output_tokens`, with no total and no cache counts.
- The reply's id is `msg_` and 24 characters, unless `id` fixes it. smock
  adds a `request-id: req_…` header, not `x-request-id`, unless the Stub
  gives its own `request-id`. [Ids, seeds and
  time](llm-responses.md#ids-seeds-and-time) says more.
- A request with `stream: true` gets the reply as named events
  ([Messages streams](#messages-streams)).
- Ollama's Anthropic compatibility offers the same path, so the Stub
  stands in for it too.

`stopReason` takes Anthropic's words: `end_turn`, `max_tokens`,
`stop_sequence`, `tool_use`, `pause_turn`, `refusal` and
`model_context_window_exceeded`. Left out, it is `tool_use` when the reply
has [tool calls](#messages-tool-calls), and `end_turn` otherwise. A word of
another API, such as `stop`, is a load error. Two words add a member:

- With `stop_sequence`, the reply's `stop_sequence` is the first element
  of the request's `stop_sequences`, when that is a string. Otherwise it
  is `null`, as it is with every other stop reason. smock does not search
  the text for the sequences, so it gives the first one, whichever would
  have matched.
- With `refusal`, the reply also carries
  `"stop_details":{"type":"refusal","category":null,"explanation":null}`,
  after `stop_sequence`, and so does the stream's `message_delta`. Any
  other stop reason leaves `stop_details` out.
  A refusal with empty text has no block, as the vendor's has none.

This Stub stands for a refusal, and the reply it gives:

```yaml
- id: refused
  mock: anthropic
  request:
    method: POST
    path: /v1/messages
    headers: { X-Test-Case: refused }
  response:
    status: 200
    llm: { api: anthropic-messages, stopReason: refusal }
```

```json
{"id":"msg_oniRcSDFUU6bnxe66XwQR5pl","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":null,"explanation":null},"usage":{"input_tokens":0,"output_tokens":0}}
```

A Stub without `stopReason` moves between `openai-chat` and
`anthropic-messages` by changing `api` alone. Its seed gives the same ids,
behind the other API's prefix: `chatcmpl-oniRcSDFUU6bnxe66XwQR5pl` becomes
`msg_oniRcSDFUU6bnxe66XwQR5pl`, a call id `call_…` becomes `toolu_…`, and
the request id stays the same, in the other header. A written stop reason
must be rewritten in the other API's word, and a [mid-stream
error](llm-errors.md#mid-stream-errors)'s `type` must be one of Anthropic's
error types.

### Messages streams

A request with `stream: true` gets the reply as Anthropic streams it: a
series of named events. Each event is an `event:` line that names it, then
one `data:` line of compact JSON whose `type` is the same name.
anthropic-sdk-python skips an event that has no `event:` line, so every
event has one. In order:

1. `message_start`, with the message: its id and model, no content yet,
   `stop_reason` and `stop_sequence` null, and `usage` with the
   `input_tokens`, and `output_tokens` 0;
2. for the text, a text block at `index` 0: `content_block_start`, with an
   empty text, then one `content_block_delta` per piece, whose
   `text_delta` gives the piece, then `content_block_stop`;
3. for each [tool call](#messages-tool-calls), a `tool_use` block at the
   next `index`: `content_block_start`, with the call id, the name and an
   empty `input`, then a `content_block_delta` whose `input_json_delta`
   gives an empty `partial_json`, one more per piece of the arguments,
   then `content_block_stop`;
4. `message_delta`, whose `delta` gives `stop_reason` and `stop_sequence`,
   and `stop_details` on a refusal, and whose `usage` gives the
   `output_tokens`;
5. `message_stop`.

There is no `ping` event, no SSE comment line and no `data: [DONE]`. The
text is cut into pieces as for every API
([Chunks](llm-responses.md#chunks)). Empty text has no text block, even when
`chunks` gives empty pieces: with no tool call, the stream is
`message_start`, `message_delta` and `message_stop`, as the JSON reply's
`content` is `[]`. A [mid-stream error](llm-errors.md#mid-stream-errors)
ends the stream early with an `error` event, without `content_block_stop`,
`message_delta` or `message_stop`. [`timing`](llm-responses.md#timing) waits
before each text delta and each piece of a tool call's arguments, and a
reply with no piece waits `first` before `message_delta`. From these events,
`messages.stream()` in anthropic-sdk-python builds the message that the JSON
reply gives, and `get_final_message()` returns it, as long as each tool
call's arguments are a JSON object ([Broken
arguments](llm-tool-calls.md#broken-arguments)).

For the `hello` Stub above, a request for `claude-test` with
`stream: true` gets this stream, which `smock render` shows with the same
seed and time:

```text
event: message_start
data: {"type":"message_start","message":{"id":"msg_oniRcSDFUU6bnxe66XwQR5pl","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hell"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"o!"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":6}}

event: message_stop
data: {"type":"message_stop"}

```

### Messages tool calls

An `anthropic-messages` reply sends each of its [tool
calls](llm-tool-calls.md#tool-calls) as a `tool_use` block, after the text
block, as the reply in Anthropic's guide on handling tool calls does. This
Stub answers with text and a call of `get_weather`:

```yaml
- id: ask-weather
  mock: anthropic
  request:
    method: POST
    path: /v1/messages
    headers: { X-Test-Case: ask-weather }
  response:
    status: 200
    llm:
      api: anthropic-messages
      text: Let me check.
      toolCalls:
        - name: get_weather
          arguments: { city: Paris }
      usage: { input: 31, output: 18 }
```

A request for `claude-test` without `stream` gets this reply, which
`smock render` shows with `--seed 7` and `--time 2026-10-23T00:00:00Z`:

```json
{"id":"msg_oniRcSDFUU6bnxe66XwQR5pl","type":"message","role":"assistant","content":[{"type":"text","text":"Let me check."},{"type":"tool_use","id":"toolu_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","input":{"city":"Paris"}}],"model":"claude-test","stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":31,"output_tokens":18}}
```

- Each block is `{"type":"tool_use","id","name","input"}`, in the order
  the calls are written.
- Its id is `toolu_` and the 24 characters of the call id's slot, unless
  the call's `id` fixes it. The same Stub under `openai-chat` sends
  `call_oLxN2ar43pJJV6rqKHXsG45M`.
- `input` is an object in every reply of the vendor. An object in
  `arguments` is the `input`. A string that holds a JSON object, such as
  `'{"city": "Paris"}'`, is sent as that object. Any other string is sent
  as a JSON string ([Broken arguments](llm-tool-calls.md#broken-arguments)).
- With tool calls, empty text has no text block, so the first `tool_use`
  block is the first block.
- Left out, the stop reason is `tool_use`.

In a [stream](#messages-streams), each tool call is a block at the next
`index`, after the text block. `content_block_start` gives the call id, the
name and an empty `input`. A `content_block_delta` follows whose
`input_json_delta` has an empty `partial_json`, as in Anthropic's examples,
then one per piece of the arguments, then `content_block_stop`. The
arguments' text is cut into pieces of `chunkSize` code points, as the text
is; `chunks` does not apply to it. Each piece
[waits](llm-responses.md#timing) as a piece of the text does, and the empty
first one does not. anthropic-sdk-python joins the pieces of each block and
parses them into its `input`. The same request with `stream: true` gets
these events after the text block:

```text
event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"ci"}}

  … "ty\":", "\"Par" …

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"is\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":18}}

event: message_stop
data: {"type":"message_stop"}

```
