# How a Stub matches a request

This document is part of the [Definition-file
reference](../definition-files.md). It describes the request conditions a
Stub can give, the order Stubs are tried in, what a Mock answers when no
Stub matches, and how a Mock turns its Journal off. The state a Stub's
`scenario` clause requires is checked beside these conditions, and
[Scenarios](scenarios.md) describes it. The [Contents](#contents) follows
the summary of the conditions.

A Stub's `request` lists the conditions a request must meet. Every condition
given must hold, and a condition that is left out matches anything, so a
Stub without `request` matches every request of its Mock.

| Condition | A request meets it when |
|---|---|
| `method` | its method is exactly this, case and all, such as `GET`. |
| `path` | its path, percent-decoded and without the query, is exactly this. `/users/a%20b` meets `"/users/a b"`. `{ "pattern": … }`: the pattern matches the whole path. |
| `query` | for each listed parameter, one of its values, decoded, is exactly the given value, or matches the given `{ "pattern": … }` as a whole, so an absent parameter fails. [`$not` and `$exists`](#negation-and-presence) are about the parameter as a whole instead, and may hold for an absent one. Parameters that are not listed are ignored. |
| `headers` | for each listed header, its name compared case-insensitively, one of its values is exactly the given value, or matches the given `{ "pattern": … }` as a whole, so an absent header fails. [`$not` and `$exists`](#negation-and-presence) are about the header as a whole instead, and may hold for an absent one. Headers that are not listed are ignored. |
| `cookies` | for each listed cookie, its name compared exactly, one of its values in the `Cookie` headers, as sent, is exactly the given value, or matches the given `{ "pattern": … }` as a whole, so an absent cookie fails. See [Cookies](#cookies). [`$not` and `$exists`](#negation-and-presence) are about the cookie as a whole instead, and may hold for an absent one. Cookies that are not listed are ignored. |
| `body` | a string: the body is exactly this text in UTF-8. `{ "pattern": … }`: the pattern matches the whole body. `{ "json": … }`: the body parses as JSON and contains the given value, which may hold patterns and [operators](#operators-in-json-conditions). `{ "form": … }`: the Content-Type says the body is a form, and each listed [field](#form-fields) meets its condition. `{ "xml": … }`: the body parses as XML, and the value at each [path](#xml-bodies) meets its condition. |

Query parameters are decoded as HTML forms encode them: `%20` and `+` both
stand for a space, so `?q=a+b` meets `"query": { "q": "a b" }`. A parameter
without `=` has the empty value. When a parameter or a header is repeated,
the condition holds when any one of its values matches. Each header field
line is one value: a client or proxy that joins repeated values into one
line, such as `X-Tag: b, a`, sends the value `b, a`, which `"X-Tag": "a"`
does not match; a pattern such as `{ "pattern": "(.*, )?a(, .*)?" }` does.

A `json` condition is a subset match:

- an object whose only member is `pattern`, with a string, is a pattern:
  see below;
- an object whose only key starts with `$` is an operator, such as
  `{ "$not": "admin" }`: see
  [Operators in json conditions](#operators-in-json-conditions);
- any other object needs each listed key, with a value that matches in
  turn, and may have other keys. A key written `$$name` is the key
  `$name`;
- an array needs the same length, matched element by element;
- any other value must be equal: strings exactly, numbers by their value
  (`1` and `1.0` are equal), and `true`, `false` and `null` themselves.
  Integers are compared exactly however many digits they have, so a 64-bit
  ID such as `9007199254740993` matches only itself. A number beyond a
  64-bit float's range is compared exactly too, by its value: `1e400`
  matches `10e399` and a `1` followed by 400 zeros, but not `1e401` or a
  `9` followed by 399 zeros. The one exception is an exponent of 10^18 or
  more: a number with such an exponent matches only a number with the same
  exponent. Any other number with a fraction or an exponent is compared as
  closely as a 64-bit float holds it.

A body that does not parse as JSON never meets a `json` condition.

A pattern in a `json` condition, such as
`"email": { "pattern": ".*@example\\.com" }`, holds when the value in its
place is a string that the pattern matches as a whole, or a number, `true`
or `false` whose JSON text it matches as a whole. So
`{ "pattern": "[0-9]{8}" }` meets both `20261017` and `"20261017"`. `null`,
objects and arrays never meet a pattern, and a missing key fails as it does
for any other value. Patterns follow the rules of
[pattern conditions](#pattern-conditions).

A number's text is its shortest form, as smock writes JSON: `1.50` is
matched as `1.5`, `1e3` as `1000` and `-0` as `0`. An integer keeps all its
digits, however many it has, and a number beyond a 64-bit float's range,
such as `1e400`, is matched as written. A string with a lone surrogate, such
as `"\ud800"`, has no UTF-8 form, so it never meets a pattern.

A pattern can also be the whole `json` value, as in
`{ "json": { "pattern": "[0-9]+" } }`. It is matched against the body
parsed as JSON, so it meets the bodies `42` and `"42"`. A pattern on the
body itself, `{ "pattern": "[0-9]+" }`, matches the body as text, so it
meets `42` but not `"42"`.

To match an object such as `{"pattern": "a.b"}` itself, nest a pattern in
it: `{ "pattern": { "pattern": "a\\.b" } }`. The outer `pattern` holds an
object, not a string, so it is literal JSON, and only the inner object is a
pattern. Unlike an exact value, the inner pattern also meets a number,
`true` or `false` whose text it matches, such as `1` for
`{ "pattern": "1" }`.

```json
{
  "id": "create-user",
  "mock": "users",
  "request": {
    "method": "POST",
    "path": "/users",
    "query": { "dryRun": "true" },
    "headers": { "Content-Type": "application/json" },
    "body": {
      "json": {
        "name": "Alice",
        "email": { "pattern": ".*@example\\.com" },
        "roles": ["admin"]
      }
    }
  },
  "response": { "status": 201 }
}
```

## Contents

- [Pattern conditions](#pattern-conditions)
- [Negation and presence](#negation-and-presence)
- [Operators in json conditions](#operators-in-json-conditions)
- [Cookies](#cookies)
- [Form fields](#form-fields)
- [XML bodies](#xml-bodies)
- [Which Stub answers](#which-stub-answers)
- [Scenarios](scenarios.md)
- [When no Stub matches](#when-no-stub-matches)
- [Turning the Journal off for a Mock](#turning-the-journal-off-for-a-mock)

## Pattern conditions

The path, a query parameter, a header, a cookie, the body, a value inside
a `json` condition, a [form field](#form-fields) and the value at an
[XML path](#xml-bodies) can each be given as a pattern instead of an exact
value, in RE2 syntax:

```json
{
  "id": "get-user",
  "mock": "users",
  "request": {
    "method": "GET",
    "path": { "pattern": "/users/[0-9]+" },
    "query": { "fields": { "pattern": "[a-z]+(,[a-z]+)*" } },
    "headers": { "Authorization": { "pattern": "Bearer [A-Za-z0-9._-]+" } }
  },
  "response": { "status": 200 }
}
```

- A pattern must match the whole value, not only part of it, so it needs
  no `^` or `$`: `/users/[0-9]+` meets `/users/42` but not
  `/users/42/orders` or `/api/users/42`.
- It is matched against the same value as an exact condition: the
  percent-decoded path without the query, the decoded values of a query
  parameter, the values of a header or a cookie, and the body. When a
  parameter, a header or a cookie is repeated, any one of its values may
  match. In a `json`
  condition, it is matched against the value in its place, as described
  above.
- The body is matched as text in UTF-8. `.` does not match a line break
  unless the pattern turns on the `s` flag, as in `(?s)BEGIN.*END`. A body
  that is not valid UTF-8 never meets a pattern, not even `(?s).*`.
- Exact, pattern and `json` conditions can be mixed on one Stub, which then
  matches only when all of them hold. Stubs with patterns are tried in the
  same order as any other Stub.

smock supports a subset of RE2 syntax, which the
[RE2 module's README](../../re2/README.mbt.md#syntax-in-the-subset) lists:
literals, `.`, bracket classes, `\d`, `\w` and `\s`, anchors and word
boundaries, groups, alternation, repetitions (counts up to 1000) and the
flags `i`, `s` and `m`. Matching takes time linear in the length of the
value, whatever the pattern, so no pattern can stall smock.

Patterns are compiled once, when smock loads the Definition files. A
pattern that does not compile, or that uses RE2 syntax outside the subset,
such as the Unicode class `\p{Greek}`, makes the definition set invalid.
`smock check` reports it, and `smock serve` does not start, with the JSON
Pointer of the `pattern` field and the position of the problem in the
pattern, counted in characters from 0:

```console
users.json: /stubs/0/request/path/pattern: is not a valid pattern: position 7: missing closing )
users.json: /stubs/1/request/headers/X-Region/pattern: is not a valid pattern: position 0: Unicode class \p{Greek} is not supported in smock's RE2 subset
users.json: /stubs/2/request/body/json/email/pattern: is not a valid pattern: position 0: missing closing )
```

## Negation and presence

A query parameter's, a header's, a cookie's or a
[form field's](#form-fields) value, or the value at an
[XML path](#xml-bodies), can also be an operator: an object whose only key
starts with `$`.

- `{ "$not": <condition> }` holds exactly when the condition does not.
  `<condition>` is an exact value, a pattern or another operator.
- `{ "$exists": true }` holds when the parameter, header, cookie or form
  field is present, with any value, even an empty one.
  `{ "$exists": false }` holds when it is absent.

```yaml
request:
  headers:
    Authorization: { $not: { pattern: "Bearer .*" } }
    X-Debug: { $exists: false }
  query:
    status: { $not: draft }
```

This Stub answers a request without a Bearer token, without `X-Debug`, and
whose `status` is not `draft`.

An operator is about the name as a whole, not about one value:

- An exact value or a pattern holds when one of the values meets it, so it
  fails when the name is absent.
- `$not` holds when its condition does not. So `{ "$not": "draft" }` holds
  when no `status` is `draft`, including when there is no `status` at all.
  `?status=draft&status=x` does not meet it. A request without
  `Authorization` meets `{ "$not": { "pattern": "Bearer .*" } }`.
- Operators nest: `{ "$not": { "$not": "a" } }` is `"a"`, and
  `{ "$not": { "$exists": true } }` is `{ "$exists": false }`.

Names are always literal: `"query": { "$filter": "name eq 'a'" }` matches the
parameter `$filter`, as OData clients send it. Only a value can be an
operator.

Keys that start with `$` in a value are reserved for operators. An unknown
one, an operator beside another key, or an `$exists` that is not `true` or
`false` makes the definition set invalid, as `$includes` does here: it is
only allowed in a `json` condition. Each such key is reported, whatever the
order of the keys:

```console
users.json: /stubs/0/request/query/status/$nto: is not an operator: the operators here are "$not" and "$exists"
users.json: /stubs/1/request/headers/Authorization/pattern: is not allowed beside "$not": an operator is the only key of its object
users.json: /stubs/2/request/query/debug/$exists: must be true or false
```

## Operators in json conditions

In a `json` condition, any value can be an operator: the whole condition,
the value of a member, or an element of an array. An operator is about the
value in its place.

- `{ "$not": <condition> }` holds when the value does not meet the
  condition. A missing key meets `$not` of any condition that a missing
  key does not meet: `{ "$not": "x" }` holds when the key is missing, but
  `{ "$not": { "$exists": false } }` does not, since a missing key meets
  `$exists: false`.
- `{ "$exists": true }` holds when the key is present, whatever its value,
  even `null`. `{ "$exists": false }` holds when the key is missing. At the
  root, `{ "$exists": true }` holds for any JSON body.
- `{ "$includes": <condition> }` holds when the value is an array with at
  least one element that meets the condition, wherever it sits. It never
  holds for a value that is not an array.
- `{ "$last": <condition> }` holds when the value is an array with at least
  one element, and its last element meets the condition. It never holds
  for an empty array or a value that is not an array.

`<condition>` is any `json` condition: a value, an object of keys, a
pattern or another operator.

```yaml
request:
  body:
    json:
      tags: { $includes: urgent }
      items: { $not: [] }
      coupon: { $exists: true }
      lines: { $includes: { sku: { pattern: "A-.*" } } }
```

This Stub answers a body whose `tags` array contains `"urgent"`, whose
`items` is not an empty array, that has a `coupon` key, even `null`, and
that has a line whose `sku` starts with `A-`.

- Operators nest. `{ "$not": { "$includes": "x" } }` holds when no element
  is `"x"`, and `{ "$includes": { "$not": "x" } }` when some element is not
  `"x"`.
- `null` still means JSON `null`: `"coupon": null` needs the key with the
  value `null`, and `"coupon": { "$exists": false }` needs it to be
  missing.
- `[]` still matches only an empty array. "Not empty" is
  `{ "$not": [] }`, which a missing key or a value that is not an array
  also meets. `{ "$includes": { "$exists": true } }` holds only for an
  array with at least one element.
- A body that does not parse as JSON never meets a `json` condition, so
  `{ "json": { "$not": … } }` fails on it too.

`$last` matches the last message of a conversation, however long it is.
An LLM client sends the whole conversation in each request, so a Stub can
answer the turn after a tool call. Each API has its own form:

```yaml
stubs:
  # OpenAI Chat Completions: the last message is a tool result.
  - id: chat-after-tool
    mock: llm
    request:
      path: /v1/chat/completions
      body: { json: { messages: { $last: { role: tool } } } }
    response: { status: 200 }
  # Anthropic Messages: the last message is a user message that holds a
  # tool result.
  - id: messages-after-tool
    mock: llm
    request:
      path: /v1/messages
      body:
        json:
          messages:
            $last: { role: user, content: { $includes: { type: tool_result } } }
    response: { status: 200 }
  # OpenAI Responses: the last input item is a tool result.
  - id: responses-after-tool
    mock: llm
    request:
      path: /v1/responses
      body: { json: { input: { $last: { type: function_call_output } } } }
    response: { status: 200 }
```

The Responses API also takes `input` as a string. A string is not an array,
so it never meets `$last`. [Agent loops](llm-tool-calls.md#agent-loops)
shows each API's loop with LLM replies, and how the reply quotes the tool's
result.

`$last` nests as the other operators do.
`{ "$not": { "$last": { "role": "tool" } } }` holds when the last message
is not a tool result, and also for an empty array, a value that is not an
array and a missing key. `{ "$last": { "role": { "$not": "user" } } }`
holds when the last element is an object whose `role` is missing or is
not `user`.

A key that starts with `$` is written `$$` and the rest, as in [response
templates](templates.md#structured-templates): `{ "$$ref": "#/a" }` matches
a body with the key `$ref`. A key that starts with one `$` and is not an
operator makes the definition set invalid, with a message that suggests
`$$`, and so do an operator beside another key and an `$exists` that is not
`true` or `false`:

```console
orders.json: /stubs/0/request/body/json/schema/$ref: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$ref" for the literal key "$ref"
orders.json: /stubs/1/request/body/json/tags/length: is not allowed beside "$includes": an operator is the only key of its object
```

The format version is still 1, but two kinds of `json` condition written
for smock 0.1 now mean something else:

- an object whose only key is `$not`, `$exists` or `$includes` was literal
  JSON, and is now an operator;
- a key that starts with `$$`, such as `$$id`, matched that key as written,
  and now matches it with one `$` less, `$id`.

Any other key that starts with `$` in a `json` condition is now an error,
so a file with one fails to load rather than change its meaning: write
the key with `$$`. This is why `$last`, added later, changed no file: a
file with a lone `$last` key failed to load before, and `$$last` still
means the key `$last`.

## Cookies

`cookies` matches the cookies of the request by name:

```yaml
request:
  cookies:
    session: { pattern: "sess_.*" }
    debug: { $not: "1" }
```

This Stub answers a request whose `session` cookie starts with `sess_` and
that has no `debug` cookie with the value `1`.

smock reads cookies from the `Cookie` header like this:

- Every `Cookie` field of the request is read, so cookies that a client or
  a proxy splits over several lines still match. Over
  [HTTP/2](../http2.md#what-a-stub-sees), a request's `cookie` fields are
  first joined into one, so `header.cookie` and a `headers` condition on
  `cookie` see the one line an HTTP/1.1 client sends.
- Each field is split on `;`, and each part is trimmed of spaces and tabs.
- The first `=` of a part separates the name from the value, so `a=b=c` is
  the cookie `a` with the value `b=c`. A part without `=` is skipped.
- Names are compared exactly, case and all: `Session` is not `session`.
- Values are compared exactly as sent. Quotes are part of a value, as
  RFC 6265bis says, so `token="abc"` meets `"token": "\"abc\""` but not
  `"token": "abc"`. Nothing is percent-decoded, so `name=a%20b` meets
  `"name": "a%20b"`, not `"name": "a b"`.

Templates read cookies the same way, with
[`cookie.NAME`](templates.md#inserting-values).

A cookie name can repeat, such as when a cookie is set for two paths. Then
the condition holds when any one of its values matches, as for a query
parameter, and `{ "$not": "1" }` holds only when none of them is `1`.
Names are literal, even when they start with `$`.

## Form fields

A `form` body condition matches the fields of an
`application/x-www-form-urlencoded` body, as HTML forms send it, by name:

```yaml
request:
  method: POST
  path: /login
  body:
    form:
      username: alice
      remember: { $not: "1" }
```

This Stub answers a login from `alice` that does not ask to be remembered,
such as `username=alice` or `remember=0&username=alice`, whatever the order
of the fields.

- Fields are decoded as query parameters are: `+` and `%20` both stand for
  a space, `%2B` is a `+`, and a field without `=` has the empty value. So
  `user+name=Alice%20Smith` meets `"user name": "Alice Smith"`.
- Names are compared exactly, case and all. They are literal, even when
  they start with `$`.
- The condition is any value condition: an exact value, a pattern, `$not`
  or `$exists`. When a field repeats, as in `tag=a&tag=b`, the condition
  holds when any one of its values matches, and `$not` holds when none
  does. An empty body has no fields.
- Fields that are not listed are ignored.

A form condition holds only when the request's Content-Type says that the
body is a form: its media type is `application/x-www-form-urlencoded`,
compared case-insensitively, with any parameters, such as
`; charset=UTF-8`. When a request has several Content-Type fields, the
first one counts. Any other Content-Type, or none, fails every listed
field, `$not` and `$exists: false` included, so a JSON or text body never
meets a form condition by accident. `{ "form": {} }` lists no field, so it
holds for any request whose Content-Type says the body is a form, as
`{ "json": {} }` holds for any body that is a JSON object.

The body is read as a form at most once per request, and only when smock
tries a Stub with a `form` condition. `multipart/form-data` bodies are not
read as forms: match them with a `pattern` on the body.

## XML bodies

An `xml` body condition maps paths into an XML body to value conditions.
It matches SOAP and other XML requests by meaning rather than by bytes:

```yaml
request:
  method: POST
  path: /soap
  body:
    xml:
      /Envelope/Body/GetUser/id: "42"
      /Envelope/Body/GetUser/@lang: { pattern: "en|ja" }
      /Envelope/Header/Trace: { $exists: false }
```

This Stub answers a request for user 42, in English or Japanese, without a
`Trace` header element, such as

```xml
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <u:GetUser xmlns:u="urn:users" lang="en">
      <u:id>42</u:id>
    </u:GetUser>
  </soap:Body>
</soap:Envelope>
```

A path is `/` followed by one or more element names separated by `/`,
optionally ending in `/@` and an attribute name:

- The first name is the root element's. Each further name selects the
  children with that name of the elements selected so far. A final
  `@name` selects that attribute of each of them.
- Names are local names. A prefix in the body is ignored, so a client that
  writes `S:Envelope` instead of `soap:Envelope` still matches, and a path
  names no prefix. Namespace URIs are not compared, so elements that
  differ only by namespace cannot be told apart.
- There are no wildcards, predicates, indexes, `//`, axes or functions.

What a node's value is:

- An element's value is all the text in it and in its descendants, in
  order, CDATA included, trimmed of whitespace at both ends. Comments are
  skipped. So `<id>42</id>`, `<id><![CDATA[42]]></id>`, and an `id`
  element with `42` indented on a line of its own all have the value
  `42`.
- An attribute's value is its text with each tab and line break turned
  into a space.
- References are decoded: `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, and
  character references such as `&#38;`.
- Namespace declarations, `xmlns` and `xmlns:p`, are not attributes, so
  a path that ends in `@xmlns` makes the definition set invalid. An
  attribute with a prefix and the local name `xmlns`, such as `p:xmlns`,
  cannot be selected either.

The condition is any value condition: an exact value, a pattern, `$not` or
`$exists`. A path is a name whose values are the values of the nodes it
selects:

- When a path selects several nodes, such as repeated elements, the
  condition holds when any one of them meets it.
- When it selects none, only `$not` and `$exists: false` hold.
  `{ "$exists": true }` holds when it selects at least one, even an empty
  element.

The Content-Type is not consulted, as for `json`. `{ "xml": {} }` lists no
path, so it holds for any body that parses as XML. The body is parsed at
most once per request, and only when smock tries a Stub with an `xml`
condition. smock reads a restricted form of XML, so that no request can
read files or exhaust memory through it:

- The body is UTF-8, optionally with a byte order mark. An XML declaration
  that names another encoding fails.
- Any DOCTYPE fails, so no entity is ever declared or expanded. This rules
  out external entities (XXE) and entity expansion bombs. Only the five
  predefined entities and character references are decoded.
- Elements nest at most 256 deep.
- The body is no longer than `--body-limit` allows (10 MiB by default).
- It must be well-formed: one root element, matching tags, no repeated
  attribute, no `<` or bare `&` in text.

A body that breaks one of these rules fails every `xml` condition, even
one with no path, and `$not` and `$exists: false` included. It is not an error: the request gets
another Stub or the no-match response.

Paths are compiled once, when smock loads the Definition files. A path
that does not compile makes the definition set invalid, with the JSON
Pointer of the path and the position of the problem in it, counted in
characters from 0. A `/` in a path is written `~1` in a JSON Pointer:

```console
soap.json: /stubs/0/request/body/xml/~1Envelope~1~1id: is not a valid XML path: position 9: // (descendants) is not supported in smock's XML paths
soap.json: /stubs/1/request/body/xml/~1soap:Envelope: is not a valid XML path: position 1: prefix soap: is not supported in smock's XML paths; name the local name only
```

## Which Stub answers

The first Stub that matches answers. Within a Mock, Stubs are tried in this
order:

1. By `priority`: a lower number is tried first. A Stub without a priority
   is tried after every Stub with one.
2. Among equal priorities, in declaration order: files in byte-wise order
   of their names, then Stubs by their position in the file.

So a specific Stub can win over a general one wherever it is declared, by
giving it a lower priority number.

A request that carries a Session tries the Ephemeral Stubs its Session added
to the Mock through the Admin API before any of these, by their own
`priority`, the newest first among equal priorities; a request without a
Session, those added without one. Priority orders Stubs only within their
source: an Ephemeral Stub without a priority still comes before a Stub from
a Definition file with priority -2147483648.

smock does not try every Stub in turn: an index, built when the Definition
files are loaded, finds the Stubs whose `method` and exact `path` fit the
request. The index never changes which Stub answers. A Stub with a `method`
and no exact `path` is tried for every request with that method, and a Stub
with neither, such as one with only a path pattern, for every request of its
Mock, each in its place in the order. So is a [CRUD
Stub](crud-stubs.md#crud-stubs), behind a quick test of its path's prefix.
Large definition sets stay fast when most Stubs have an exact path.

## When no Stub matches

The Mock answers with its `noMatch.status`, 404 by default, and the body
`{"error":"no Stub matched"}` with `Content-Type: application/json`. Give a
Mock the status its real service returns for unknown requests:

```json
{ "mocks": [{ "name": "users", "noMatch": { "status": 501 } }] }
```

`noMatch` applies to HTTP requests only. A gRPC call that no gRPC Stub
matches gets UNIMPLEMENTED instead, with its Near miss in a
`smock-near-miss` trailer
([Unmatched calls](../grpc/unmatched-and-refused-calls.md#unmatched-calls)).

The response also names the *Near miss*: the Stub that came closest, and
the conditions it failed, in a `Smock-Near-Miss` header. With this Stub:

```json
{
  "id": "get-user",
  "mock": "users",
  "request": {
    "method": "GET",
    "path": "/users/1",
    "headers": { "X-Api-Key": "secret" }
  },
  "response": { "status": 200 }
}
```

`POST /users/1` without an `X-Api-Key` header gets

```http
Smock-Near-Miss: get-user; failed=method,header:x-api-key
```

The Near miss is the Stub of the Mock that failed the fewest conditions; on
a tie, the one tried first. The request's Ephemeral Stubs are candidates
too, in the order they are tried, and the header names them by their ID,
such as `eph-3`. Each of these counts as one condition: the method, the
path, each listed query parameter, each listed header, each listed cookie,
the body or each field of a [`form` condition](#form-fields) or each path of
an [`xml` condition](#xml-bodies), and the state a [`scenario`
clause](scenarios.md#scenarios) requires. They are named `method`, `path`,
`query:<name>`, `header:<name>` (in lower case), `cookie:<name>`, `body`,
`form:<name>` or `xml:<path>`, and `scenario:<name>`, in that order. A
parameter, a header, a cookie, a form field or an XML path counts once
whatever its condition, operators included. A `form` or `xml` condition with
no field or path counts as `body`, as `{ "json": {} }` does. A [CRUD
Stub](crud-stubs.md#crud-stubs) counts two, `method` and `path` ([A CRUD
Stub's Near miss](crud-stubs.md#a-crud-stubs-near-miss)). The header is
ASCII only and never carries what a condition expects or what the request
sent: the Stub ID, query, header, cookie, form field and Scenario names, and
XML paths are percent-encoded where they hold anything other than the
characters of an HTTP token, so `/order/@status` is sent as
`xml:%2Forder%2F%40status`. A Mock without Stubs, and a request for a Host
that no Mock answers, get no `Smock-Near-Miss` header.

A request that matches pays nothing for this: smock counts failed
conditions only once every Stub has failed to match.

The [Journal](../admin-api.md#the-journal) records the full Near miss of
each unmatched request: every condition it failed, with what the Stub
expects and what the request sent. A test lists its Session's unmatched
requests with `GET /v1/journal/unmatched` ([Admin
API](../admin-api.md#verifying-calls-and-unmatched-requests)).

What the Stub expects is the condition as the Stub writes it, operators
included. What the request sent is every value of the parameter, header,
cookie or form field, or of the nodes an XML path selects, in order, and
none when it is absent, or when the body is not a form or not XML. So a
request whose Content-Type is not a form's shows no value for any field of
a `form` condition. A request with `Authorization: Bearer abc` fails the
[negation example](#negation-and-presence) like this:

```json
{
  "condition": "header:authorization",
  "expected": { "$not": { "pattern": "Bearer .*" } },
  "actual": ["Bearer abc"]
}
```

What the request sent is shown as text. A body that is not valid UTF-8 is
shown with U+FFFD in place of each sequence that is not, so a failed exact
`body` condition can show an expected and an actual value that look the
same. The Journal entry itself keeps the body's bytes, in base64, up to
`--journal-body-limit`, and the Near miss in it cuts the body to the same
limit. It also keeps the values taken from a form or an XML body up to that
limit in total: each value counts its bytes and 32 more, the value that
reaches the limit is cut there, and the values after it are left out. So
even a body of many empty fields adds little to an entry.

`noMatch.headers` adds header fields to the response when no Stub
matches, such as CORS headers. Without them, a browser client that calls
the Mock from another origin gets a CORS error instead of the 404, and
cannot read the body or the Near miss. Before many cross-origin requests,
such as one with a JSON body, a browser also sends a preflight `OPTIONS`
request, and stops unless it gets a 2xx status. A Stub answers those:

```yaml
mocks:
  - name: users
    noMatch:
      status: 404
      headers:
        Access-Control-Allow-Origin: "*"
        Access-Control-Expose-Headers: Smock-Near-Miss, Smock-Mock
stubs:
  - id: preflight
    mock: users
    request:
      method: OPTIONS
      headers: { Access-Control-Request-Method: { pattern: ".+" } }
    response:
      status: 204
      headers:
        Access-Control-Allow-Origin: "*"
        Access-Control-Allow-Methods: GET, POST, PUT, DELETE
        Access-Control-Allow-Headers: Content-Type, Authorization
```

Preflight requests then match, so they are not among the unmatched
requests. A request with another method fails two of this Stub's
conditions, `method` and the header, so a Stub that fails only one is the
Near miss instead. With only a `method`, this Stub would be the Near miss
of most unmatched requests. Declare it after the Mock's other Stubs
([Which Stub answers](#which-stub-answers)), so that it also loses a tie.

`noMatch.headers` follows the rules of a Stub's `headers`
([Responses](responses.md#responses)), and cannot give `Content-Type` or
`Smock-Near-Miss` either, as smock sets them on this response. smock sends
the headers as written, never as templates, after `Content-Type` and
before `Smock-Near-Miss` and `Smock-Mock`. A `Date` given here replaces
the one smock sends, as a Stub's does. A request for a Host that no
Mock answers gets none of them.

## Turning the Journal off for a Mock

smock records every request a Mock answers in the Journal, unless the Mock
says `"journal": false`. A Mock that takes a high-rate load test can turn it
off, so that recording costs nothing:

```json
{ "mocks": [{ "name": "load-target", "hosts": ["api.example.com"], "journal": false }] }
```

A Journal query or verification whose filter names such a Mock is refused
with 409 `journal_off`, rather than answered with no entries. Only such a
filter is refused: a filter that names no Mock is answered from the
requests that were recorded, which leave out this Mock's, and the
unmatched requests leave them out too. `--journal off` turns the Journal
off for every Mock, and then every query, verification and list of
unmatched requests is refused.
