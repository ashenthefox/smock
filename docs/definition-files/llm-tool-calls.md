# Tool calls and agent loops

This part of the [Definition-file reference](../definition-files.md)
describes the tool calls of an LLM response, and the Stubs that answer
each turn of an agent's tool loop, for each API. It builds on [LLM
responses](llm-responses.md), which describes the `llm` field, its `api`
and its other fields, streams, ids and templates.

## Contents

- [Tool calls](#tool-calls)
  - [Broken arguments](#broken-arguments)
- [Agent loops](#agent-loops)
  - [A Chat Completions loop](#a-chat-completions-loop)
  - [A Messages loop](#a-messages-loop)
  - [A Responses loop](#a-responses-loop)
  - [Responses follow-ups](#responses-follow-ups)
  - [Conversations of several turns](#conversations-of-several-turns)

## Tool calls

`toolCalls` declares the function tool calls of the reply, so that an
agent's tool loop runs against smock. This Stub answers a conversation whose
[last message](matching.md#operators-in-json-conditions) is the user's with
text and a call of `get_weather`:

```yaml
mocks:
  - name: openai
stubs:
  - id: ask-weather
    mock: openai
    request:
      method: POST
      path: /v1/chat/completions
      body: { json: { messages: { $last: { role: user } } } }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Let me check.
        toolCalls:
          - name: get_weather
            arguments: { city: Paris }
        usage: { input: 31, output: 18 }
```

Each tool call has these fields:

| Field | Value | When left out |
|---|---|---|
| `name` | the function's name, non-empty text | required |
| `arguments` | a JSON object, or a string sent as written | required |
| `id` | the call id, sent as written | generated |

- The text comes first, then each tool call in the order written.
- An object in `arguments` is written as compact JSON, its members in the
  order written and its numbers as a `json` body writes them. A string is
  sent exactly as written, so a test can send
  [arguments that are not valid JSON](#broken-arguments).
- smock checks no `name` against a vendor's naming rule, and no
  `arguments` against the request's `tools`.
- With tool calls, empty text gives no content: `content` is `null` in the
  JSON reply and in the stream's opening chunk, and no chunk carries
  content, even when `chunks` gives empty pieces. So openai-python's
  stream helper builds the same message from the stream as from the JSON
  reply. An `openai-responses` reply has no message item then, and an
  `anthropic-messages` reply no text block.
- Left out, the [stop reason](llm-responses.md#usage-and-stop-reasons) is
  `tool_calls`, or `tool_use` for `anthropic-messages`. A written one is
  sent whatever the reply holds.
- A missing `name` or `arguments`, an empty `name`, `arguments` that are
  neither an object nor a string, an unknown field of a tool call, and two
  tool calls of one `llm` with the same `id` are load errors. With
  [templates](llm-responses.md#templates-in-llm-replies), ids that insert a
  value are compared after rendering.
- `openai-responses` sends them as [function call
  items](llm-apis.md#function-call-items), and `anthropic-messages` as
  `tool_use` blocks ([Messages tool
  calls](llm-apis.md#messages-tool-calls)).

A request for `gpt-6-astra` without `stream` gets this reply, which
`smock render` shows with `--seed 7` and `--time 2026-10-23T00:00:00Z`.
The message gives `tool_calls` after its content, each call's arguments
as a JSON string:

```json
{"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"message":{"role":"assistant","content":"Let me check.","tool_calls":[{"id":"call_oLxN2ar43pJJV6rqKHXsG45M","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}],"refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":31,"completion_tokens":18,"total_tokens":49,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
```

In a [stream](llm-responses.md#streams), the text's pieces come first. Then
each tool call, counted from 0 as its `index`, opens with a chunk that gives
its `index`, its call id, `type: function`, its name and empty arguments.
One chunk follows per piece of its arguments, with the `index` and the piece
alone. The arguments are cut as the text is, into pieces of `chunkSize` code
points, 4 by default; `chunks` does not apply to them. Every tool-call chunk
carries the integer `index`, so openai-python joins the pieces of each call.
The same request with `stream: true` gets these events after the text's
pieces:

```text
  … "Let ", "me c", "heck", "." …

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_oLxN2ar43pJJV6rqKHXsG45M","type":"function","function":{"name":"get_weather","arguments":""}}]},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"ci"}}]},"logprobs":null,"finish_reason":null}]}

  … "ty\":", "\"Par" …

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"is\"}"}}]},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"tool_calls"}]}

data: [DONE]

```

Call ids follow the rules of [Ids, seeds and
time](llm-responses.md#ids-seeds-and-time):

- A tool call's call id is `call_` and 24 characters, or `toolu_` and 24
  characters for `anthropic-messages`, the same in every event of a
  stream, unless `id` fixes it. smock sends a fixed id exactly as written,
  with no prefix.
- Each tool call draws two slots of the ids' order, after the reply's and
  before the request id's. `openai-chat` sends the second as the call id.
  `openai-responses` sends the first as its function call item's `fc_` id
  and the second as its `call_id`. `anthropic-messages` sends the second
  as the `tool_use` id. So a Stub that moves between the APIs keeps the 24
  characters of each call id. Adding a tool call changes the request id,
  and not the reply's id.
- A fixed `id` still draws its slots, so fixing one call id changes no
  other id.
- The call ids of one reply must differ, so two tool calls of one `llm`
  with the same `id` are a load error. Templated ids that render the same
  give the [template error](llm-responses.md#templates-in-llm-replies) 500.

When the agent sends the tool's result back, a second Stub answers it. A
condition on the last message tells the turns apart, as the [`$last`
examples](matching.md#operators-in-json-conditions) show for each API:

```yaml
- id: answer-weather
  mock: openai
  request:
    method: POST
    path: /v1/chat/completions
    body: { json: { messages: { $last: { role: tool } } } }
  response:
    status: 200
    llm: { api: openai-chat, text: It is 18°C in Paris. }
```

[Agent loops](#agent-loops) shows the whole loop for each API, with a
reply that quotes the tool's result.

### Broken arguments

A model can send arguments that are not valid JSON, and an agent should
survive them. Give `arguments` as a string to send it exactly as written:

```yaml
- id: broken-arguments
  mock: openai
  request:
    method: POST
    path: /v1/chat/completions
    headers: { X-Test-Case: broken-arguments }
  response:
    status: 200
    llm:
      api: openai-chat
      toolCalls:
        - name: get_weather
          arguments: '{"city": "Par'
```

The JSON reply's call has `"arguments":"{\"city\": \"Par"`, and a stream
sends the same text in pieces. smock does not check it. Checked with
openai-python 3.36.1: `chat.completions.create()` returns the arguments as
the string they are, so the agent's own `json.loads` raises
`JSONDecodeError`. `chat.completions.parse()` and the
`chat.completions.stream()` helper parse the arguments of a strict
function tool, such as one made with `openai.pydantic_function_tool`, and
raise pydantic's `ValidationError`.

Under `api: anthropic-messages`, the vendor's `input` is always an object,
and smock sends a string that holds a JSON object as that object. Any
other string, such as this one, is sent as a JSON string: the JSON reply's
`tool_use` block has `"input":"{\"city\": \"Par"`. A stream sends the
text as written, in `partial_json` pieces, so a client that reads the raw
events sees it exactly. The vendor never sends such a stream. Checked with
anthropic-sdk-python 2.1.0:

- `messages.create()` returns the string as the block's `input`. With
  `stream=True`, it yields the events with their pieces as written.
- `messages.stream()` parses the pieces of each block as they arrive, as
  partial JSON. On arguments that are not JSON, such as `not JSON`, it
  raises `ValueError` mid-stream, as it would on such a vendor stream.
- JSON cut short, such as the Stub's above, is no error to it: the block's
  `input` is what has arrived whole, here `{}`.

## Agent loops

An agent sends the whole conversation in each request. When the model calls
a tool, the agent runs the tool and sends the conversation again, with the
tool's result as its last message. The model then answers with text, or
calls another tool. Two Stubs follow this loop: the first calls the tool,
and the second answers once the last message is the tool's result. A
[`$last` condition](matching.md#operators-in-json-conditions) tells the two
requests apart, and the second Stub quotes the result with
[`last()`](template-helpers.md#arrays), in a
[template](llm-responses.md#templates-in-llm-replies). Each API sends the
result in its own form:

| `api` | The last message is the tool's result when | The result in a template |
|---|---|---|
| `openai-chat` | `messages: { $last: { role: tool } }` | `last(body.messages).content` |
| `anthropic-messages` | `messages: { $last: { role: user, content: { $includes: { type: tool_result } } } }` | `find(last(body.messages).content, 'type', 'tool_result').content` |
| `openai-responses` | `input: { $last: { type: function_call_output } }` | `last(body.input).output` |

- The first Stub takes the same condition under `$not`, so it answers
  every other request to its path, and the two never both match.
  `$last: { role: user }` would not do for every API: Anthropic sends a
  tool's result in a user message, and a Responses request often gives
  `input` as a string, which never meets `$last`.
- A user message can hold text after its tool results, so the Messages
  template finds the `tool_result` block rather than taking the last one.
- The result is inserted as text when the agent sends it as a string, as the
  vendors' examples do. A result sent as an array of content blocks is an
  array, which a text template inserts only with `json(x)`; otherwise the
  request gets the [500 `template
  failed`](templates.md#missing-values-and-render-errors).
- smock checks no request against its `tools`, so the Stubs need none,
  and neither do the sketches below. The sketches were checked with
  openai-python 3.37.0 and anthropic-sdk-python 2.1.0.

### A Chat Completions loop

```yaml
mocks:
  - name: openai
stubs:
  - id: ask-weather
    mock: openai
    request:
      method: POST
      path: /v1/chat/completions
      body: { json: { messages: { $not: { $last: { role: tool } } } } }
    response:
      status: 200
      llm:
        api: openai-chat
        toolCalls:
          - name: get_weather
            arguments: { city: Paris }
  - id: answer-weather
    mock: openai
    request:
      method: POST
      path: /v1/chat/completions
      body: { json: { messages: { $last: { role: tool } } } }
    response:
      status: 200
      template: true
      llm:
        api: openai-chat
        text: It is ${last(body.messages).content} in Paris.
```

An agent built on openai-python runs the loop like this:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8080/v1", api_key="test")
messages = [{"role": "user", "content": "Weather in Paris?"}]
first = client.chat.completions.create(model="gpt-6-astra", messages=messages)
call = first.choices[0].message.tool_calls[0]
messages.append(first.choices[0].message)
messages.append({"role": "tool", "tool_call_id": call.id, "content": "18°C"})
second = client.chat.completions.create(model="gpt-6-astra", messages=messages)
print(second.choices[0].message.content)  # It is 18°C in Paris.
```

The second request's last message is
`{"role":"tool","tool_call_id":"call_…","content":"18°C"}`, so
`answer-weather` answers it, and quotes `18°C`.

### A Messages loop

```yaml
mocks:
  - name: anthropic
stubs:
  - id: ask-weather
    mock: anthropic
    request:
      method: POST
      path: /v1/messages
      body:
        json:
          messages:
            $not:
              $last: { role: user, content: { $includes: { type: tool_result } } }
    response:
      status: 200
      llm:
        api: anthropic-messages
        toolCalls:
          - name: get_weather
            arguments: { city: Paris }
  - id: answer-weather
    mock: anthropic
    request:
      method: POST
      path: /v1/messages
      body:
        json:
          messages:
            $last: { role: user, content: { $includes: { type: tool_result } } }
    response:
      status: 200
      template: true
      llm:
        api: anthropic-messages
        text: "It is ${find(last(body.messages).content, 'type', 'tool_result').content} in Paris."
```

With anthropic-sdk-python:

```python
from anthropic import Anthropic

client = Anthropic(base_url="http://localhost:8080", api_key="test")
messages = [{"role": "user", "content": "Weather in Paris?"}]
first = client.messages.create(model="claude-test", max_tokens=1024, messages=messages)
call = first.content[0]
messages.append({"role": "assistant", "content": first.content})
messages.append({"role": "user", "content": [
    {"type": "tool_result", "tool_use_id": call.id, "content": "18°C"},
]})
second = client.messages.create(model="claude-test", max_tokens=1024, messages=messages)
print(second.content[0].text)  # It is 18°C in Paris.
```

The first reply has no text, so its `tool_use` block is `content[0]`.
The second request's last message is the user's, and holds the
`tool_result` block, so `answer-weather` answers it.

### A Responses loop

```yaml
mocks:
  - name: openai
stubs:
  - id: ask-weather
    mock: openai
    request:
      method: POST
      path: /v1/responses
      body: { json: { input: { $not: { $last: { type: function_call_output } } } } }
    response:
      status: 200
      llm:
        api: openai-responses
        toolCalls:
          - name: get_weather
            arguments: { city: Paris }
  - id: answer-weather
    mock: openai
    request:
      method: POST
      path: /v1/responses
      body: { json: { input: { $last: { type: function_call_output } } } }
    response:
      status: 200
      template: true
      llm:
        api: openai-responses
        text: It is ${last(body.input).output} in Paris.
```

With openai-python, the agent sends the whole conversation as `input`
items:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8080/v1", api_key="test")
first = client.responses.create(model="gpt-6-astra", input="Weather in Paris?")
call = first.output[0]
items = [{"role": "user", "content": "Weather in Paris?"}, *first.output]
items.append({"type": "function_call_output", "call_id": call.call_id, "output": "18°C"})
second = client.responses.create(model="gpt-6-astra", input=items)
print(second.output_text)  # It is 18°C in Paris.
```

The first request gives `input` as a string, which `ask-weather` answers.
The first reply has no text, so its function call item is `output[0]`.
The second request's last item is the call's output, so `answer-weather`
answers it.

### Responses follow-ups

A Responses request can name an earlier Response with
`previous_response_id`, and send only the new items. The vendor then
reads the earlier turns from its store. smock keeps no Responses state:
it only copies `previous_response_id` into the reply. A follow-up is an
ordinary request, so a body condition on `previous_response_id` answers
it. When the first reply's `id` is fixed, the follow-up can name it:

```yaml
mocks:
  - name: openai
stubs:
  - id: ask-weather
    mock: openai
    request:
      method: POST
      path: /v1/responses
      body: { json: { previous_response_id: { $exists: false } } }
    response:
      status: 200
      llm:
        api: openai-responses
        id: resp_weather
        toolCalls:
          - name: get_weather
            arguments: { city: Paris }
  - id: answer-weather
    mock: openai
    request:
      method: POST
      path: /v1/responses
      body: { json: { previous_response_id: resp_weather } }
    response:
      status: 200
      template: true
      llm:
        api: openai-responses
        text: It is ${last(body.input).output} in Paris.
  - id: get-weather
    mock: openai
    request: { method: GET, path: /v1/responses/resp_weather }
    response:
      status: 200
      llm:
        api: openai-responses
        id: resp_weather
        model: gpt-6-astra
        toolCalls:
          - name: get_weather
            arguments: { city: Paris }
```

```python
first = client.responses.create(model="gpt-6-astra", input="Weather in Paris?")
call = first.output[0]
second = client.responses.create(
    model="gpt-6-astra",
    previous_response_id=first.id,
    input=[{"type": "function_call_output", "call_id": call.call_id, "output": "18°C"}],
)
print(second.output_text)  # It is 18°C in Paris.
print(second.previous_response_id)  # resp_weather
print(client.responses.retrieve(first.id).output[0].name)  # get_weather
```

- The follow-up sends only the call's output, so its last item is that
  output, and the template quotes it as in the loop above.
- A follow-up of another id matches no Stub, and gets the Mock's
  [`noMatch` reply](matching.md#when-no-stub-matches).
- `client.responses.retrieve()` sends `GET /v1/responses/{id}`. smock
  does not store the first reply, so an ordinary Stub answers it. This one
  gives the same `id` and tool call. A GET has no body, so it gets the JSON
  reply, and its Stub gives `model`, which no request names. Its
  `created_at` and the ids it does not fix are new.

When the first reply's id is generated, a follow-up cannot name it. Then
`previous_response_id: { $exists: true }` answers any follow-up, and a
[Scenario](scenarios.md#scenarios) tells which turn it follows:

```yaml
mocks:
  - name: openai
stubs:
  - id: ask-weather
    mock: openai
    request:
      method: POST
      path: /v1/responses
      body: { json: { previous_response_id: { $exists: false } } }
    scenario: { name: weather, moveTo: Asked }
    response:
      status: 200
      llm:
        api: openai-responses
        toolCalls:
          - name: get_weather
            arguments: { city: Paris }
  - id: answer-weather
    mock: openai
    request:
      method: POST
      path: /v1/responses
      body: { json: { previous_response_id: { $exists: true } } }
    scenario: { name: weather, requires: Asked, moveTo: Answered }
    response:
      status: 200
      template: true
      llm:
        api: openai-responses
        text: It is ${last(body.input).output} in Paris.
```

The same agent gets the same answer. A follow-up before the question, or
after the answer, matches no Stub, since `answer-weather` requires
`Asked`. A Stub that requires `Answered` would answer the next turn, as
[Conversations of several turns](#conversations-of-several-turns) shows.

### Conversations of several turns

A conversation goes on after the answer. When the user asks again, the last
message is the user's once more, as on the first turn, so the messages alone
do not say which turn it is. A [Scenario](scenarios.md#scenarios) follows
the turns, and a [Variable](variables.md#variables) counts them:

```yaml
mocks:
  - name: openai
stubs:
  - id: ask-weather
    mock: openai
    request:
      method: POST
      path: /v1/chat/completions
      body: { json: { messages: { $not: { $last: { role: tool } } } } }
    scenario: { name: weather, requires: Started, moveTo: Asked }
    variables: { turns: "${add(vars.turns ?? 0, 1)}" }
    response:
      status: 200
      llm:
        api: openai-chat
        toolCalls:
          - name: get_weather
            arguments: { city: Paris }
  - id: answer-weather
    mock: openai
    request:
      method: POST
      path: /v1/chat/completions
      body: { json: { messages: { $last: { role: tool } } } }
    scenario: { name: weather, requires: Asked, moveTo: Answered }
    variables: { turns: "${add(vars.turns ?? 0, 1)}" }
    response:
      status: 200
      template: true
      llm:
        api: openai-chat
        text: It is ${last(body.messages).content} in Paris.
  - id: next-question
    mock: openai
    request:
      method: POST
      path: /v1/chat/completions
      body: { json: { messages: { $not: { $last: { role: tool } } } } }
    scenario: { name: weather, requires: Answered }
    variables: { turns: "${add(vars.turns ?? 0, 1)}" }
    response:
      status: 200
      template: true
      llm:
        api: openai-chat
        text: Turn ${vars.turns}. Ask me about another city.
```

The agent of [the Chat Completions loop](#a-chat-completions-loop) gets
the tool call, then `It is 18°C in Paris.` When it then appends the
answer and the user's next question, the third request gets
`Turn 3. Ask me about another city.`

- `ask-weather` and `next-question` have the same request conditions.
  Their `requires` tell them apart, so neither shadows the other
  ([Warnings](../definition-files.md#a-stub-that-can-never-match)).
- Each Stub adds one to `turns`, and the reply reads the new count, since a
  response sees the Variables its Stub has just written. A test can also
  read the count through the [Admin
  API](variables.md#through-the-admin-api), or count the Journal's entries.
- The state and the count belong to the
  [Session](../admin-api.md#sessions-and-ephemeral-stubs). Give each test
  its own Session, or reset it, so that each conversation starts in
  `Started` with no count. Requests without a Session share one state
  and one count.
- The same Stubs work for the other APIs with their own
  [conditions](#agent-loops), and for Responses follow-ups with
  `previous_response_id: { $exists: true }`.
