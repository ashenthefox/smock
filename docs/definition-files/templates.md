# Templates

This document of the [Definition-file reference](../definition-files.md)
describes templates: what they insert, how they escape and fail, and what
`smock render` shows. The helpers that a template calls, and the Variables
and Data buckets that it reads as `vars.NAME` and `data.NAME`, have
documents of their own: [Template helpers](template-helpers.md),
[Variables](variables.md) and [Data buckets](data-buckets.md).

With `template: true`, a response is rendered for each request: its body
and header values can take values from the request, loop over them, branch
on them and include fake data. Templates are parsed when the Definition
files are loaded, so a syntax error is reported by `smock check`, stops
`smock serve` at startup, and makes a reload keep the definitions it
serves, like any other problem; an Ephemeral Stub with one is refused with
400.

```yaml
- id: get-user
  mock: users
  request: { method: GET, path: { pattern: "/users/[0-9]+" } }
  response:
    status: 200
    template: true
    headers:
      X-Request-Id: ${header.x-request-id ?? 'none'}
    json:
      id: ${path[1]}
      lang: ${query.lang ?? 'en'}
      requestId: ${header.x-request-id ?? 'none'}
```

`GET /users/42?lang=ja` with `X-Request-Id: req-7` gets `X-Request-Id:
req-7`, `Content-Type: application/json` and
`{"id":"42","lang":"ja","requestId":"req-7"}`; without the query and the
header, `X-Request-Id: none` and `{"id":"42","lang":"en","requestId":"none"}`.

What is a template with `template: true`:

- `json` is a structured template, and so is the `json` of each event.
- `body`, a body file (`bodyFile`, which must then be UTF-8) and the
  `data`, `id` and `event` of each event are text templates.
- Header values are text templates, each value of an array on its own,
  except `Content-Type`, which must not contain `${`. An array's length is
  fixed: a template cannot add or drop a field.
- In `llm`, the text, each chunk, `id`, `model` and each tool call's `name`,
  `id` and `arguments` are templates, as [Templates in LLM
  replies](llm-responses.md#templates-in-llm-replies) says.
- A gRPC Stub's `grpc.message` is a text template. The control characters
  it renders are kept, then percent-encoded
  ([The status of a gRPC reply](grpc.md#the-status-of-a-grpc-reply)).
- A gRPC Stub's `grpc.trailers` values are text templates, rendered as
  header values are, after the message. A rendered value of its headers
  or trailers that gRPC's rules refuse fails the call
  ([gRPC reply metadata](grpc.md#grpc-reply-metadata)).
- Each of a gRPC Stub's `grpc.details` is a structured template, rendered
  after the trailers, then encoded. A rendered detail that does not fit its
  type fails the call ([gRPC error details](grpc.md#grpc-error-details)).
- `status`, a gRPC Stub's `grpc.status` and an event's `delay` are never
  templated.

With `template` off, nothing is parsed or rendered: `${` is plain text and
`$each` a plain key.

## Contents

- [Inserting values](#inserting-values)
- [Structured templates](#structured-templates)
- [Template helpers](template-helpers.md)
- [Escaping and line breaks](#escaping-and-line-breaks)
- [Missing values and render errors](#missing-values-and-render-errors)
- [Environment variables](#environment-variables)
- [Variables](variables.md)
- [Errors when loading](#errors-when-loading)
- [Rendering a template](#rendering-a-template)
  - [Rendering a CRUD Stub](#rendering-a-crud-stub)

## Inserting values

`${ expr }` inserts a value, and `$${` writes a literal `${`; a `$` before
anything else is plain text. In YAML, a value can start with `${` in block
style without quotes (`id: ${path[1]}`); quote it in flow style
(`{ id: "${path[1]}" }`) and when the expression contains `: ` or ` #`. In
JSON, `${…}` sits in an ordinary string; string literals in an expression
may use single quotes (`"${query.lang ?? 'en'}"`).

An expression is a value, a request field, a literal (`'text'` or `"text"`
with the escapes `\'`, `\"` and `\\`, a JSON number, `true`, `false` or
`null`) or a helper call, optionally followed by fallbacks: `a ?? b` is `a`
when `a` is present, otherwise `b`. There are no arithmetic operators, no
string operators and no user-defined functions:
[helpers](template-helpers.md#template-helpers) do that work, such as
`add(a, b)`. The words `for`, `if`, `else`, `end`, `each` and `params` are
reserved.

| Name | Value |
|---|---|
| `method` | The request method, such as `GET`. |
| `path` | The percent-decoded path without the query, as conditions compare it. |
| `path[n]` | Segment `n` of that path, counted from 0 after the leading `/`: for `/users/42`, `path[0]` is `users` and `path[1]` is `42`. |
| `query.NAME` | The first decoded value of the query parameter. |
| `header.NAME` | The first value of the header, its name compared case-insensitively; each field line is one value. |
| `cookie.NAME` | The first value of the cookie, read from every `Cookie` field as [cookie conditions](matching.md#cookies) read it. |
| `body` | The body parsed as JSON. `body.a.b`, `body.items[0]` and `body['odd.key']` walk into it. |
| `bodyText` | The body as text; bytes that are not UTF-8 become U+FFFD. |
| `env.NAME` | The value of an environment variable that `--template-env` lists, as a string; see [Environment variables](#environment-variables). |
| `vars.NAME` | The [Variable](variables.md#variables) `NAME` of the request's Mock and Session, with its own type. `vars.cart.items[0]` walks into it. |
| `data.NAME` | The [Data bucket](data-buckets.md#data-buckets) `NAME` of the Stub's Mock, with its own type. `data.orders[0].id` walks into it. |
| `loop.index` | The position in the innermost `$each`, from 0. |
| a loop variable | The current element of the `$each` that names it with `as`. |

A name in a reference is ASCII letters, digits, `_` and `-`; write any other
name as `['…']`, such as `query['page size']`.

`cookie.NAME` reads cookies exactly as a cookie condition does, so what a
condition matched is what a template inserts:

- Every `Cookie` field counts. Each is split on `;`, and each part is
  trimmed of spaces and tabs.
- The first `=` of a part separates the name from the value. A part
  without `=` holds no cookie.
- Names are compared exactly, case and all.
- Values stay as sent: quotes are kept, and nothing is percent-decoded. So
  `Cookie: session="s1"` gives `"s1"` with its quotes.
- An absent cookie is missing, so `??` gives a fallback, as in
  `${cookie.session ?? null}`.

```yaml
json:
  session: ${cookie.session ?? null}
  themes: { $each: cookie.theme, as: t, do: "${t}" }
```

A request with `Cookie: theme=dark; session="s1"` and a second line
`Cookie: theme=light` gets `{"session":"\"s1\"","themes":["dark","light"]}`.

A helper call can be followed by steps into what it gives, as `body` can:
`.name`, `[n]` and `['name']`. `${range(1, 3)[1]}` gives `2`. A step into
what is not an object or an array, or past its end, gives a missing value,
so `??` applies: `${range(1, 3)[5] ?? 'none'}` gives `none`.

## Structured templates

In `json`:

- A string that is exactly one `${expr}` gives the value with its own type:
  a number stays a number and an object stays an object. Any other string
  gives a string, each value written as text.
- `{ "$each": expr, "as": name, "do": template }` gives an array, one
  element per item. It walks an array (from `body` or a loop variable),
  every value of a query parameter, a header or a cookie (none when it is
  absent), or `range(a, b)`. The name in `as` cannot be a request field
  (`method`, `path`, `query`, `header`, `cookie`, `body` or `bodyText`),
  `env`, `vars`, `data`, `loop` or a reserved word.
- `{ "$if": cond, "then": template, "else": template }` gives `then` or
  `else`. Without `else`, a false condition leaves the member or the array
  element out; at the root of `json`, `else` is required. A condition is
  an expression, optionally negated with `!` and compared with a literal
  with `==` or `!=`. It is true when the value is present and neither
  `null` nor `false`; strings compare exactly and numbers by value, and a
  string never equals a number.
- An object with `$each` or `$if` has only the keys listed for it. Other
  keys that start with `$` are reserved: write `$$name` for the key
  `$name`. Keys are never templated.
- The output is compact JSON in UTF-8, members in the order written, with
  numbers written as for a [JSON body](responses.md#json-bodies).

```yaml
json:
  orderId: ${fake.uuid()}
  customer: ${body.customer.name}
  lines:
    $each: body.items
    as: item
    do:
      sku: ${item.sku}
      qty: ${item.qty}
      status:
        $if: item.qty == 0
        then: backordered
        else: reserved
```

Text templates have no loops and no conditionals.

## Escaping and line breaks

- In `json`, smock writes the JSON itself, so every string is escaped.
- In `body` and a body file, inserted values are escaped by the media type
  of the response's `Content-Type`, compared case-insensitively and
  without its parameters: for `application/json` and `*/*+json`, as the
  content of a JSON string (write `json(x)` for a value outside a string,
  which is not escaped again); for `text/html`, `text/xml`,
  `application/xml` and `*/*+xml`, `&`, `<`, `>`, `"` and `'` become
  character references (also in the output of `json(x)`); for any other
  type, or none, not at all. `raw(x)` is never escaped. A `text/html` body
  file with `<p>Hello, ${query.name ?? 'guest'}</p>` answers
  `?name=<b>Ann</b>` with `<p>Hello, &lt;b&gt;Ann&lt;/b&gt;</p>`.
- In text, a string is written as it is, a number as in `json`, and `true`,
  `false` and `null` as those words; an object or an array needs `json(x)`.
- In a header value, every control character except tab, CR and LF
  included, becomes a space after rendering, so a value never adds a line
  to the response head. In an event's `id` and `event`, every control
  character becomes a space. An event's `data` is written as rendered, so
  a value with line breaks gives several `data:` lines.

## Missing values and render errors

A reference is missing when it names nothing: an absent query parameter,
header or cookie, a path segment past the end, a body path that leads nowhere, or
`body` when the body is not JSON. A missing value in `${…}` or in `$each` is
an error unless `??` gives a fallback (`${query.lang ?? 'en'}`,
`${body.note ?? null}`); a loop over an absent query parameter, header or
cookie runs zero times, and in `$if` a missing value is never an error: it is
false, and it equals no literal (so `query.x != 'a'` holds when `x` is
absent). A call with a missing argument is missing too, and so are a JWT
helper's call on what is not a token and a `find` that finds no element.

Type errors are errors as well: a loop over what is not an array,
`number(x)` of text that is not a JSON number, a `range` bound that is not
an integer, a helper argument of the wrong kind, an object or an array in
text, a zero divisor, and a bound exceeded. `range` gives at most 1000
values, one response runs at most 10,000 loop iterations in all, a helper's
result takes at most 1 MiB, an arithmetic helper's numbers have at most 18
digits before the point and 18 after, and a rendered body, or all the events
of a response together, takes at most 1 MiB. So does an [LLM
reply](llm-responses.md#the-size-bound) once encoded. Bounds that literals
give are checked when the files are loaded.

When a template cannot be rendered for a request, the client gets status
500, `Content-Type: application/json` and `{"error":"template
failed","stub":"<id>","at":"<JSON Pointer within the
Stub>","message":"<what>"}`, such as
`"at":"/response/json/customer","message":"body.customer.name is missing"`.
A delay Fault still applies first, and a connection Fault still replaces the
response. A stream is rendered whole before its head is sent, so a failed
event also gives this 500 and no stream. The Journal entry records the 500
and `templateError`. The default `json` [log format](../running.md#logs)
writes no line for it. The `mockoon` format writes an error line to stdout,
after the response's last byte and just before the request's `Transaction
recorded` line, also with the Journal off. It has the message, the Stub's
path as written (`routePath`, left out for a Stub with no path condition)
and the Stub ID (`routeUUID`):

```json
{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: body.customer.name is missing","routePath":"/orders","routeUUID":"create-order","timestamp":"2026-10-31T09:00:04.000Z"}
```

A value of `variables` or `dataWrites` that fails to render writes the
same line.

A gRPC call never gets this 500. Its Stub's template failure is
Trailers-Only INTERNAL `template failed`, with the HTTP status 200, and its
Journal entry has the same `templateError` ([smock's own
failures](../grpc/unmatched-and-refused-calls.md#smocks-own-failures)).

## Environment variables

A template can read an environment variable only when it is listed with
`--template-env` (`SMOCK_TEMPLATE_ENV`), names separated by commas.
`env.NAME` gives its value as a string.

```yaml
response:
  status: 200
  template: true
  json:
    region: ${env.REGION ?? 'local'}
```

With `smock serve --template-env REGION` and `REGION=eu-west-1`, the
response is `{"region":"eu-west-1"}`, and with `REGION` unset,
`{"region":"local"}`. Without `--template-env REGION`, the file does not
load.

- `env` takes exactly one name: `env.REGION` or `env['REGION']`. `${env}`
  alone and `env.REGION.x` are errors when loading. A loop variable cannot
  be named `env`.
- A name that is not listed is an error when loading, so `smock check`
  catches a typo.
- A listed variable that is unset is missing, so `??` gives a fallback. A
  variable set to the empty string is present.
- A listed name is ASCII letters, digits and `_`, starting with a letter or
  `_`. A name that starts with `SMOCK_` cannot be listed, so smock's own
  variables, such as `SMOCK_ADMIN_TOKEN`, never reach a template. Either
  mistake is a usage error: smock exits with status 2.
- The values are read once, at startup. Every load uses them: the first
  one, each reload and each Ephemeral Stub that is added. A reload does
  not read them again, so restart smock to change a value.
- `smock check` and `smock render` take the same flag and environment
  variable, and read the values from their own environment, so that they
  accept the same templates as `smock serve`.
- The values are not part of the
  [definition set digest](../definition-files.md#reloading).

A listed value reaches only what a template that reads it produces: a
response, a rendering, a [Variable](variables.md#variables) it writes (which
the Admin API lists), or a template error message that quotes it, such as
`number(): "eighty" is not a JSON number`. Such a message goes into the 500
of the failed template and into the Journal entry's `templateError`. smock
writes no value in its logs or in the Admin API status, and the Journal
holds one only inside such a message. So list only values that may be shown
to whoever can send requests to smock or read its Journal.

## Errors when loading

A template problem found when the files are loaded is reported with the
file and the JSON Pointer of the field (for a body file, of `bodyFile`), and
a message that starts with `template:` and gives the column of the problem
in a one-line string, or its line and column in a text of several lines:

```text
users.yaml: /stubs/0/response/json/id: template: column 3: unknown helper "fake.phone": not one of the helpers smock has
users.yaml: /stubs/1/response/bodyFile: template: line 3, column 5: unknown helper "fake.nickname": not one of the helpers smock has
```

For a literal that is not well-formed, such as the number `1e` in
`${1e}`, the column is the literal's first character. For a message that
says what it found, such as `expected } to end the ${, found "q"`, it is
the character found.

These are checked when the files are loaded:

- every name, loop variable and helper;
- an `env` name, which must be listed with `--template-env`;
- a `data` name, which must be a Data bucket of the Stub's Mock;
- the names of `variables`;
- the number of arguments of each call, and the kinds and bounds of its
  literal arguments;
- date formats, offsets and durations;
- the keys of `$each` and `$if` objects, and reserved keys;
- `${` in a key or in `Content-Type`;
- `json()` and `raw()` in `json`;
- a templated body file that is not UTF-8.

## Rendering a template

`smock render` and the Admin render operation render a Stub for a sample
request, templates included, and show the time and the seed they used. A
sample's cookies come from its `headers.Cookie`, and its form fields from
its body when its `headers.Content-Type` says the body is a form. `--time`
(the Admin API's `time`) is the time of the request; `--seed` (`seed`) gives
the output the request takes from its Stub's source as the first output of a
generator seeded with it, so a rendering with seed `S` shows what the first
matched request of a Stub with `fault.seed: S` gets. Without a seed they use
the Stub's `fault.seed`, or a fresh seed when it has none. A Stub with
[`responses`](responses.md#several-responses) renders the response the seed
picks, and the rendering shows its index as `responseIndex` (null for a Stub
with `response`). `--response <i>` (the Admin API's `response=<i>`) renders
the response at index `i` instead, from 0; a Stub with `response` takes 0
only, and a [CRUD Stub](#rendering-a-crud-stub) none. An index the Stub does
not have fails: the Admin API answers 400 `invalid_request`, and `smock
render` exits with status 1. A value that is not an integer from 0 to 99 is
refused before rendering: 400 `invalid_request`, or a usage error with
status 2. With the same time, seed and index, a rendering is the same on
every run. A template that fails for the sample shows the 500 and the error.
A response that serves [byte ranges](responses.md#range-requests) answers
the sample's `Range` header, so the rendering shows the 206 or the 416 a
request would get.

An [LLM response](llm-responses.md#llm-responses) renders as a request gets
it. A sample that gets a [stream](llm-responses.md#streams), such as one
whose body sets `stream: true` for `openai-chat`, shows the events, each
with its [wait](llm-responses.md#timing) as `delay`, and a null `body`. Any
other sample shows the JSON body. The seed fixes the ids and the waits, and
the reply's time, such as `created`, is the rendering's time. For the
[`slow-hello` Stub](llm-responses.md#timing), with `sample.json` holding

```json
{"method": "POST", "path": "/v1/chat/completions",
 "body": "{\"model\": \"gpt-6-astra\", \"stream\": true, \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}]}"}
```

this command lists the waits of the events, from the opening chunk to
`[DONE]`:

```sh
smock render --dir defs slow-hello --request sample.json --seed 7 | jq -c '[.response.events[].delay]'
# [0,824,27,20,38,19,40,38,26,28,0,0]
```

A [gRPC Stub](grpc.md#grpc-stubs) renders as a call to its method, whatever
the sample's `method` and `Content-Type`, which are only conditions. The
sample's body is the request message as JSON, checked against the method's
input type: a body that does not fit fails, with 400 `invalid_request` or
status 1. The rendering shows the reply message as JSON, its initial
metadata as `headers`, and, in `response.grpc`, the gRPC status, message,
trailing metadata and error details, never protobuf bytes. A template that
fails, or a rendered reply that does not fit its type, shows the INTERNAL a
call gets, with its `templateError`. The [gRPC
guide](../grpc/rendering-and-journal.md#rendering-a-grpc-stub) says more.

A rendering reads and writes no live [Variables](variables.md#variables), so
it stays the same on every run:

- The sample's optional `vars` object gives the Variables that templates
  read, by name: `"vars": {"user": "bob"}`. By default there are none.
  A `vars` that is not an object, or a name that is not a Variable name,
  makes the sample invalid.
- The rendering shows the values the Stub would write as `variables`, an
  object, empty when the Stub has no `variables`. They are rendered
  against the sample's `vars`, in the order written, and their helpers
  draw from the seed as a request's do. Nothing is written, so the state
  bound never applies to them.
- The response reads the sample's `vars` with the Stub's values written
  over them, as the response to a request sees its writes.
- A value that fails to render shows the 500 a request would get, with
  its `templateError` (an `at` under `/variables/NAME`), empty
  `variables` and `responseIndex: null`, even when `--response` names a
  response.

For the [`login` Stub](variables.md#variables), a sample with the body
`{"user":"ann"}` and `"vars": {"user": "bob"}` shows
`"variables": {"user": "ann", "previous": "bob"}` and the response
`{"user":"ann","previous":"bob"}`.

A rendering reads and writes no Session's copy of a [Data
bucket](data-buckets.md#data-buckets), so it stays the same on every run
too:

- The sample's optional `data` object gives the value of a bucket of the
  Stub's Mock, by name, in place of its initial value: `"data": {"orders":
  [{"id": 1002, "status": "pending"}]}`. The buckets it does not name read
  their initial values. A name that is not a bucket of the Stub's Mock, or a
  value that breaks the [rules of a keyed
  bucket](data-buckets.md#keys-and-key-texts), fails: the Admin API answers
  400 `invalid_data`, and `smock render` exits with status 1.
- The rendering shows the writes the Stub's
  [`dataWrites`](data-buckets.md#writing-buckets-datawrites) would make as
  `dataWrites`, in order, empty when the Stub has none. Each is `{op,
  bucket, key, value}`: `key` is the rendered key, or null; `value` is the
  rendered value, with the [new key](data-buckets.md#new-keys) filled in for
  an `append` to a keyed bucket, or null for `remove`. They render and apply
  to the sample's data as at the [match
  decision](data-buckets.md#when-data-is-written), and their helpers and new
  `uuid` keys draw from the seed as a request's do. Nothing is written, so
  the state bound never applies to them.
- The response reads the sample's data after the writes, as the response
  to a request sees its writes.
- A key or a value that fails to render, or a write that cannot be applied
  to the sample's data, shows the 500 a request would get, with empty
  `dataWrites` and `variables`, and `responseIndex: null`. A key or a value
  that fails to render also fills `templateError`; a write that cannot be
  applied is named in the 500's body, `data write failed`.

For the [`pay-order` Stub](data-buckets.md#writes-by-key), the sample

```json
{"method": "POST", "path": "/api/v1/orders/1002/pay",
 "data": {"orders": [{"id": 1002, "status": "pending"}]}}
```

with `--time 2026-10-12T14:30:05Z` shows the `merge` it would make, and
the order after it:

```json
"dataWrites": [{"op": "merge", "bucket": "orders", "key": "1002",
  "value": {"status": "paid", "paidAt": "2026-10-12T14:30:05.000Z"}}]
```

and the response `{"id":1002,"status":"paid","paidAt":"2026-10-12T14:30:05.000Z"}`.
The same sample with the path `/api/v1/orders/9999/pay` shows `dataWrites:
[]` and the 500 `data write failed`, since the sample's data has no order
9999.

### Rendering a CRUD Stub

A [CRUD Stub](crud-stubs.md#crud-stubs) renders the answer its operation
would give to the sample, from the sample's data, or else from the bucket's
initial value. Its failures, such as a 404 or a 409, and its [list
queries](crud-stubs.md#list-queries) render too.

- A create, replace, update or delete shows its write as `dataWrites`, with
  the op that makes the [same write](crud-stubs.md#writes): `append` for a
  create, with the new key filled in; `set` for a replace and `merge` for an
  update, with the item path's key and the body as sent; and `remove` for a
  delete, with the key. A list or a read, and a write that fails, show
  `dataWrites: []`.
- A new `uuid` key draws from the seed, as a request's does.
- `responseIndex` is null and `variables` is empty. `failed` is empty too,
  since a sample that fits an operation fails neither of the Stub's [two
  conditions](crud-stubs.md#a-crud-stubs-near-miss). A CRUD Stub has no
  responses, so `--response` (`response`) fails.
- A sample whose method and path fit no operation of the Stub, such as
  `DELETE /api/v1/orders`, has nothing to render: `smock render` exits
  with status 1, and the Admin API answers 400 `invalid_request`.

For the [`orders` CRUD Stub](crud-stubs.md#crud-stubs), the sample

```json
{"method": "POST", "path": "/api/v1/orders",
 "body": "{\"customerId\":42,\"status\":\"pending\"}"}
```

shows the `append` it would make to the three orders of `orders.json`:

```json
"dataWrites": [{"op": "append", "bucket": "orders", "key": null,
  "value": {"customerId": 42, "status": "pending", "id": 1004}}]
```

and the 201 with `Location: /api/v1/orders/1004` and the body
`{"customerId":42,"status":"pending","id":1004}`. The sample

```json
{"path": "/api/v1/orders", "query": {"status": "pending"},
 "data": {"orders": [{"id": 1, "status": "pending"},
                     {"id": 2, "status": "paid"}]}}
```

shows the list `[{"id":1,"status":"pending"}]`, with `X-Total-Count: 2`
and `X-Filtered-Count: 1`, and `dataWrites: []`.
