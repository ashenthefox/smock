# Migrating from Mockoon

This guide turns a Mockoon environment into Definition files for smock.
It is written for Mockoon 9.x environment files, whose `lastMigration` is
33, and its statements about Mockoon were checked against Mockoon 9.9.0,
its documentation and its source from 2026-10-17 to 2026-10-22. It starts
with what smock does not do, so that a reader whose environments depend
on one of those features can stop there. A [worked
example](mockoon/worked-example.md) then translates one environment step by
step, and a [reference](mockoon/mapping-reference.md) maps every part of an
environment that has a counterpart:

- The example is in [`examples/from-mockoon/`](examples/from-mockoon/):
  the Mockoon environment `mockoon/users-api.json`, and the definitions
  directory `defs/` that replaces it. `smock check` passes on it, and
  both servers give the answers this guide shows.
- Mockoon's own words (environment, route, response, rule) name
  Mockoon's features. smock's terms, such as Mock and Stub, are
  introduced [below](#how-the-models-differ) and defined in
  [GLOSSARY.md](../GLOSSARY.md).
- Unless a step says otherwise, the commands run in
  `docs/examples/from-mockoon/`, with `mockoon-cli` and `smock` on the
  `PATH`. [Running it where Mockoon ran](#running-it-where-mockoon-ran)
  says where to get smock.
- The guide and its example need smock 0.3.0 or later. The operators and the
  cookie, form and XML conditions that
  [Rules](mockoon/mapping-reference.md#rules) maps came in 0.2.0. Data
  buckets and CRUD Stubs, Variables, `responses`, the template roots
  `cookie` and `env`, the helpers for text, encodings, JWTs, dates and
  arithmetic, `find`, byte ranges and `smock import-openapi` came in 0.3.0.
  An older smock fails to load a Definition file that uses one of those
  fields, roots or helpers, and `smock check` names each, as in `/data: is
  not a known field` or `unknown helper "add"`.

The worked example and the reference are documents of their own, in
`docs/mockoon/`, and the [Contents](#contents) lists them: the example takes
three, read in order, and the reference one. This document holds the rest of
the guide. The notes above hold for all five documents.

## Contents

In this document:

- [What smock does not do](#what-smock-does-not-do)
- [How the models differ](#how-the-models-differ)
- [A worked example](#a-worked-example)
- [Behaviour that differs](#behaviour-that-differs)
- [Checking the migration](#checking-the-migration)
- [Running it where Mockoon ran](#running-it-where-mockoon-ran)
- [Logs](#logs)
  - [Turning it on](#turning-it-on)
  - [Mockoon's lines in smock](#mockoons-lines-in-smock)
  - [How the lines differ](#how-the-lines-differ)

In the other documents:

- [A worked example: from the routes to the CRUD route](mockoon/worked-example.md)
  - [List the routes Mockoon serves](mockoon/worked-example.md#list-the-routes-mockoon-serves)
  - [Declare the Mock](mockoon/worked-example.md#declare-the-mock)
  - [Environments told apart by port](mockoon/worked-example.md#environments-told-apart-by-port)
  - [One Stub per response](mockoon/worked-example.md#one-stub-per-response)
  - [Paths and request conditions](mockoon/worked-example.md#paths-and-request-conditions)
  - [Bodies, headers and templates](mockoon/worked-example.md#bodies-headers-and-templates)
  - [Latency, CORS and the CRUD route](mockoon/worked-example.md#latency-cors-and-the-crud-route)
- [A worked example: answers that change between requests](mockoon/worked-example-state.md)
  - [Answers that change between requests](mockoon/worked-example-state.md#answers-that-change-between-requests)
    - [Random responses](mockoon/worked-example-state.md#random-responses)
    - [Global variables](mockoon/worked-example-state.md#global-variables)
    - [Data buckets](mockoon/worked-example-state.md#data-buckets)
- [A worked example: the result](mockoon/worked-example-result.md)
- [Mapping reference](mockoon/mapping-reference.md)
  - [Environments and routes](mockoon/mapping-reference.md#environments-and-routes)
  - [Rules](mockoon/mapping-reference.md#rules)
  - [Responses](mockoon/mapping-reference.md#responses)
  - [Template helpers](mockoon/mapping-reference.md#template-helpers)
  - [Running and operating](mockoon/mapping-reference.md#running-and-operating)

## What smock does not do

These Mockoon features have no counterpart in smock. Where something
covers part of the need, the item says what.

- **Proxy mode and recording.** smock never forwards a request to the
  real service and never records traffic: every answer comes from a
  Stub, and a request that no Stub matches gets a 404. Before switching,
  find the paths that clients reached through the proxy: the Mockoon CLI
  logs each request with `"requestProxied":true` or `false`. smock's
  `mockoon` log format writes `"requestProxied":false` on every request
  ([Logs](#logs)).
- **Some features of data buckets and CRUD routes.** A data bucket becomes a
  [Data bucket](definition-files/data-buckets.md#data-buckets), and a CRUD
  route a [CRUD Stub](definition-files/crud-stubs.md#crud-stubs), as [the
  CRUD route](mockoon/worked-example.md#latency-cors-and-the-crud-route) of
  the example and [Data
  buckets](mockoon/worked-example-state.md#data-buckets) show. These have no
  counterpart:
  - templated or generated bucket content: a bucket's initial value is
    static JSON, so save the value that Mockoon generated
    ([Behaviour that differs](#behaviour-that-differs));
  - CRUD routes over a bucket that is not an array of objects with keys,
    such as an object or an array of texts: ordinary Stubs read and write
    such a bucket ([Data
    buckets](mockoon/worked-example-state.md#data-buckets));
  - nested keys, such as a `crudKey` of `data.id`;
  - list operators other than equality, such as `_gt` and `_like`, and
    `search`;
  - `PUT`, `PATCH` and `DELETE` on a whole list: ordinary Stubs with
    `dataWrites` take them ([Data
    buckets](mockoon/worked-example-state.md#data-buckets));
  - writes to a path inside a value, as `setData` takes: a write sets or
    merges a whole bucket, or one item of a bucket with keys.
- **Callbacks.** smock never sends a request of its own. A test that
  relied on a callback sends that request to the callback's URL itself,
  and can check in the Journal that the request that fired it arrived.
- **WebSockets.** smock serves HTTP/1.1, HTTP/2 and HTTPS. It can stream
  Server-Sent Events, which only a client written for them reads.
- **Schema validation, multipart bodies and rules on state.** The
  `valid_json_schema` operator has no counterpart, and a multipart body can
  be matched only by a pattern on the whole body. The rule targets
  `global_var`, `data_bucket` and `templating` have none either: a condition
  reads the request, never a Variable or a Data bucket.
  [Rules](mockoon/mapping-reference.md#rules) maps the other rules, `invert`
  and rules on cookies, form fields and XML bodies included.
- **Some Handlebars helpers.** smock's templates are not Handlebars.
  [Template helpers](mockoon/mapping-reference.md#template-helpers) maps the
  helpers that have a counterpart, among them arithmetic, strings, dates,
  JWTs, cookies, environment variables and global variables. These have
  none:
  - array literals, local variables (`setVar` and `getVar`), and
    comparisons other than `==` and `!=`, such as `gt` and `lt`;
  - helpers that filter, sort or merge arrays and objects, such as
    `filter`, `sort` and `objectMerge`;
  - `jsonParse`, `someOf`, `objectId`, random dates (`date` and `time`)
    and faker locales;
  - the `status` helper:
    [`responses`](mockoon/worked-example-state.md#random-responses) vary the
    status instead;
  - setting a global variable or a data bucket from inside a template: a
    Stub's `variables` set
    [Variables](mockoon/worked-example-state.md#global-variables), and its
    `dataWrites` write [Data
    buckets](mockoon/worked-example-state.md#data-buckets), instead;
  - local time and time-zone names: Mockoon writes dates in its process's
    time zone, such as `TZ=Asia/Tokyo`, and smock in UTC or at a fixed
    offset, such as `+09:00`. Neither has date locales: month and day
    names are in English;
  - the `MOCKOON_` prefix of environment variables: `--template-env` lists
    each name in full.
- **A port or a path prefix per environment.** One smock serves all its
  Mocks on one plain port and one TLS port, and tells them apart by the
  request's Host. [Environments told apart by
  port](mockoon/worked-example.md#environments-told-apart-by-port) gives the
  two ways round it.
- **Response limits.** A response's status is from 200 to 599. A body
  file serves one byte range at a time, never `multipart/byteranges`, and
  there are no conditional requests, since smock sends no `ETag` or
  `Last-Modified`. Mockoon has neither, but sends the first of several
  ranges where smock sends the whole body
  ([Behaviour that differs](#behaviour-that-differs)).
- **OpenAPI export, and a GUI.** smock writes no OpenAPI document, and
  Definition files are edited as text. Editors can check them against the
  JSON Schema ([editor support](definition-files.md#editor-support)).
- **Windows and macOS.** smock runs on Linux, on amd64 and arm64, or in a
  Linux container.

An environment that Mockoon imported from an OpenAPI document can be
imported into smock from the same document, with `smock import-openapi`,
instead of being translated by hand.
[Importing OpenAPI](importing-openapi.md) explains the command, and its
[notes for Mockoon users](importing-openapi.md#notes-for-mockoon-users)
say where the result differs from Mockoon's import. Only what was changed
in the environment after the import, such as rules, is then translated
with the steps of the [worked example](mockoon/worked-example.md).

## How the models differ

A Mockoon environment is a server of its own: a port, a path prefix, and
routes in order, each with responses in order that rules choose between.
smock's model is flatter:

- A *Definition file*, in YAML or JSON, declares *Mocks* and their
  *Stubs*. The files sit in a definitions directory, such as `defs/`,
  with body files in its `files/` subdirectory, and smock reloads them
  when they change.
- A Mock stands in for one service, as an environment does. A request
  reaches a Mock by its Host, not by its port. A lone Mock is the
  *Default Mock*, which also answers requests for Hosts that no Mock
  lists.
- A Stub pairs request conditions with one response, or with several
  `responses` that it picks from at random. Each response of a Mockoon
  route becomes a Stub of its own, whose conditions are the route's
  method and path plus the response's rules, except that the responses of
  a `RANDOM` route share one Stub.
- The first Stub that matches a request answers it. Stubs are tried in
  the order they are declared, unless `priority` reorders them, so the
  order of the routes, and of the responses within each route, carries
  over.
- A *Scenario* is a named state machine within a Mock, which starts in the state
  `Started`. A Stub can require one of its states and move it to
  another, so that the same request gets different answers at different
  points of a flow.
- A *Variable* is a named JSON value that a Stub writes when it matches,
  and that templates read. Like a Scenario's state, it is kept per Mock
  and per Session. Variables stand in for global variables.
- A *Data bucket* is a named JSON value that a Mock declares with its
  initial value, as an environment declares a data bucket. Templates read
  it, and Stubs write it when they match. Each Session reads and writes a
  copy of its own. A *CRUD Stub* serves a bucket of objects with keys as
  a REST resource, as a CRUD route does.
- A response is a template only with `template: true`, and templates
  insert values with `${…}` expressions, not Handlebars.
- A request that no Stub matches gets a 404 whose `Smock-Near-Miss`
  header names the *Near miss*: the Stub that came closest, and the
  conditions it failed.

[docs/definition-files.md](definition-files.md) and the documents it lists
describe the format in full.

## A worked example

The worked example translates one environment step by step, in three
documents read in order: [the steps up to its CRUD
route](mockoon/worked-example.md), [answers that change between
requests](mockoon/worked-example-state.md), and [the
result](mockoon/worked-example-result.md). The sections below refer to its
Stubs.

## Behaviour that differs

Even a faithful translation answers some requests differently. These
differences were checked against Mockoon CLI 9.9.0 from 2026-10-17 to
2026-10-22, most of them by sending the same requests to both servers,
with the example or with small environments made to test them:

- **Paths.** Mockoon matches paths case-insensitively, accepts a trailing
  slash and merges repeated slashes. smock compares the decoded path
  exactly, so `GET /API/V1/USERS` and `GET /api/v1/users/` reach
  `list-users` in Mockoon and get 404 from smock. Where clients rely on
  that, use a pattern such as `(?i)/api/v1/users/?`.
- **Request bodies.** Mockoon parses JSON, form, multipart and XML bodies by
  their Content-Type before its rules read them ([supported body
  formats](https://mockoon.com/docs/latest/requests/supported-body-formats/)),
  and a rule with a path reads whichever it got. Each smock body condition
  reads one format: `json` and `xml` parse the body whatever its
  Content-Type, and `form` reads it only with the form Content-Type. So the
  form `name=Alice&role=admin`, sent with the key to `POST /api/v1/users`,
  gets 201 from Mockoon and 403 from smock, whose `create-user` has only a
  `json` condition, and the same JSON without a Content-Type gets 403 from
  Mockoon and 201 from smock. A second Stub with `body: { form: { role:
  admin } }` would take the form, but its answer could not repeat the name:
  in a template, `${body.x}` reads JSON bodies only.
- **Content-Type.** Mockoon adds `; charset=utf-8` to the Content-Type of
  a body it sends as text: an inline body, whatever its type, so
  `application/json; charset=utf-8` and `text/plain; charset=utf-8`, and
  even `application/pdf; charset=utf-8` for a `fallbackTo404` body; and a
  file of a type that it renders as a template, such as JSON. It sends
  other files, such as a PDF, with the type alone, and an inline body
  with no Content-Type configured as `text/html; charset=utf-8`. smock
  sends the Content-Type exactly as the Stub gives it; without one, a
  `json` body gets `application/json`, and other bodies get none. Where
  clients compare the whole value, give it with the charset, as in
  `Content-Type: application/json; charset=utf-8`.
- **Body bytes.** Mockoon sends an inline body with the spacing it was
  written with. smock writes `json` compactly, numbers in their shortest
  form (`9.90` as `9.9`), except the output of `fake.decimal`, which
  keeps its places (`25.00`). Compare bodies after `jq -S`, or write the
  body as `body` text where the exact bytes matter.
- **Escaping.** Mockoon's `body` and `queryParam` helpers insert values
  as they are, so `GET /api/v1/users/7?lang=a%22b` makes the example's
  body invalid JSON in Mockoon. Its other values, `urlParam` and
  `header` among them, are escaped for HTML: `GET /api/v1/users/a%22b`
  answers `"id": "a&quot;b"`. smock escapes every inserted value for the
  response's Content-Type, and in `json` always as JSON, so it answers
  `"lang":"a\"b"` and `"id":"a\"b"`; it escapes for HTML only in HTML
  and XML responses.
- **Unmatched requests.** Mockoon answers a request that no route takes
  with 404, the `text/html` page "Cannot GET /path", and the environment
  headers, CORS headers among them, except a few that it replaces or
  drops for that page, such as Content-Type and Content-Language. smock
  answers with the Mock's `noMatch.status`, 404 by default, the body
  `{"error":"no Stub matched"}`, a header such as
  `Smock-Near-Miss: list-users; failed=path`, and the Mock's
  `noMatch.headers`. Copy there the environment headers that clients rely
  on, except Content-Type, which smock sets to `application/json`.
  Without the CORS headers, a page on another origin that reads a 404
  from Mockoon gets a CORS error from smock. For the environment headers
  `Access-Control-Allow-Origin: http://localhost:5173` and
  `Access-Control-Allow-Credentials: true`, the Mock becomes:

  ```yaml
  mocks:
    - name: users-api
      hosts: [localhost, users-api]
      noMatch:
        headers:
          Access-Control-Allow-Origin: http://localhost:5173
          Access-Control-Allow-Credentials: "true"
          Access-Control-Expose-Headers: Smock-Near-Miss
  ```

  The last header, which Mockoon does not send, lets that page read the
  Near miss too.
- **Sequences and request numbers.** Mockoon keeps one count for each route,
  which every client moves. smock keeps a Scenario's state for each Session,
  in each replica, and moves it only when a Stub with `moveTo` answers
  ([Answers that change between
  requests](mockoon/worked-example-state.md#answers-that-change-between-requests)).
- **Random responses.** No run of a Mockoon `RANDOM` route can be
  repeated. smock's pick follows `fault.seed` and `--seed`, and its
  weights stand for copies of a response
  ([Random responses](mockoon/worked-example-state.md#random-responses)).
- **Global variables.** Mockoon keeps one set for each environment, which
  every client reads and writes, and its templates set them. smock keeps
  Variables for each Mock and Session, in each replica, and writes them when
  a Stub matches ([Global
  variables](mockoon/worked-example-state.md#global-variables)).
- **Data buckets.** Mockoon keeps one value for each bucket, which every
  client reads and writes, and writes it while a template renders, or after
  the latency of a CRUD route's response. smock keeps a copy for each Mock
  and Session, in each replica, and writes it when a Stub matches, before
  any delay ([Data buckets](mockoon/worked-example-state.md#data-buckets)).
- **Bucket content.** Mockoon renders a bucket's content as a Handlebars
  template when it starts, and again on a purge, so `{{faker …}}` in it
  gives new data each time. smock never templates a bucket: every Session
  starts from the same JSON. To keep the data that Mockoon generated,
  start it with `--admin-api-token change-me`, read the bucket by its
  `id`, and save its value as the bucket's `jsonFile`:

  ```sh
  curl -s -H "Authorization: Bearer change-me" localhost:3000/mockoon-admin/data-buckets/ordr |
    jq .value >defs/files/orders.json
  ```

  A bucket whose content reads the request, such as with `body` or
  `urlParam`, is generated when a route first uses it, so send that
  request first. A key written as a template also makes the keys of
  Mockoon's creates: a key such as `"id": "{{faker 'string.uuid'}}"`
  becomes `newKey: uuid`, and other key templates have no counterpart.
- **CRUD routes.** A CRUD Stub answers some requests differently from a
  CRUD route:
  - A CRUD Stub compares its paths exactly, as other Stubs do, and takes
    no pattern: `GET /API/V1/ORDERS` and `GET /api/v1/orders/` reach the
    CRUD route, and get 404 from smock.
  - A missing item gets 404 with `{}` from Mockoon, and with
    `{"error":"no item with this key","stub":"orders","key":"9"}` from
    smock.
  - A delete answers `{}` in Mockoon, and the removed item in smock.
  - A create answers with `Location`, such as `/api/v1/orders/3`, in
    smock only.
  - A `PUT` or `PATCH` whose body holds another key changes the item's key
    in Mockoon. smock keeps the key, and answers 400
    `key does not match the path`.
  - A body that is not a JSON object is stored by Mockoon: a JSON text,
    such as `"pen"`, is added as it is, and a create without a body adds
    an item that holds only a new key. smock answers 400
    `body is not a JSON object`, and stores nothing. A create whose key
    an item has adds a second item with that key in Mockoon, and gets 409
    `key already exists` from smock.
  - smock reads the body as JSON whatever its Content-Type. Mockoon reads
    JSON only with a JSON Content-Type, so `curl -d '{"item":"pencil"}'`,
    which sends a form's, stores an item with one form field, named
    `{"item":"pencil"}`.
  - Mockoon sorts texts in lower case, so `apple` comes before `Book`.
    smock sorts them by code point, case-sensitively, so `Book` comes
    before `apple`.
  - A list parameter that Mockoon does not read is ignored there, and is a
    filter in smock, which no item meets ([The CRUD
    route](mockoon/worked-example.md#latency-cors-and-the-crud-route)).
  - A create without a key gets one more than the highest numeric key in
    both. With no numeric key, an empty bucket included, Mockoon gives a
    UUID, and smock gives 1, or the next integer that no key has, unless
    the bucket takes `newKey: uuid`. Give that to a bucket whose keys are
    UUIDs.
- **Range requests.** Both serve byte ranges only from a body file that
  is not a template, but they differ in what they serve:
  - Mockoon serves a range to any method, such as `POST`, and in place
    of any status, a 404 included. smock serves one only to a `GET` of a
    200.
  - For a malformed `Range`, such as `bytes=abc`, Mockoon answers 400.
    For a range whose last position is below its first, such as
    `bytes=5-2`, it answers 416. For several ranges it sends the first,
    and it takes another unit, such as `items=0-5`, as bytes. It ignores
    `If-Range`. smock sends the whole body with 200 in each of these
    cases.
  - Mockoon's 416 carries no `Content-Range`, and its body is the text
    `Requested range not satisfiable`. smock's carries
    `Content-Range: bytes */<length>` and no body, along with the Stub's
    headers.
  - Mockoon sends `Accept-Ranges: bytes` only with a 206. smock also
    sends it with the 200 of a body file that serves ranges.

  [Range requests](definition-files/responses.md#range-requests) has smock's
  rules.
- **Latency of unmatched requests.** Mockoon's environment latency delays
  its 404s too. A smock delay applies only to the requests its Stub
  matches.
- **HEAD.** Neither answers `HEAD /api/v1/users` from its `GET` route or
  Stub: both send 404.
- **Hosts.** Mockoon does not look at the Host. With several Mocks, smock
  sends a request for a Host that no Mock lists to the Default Mock, marked
  `via=default`, or answers 404 `no Mock for this Host` when there is no
  Default Mock ([Hosts and the Default
  Mock](definition-files.md#hosts-and-the-default-mock)).
- **Template errors.** Mockoon answers a template that fails with the
  response's own status and a `text/plain` message. smock finds most
  template errors when it loads the files, and answers one that fails
  for a request with 500 and `{"error":"template failed",…}`. Most
  Mockoon helpers never fail: an unknown helper gives an empty text, and
  a value of the wrong kind gives an empty text, `NaN`, or is skipped, so
  `{{add '1' '2' 'dolphins' '3'}}` gives `6`. smock reports an unknown
  helper, and a literal of the wrong kind, when it loads the files, and a
  value of the wrong kind from the request fails the template, so
  `${add(query.n, 1)}` with `?n=dolphins` gets the 500. A few Mockoon
  helpers fail where smock's do not: `{{uppercase 5}}` fails, and
  `${uppercase(5)}` gives `5`.
- **Text.** Mockoon counts the length of a text and the positions in it
  in UTF-16 units, as JavaScript does, so `{{len '😀'}}` gives `2`, and
  `substr` can cut an emoji in two. smock counts code points, so
  `len('😀')` gives `1`.
- **Request size.** Mockoon accepts request bodies up to 100 MB by
  default; smock accepts up to 10 MiB (`--body-limit`), and answers
  longer ones with 413.
- **Fake data.** smock draws names and words from built-in lists of ASCII
  names and English words, with no locale. `fault.seed` on a Stub
  repeats them from run to run, and so does `--seed` for the same
  requests in the same order, as `--faker-seed` does in Mockoon.
- **Dates.** Both write dates with date-fns format tokens, so
  `{{now 'yyyy-MM-dd'}}` becomes `${now('yyyy-MM-dd')}`, but six things
  differ:
  - Mockoon writes local time, in its process's time zone, with an
    offset: `{{now}}` gives `2026-10-17T14:01:59.615+00:00` in UTC, and
    `2026-10-17T23:01:59.615+09:00` under `TZ=Asia/Tokyo`. smock writes
    UTC with `Z`: `now()` gives `2026-10-17T14:01:59.615Z`. Where clients
    compare the text, write
    `${now("yyyy-MM-dd'T'HH:mm:ss.SSSxxx")}`, which gives `+00:00`, or
    `dateFormat` with a fixed offset, such as
    `${dateFormat(now(), "yyyy-MM-dd'T'HH:mm:ss.SSSxxx", '+09:00')}`.
  - Mockoon takes the week-numbering year (`YYYY`, `YY`) and the day of
    the year (`DD`, `D`) where it finds them, so a format of
    `yyyy-MM-DD`, which Mockoon's own documentation shows, writes
    `2026-02-36` on February 5. smock refuses those tokens when it loads
    the files: write `yyyy` and `dd`.
  - Mockoon reads a date with JavaScript's `new Date(…)`, which takes a
    date-time without an offset as local time, and other texts by rules
    of its own. smock takes an RFC 3339 date-time with an offset, a date
    `YYYY-MM-DD` or epoch milliseconds, and nothing else: any other value
    is missing, so `??` gives a fallback.
  - Mockoon's `dateTimeShift` rolls a day past the end of the month over
    into the next one, so January 31, 2026 plus one month is March 3.
    smock stops at the last day of the month, February 28.
  - Mockoon shifts days first, then months and years; smock shifts years
    and months first, then days.
  - Mockoon writes the year 0, 1 BC, under `yyyy` and `yy` as date-fns's
    year of the era, `0001` and `01`, so
    `{{dateFormat '0000-06-01' 'yyyy-MM-dd'}}` gives `0001-06-01`. smock
    writes the calendar year, `0000` and `00`, as its RFC 3339 times do,
    so `${dateFormat('0000-06-01', 'yyyy-MM-dd')}` gives `0000-06-01`.
- **Logs.** The Mockoon CLI logs every request. By default smock logs
  none, and records them in the Journal instead. Its `mockoon` log
  format writes the Mockoon CLI's lines, with the differences that
  [Logs](#logs) lists.

## Checking the migration

`smock check` reads a definitions directory as `smock serve` would, and
prints every problem with its file and a JSON Pointer. It also warns
about two things that often show a slip in the translation
([warnings](definition-files.md#warnings)): a Stub that can never match
because an earlier one always matches first, which often means that
responses were written in the wrong order, and a state that a Stub
requires but no Stub moves to, which often means a typo in a state name:

```sh
smock check defs   # prints nothing and exits with 0 for the example
```

In CI, run it as a step that fails the build: `- run: smock check defs`.

The first warning compares a pattern only with an exact path, never with
another pattern ([warnings](definition-files.md#warnings)), so it misses
two Stubs in the wrong order whose paths are both patterns: with
`get-user` declared before `get-user-missing`, `smock check` prints
nothing, and `GET /api/v1/users/000` gets 200. Those are the Stubs of
routes with parameters, so check them with `smock render` or with
requests, as below.

`smock render` shows, without a server, what one Stub answers to a
sample request, and which of the Stub's conditions the sample fails. The
sample is JSON,
`{method, path, query, headers, body, session, vars, data}`, every
member optional, with the path and the query values decoded and the
cookies in `headers.Cookie`, and `--seed` makes the fake data
repeatable:

```sh
echo '{"method":"GET","path":"/api/v1/users/42","query":{"lang":"ja"}}' >sample.json
smock render --dir defs --request sample.json --seed 7 get-user |
  jq -c '[.response.status, .response.body.data, .failed]'
# [200,"{\"id\":\"42\",\"name\":\"Sebastian Garcia\",\"lang\":\"ja\"}",[]]
```

It renders the CRUD Stub too, with the answer its operation would give
from the bucket's initial value, or from the sample's `data`, and writes
nothing. So a list query can be checked before clients send it:

```sh
echo '{"method":"GET","path":"/api/v1/orders","query":{"item":"book"}}' >sample.json
smock render --dir defs --request sample.json orders | jq -c '[.response.status, .response.body.data]'
# [200,"[{\"id\":1,\"item\":\"book\"}]"]
```

Then run both servers, started as in [The
result](mockoon/worked-example-result.md), send each the same requests, and
compare the status, the Content-Type and the body, its keys sorted by `jq
-S`. This bash function sends one request to Mockoon on port 3000 and to
smock on port 8080; its arguments are the path and any further curl
arguments:

```sh
both() {
  for port in 3000 8080; do
    curl -s -o body.out -w "$port %{http_code} %{content_type} " "${@:2}" "localhost:$port$1"
    jq -cS . body.out 2>/dev/null || echo '(not JSON)'
  done
}
both '/api/v1/users?status=inactive'
both /api/v1/users -H 'X-Api-Key: secret' -d 'name=Alice&role=admin'
both /api/v1/users/
```

```text
3000 200 application/json; charset=utf-8 [{"id":3,"name":"Carol","status":"inactive"}]
8080 200 application/json [{"id":3,"name":"Carol","status":"inactive"}]
3000 201 application/json; charset=utf-8 {"id":"7b379cf7-3cf7-4005-a7c6-e38675c61cbd","name":"Alice"}
8080 403 application/json {"error":"forbidden"}
3000 200 application/json; charset=utf-8 [{"id":1,"name":"Alice","status":"active"},{"id":2,"name":"Bob","status":"active"}]
8080 404 application/json {"error":"no Stub matched"}
```

The last two pairs are differences from the section above: a form body,
which the example's Stubs do not read, and a trailing slash.

Last, run the clients' own tests against smock. The Journal records every
request, and `GET /v1/journal/unmatched` on the Admin API lists those that
no Stub answered, oldest first, each with its Near miss and the conditions
it failed. When a smock just started gets the requests in the table of [The
result](mockoon/worked-example-result.md#a-worked-example-the-result) and
the three `both` calls above, it lists only the trailing slash, since the
CRUD Stub answers every request for orders:

```sh
curl -s -H "Authorization: Bearer change-me" localhost:9090/v1/journal/unmatched |
  jq -c '.entries[] | [.request.method, .request.target, .nearMiss.stub, [.nearMiss.failed[]?.condition]]'
# ["GET","/api/v1/users/","list-users",["path"]]
```

Without a `baggage` header, it lists the requests that named no Session; a
test that names its Session sees its own ([Verifying calls and unmatched
requests](admin-api.md#verifying-calls-and-unmatched-requests)).

## Running it where Mockoon ran

Each release of smock publishes binaries, an image and a Helm chart,
all under the release's version: its tag without the `v`. Take the
latest release, 0.3.0 or later, listed under
[Releases](https://github.com/hirunefu/smock/releases), and put its
version in place of `<version>` below.

- **On Linux.** The release has the binaries
  `smock-<version>-linux-amd64` and `smock-<version>-linux-arm64`. Each
  needs glibc 2.34 or later and OpenSSL 3 (on Debian and Ubuntu, the
  `libssl3` package, or `libssl3t64` on newer releases):

  ```sh
  curl -fsSL --create-dirs -o bin/smock \
    https://github.com/hirunefu/smock/releases/download/v<version>/smock-<version>-linux-amd64
  chmod +x bin/smock
  SMOCK_ADMIN_TOKEN=change-me bin/smock serve --dir defs
  ```

  `smock serve` needs a token for its Admin API; `--admin-auth off`
  turns the Admin API's authentication off for local use.
- **In Docker**, `ghcr.io/hirunefu/smock:<version>` in place of
  `mockoon/cli`. It is for linux/amd64 and linux/arm64, so docker pulls the
  one for the machine. Mount the definitions directory, readable by UID
  65532, and map port 3000 to 8080, so that clients keep the port they used
  for Mockoon ([Environments told apart by
  port](mockoon/worked-example.md#environments-told-apart-by-port) covers
  several environments):

  ```sh
  export SMOCK_ADMIN_TOKEN=change-me
  docker run --rm --read-only -e SMOCK_ADMIN_TOKEN -p 3000:8080 -p 9090:9090 \
    -v "$PWD/defs:/defs:ro" ghcr.io/hirunefu/smock:<version> serve --dir /defs
  ```

- **On Kubernetes.**
  [getting-started-on-gke.md](getting-started-on-gke.md) installs the
  release's chart. The Definition file and its body files go in as
  values. The command reuses that guide's namespace `mocks`, token
  Secret and `$VERSION`, so run it in that guide's shell, in
  `docs/examples/from-mockoon/`, before that guide's clean-up. It
  upgrades that guide's release `smock` to serve the example in place of
  its Definition file:

  ```sh
  helm upgrade --install smock oci://ghcr.io/hirunefu/charts/smock --version "$VERSION" --namespace mocks \
    --set adminAuth.tokenSecret.name=smock-admin-token \
    --set-file 'definitions.configMap.files.users-api\.yaml=defs/users-api.yaml' \
    --set-file 'definitions.configMap.bodyFiles.users\.json=defs/files/users.json' \
    --set-file 'definitions.configMap.bodyFiles.inactive-users\.json=defs/files/inactive-users.json' \
    --wait --timeout 10m
  ```

  After that guide's
  [appendix](getting-started-on-gke.md#appendix-an-unreleased-commit),
  name the chart and the image as its install does instead, with the
  chart's path from here, `../../../charts/smock`.
  Adding body files replaces the Pod. That guide's port-forwards reach
  the old Pod, with the old files, until it stops, and then end, so stop
  them (`kill %1 %2`) and start them again. `localhost:8080/api/v1/users`
  then reaches `users-api`, whose `hosts` lists `localhost`. On
  2026-10-17 the example ran this way on GKE Autopilot, from an image of
  CI's binary and the chart in a checkout. It had no Scenario Stubs and
  no Data bucket then; those were checked later, with a local smock
  only.
  Values hold text only, so binary body files need git-sync or a
  ConfigMap of one's own
  ([charts/smock/README.md](../charts/smock/README.md)).
  With several Mocks, each client must send a Host that its Mock lists,
  and the chart creates one Service for traffic, `smock`, for all of
  them: the other names need Services of their own for the same Pods, or
  clients that set the Host header.
- **Switching clients over.** Point clients at smock's plain port, 8080, or
  keep their port by mapping it as above. Clients of an environment with
  `tlsOptions.enabled` move to the TLS port, 8443, or keep their port by
  mapping it there (`-p 3000:8443` in Docker). Check that the Host they send
  is in the Mock's `hosts`: a `Smock-Mock: …; via=default` header on their
  responses means it is not. A Host that another Mock lists shows no such
  header ([Environments told apart by
  port](mockoon/worked-example.md#environments-told-apart-by-port)). Then
  read the unmatched requests as in [Checking the
  migration](#checking-the-migration).
- **An unreleased commit.** To run a commit that no release holds yet,
  take CI's binary or build one, as in the
  [appendix](getting-started-on-gke.md#appendix-an-unreleased-commit)
  of getting-started-on-gke.md. An image built there for local use needs
  no registry, so tag it `smock:dev` in place of `"$IMAGE"`, and run it
  as above with `smock:dev` in place of `ghcr.io/hirunefu/smock:<version>`.

## Logs

The Mockoon CLI writes one JSON object per line to stdout: a
`Transaction recorded` line for each request, and lines when it starts,
stops or fails to serve. By default, smock writes none of those. Its
`json` log format writes smock's own entries to stderr, in smock's
shape, and no line per request: the Journal records the requests
instead. Log pipelines, dashboards, alerts and readiness checks built
on Mockoon's lines need the `mockoon` log format, which writes them to
stdout. What this section says of Mockoon was checked against Mockoon
v9.10.0's source and a local Mockoon CLI trial's log on 2026-10-31.
smock's tests compare its lines with that log.

### Turning it on

Set `--log-format mockoon`, or `SMOCK_LOG_FORMAT=mockoon`. smock 0.3.0
and earlier have only `json`, and refuse `mockoon` with a usage error.

- **The binary.** As in [Running it where Mockoon
  ran](#running-it-where-mockoon-ran), with the flag:

  ```sh
  SMOCK_ADMIN_TOKEN=change-me bin/smock serve --dir defs --log-format mockoon
  ```

- **Docker.** Add `-e SMOCK_LOG_FORMAT=mockoon`:

  ```sh
  docker run --rm --read-only -e SMOCK_ADMIN_TOKEN -e SMOCK_LOG_FORMAT=mockoon -p 3000:8080 -p 9090:9090 \
    -v "$PWD/defs:/defs:ro" ghcr.io/hirunefu/smock:<version> serve --dir /defs
  ```

- **The Helm chart.** Set it in the chart's `env`: add
  `--set env.SMOCK_LOG_FORMAT=mockoon` to `helm upgrade --install`, or
  `env: { SMOCK_LOG_FORMAT: mockoon }` to a values file
  ([charts/smock/README.md](../charts/smock/README.md#logs)).
  `kubectl logs` then shows the lines.

With the example, `GET /api/v1/users` and `GET /api/v1/users/`, then
SIGTERM, give these Mockoon lines, among smock's own:

```text
{"app":"smock","environmentName":"users-api","level":"info","message":"Server started on port 8080","timestamp":"2026-10-31T15:38:32.992Z"}
{"app":"smock","environmentName":"users-api","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/api/v1/users","requestProxied":false,"responseStatus":200,"timestamp":"2026-10-31T15:38:34.785Z"}
{"app":"smock","environmentName":"users-api","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/api/v1/users/","requestProxied":false,"responseStatus":404,"timestamp":"2026-10-31T15:38:34.789Z"}
{"app":"smock","environmentName":"users-api","level":"info","message":"Server stopped","timestamp":"2026-10-31T15:38:37.980Z"}
```

smock's own lines, such as `listening`, `definitions reloaded` and
`drain ended`, share stdout, in the same envelope: `app`, `level`,
`message` and `timestamp`, with their own fields beside them, keys
sorted. To keep only Mockoon's lines, filter on the four messages:

```sh
SMOCK_ADMIN_TOKEN=change-me bin/smock serve --dir defs --log-format mockoon |
  jq --unbuffered -c 'select(.message | test("^(Transaction recorded|Server stopped)$|^(Server started on port|Error while serving the content:) "))'
```

The four Mockoon lines and the envelope of every line are a stable
contract: smock changes them only in a breaking change, which the
CHANGELOG lists under Changed and the release notes call out
([Logs](running.md#logs)).

### Mockoon's lines in smock

| Mockoon line | In smock's `mockoon` format |
|---|---|
| `Server started on port %d` | Written once per Mock, with the plain port, once every listener is open. |
| `Admin API token (auto-generated): …` (warn) | None: smock never generates a token. |
| `Server stopped` | Written once per Mock, when the drain after SIGTERM ends. |
| `Port %d is already in use`, `Port %d is invalid or access is denied`, the hostname errors, `Certificate file not found`, `An unknown server error occurred: %s` | None: smock writes its own `cannot listen` or `cannot load the TLS certificate` line, then exits with status 1, where Mockoon exits with 2. |
| `Error while trying to parse request body …` | None: smock never fails a request on its body; a body that does not parse fails the conditions that read it. |
| `Error while serving the content: %s` | Written when a Stub's template cannot be rendered or its data write cannot be applied, just before the request's `Transaction recorded` line, also with the Journal off. |
| `Error while serving the file content: %s` | None: smock reads body files when it loads the definitions. |
| `Header parsing error: %s` | None: a templated header that fails is a template failure, so it gives `Error while serving the content`. |
| `Invalid route path: %s` | None: an invalid path is a load error. |
| `An error occurred while trying to proxy to %s`, and the callback and WebSocket lines | None: smock has no proxy, callbacks or WebSockets. |
| `Transaction recorded` | Written once for each request a Mock handles, over HTTP/1.1 and HTTP/2 alike, when it ends, without `transaction`, which only `--log-transaction` adds. |

`--log-transaction`, `GET /mockoon-admin/logs` and
`/mockoon-admin/events` have no counterpart in the lines. The Journal
keeps each request whole, with the Stub that answered and its status:
query it with `POST /v1/journal/query`, and list the requests no Stub
answered with `GET /v1/journal/unmatched`
([The Journal](admin-api.md#the-journal)).

### How the lines differ

- **`app` is `"smock"`** on every line, Mockoon's lines included, so a
  filter on `app == "mockoon-server"` needs changing, for example to
  the four messages above. During the switch, `app` tells the two
  servers' lines apart.
- **No `environmentUUID`**, since Mocks have no UUIDs. `environmentName` is
  the Mock's name, which may differ from the environment's: a Mock's name is
  best short and without spaces ([Environments and
  routes](mockoon/mapping-reference.md#environments-and-routes)). Update
  queries on `environmentUUID`, and on an environment's name that the Mock
  does not keep.
- **Requests the HTTP/1.1 codec rejects get no line**: the 400, 413,
  431, 501 and 505 that smock sends before any Mock sees the request.
  Mockoon logs the 413 of a body over its limit; smock's 413 for a body
  over `--body-limit` shows only in `smock_requests_total`, with
  `mock=""`. Over HTTP/2, a stream that never reaches a Mock gets none
  either: one that gets 400, 413 or 431, or is refused or reset before
  its request has arrived ([Logs](http2.md#logs)).
- **Connection Faults** have no status, so a request that a reset or a
  close Fault ends logs `"fault":"reset"` or `"fault":"close"` and no
  `responseStatus`. A `partial` Fault logs the status it wrote.
- **`requestPath`** is the path as the client sent it, without the
  query. Mockoon's URL parsing rewrites some paths: it logs `/a/../b`
  as `/b`, and the URL Standard, which that parsing follows, also
  rewrites a path that starts with `//`. smock keeps them as sent, as
  its conditions read them.
- **A template failure answers 500**, where Mockoon keeps the status already
  set, 200 in the trial, so the request's `Transaction recorded` line has
  `responseStatus` 500. Its error line carries smock's own message after
  `Error while serving the content: `, the `message` of the 500's body, such
  as `uppercase(): argument 1 must be a string, a number or a boolean, not
  an array` where Mockoon wrote `text.toUpperCase is not a function`.
  `routePath` is the Stub's path as the Definition file writes it, with its
  leading `/`, where Mockoon writes the route's endpoint without it; a Stub
  with no path condition has none. `routeUUID` is the Stub ID. A data write
  that fails gives the same line.
- **`Server started on port <port>`** comes once per Mock, with the
  plain port that every Mock shares, once the plain and TLS listeners
  are open, and never again on a reload, which keeps serving. Mockoon
  restarts on a `--watch` reload and writes it again. There is no token
  warning.
- **`Server stopped`** comes only after SIGTERM's drain, right after
  `drain ended`, and names a Mock that a reload added, which has no
  started line. SIGINT ends smock at once, without it; Mockoon writes
  it on SIGINT. A reload writes no stop and start pair.
- **Fatal errors** are smock's own lines, such as `invalid definitions`
  and `cannot listen`, in the same envelope on stdout, then smock exits
  with status 1. Mockoon writes its error line and a plain-text one,
  then exits with 2.
- **No log file**, in either format, and nothing like
  `--disable-log-to-file`: smock writes only to stdout and stderr.
  Mockoon's Docker image already starts the CLI with
  `--disable-log-to-file`.
- **smock's own lines share the stream.** Filter on the four messages,
  as above, to keep only Mockoon's.
- **No fields dropped.** Mockoon leaves `app` and `environment…` out of
  a line whose message holds a printf token, such as `%s` in a template
  error. smock keeps every field.
