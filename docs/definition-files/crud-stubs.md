# CRUD Stubs

This document of the [Definition-file reference](../definition-files.md)
describes CRUD Stubs. It assumes [Data buckets](data-buckets.md): a keyed
bucket is a Data bucket with `key` ([Keys and key
texts](data-buckets.md#keys-and-key-texts)), and a CRUD Stub writes to it
as `dataWrites` do, by key, in the copy of the request's Session and
within [the state bound](data-buckets.md#copies-and-the-state-bound).

A *CRUD Stub* serves a keyed bucket as a REST resource: it lists and
creates items at its path, and reads, replaces, updates and deletes one
item at the path plus its key. It has `crud` in place of `request` and
`response`:

```yaml
data:
  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
stubs:
  - id: orders
    mock: shop
    crud:
      bucket: orders
      path: /api/v1/orders
      headers: { Access-Control-Allow-Origin: "*" }
```

With `files/orders.json` holding orders 1001 to 1003,
`GET /api/v1/orders` answers 200 with the three orders, `X-Total-Count: 3`,
`X-Filtered-Count: 3` and the CORS header. `GET /api/v1/orders/1002`
answers order 1002. `GET /api/v1/orders/9999` answers 404, with the CORS
header too:

```json
{"error":"no item with this key","stub":"orders","key":"9999"}
```

A Session that sends `POST /api/v1/orders` with
`{"customerId":42,"status":"pending"}` gets 201,
`Location: /api/v1/orders/1004` and
`{"customerId":42,"status":"pending","id":1004}`. Its
`GET /api/v1/orders/1004` then answers that order, and its
`DELETE /api/v1/orders/1004` answers it once more and removes it. Another
Session still sees the three orders.

A list can be filtered, sorted and paged with a
[list query](#list-queries). `smock render` shows what a CRUD Stub would
answer to a sample request ([Rendering a CRUD
Stub](templates.md#rendering-a-crud-stub)).

## Contents

- [The shape of a CRUD Stub](#the-shape-of-a-crud-stub)
- [CRUD paths](#crud-paths)
- [Reads](#reads)
- [List queries](#list-queries)
- [Writes](#writes)
- [When a CRUD Stub writes](#when-a-crud-stub-writes)
- [Order and overrides](#order-and-overrides)
- [A CRUD Stub's Near miss](#a-crud-stubs-near-miss)
- [CRUD headers](#crud-headers)
- [Faults on a CRUD Stub](#faults-on-a-crud-stub)
- [CRUD Stubs in the Journal](#crud-stubs-in-the-journal)
- [Ephemeral CRUD Stubs](#ephemeral-crud-stubs)
- [CRUD Stubs that do not load](#crud-stubs-that-do-not-load)

## The shape of a CRUD Stub

`crud` has these members, and no others:

| Member | Value |
|---|---|
| `bucket` | A keyed bucket of the Stub's Mock ([Keys and key texts](data-buckets.md#keys-and-key-texts)). Required. |
| `path` | The list path, such as `/api/v1/orders`. Required. |
| `headers` | Headers for every answer of the Stub ([CRUD headers](#crud-headers)). |

- Beside `crud`, the Stub may have `id`, `mock`, `priority` and
  [`fault`](faults.md#faults). `request`, `response`, `responses`,
  `scenario`, `variables` and `dataWrites` are not allowed. A Stub has
  exactly one of `response`, `responses` and `crud`.
- Two CRUD Stubs may have the same `path`. The first in the order answers,
  and `smock check`
  [warns](../definition-files.md#a-stub-that-can-never-match) about the
  other.

## CRUD paths

- `path` starts with `/`, does not end with `/`, and has no empty segment.
  So `/` alone is not a path.
- The list path is `path`. An item path is `path`, then `/`, then one
  non-empty segment: the key text.
- Both are compared with the percent-decoded path, byte for byte, as [`path`
  conditions](matching.md#how-a-stub-matches-a-request) compare it. So
  `/api/v1/orders/` and `/API/v1/orders` are not served. A key sent with
  `%2F` is never reached, since it decodes to a deeper path.

## Reads

| Request | Answer |
|---|---|
| `GET <path>` | 200, the items that its [list query](#list-queries) keeps, as a plain JSON array, with `X-Total-Count` and `X-Filtered-Count`. Without a query, every item, and both counts are the number of items. 400 when smock cannot read the query. |
| `GET <path>/<key>` | 200, the item whose key has the text `<key>`, or 404 with the body above. |

- A read sees the copy of the request's Session when it holds one, and else
  the initial value ([Session copies](data-buckets.md#session-copies)). A
  read never copies.
- Keys compare by their text ([Keys and key
  texts](data-buckets.md#keys-and-key-texts)). So `/api/v1/orders/1002`
  finds the order whose `id` is `1002` or `"1002"`, but
  `/api/v1/orders/01002` finds none.
- A request body is ignored.
- Every answer is compact JSON with `Content-Type: application/json`, its
  numbers written as smock writes them, so a stored `9.90` comes back as
  `9.9`. The answers are not templates, so the 1 MiB bound on a rendered
  body does not apply: a list is as large as its bucket.
- The 404 and the 400 are the CRUD Stub's own answers. The request counts
  as matched, under the Stub's ID, and gets no
  [Near miss](matching.md#when-no-stub-matches).

## List queries

A list reads its query in smock's own syntax: filters by member, `$sort`,
`$offset` and `$limit`. So
`GET /api/v1/orders?status=paid&$sort=-id&$limit=10` lists the paid
orders, highest `id` first, at most ten. A read ignores the query.

Parameters are decoded as [`query`
conditions](matching.md#how-a-stub-matches-a-request) decode them: `%20` and
`+` both stand for a space, and a parameter without `=` has the empty value.

**Filters.** A name that does not start with `$` filters on the item
member of that name.

- Names are top-level members, taken literally: `a.b` names the member
  `a.b`, not `b` inside `a`.
- Every name must hold. A repeated name holds when any of its values does,
  so `?status=paid&status=pending` lists both.
- A member meets a value as [`find`](template-helpers.md#arrays)
  compares: a string equal to the value; a number of equal value, so
  `?total=12.5` finds `12.50`, and integers beyond 2^53 compare exactly;
  `true`, `false` and `null` by those words. So `?id=1002` finds the order
  whose `id` is `1002` or `"1002"`. Objects, arrays and absent members never
  meet a value.

**Names that start with `$`** are smock's. `$sort`, `$offset` and `$limit`
are read below, and `$$name` filters on the member `$name`. Any other
name that starts with `$` is 400, so an OData client's `$top` gets an
error rather than a wrong list.

**Sort.** `$sort=customerId,-total` sorts by `customerId`, ascending, and
then, among items that tie, by `total`, descending.

- The value is a comma-separated list of member names, each after an
  optional `-`. Names are literal, and `$$` is not an escape here. A
  member whose name starts with `-` or holds `,` cannot be a sort key.
- Ascending, values order by type first: null, false, true, numbers,
  strings. Numbers order by value, compared as `json` conditions compare
  them, so large integers order exactly. Strings order by Unicode code
  point, case-sensitive, with no locale rules: `B` comes before `a`.
  Descending reverses that whole order.
- Items whose member is absent, an object or an array go last, in either
  direction. They tie with each other on that member, so the next sort
  key, or the bucket's order, decides between them.
- The sort is stable: items that tie keep the bucket's order. Without
  `$sort`, items keep the bucket's order.

**Paging.** `$offset` skips that many items, 0 by default. `$limit` keeps
at most that many, with no limit by default.

- Both are decimal digits: `$offset` from 0 and `$limit` from 1.
- A number too large to hold counts as the largest: an offset past the
  end gives `[]`, and such a limit keeps every item.

**Order and counts.** The list applies the filters, then `$sort`, then
`$offset` and `$limit`, wherever they stand in the query. Every 200 list
answer carries `X-Total-Count`, the number of items in the bucket, and
`X-Filtered-Count`, the number that pass the filters, before paging. The
body stays the plain array.

**Errors.** A query that smock cannot read answers 400 with the Stub's
`crud.headers` and without the two counts, since it lists nothing. It
names the first such parameter in the query:

```json
{"error":"invalid query parameter","stub":"orders","parameter":"$top"}
```

These are 400: a name that starts with `$` other than the three above; an
empty sort name, as in `$sort=`, `$sort=a,,b` or `$sort=-`, or one that
starts with `-`, as in `$sort=--a`; an `$offset` or a `$limit` that is not
decimal digits, or a `$limit` of 0; and `$sort`, `$offset` or `$limit`
given twice.

**A client's own parameters are filters too.** A client that sends its
own paging or tracking parameters, such as `page` or `_`, gets `[]` with
`X-Filtered-Count: 0`, since no item has the member `page` or `_`. An
ordinary Stub before the CRUD Stub can answer such lists from
[`data.NAME`](data-buckets.md#reading-buckets-in-templates):

```yaml
- id: orders-by-page
  mock: shop
  request:
    method: GET
    path: /api/v1/orders
    query: { page: { $exists: true } }
  response:
    status: 200
    template: true
    json: "${data.orders}"
- id: orders
  mock: shop
  crud: { bucket: orders, path: /api/v1/orders }
```

## Writes

| Request | Answer |
|---|---|
| `POST <path>` | create: 201, the item stored, with `Location`. |
| `PUT <path>/<key>` | replace: 200, the item stored. |
| `PATCH <path>/<key>` | update: 200, the item stored. |
| `DELETE <path>/<key>` | delete: 200, the item removed. |

Each is one [write by key](data-buckets.md#writes-by-key), the one that
`dataWrites` makes with the same op: a create is an `append`, a replace a
`set` with `key`, an update a `merge` with `key`, and a delete a `remove`.

- A create adds the item at the end of the bucket.
- A replace makes the body the item, in its place.
- An update merges the body into the item, shallowly: each member replaces
  the member of the same name, in its place, and new members are added at
  the end, in body order. `null` is stored as null.
- A delete removes the item, and answers it.
- The write goes to the copy of the request's Session. A Session's first
  write copies the bucket, and later ones change that copy ([Session
  copies](data-buckets.md#session-copies)). Requests without a Session share
  one copy.

The request body:

- It is parsed as JSON whatever its `Content-Type`, as [`json`
  conditions](matching.md#how-a-stub-matches-a-request) parse it, within
  `--body-limit`.
- A create, replace or update needs a JSON object. Anything else, no body,
  a body that is not JSON, an array or a scalar, gets 400
  `body is not a JSON object`.
- A delete ignores any body.

Keys:

- A create whose body has no key member gets a [new
  key](data-buckets.md#new-keys), added as the item's last member. A body
  whose key member holds a valid key that no item has keeps it. A key member
  that holds no valid key, `null` included, gets 400 `invalid key`. A key
  that an item has gets 409 `key already exists`.
- A replace or update keeps the item's key. The body's key member may be
  absent, or hold the item's key text. Any other key gets 400
  `key does not match the path`. The item keeps its stored key value, so
  `42` stays a number when the body sends `"42"`, and a replace whose body
  has no key member gets the key as its last member.
- A replace, update or delete of a key that no item has gets 404, as a
  read does.
- `Location` is the new item's path: each segment of `path`, then the key
  text, each after a `/`, and percent-encoded as
  [`urlEncode`](template-helpers.md#encodings) encodes it. So the key
  `a b` under `/api/v1/orders` gives `/api/v1/orders/a%20b`.

So `PATCH /api/v1/orders/1004` with `{"status":"paid","id":"1004"}`
answers `{"customerId":42,"status":"paid","id":1004}`.

A write that fails writes nothing, and gets one of these answers. Each
body is compact JSON, `{"error": "<what>", "stub": "<id>", ...}`:

| Status | `error` | When |
|---|---|---|
| 400 | `body is not a JSON object` | A create, replace or update whose body is not a JSON object. |
| 400 | `invalid key` | A create whose body's key member holds no valid key. |
| 400 | `key does not match the path` | A replace or update whose body's key member holds another key. |
| 404 | `no item with this key` | A replace, update or delete of a key that no item has. The body has `key`. |
| 409 | `key already exists` | A create whose body's key an item has. The body has `key`. |
| 500 | `no new key` | A create when the next integer key would pass 2^53 - 1. |
| 507 | `state limit reached` | A write past [the state bound](data-buckets.md#copies-and-the-state-bound). The body has `message`, as for other writes. |

These are the CRUD Stub's own answers. The request counts as matched,
under the Stub's ID, and gets no Near miss.

## When a CRUD Stub writes

The write is made at the match decision, as
[`dataWrites`](data-buckets.md#when-data-is-written) are: the request takes
its one random draw, the write is applied to a working copy, the state bound
is checked, and the copy is stored. Only then is the answer sent, after any
delay.

- Once stored, the write stands. A delay, a connection Fault, a client
  that leaves, or a Journal that is off does not undo it.
- Each request sees the writes of every request that reached smock before
  it. So two creates whose answers are both delayed still get different
  keys.
- A new `uuid` key comes from the request's helpers, seeded with its one
  draw, as a response's first `fake.uuid()` would. So [`fault.seed` and
  `--seed`](faults.md#seeds) repeat it, and the Fault decisions do not move
  it.
- A write that would take the count of per-Session state above [the
  bound](data-buckets.md#copies-and-the-state-bound) gets 507, writes
  nothing, and counts in `smock_state_writes_refused_total`. A delete can
  get it too, since a Session's first write copies the whole bucket.

## Order and overrides

A CRUD Stub matches only the requests it serves. Any other method or path
shape does not match it: `HEAD` and `OPTIONS`, `PUT`, `PATCH` and `DELETE`
on the list path, `POST` on an item path, and paths deeper than an item
path. Later Stubs are tried, then the Mock's [no-match
answer](matching.md#when-no-stub-matches). Methods are compared exactly.

A CRUD Stub is tried in [the usual order](matching.md#which-stub-answers).
It has no conditions and no Scenario clause of its own, so an earlier Stub
takes over one of its requests:

```yaml
- id: no-token
  mock: shop
  request: { headers: { authorization: { $exists: false } } }
  response: { status: 401, json: { error: unauthorized } }
- id: orders-down
  mock: shop
  scenario: { name: orders, requires: Down }
  request: { path: { pattern: "/api/v1/orders(/[^/]+)?" } }
  response: { status: 503 }
- id: orders
  mock: shop
  crud: { bucket: orders, path: /api/v1/orders }
```

A request without `Authorization` gets 401, and a request of a Session
whose Scenario `orders` is in `Down` gets 503. Every other request to the
orders gets the CRUD Stub's answer. A lower `priority` than the CRUD
Stub's places a Stub before it wherever it is declared.

An override placed after the CRUD Stub never answers. `smock check`
[warns](../definition-files.md#a-stub-that-can-never-match) about a Stub
with a `method` and an exact `path` that an earlier CRUD Stub serves, such
as one for `GET /api/v1/orders/1001` after the `orders` CRUD Stub.

## A CRUD Stub's Near miss

A CRUD Stub can be the [Near miss](matching.md#when-no-stub-matches) of a
request that no Stub matches. It counts two conditions:

- `path` fails when the request path is neither the list path nor an item
  path. It expects `{"crud": "<path>"}`.
- `method` fails when the Stub does not serve the method at the request
  path's shape: `GET` and `POST` at the list path, and `GET`, `PUT`,
  `PATCH` and `DELETE` at an item path. When `path` fails too, the method
  is judged at either shape. It expects `{"crud": [<methods>]}`: those
  methods, each once, in the order `GET`, `POST`, `PUT`, `PATCH`,
  `DELETE`.

What the request sent is its method, or its percent-decoded path, as for
any Stub. A CRUD Stub competes with the Mock's other Stubs by the same
rules: the fewest failed conditions, and the one tried first on a tie.
With only the `orders` CRUD Stub, `HEAD /api/v1/orders` gets the no-match
answer with

```http
Smock-Near-Miss: orders; failed=method
```

and the Journal shows the failed condition in full:

```json
{
  "condition": "method",
  "expected": { "crud": ["GET", "POST"] },
  "actual": ["HEAD"]
}
```

`GET /api/v1/orders/1001/items` fails only `path`, since the Stub serves
`GET` at both shapes. `HEAD /api/v1/orders/1001/items` fails both, and its
`method` expects all five methods.

## CRUD headers

smock sets `Content-Type`, `Location` on a create, and `X-Total-Count`
and `X-Filtered-Count` on a list's 200. `crud.headers` adds static
headers to every answer of the Stub, errors, 500 and 507 included:

- It has the shape and rules of
  [`noMatch.headers`](matching.md#when-no-stub-matches): by name, a value or
  a non-empty array of values, each sent as its own field line, in order.
  Two names that differ only in case are an error. It is never templated.
- A header that smock sets cannot be given: `Content-Type`, `Location`,
  `X-Total-Count`, `X-Filtered-Count`, `Content-Length`,
  `Transfer-Encoding`, `Connection` and `Smock-Mock`. Names are compared
  case-insensitively.
- A browser reads `X-Total-Count` and `X-Filtered-Count` of a
  cross-origin answer only when `Access-Control-Expose-Headers` names
  them, which `crud.headers` can give:

  ```yaml
  headers:
    Access-Control-Allow-Origin: "*"
    Access-Control-Expose-Headers: X-Total-Count, X-Filtered-Count
  ```

- A CRUD Stub does not answer `OPTIONS`, so a browser's preflight needs a
  Stub of its own, as in [When no Stub
  matches](matching.md#when-no-stub-matches).

## Faults on a CRUD Stub

[`fault`](faults.md#faults) works as on any Stub. Every matched request
takes its one draw, its 4xx and 5xx answers included, so
[`fault.seed`](faults.md#seeds) replays the same decisions. A delay comes
before the answer, and after the write. A connection Fault replaces the
answer, but not the write, and `partial` sends half of its body.

## CRUD Stubs in the Journal

Each [Journal](../admin-api.md#the-journal) entry has `crud`: null, or the
operation and its key. A list records `{"op":"list","key":null}`,
whatever its query. A read, a replace, an update and a delete record
`read`, `replace`, `update` and `delete` with the item path's key text,
whatever the outcome, such as `{"op":"read","key":"9999"}` for the 404
above. A create records `create` with the key of the item stored, the
body's key on a 409, and else null. `crud` counts toward the entry's
bytes, and `responseIndex` is null for a CRUD Stub's answers.

`dataWritten` names the bucket after a write, and is `[]` after a list, a
read, or any failure. `dataError` stays null: a CRUD Stub's failures are
its own answers.

## Ephemeral CRUD Stubs

An [Ephemeral Stub](../admin-api.md#sessions-and-ephemeral-stubs) can be a
CRUD Stub, with no `id` or `mock`, as any Ephemeral Stub. It serves the
requests of its Session, and reads and writes its Session's copy of the
bucket.

An Ephemeral Stub is not read again at a reload, so a CRUD Stub looks its
bucket up by name on each request. After a reload removes the bucket, it
answers 500 with its headers:

```json
{"error":"unknown data bucket","stub":"eph-1","bucket":"orders"}
```

After a reload takes the bucket's `key` away, it answers 500 with
`"error":"data bucket changed"`, and the same `stub` and `bucket`. Either
way, a create, replace, update or delete writes nothing.

## CRUD Stubs that do not load

These are errors when loading, reported by `smock check`, at startup, by a
reload, which then keeps the files it serves, and as 400 `invalid_stub` for
an Ephemeral Stub:

- a `bucket` that is not one of the buckets of the Stub's Mock, or that
  has no `key`;
- a `path` that breaks the rules above;
- a member that the shape does not allow, beside `crud` or in it;
- a `crud.headers` name that smock sets.

`smock check` also
[warns](../definition-files.md#a-stub-that-can-never-match) when a CRUD Stub
hides a later Stub, or a Stub hides a later CRUD Stub.
