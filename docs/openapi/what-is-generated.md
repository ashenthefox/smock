# What is generated

This part of [Importing OpenAPI](../importing-openapi.md) says what
`smock import-openapi` makes of an OpenAPI document, "the document" here:
what each of its parts becomes in the Definition file that the command
writes, "the file", and which parts are left out. The command and its flags,
such as `--mock` and `--base-path`, are in the guide's [Quick
start](../importing-openapi.md#quick-start). A warning or an error is a
problem that the command prints with its file and the JSON Pointer of its
place, as [Problems and exit
codes](../importing-openapi.md#problems-and-exit-codes) says.

The file declares one Mock, named by `--mock`, with the Hosts of `--hosts`
and no other field, unless `--declare-mock` is `off` ([The Mock and its
Hosts](../importing-openapi.md#the-mock-and-its-hosts)). Then come the Stubs
of each operation. Operations at concrete paths come before those at
templated paths. Otherwise, they keep the order the document writes them in:
path keys, then methods in the order each Path Item writes them ([Paths with
parameters](#paths-with-parameters)). An operation has a Stub for each
response it answers, and for each further named example ([Selecting
responses](../importing-openapi.md#selecting-responses)).

| In the document | In the Definition file |
|---|---|
| The document | `version: 1`, then `mocks` with the one Mock, unless `--declare-mock` is `off`, then `stubs`. In YAML, a comment at the top names the document, its `info.title` and `info.version`, its OpenAPI version, and the flags whose value is not the default: `--mock`, then `--hosts` when the Mock has Hosts, `--declare-mock off`, and `--base-path` when given. |
| An operation | One Stub per response: the main Stub, and one for each other response. One more Stub per further named example. In YAML, a comment above each gives the method, the path as written, the response key and the example's name, or `sample cut` for a sample cut to its required parts. |
| `summary` | In YAML, its first line ends the Stub's comment. Control characters become spaces. |
| `get`, `put`, `post`, `delete`, `options`, `head`, `patch`, `trace`, and 3.2's `query` | The `method`, in upper case. In 3.0 and 3.1, which do not define `query`, it is neither read nor checked. |
| A key of 3.2's `additionalOperations` | The `method`, as written. In 3.0 and 3.1, which do not define `additionalOperations`, it is neither read nor checked. |
| `head` | `HEAD` is answered only where the document has `head`. |
| `servers`, of an operation, a Path Item or the document | The path of the first server, in front of the paths of the operations it applies to, unless `--base-path` replaces it ([Servers and base paths](#servers-and-base-paths)). The URL's host is not used. |
| A path key without parameters | The exact `path`, percent-decoded as smock decodes request paths, so that the match index finds it. |
| A path key with parameters, such as `/pets/{petId}` | A `path` pattern, in which each parameter matches text within one segment: `pattern: /pets/[^/]+` ([Paths with parameters](#paths-with-parameters)). |
| `operationId` | The Stub ID `<mock>.<operationId>.<key>`, where `<key>` is the response's key as written, such as `petstore.listPets.200` and `petstore.listPets.default`. A further named example's Stub adds its name: `<mock>.<operationId>.<key>.<example>`, such as `petstore.getPet.200.dog`. |
| No `operationId` | The Stub ID `<mock>.<METHOD> <path>.<key>`, with the path as written, such as `petstore.GET /pets.200`. |
| The main response | The `status` of the main Stub (see below). |
| Another response | The `status` of its Stub (see below), which also has the request condition `Smock-Status: <key>` ([Selecting responses](../importing-openapi.md#selecting-responses)). |
| A response's `content` | The body, as `json` or `body`, from one media type, with its `Content-Type` in `headers` ([Bodies](#bodies)). |
| A media type's `examples` | The first gives the body. Each further one gets a Stub of its own, which also has the request condition `Smock-Example: <name>` ([Bodies from examples](#bodies-from-examples)). |
| A media type's `example` | The body, when the media type has no `examples`. |
| A media type's `schema` | One fixed sample of the schema, written in the file, when the media type has no example ([Samples from schemas](#samples-from-schemas)). A sample whose compact JSON would pass 64 KiB is cut to its required parts below its first level ([Sample size](#sample-size)). |
| A response's `headers` | Each header in `headers`, after the `Content-Type`, with its example or a sample of its schema, on every Stub of the response ([Response headers](#response-headers)). |
| Parameters, request bodies, `Content-Type`, `Accept` and `security` | No condition, so a request without a documented parameter still gets the documented answer. A path parameter's schema does not narrow its pattern either. |
| `deprecated: true` | The operation is imported like any other. In YAML, the Stub's comment says `deprecated`. No `Deprecation` header is added, since the document does not declare one. |
| `callbacks` | Not imported, with one warning per operation. |
| `webhooks` | Not imported, with one warning: they are requests the API sends, not ones it answers. |
| `security`, `links`, descriptions, tags and `x-` extensions | Nothing, and no warning. |
| A `$ref` to a Path Item, a Response, a Header, an Example or, as 3.2 allows, a Media Type, in the same document or in another file under `--ref-dir` | Followed, as if the part it names were written in place (see [References and bundling](references-and-yaml.md#references-and-bundling)). In 3.0 and 3.1, which allow no reference in place of a Media Type, a `$ref` in a media type is ignored, with a warning, and the rest of it is read as written. |
| A `$ref` in a schema | Followed too, into other files as well. A recursive schema gives a finite sample ([Schema references and recursion](#schema-references-and-recursion)). |
| Fields beside a Path Item's `$ref` | Ignored, with a warning for each but an `x-` extension, since OpenAPI leaves their meaning undefined. |

A Stub matches on its method and its path. The Stub of a response other
than the main one matches on `Smock-Status` too, and the Stub of a further
named example on `Smock-Example`. The file holds only
`status`, `headers`, and `json` or `body` in its responses: no
`template`, `responses`, `variables`, `dataWrites`, `crud`, `fault`,
`scenario` or `priority`, and no `data`.

## Contents

- [Paths with parameters](#paths-with-parameters)
- [Servers and base paths](#servers-and-base-paths)
- [The main response](#the-main-response)
- [The other responses](#the-other-responses)
- [Bodies](#bodies)
- [Bodies from examples](#bodies-from-examples)
- [Samples from schemas](#samples-from-schemas)
  - [Numbers](#numbers)
  - [Composed schemas](#composed-schemas)
  - [Schema references and recursion](#schema-references-and-recursion)
  - [Sample size](#sample-size)
- [Response headers](#response-headers)
- [IDs and conditions that repeat](#ids-and-conditions-that-repeat)

## Paths with parameters

A path key with parameters becomes a pattern. Each `{name}` in it becomes
`[^/]+`, which matches text within one path segment. Take three
operations, written in this order:

```json
"/pets/{petId}": { "get": { "operationId": "getPetById", "responses": { "200": {} } } },
"/pets/mine": { "get": { "operationId": "getMyPet", "responses": { "200": {} } } },
"/files/{name}.json": { "get": { "operationId": "getFile", "responses": { "200": {} } } }
```

The file has their Stubs in this order:

```yaml
stubs:
  # GET /pets/mine, 200
  - id: petstore.getMyPet.200
    mock: petstore
    request:
      method: GET
      path: /pets/mine
    response:
      status: 200
  # GET /files/{name}.json, 200
  - id: petstore.getFile.200
    mock: petstore
    request:
      method: GET
      path:
        pattern: /files/[^/]+\.json
    response:
      status: 200
  # GET /pets/{petId}, 200
  - id: petstore.getPetById.200
    mock: petstore
    request:
      method: GET
      path:
        pattern: /pets/[^/]+
    response:
      status: 200
```

So `GET /pets/mine` gets its own Stub, and `GET /pets/7` the pattern's.

- Literal text is percent-decoded as smock decodes request paths. Then
  its ASCII punctuation other than `/` is escaped with `\`, so that it
  stands for itself. So `/files/{name}.{ext}` becomes
  `/files/[^/]+\.[^/]+`.
- The path of the server, or `--base-path`, comes first. It is literal text,
  escaped like the rest: under the server `https://api.example.com/v1.0`,
  `/pets/{petId}` becomes `/v1\.0/pets/[^/]+` ([Servers and base
  paths](#servers-and-base-paths)).
- A parameter's schema does not narrow its pattern: an integer does not
  become `[0-9]+`, and an `enum` does not become a list of values. A
  request with a mistyped value still gets the documented answer, not the
  Mock's 404.
- smock decodes the path of a request before it matches it, so `%2F` is a
  `/`. A value with an encoded `/`, as in `/pets/a%2Fb`, never fills one
  segment. This agrees with OpenAPI 3.2.1.

The operations are sorted, so that a concrete path comes before a
templated one, as OpenAPI asks:

- Each path, with the server's path or `--base-path` in front, is split
  on `/`, and the paths are compared segment by segment from the left. A
  literal segment comes first, then a segment that mixes literal text and
  parameters, such as `{name}.json`, then a segment that is one
  parameter.
- When one path runs out first, and its segments are of the same kinds as
  the other's so far, the shorter path comes first. So `/pets` comes
  before `/pets/mine`.
- Otherwise, the document's order is kept: path keys first, then methods.
  The Stubs of one operation keep their order.
- So an exact path always comes before a pattern that matches it, and
  `smock check` gives no warning. No `priority` is written.
- [Problems](../importing-openapi.md#problems-and-exit-codes) still come
  in the order the document writes the operations.

Two patterns that can match the same request, such as
`/files/{name}.{ext}` and `/files/{name}.json`, keep the document's order.
The first one answers `/files/a.json`, and there is no warning, since
`smock check` does not compare two patterns. So list the specific one
first in the document.

## Servers and base paths

The Mock answers where the real service does: the path of a server URL
is put in front of every path. Take a document whose server is
`https://api.example.com/v1`, with the path `/pets/{petId}`:

```json
"servers": [{ "url": "https://api.example.com/v1" }],
"paths": {
  "/pets/{petId}": { "get": { "operationId": "getPetById", "responses": { "200": {} } } }
}
```

The Stub's path is:

```yaml
path:
  pattern: /v1/pets/[^/]+
```

So `GET /v1/pets/7` gets the Stub, and `GET /pets/7` does not.

- The server is the first of the operation's `servers`, else of its Path
  Item's, else of the document's. An empty list counts as none. Without
  any, there is no prefix, since OpenAPI's default server is `/`.
- Variables, such as `{version}` in `https://api.example.com/{version}`,
  are replaced by their `default`. A variable that the URL uses but that
  has no string `default` is an error.
- The path of an absolute URL is taken: its scheme and its host never
  matter, and get no warning. A relative URL is resolved against `/`, so
  `/v1`, `v1` and `./v1` all give `/v1`, and `//cdn.example.com/v1` gives
  `/v1` too. Dot segments are resolved, as in `/a/../v1`.
- A URL with a query or a fragment, such as `/v1?lang=en`, is an error.
- The prefix is percent-decoded as smock decodes request paths, and one
  trailing `/` is dropped, so `/v1/` gives `/v1`, and `/` gives no prefix.
- The path key is then appended as it is. So the key `/` under the prefix
  `/v1` gives `/v1/`, and `/` alone with no prefix.
- When the servers in one list have different paths, such as
  `https://api.example.com/v1` and `http://localhost:8080`, only the first
  is used, and a warning names it. Servers that differ only in their
  host give no warning.
- Every `servers` list is read and checked, even one that an inner list
  overrides for every operation.

`--base-path` mounts the API where the system under test calls it
instead:

```sh
smock import-openapi api/petstore.json --mock petstore --output defs/petstore.yaml --base-path /mock/petstore
```

```yaml
path:
  pattern: /mock/petstore/pets/[^/]+
```

- It replaces every prefix, and `servers` are then not read at all, so a
  mistake in them gives no problem.
- `--base-path /` means no prefix: each path comes from its path key
  alone.
- Its value must start with `/` and hold no `?` or `#`, or the command
  stops with a usage error, exit status 2. It is decoded, and one
  trailing `/` is dropped, as for a server's path.
- In YAML, the comment at the top of the file lists `--base-path` after
  the other flags.

## The main response

Each operation answers one main response. It is the first of these that
the operation's `responses` has:

1. the lowest explicit code from 200 to 299, then `2XX`;
2. `default`, which answers 200;
3. the lowest explicit code from 300 to 599, then `3XX`, `4XX` and `5XX`.

An explicit code answers itself, and a range answers its first code: 200,
300, 400 or 500.

- An operation without `responses`, or with an empty one, answers 200
  with an empty body, with a warning. Its Stub ID ends in `.200`.
- An operation with only 1xx responses is left out, with a warning: smock
  answers with a status from 200 to 599.
- A response key that is not a code from 100 to 599, a range from `1XX`
  to `5XX` in upper case, `default` or an `x-` extension is left out,
  with a warning. `x-` keys are ignored.

## The other responses

Every other response gets a Stub of its own, which a request selects with
`Smock-Status` ([Selecting
responses](../importing-openapi.md#selecting-responses)). Its status:

- An explicit code from 200 to 599 answers itself.
- `2XX` to `5XX` answer 200, 300, 400 and 500, as for the main response.
- `default`, when it is not the main response, answers 500.
- `1XX`, and explicit codes from 100 to 199, get no Stub, with a warning:
  smock answers with a status from 200 to 599.

## Bodies

A response's body comes from one of its media types. It is the example that
the document gives there ([Bodies from examples](#bodies-from-examples)),
else one fixed sample of that media type's schema ([Samples from
schemas](#samples-from-schemas)). Either way, it is written in the file.
Nothing is random and nothing is templated, so a reviewer sees what the Mock
answers, and tests repeat. A `200` response whose `application/json` media
type has no example, and whose schema is

```yaml
type: object
properties:
  id: { type: string, format: uuid }
  born: { type: string, format: date }
  tags: { type: array, items: { type: string } }
  password: { type: string, writeOnly: true }
```

answers

```yaml
response:
  status: 200
  json:
    id: 00000000-0000-4000-8000-000000000000
    born: "2000-01-01"
    tags:
      - string
```

- **One media type.** It is `application/json`, with any parameters, else
  the first `+json` type, else the first key. Media types are compared
  case-insensitively, without their parameters. The response's other
  media types are left out, with a warning.
- **Content-Type.** It is written in `headers`, with the key as the
  document writes it. It is not written for plain `application/json` with
  a `json` body, since smock sends that Content-Type itself, nor for a
  range such as `*/*`. A key with a control character is left out, with a
  warning, since a header cannot hold it.
- **`json` or `body`.** A JSON media type, `application/json` or
  `*/*+json`, gives `json`. Under a range such as `*/*` or
  `application/*`, a value that is not a string gives `json` too, so smock
  sends it as JSON: some generators write `*/*` for every response. Any
  other media type gives `body`: a string as it is, and a number or a
  boolean as smock writes it. An object, an array or null there gives an
  empty body, with a warning. These rules hold for examples and samples
  alike.
- **No body.** A response without `content`, or with an empty one, has no
  body and no Content-Type. A media type with neither an example nor a
  schema has an empty body and its Content-Type, with no warning. 204, 205
  and 304 responses, and responses to HEAD, have no body and no
  Content-Type: content that the document gives them is left out, with a
  warning.
- **Order.** In `response`, `status` comes first, then `headers`, then
  `json` or `body`.

## Bodies from examples

The body comes from the examples the API's authors wrote, before any
sample. For the media type a response answers with, the first of these
gives it:

1. its `examples`: the first is the response's body, and each further one
   gets a Stub of its own, which a request selects with `Smock-Example`
   ([Selecting responses](../importing-openapi.md#selecting-responses));
2. its `example`;
3. a sample of its `schema` ([Samples from schemas](#samples-from-schemas)),
   which uses the schemas' own examples at every level.

A media type with both `example` and `examples` uses `examples`, with a
warning. Take a `200` response whose examples are `cat`, then `dog`:

```json
"application/json": {
  "examples": {
    "cat": { "value": { "name": "Tom" } },
    "dog": { "value": { "name": "Rex" } }
  }
}
```

The main Stub answers `cat`, and a Stub of its own answers `dog`:

```yaml
stubs:
  # GET /pets/mine, 200, example dog
  - id: petstore.getPet.200.dog
    mock: petstore
    request:
      method: GET
      path: /pets/mine
      headers:
        Smock-Example: dog
    response:
      status: 200
      json:
        name: Rex
  # GET /pets/mine, 200, example cat
  - id: petstore.getPet.200
    mock: petstore
    request:
      method: GET
      path: /pets/mine
    response:
      status: 200
      json:
        name: Tom
```

An Example Object gives one of its fields:

| Media type | Field, the first it has |
|---|---|
| A JSON media type, `application/json` or `*/*+json` | 3.2's `dataValue`, then `value`, then 3.2's `serializedValue` |
| Any other one, ranges such as `*/*` included | `serializedValue`, then `dataValue`, then `value` |

- A `serializedValue` is the exact text of the body. It is written as
  `body`, with its Content-Type, even for a JSON media type. So
  `{"price": 9.90}` keeps its spaces and its `9.90`.
- `dataValue` and `serializedValue` are read in every OpenAPI version.
- An Example Object with none of these fields, such as one with only an
  `externalValue`, is left out, with a warning. smock reads no
  `externalValue`: it names another file or a URL. The other examples keep
  their order, and when none is left, the next source gives the body.
- An Example Object that is not an object is an error. So is a
  `serializedValue` that is not a string, and `examples` that is not an
  object.
- Example data is copied as data: a `$ref` member in `example`, `value`
  or `dataValue` stays as written, and so do `${` and keys that start
  with `$`. A `$ref` that stands for a whole Example Object is followed.
- An example body above 1 MiB, its compact JSON or its text, is left
  empty, with a warning.

## Samples from schemas

The sample depends only on the schema. For each schema, nested ones
included, after its `$ref` is followed
([Schema references and recursion](#schema-references-and-recursion))
and its `allOf`, `oneOf` and `anyOf` are merged
([Composed schemas](#composed-schemas)), the first of these gives it:

1. `const`;
2. the first of `examples`, in 3.1 and 3.2;
3. `example`;
4. `default`;
5. the first of `enum`;
6. the type.

The values of `const`, `examples`, `example`, `default` and `enum` are
copied as data: a `$ref` member in them stays as written.

The type is the first type other than `null` in a type array, in every
version, and `null` when it is the only one. Without a type, the sample
takes the one the keywords imply, tried in this order:

| Type | Keywords |
|---|---|
| object | `properties`, `required`, `additionalProperties`, `patternProperties`, `propertyNames`, `minProperties`, `maxProperties` |
| array | `items`, `prefixItems`, `contains`, `minItems`, `maxItems`, `uniqueItems` |
| integer | `format` `int32` or `int64` |
| number | `format` `float` or `double`, or `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf` |
| string | `minLength`, `maxLength`, `pattern`, or any other `format` |

Else the sample is null. `nullable` changes nothing. The schema `true`
samples as null. The schema `false` gives no value: a property whose
schema is `false` is left out, and as the whole body it gives an empty
body.

- **Strings** sample as the fixed sample of their `format`, from the
  table below. Any other format, or none, gives `"string"`, repeated or
  cut to fit `minLength` and `maxLength`. Length bounds do not change a
  format's sample.
- **Booleans** sample as `true`.
- **Numbers** sample within their bounds: 0 when the bounds allow it,
  else the nearest bound ([Numbers](#numbers)).
- **Arrays** have `minItems` items, at least 1 and at most 100, with a
  warning past 100. `maxItems: 0` gives `[]`. Items come from
  `prefixItems`, then `items`, and the array ends where neither gives one.
  An array with neither gives `[]`.
- **Objects** have every property in `properties`, required or not, in
  the order written, except `writeOnly` ones. `additionalProperties` and
  `patternProperties` add nothing. A name in `required` that no property
  defines is not added.

| `format` | Sample |
|---|---|
| `date-time` | `2000-01-01T00:00:00Z` |
| `date` | `2000-01-01` |
| `time` | `00:00:00Z` |
| `duration` | `P1D` |
| `email`, `idn-email` | `user@example.com` |
| `hostname`, `idn-hostname` | `example.com` |
| `ipv4` | `192.0.2.1` |
| `ipv6` | `2001:db8::1` |
| `uri`, `uri-reference`, `iri`, `iri-reference` | `https://example.com/` |
| `uri-template` | `https://example.com/{id}` |
| `uuid` | `00000000-0000-4000-8000-000000000000` |
| `json-pointer` | `/a` |
| `relative-json-pointer` | `0` |
| `regex` | `.*` |
| `byte` | `c3RyaW5n` |

The sampler does not honour these keywords, so a sample may not satisfy
them: `pattern`, `multipleOf`, `uniqueItems`, `contains`,
`minProperties`, `maxProperties`, `propertyNames`, the `dependent`
keywords, the `unevaluated` keywords and the `content` keywords. They are
ignored without a warning.

A keyword the sampler reads that has the wrong type, such as
`minItems: "3"`, is ignored, with a warning at its pointer. A Media Type
Object that is not an object, or a `schema` that is neither an object nor
a boolean, is an error.

The file has no template, so `${` in a value and keys that start with `$`
are written as they are, with no escaping.

### Numbers

A number or an integer samples within `minimum`, `maximum`,
`exclusiveMinimum` and `exclusiveMaximum`, so that a client that checks
ranges accepts it. In a 3.1 document:

```yaml
count: { type: integer, minimum: 10, maximum: 20 }                   # samples as 10
offset: { type: integer, minimum: -5 }                               # 0
ratio: { type: number, exclusiveMinimum: 0 }                         # 1
weight: { type: number, exclusiveMinimum: 0, exclusiveMaximum: 1 }   # 0.5
```

- **The value.** 0 when the bounds allow it. Else the nearest bound,
  moved by 1 inside an exclusive bound, or to the middle of the two bounds
  when that leaves the range.
- **Versions.** In 3.0, `exclusiveMinimum` and `exclusiveMaximum` are
  `true` or `false`, and `true` makes `minimum` or `maximum` exclusive. In
  3.1 and 3.2, they are numbers, and the tighter of a bound and its
  exclusive form counts, the exclusive one when they are equal. One of the
  wrong type for the version is ignored, with a warning.
- **Integers.** A bound that is not whole is rounded inward: a lower bound
  up, an upper bound down. So `exclusiveMinimum: 2.5` gives 3. The middle
  is rounded down.
- **Nothing fits.** When no integer fits the bounds, as for
  `minimum: 0.25` with `maximum: 0.75`, the sample is the lower bound,
  rounded up, with a warning. So is a number's when no number fits, as
  for a `minimum` above the `maximum`.
- **Exact digits.** The arithmetic is exact decimal arithmetic on the
  shortest decimal text of each bound: the shortest text that reads back
  as the same 64-bit float, or every digit of a large integer. So every
  platform writes the same digits. A bound written with more digits than
  a float keeps is read as that shortest text:
  `minimum: 0.30000000000000001` is `0.3`. The sample is a plain
  decimal, without an exponent: `exclusiveMinimum: 0` with
  `exclusiveMaximum: 1e-18` gives `0.0000000000000000005`.
- **Large bounds.** A bound whose shortest text has more than 18 digits
  before or after the point, such as `1e20` or `1e-19`, is ignored, with
  a warning.
- **`allOf`.** Each bound comes from the schema's own keyword, else from
  the first branch that has it, not from the tightest branch.

### Composed schemas

A schema with `allOf`, `oneOf` or `anyOf` is first merged with its
branches into one schema, which is then sampled as above. Generators write
such schemas for shared parts, and a nullable field as a `oneOf` with a
null branch. The schema

```yaml
allOf:
  - type: object
    required: [id]
    properties:
      id: { type: string, format: uuid }
  - type: object
    properties:
      email:
        oneOf:
          - type: "null"
          - type: string
            format: email
```

samples as

```yaml
json:
  id: 00000000-0000-4000-8000-000000000000
  email: user@example.com
```

- **`allOf`** is merged in order, a nested `allOf` included. `properties`
  are joined by name, the schema's own first. A property met again is
  merged the same way, with the one met first as its own schema.
  `required` is joined. For any other keyword, such as `type`, `format` or
  `items`, the schema's own value wins, then the first branch that has
  one.
- **Values from branches.** A branch's `const`, `examples`, `example`,
  `default` and `enum` are used only when the merged schema is not an
  object, since a branch's example shows only its part of an object. The
  schema's own are used on an object too. Each keyword is merged on its
  own, so a branch's `const` still comes before the schema's own
  `example`, in the order of the list above.
- **`oneOf` and `anyOf`** take their first branch that is not only null,
  such as `{ type: "null" }`, `{ const: null }` or `{ enum: [null] }`. A
  branch that is a `$ref` to such a schema, such as a `Null` schema under
  `components`, counts as only null too. The branch is merged with the
  schema's own keywords, after the branches of `allOf`. When every branch
  is only null, the sample is null.
- **`true` and `false`.** The branch `true` adds nothing. The branch
  `false` allows no value: in `allOf`, the schema then gives no value, and
  `oneOf` and `anyOf` skip it, as written or named by a `$ref`.
- **Ignored.** `not`, `if`, `then`, `else` and `discriminator` are ignored,
  without a warning.
- **Wrong types.** An `allOf`, `oneOf` or `anyOf` that is not an array,
  and a branch that is neither an object nor a boolean, are ignored, with
  a warning. A keyword of the wrong type is ignored, with a warning where
  it is written, in a branch too. The next branch that has the keyword
  then gives it.

### Schema references and recursion

A `$ref` in a schema is followed, by the rules of other references
([References and bundling](references-and-yaml.md#references-and-bundling)),
and the schema it names is sampled in its place. A schema may name itself,
directly or through others. The schema

```yaml
components:
  schemas:
    Node:
      type: object
      required: [name]
      properties:
        name: { type: string }
        parent: { $ref: "#/components/schemas/Node" }
        children:
          type: array
          items: { $ref: "#/components/schemas/Node" }
```

samples as

```yaml
json:
  name: string
  children: []
```

- **Keywords beside a `$ref`.** In 3.1 and 3.2, the schema the `$ref`
  names counts as part of the schema that holds the `$ref`, not as an
  `allOf` branch. The keywords beside the `$ref` come first, then those of
  the schema it names, merged by the rules of `allOf`: `properties` joined
  by name and `required` joined, and for any other keyword the first that
  has one ([Composed schemas](#composed-schemas)). So
  `{ $ref: "#/components/schemas/Pet", example: { name: Rex } }` samples
  as its own example, and
  `{ $ref: "#/components/schemas/Pet", description: A pet }` as Pet's
  `example`, on an object too, where an `allOf` branch's would not be
  used. In 3.0, the keywords beside a `$ref` are ignored, as 3.0
  asks.
- **Recursion.** A schema reached again through a `$ref` it is already
  being sampled from ends the sample there. As an optional property, it is
  left out. As the items of an array, it gives no item, so the array is
  `[]`. Otherwise, as a required property, it is null.
- **Cycles in `allOf`.** A `$ref` met again while a schema is merged with
  its branches is skipped, so two schemas whose `allOf` name each other
  are merged once each. A cycle of schemas is allowed, unlike a cycle of
  other references.
- **Depth.** A sample nests at most 32 levels: an object or an array
  inside 32 others is null. Values copied from `const`, `examples`,
  `example`, `default` and `enum` are not cut.
- **`writeOnly`.** In 3.1 and 3.2, a property that is `writeOnly` beside
  a `$ref` is left out without following the `$ref`.
- **Identifiers.** A `$id` inside a document is an error when a `$ref`
  lies under it, or beside it, since it would change what the `$ref`
  names: smock does not resolve `$id`. Without one, it is ignored. So is a
  `$id` at the root of a document, the one given or another file.
  `$dynamicRef` is an error. `$schema` and `jsonSchemaDialect` are
  ignored.

### Sample size

A sample is first made with every property. Wide schemas that nest grow
fast, so its size is bounded:

- **Cut.** When its compact JSON would pass 64 KiB, it is made again with
  only the required properties, and only `minItems` items, none when
  `minItems` is 0, in every object and array nested more than one level
  below the body. The body and the objects and arrays right inside it keep
  every property and item. In YAML, the Stub's comment says `sample cut`.
- **Empty.** When the cut sample would pass 1 MiB, the body is left
  empty, with a warning.
- **Bounded work.** The sampler stops as soon as a sample passes its
  bound, so neither time nor memory grows past it.
- **Problems.** Only the problems of the sample that is written are
  reported: a part that only the first sample reached gives none.
- **Headers.** A header's sample has the same bounds. When the cut
  sample would pass 1 MiB, the header's value is empty, with a warning.

## Response headers

Each header that a response documents in `headers` is written in the
Stub's response, so that clients that read it see it. Every Stub of the
response sends it, those of its named examples too. A `200` response with

```yaml
headers:
  X-Rate-Limit:
    schema: { type: integer }
  X-Request-Id:
    example: req-1
  Content-Length:
    schema: { type: integer }
```

answers

```yaml
response:
  status: 200
  headers:
    X-Rate-Limit: "0"
    X-Request-Id: req-1
```

- **Value.** A header is written with its `example`, else the first of
  its `examples` that gives a value, else a sample of its `schema`
  ([Samples from schemas](#samples-from-schemas), bounded as in
  [Sample size](#sample-size)). With none of these, it is left out, with
  a warning (see below).
- **Example Objects.** An Example Object gives a header its
  `serializedValue` first, since it is the exact text of the header, then
  its `dataValue`, then its `value`.
- **`content`.** A header described with `content` takes its value the
  same way from the media type there, after its own `example` and
  `examples`.
- **Text.** A string is written as it is. A number is written as smock
  writes numbers, a boolean as `true` or `false`, and an array of these
  joined with `,`, as style `simple` asks: `["a", 1]` is `a,1`.
- **Order.** In `headers`, the `Content-Type` comes first, then the
  documented headers, in the order the document writes them.

These are skipped without a warning, since documenting them is common and
right: `Content-Type`, which OpenAPI says to ignore here, and
`Content-Length`, `Transfer-Encoding` and `Connection`, which smock sets
itself.

These are left out, with a warning:

- `Smock-Mock`, which smock adds itself when the Default Mock answers;
- a name that is not an HTTP token, such as one with a space;
- a name that repeats an earlier one in another case, such as `x-id`
  after `X-Id`, since header names are case-insensitive;
- a header that nothing gives a value: one with no `example`, and no
  `examples`, `schema` or `content` that gives one, or one whose schema
  allows no value, such as `schema: false`;
- a value that is an object or null, or an array that holds one or an
  array;
- a value with a character HTTP forbids in a field value: an ASCII
  control character other than tab, such as a line break.

A header with both `example` and `examples` uses `example`, with a
warning. The examples after the one that gives the value are left out,
with a warning each. A `schema` beside `content` is ignored, with a
warning, and so is each media type of `content` after the first.

## IDs and conditions that repeat

- Two imported operations with the same `operationId` are an error that
  names both places. So is any generated Stub ID that repeats. A Path
  Item that two path keys name through `$ref` gives two operations, so an
  `operationId` in it is an error.
- When two operations' method and path come out the same, the first in
  document order is kept, and the later one is left out with a warning.
  Two paths that decode alike, such as `/a%2Fb` and `/a/b`, are the same
  path. Two templated paths that differ only in their parameters' names,
  such as `/pets/{id}` and `/pets/{petId}`, give the same pattern.
- Operations that are left out take part in neither check.
