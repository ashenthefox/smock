# Data buckets

This document of the [Definition-file reference](../definition-files.md)
describes Data buckets: how a Mock declares them, how
[templates](templates.md) read them as `data.NAME`, how Stubs and the
Admin API write them, and the copies that Sessions keep. A keyed bucket
can also be served as a REST resource by a [CRUD Stub](crud-stubs.md),
which has a document of its own.

A *Data bucket* is a named JSON value that a Mock declares in Definition
files, with its initial value. Templates read it as `data.NAME`:

```yaml
data:
  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
  - { mock: shop, name: visits, json: 0 }
stubs:
  - id: list-orders
    mock: shop
    request: { method: GET, path: /api/v1/orders }
    response: { status: 200, template: true, json: "${data.orders}" }
```

With `files/orders.json` holding orders 1001 to 1003, `GET /api/v1/orders`
answers the three orders. Each Session reads the initial value until it
first writes to the bucket, which gives it its own copy ([Session
copies](#session-copies)).

## Contents

- [Declaring a bucket](#declaring-a-bucket)
- [Initial values](#initial-values)
- [Keys and key texts](#keys-and-key-texts)
- [Reading buckets in templates](#reading-buckets-in-templates)
- [Session copies](#session-copies)
- [Writing buckets: `dataWrites`](#writing-buckets-datawrites)
  - [Writes by key](#writes-by-key)
  - [New keys](#new-keys)
  - [When data is written](#when-data-is-written)
  - [When a write fails](#when-a-write-fails)
  - [Writes in the Journal](#writes-in-the-journal)
- [CRUD Stubs](crud-stubs.md)
- [Data buckets through the Admin API](#data-buckets-through-the-admin-api)
- [Copies in resets and reloads](#copies-in-resets-and-reloads)
- [Copies and the state bound](#copies-and-the-state-bound)

## Declaring a bucket

The top-level `data` of a Definition file, beside `mocks` and `stubs`, is
a list of buckets. Each entry has these members, and no others:

| Member | Value |
|---|---|
| `mock` | The name of the bucket's Mock. Some file must declare it. Required. |
| `name` | 1 to 128 ASCII letters, digits, `_` and `-`, unique within the Mock. Required. |
| `json` | The initial value, inline: any JSON value. `json: null` counts as given. |
| `jsonFile` | The initial value, from a JSON file in the [body-file subdirectory](../definition-files.md), such as `orders.json`. |
| `key` | Makes the bucket keyed: the name of the member that holds each item's key. |
| `newKey` | How a keyed bucket makes new keys: `integer` (the default) or `uuid`. |

- Give exactly one of `json` and `jsonFile`.
- A bucket may sit in any file, apart from its Mock, so it can sit beside
  the Stubs that use it. A Stub may read a bucket declared in any file,
  earlier or later.
- Two Mocks may use the same name. Each has its own bucket.
- `newKey` needs `key`. [New keys](#new-keys) says what it does.
- A keyed bucket can be served by a [CRUD Stub](crud-stubs.md#crud-stubs).

## Initial values

The initial value is static JSON. It is never templated, so every Session
starts from the same value, on every replica and in every run. Bulk data
comes from a script, or from a [configuration
language](../definition-files.md#writing-definition-files-in-another-configuration-language).

A `jsonFile` follows the path rules of `bodyFile`: the path stays inside
the body-file subdirectory, and none of its names start with `.`. The file
must be JSON in UTF-8. It follows the rule of a JSON Definition file: a
key repeated in one object is an error (`duplicate key`, at the later
key), since JSON parsers disagree on which value counts. A missing file,
or one that breaks these rules, is an error when loading. smock reads the
file with the body files, so it is part of the digest, and editing it
triggers a [reload](../definition-files.md#reloading).

## Keys and key texts

`key: id` makes a bucket keyed. The member name is taken literally:
`key: a.b` names the member `a.b`, not a nested one. There is no default
key.

- A keyed bucket's value is an array of objects.
- Each object has the key member. It holds a non-empty string without
  `/`, or an integer: a whole number from -(2^53 - 1) to 2^53 - 1.
- A key's *text* is the string, or the integer's digits, with `-` when it
  is negative and no leading zeros. `42`, `42.0` and `4.2e1` all have the
  text `42`.
- A number is judged by its 64-bit floating-point value, as JSON parsers
  commonly read it, not by its digits. So `1.0000000000000001`, which reads
  as 1, is the key `1`.
- No two items have the same key text, so `42` and `"42"` collide.

A key cannot hold `/`, since a path segment cannot carry it once
percent-decoded. Every write keeps these rules, [writes by
key](#writes-by-key) and the Admin API included. In an initial value,
they are errors when loading, reported with the JSON Pointer of the item
or its key. For a `jsonFile`, the problem is reported at `jsonFile`, with
the file's name and the pointer in it:

```text
shop.yaml: /data/0/json/2/id: has the key text "1001", as item 0 does
shop.yaml: /data/1/jsonFile: "orders.json" at /3: needs the key member "id"
```

## Reading buckets in templates

`data.NAME` gives the bucket's value with its own type, in any template
of a Stub of the bucket's Mock, the values of `variables` included.

```yaml
- id: summary
  mock: shop
  request: { method: GET, path: /api/v1/summary }
  response:
    status: 200
    template: true
    headers: { X-Visits: "${data.visits}" }
    json:
      count: ${len(data.orders)}
      first: ${data.orders[0].id}
      ids: { $each: data.orders, as: o, do: "${o.id}" }
```

- Steps go into the value: `${data.orders[0].id}`. `data['orders']` is the
  same as `data.orders`.
- [`find`](template-helpers.md#arrays) picks an item by its key:
  `${find(data.orders, 'id', path[3]) ?? null}` answers the order of
  `/api/v1/orders/1002`, whose `id` is `1002` or `"1002"`.
- [`last`](template-helpers.md#arrays) reads the last item:
  `${last(data.orders).id}`.
- The first step must name a bucket of the Stub's Mock. An unknown name,
  an index (`${data[0]}`) and `${data}` alone are errors when loading. A
  loop variable cannot be named `data`.
- A request that the [Default
  Mock](../definition-files.md#hosts-and-the-default-mock) answers reads the
  Default Mock's buckets.
- A template reads the copy of the request's Session when it holds one,
  and else the initial value ([Session copies](#session-copies)).
- An [Ephemeral Stub](../admin-api.md#sessions-and-ephemeral-stubs) reads
  the buckets of its Mock, and the copies of its Session. After a reload
  removes a bucket, its reads of that bucket are missing, so `??` gives a
  fallback.

## Session copies

A Session reads a bucket's initial value until it first writes to the
bucket. That write gives the Session its own copy, which its requests read
from then on. Other Sessions still read the initial value, or their own
copies. A Stub writes with [`dataWrites`](#writing-buckets-datawrites),
and a test can set its Session's copy through the Admin API ([Data buckets
through the Admin API](#data-buckets-through-the-admin-api)).

- Reads never copy, so a Session that only reads costs no memory.
- Copies are kept per Mock, per
  [Session](../admin-api.md#sessions-and-ephemeral-stubs) and per bucket, in
  the process. Requests without a Session share one copy of each bucket,
  as they share Scenario state.
- Each replica keeps its own copies, and they are lost on restart.
- A copy lives until a [reset](#copies-in-resets-and-reloads), a
  [reload](../definition-files.md#reloading) that drops it, an Admin API
  drop, or a restart. Nothing expires it, so a test's outcome never depends
  on its timing.
- `smock render` and the Admin render operation read the sample's `data`,
  or else each bucket's initial value, also when the sample names a
  Session that holds a copy. A rendering never reads or writes a Session's
  copy ([Rendering a template](templates.md#rendering-a-template)).

## Writing buckets: `dataWrites`

A Stub's `dataWrites` writes to the buckets of its Mock when the Stub
matches. The writes go to the copies of the request's Session:

```yaml
data:
  - { mock: shop, name: visits, json: 0 }
stubs:
  - id: visit
    mock: shop
    request: { method: GET, path: /visit }
    dataWrites:
      - { op: set, bucket: visits, value: "${add(data.visits, 1)}" }
    response: { status: 200, template: true, json: { visits: "${data.visits}" } }
```

Three calls in one Session answer `{"visits":1}`, `{"visits":2}` and
`{"visits":3}`. Another Session starts again from 1.

- `dataWrites` is a list of 1 to 100 writes, applied in order. It sits
  beside `response` or `responses`, so a Stub writes once, whichever
  response is picked.
- Each write has `op`, `bucket`, and the members its op takes, and no
  others:

  | `op` | Members | Effect |
  |---|---|---|
  | `set` | `value`, optional `key` | The bucket becomes the value. With `key`, the item with that key does, in its place. |
  | `merge` | `value`, optional `key` | A shallow merge of the value, an object, into the bucket, which must hold an object. Each member replaces the member of the same name in its place, or is added at the end. `null` is stored as null. With `key`, the merge is into the item with that key. |
  | `append` | `value` | The value is appended to the bucket, which must hold an array. In a keyed bucket, it is an item, which gets a [new key](#new-keys) when it has none. |
  | `remove` | `key` | The item with that key is removed from the keyed bucket. |

- `bucket` names a bucket of the Stub's Mock, as written. It is never a
  template.
- `value` is any JSON. It is always a [structured
  template](templates.md#structured-templates), whether or not a response
  has `template: true`: `${…}` inserts a value, and `$${` writes `${`. As at
  the root of `json`, a `$if` at its root needs `else`.
- `key` names one item of a keyed bucket. It is a text template, always
  parsed, and its output is compared as a [key text](#keys-and-key-texts).
  Only a keyed bucket takes it ([Writes by key](#writes-by-key)).
- Each key and each value is bounded as a rendered body is: at most 1 MiB
  of output, and at most 10,000 loop iterations. Past either is a render
  error.
- A counter is a `set` with a helper, as above. `merge` and `append` keep
  the rest of the bucket: `{ op: append, bucket: cart, value: "${body}" }`
  adds the request's body to a cart.
- An [Ephemeral Stub](../admin-api.md#sessions-and-ephemeral-stubs) takes
  `dataWrites` too, over the buckets of its Mock, and writes the copies of
  its Session.

### Writes by key

A keyed bucket is written item by item. `set`, `merge` and `remove` take
the `key` of the item, and `append` adds one:

```yaml
- id: pay-order
  mock: shop
  request: { method: POST, path: { pattern: "/api/v1/orders/[^/]+/pay" } }
  dataWrites:
    - { op: merge, bucket: orders, key: "${path[3]}", value: { status: paid, paidAt: "${now()}" } }
  response:
    status: 200
    template: true
    json: "${find(data.orders, 'id', path[3])}"
```

`POST /api/v1/orders/1002/pay` marks order 1002 paid for that Session, and
answers the paid order, which [`find`](template-helpers.md#arrays)
picks. `POST /api/v1/orders/9999/pay` answers 500 `data write failed`, since
no order has that key, and writes nothing.

- `key` is compared as a key text, so `${path[3]}` finds the order whose
  `id` is `1002` or `"1002"`. A key that no item has fails the write: a
  missing item is never skipped, so a Stub never answers as if the item
  were there.
- `set` with `key` makes the item the value, an object, in its place.
  `merge` with `key` merges the value, an object, into the item, as
  `merge` merges into a bucket.
- The value's key member may be absent, or hold the item's key text. The
  item keeps its stored key value, so `42` stays a number when the value
  holds `"42"`. When `set` gives no key member, the key is added as the
  item's last member. Any other key fails the write.
- `remove` removes the item.
- `append` adds the value, an object, at the end. A key member that holds
  a valid key that no item has is kept. A value without the key member
  gets a [new key](#new-keys), added as its last member.
- `set` without `key` replaces the whole bucket. Its value must keep the
  [rules of keyed buckets](#keys-and-key-texts).
- `merge` without `key` cannot write to a keyed bucket, which holds an
  array. It is an error when loading.

A Stub's response reads the bucket after its own writes, so
`${last(data.orders)}` answers the item that its `append` just added, new
key included, as the [`last` example](template-helpers.md#arrays)
shows. A [CRUD Stub](crud-stubs.md#crud-stubs) answers what it creates.

As for other writes, only a Session's first write to a bucket copies it,
and the [state bound](#copies-and-the-state-bound) counts what each item
changed.

### New keys

A keyed bucket makes a key for an item that `append` adds without one, as
its `newKey` says:

- `integer`, the default: one more than the highest integer key, or 1
  when there is none. String keys are not counted, but when a string key
  already has the new key's text, the next integer is tried, until one is
  free. A deleted highest key can be given again.
- `uuid`: a version 4 UUID, as `fake.uuid()` makes it, drawn again while
  an item has it. It comes from the request's helpers, so [`fault.seed`
  and `--seed`](faults.md#seeds) repeat it.

When the new integer key would pass 2^53 - 1, the write fails with
`no new key`, and nothing is written.

### When data is written

The writes are made at the match decision, together with the Stub's
[Variables](variables.md#when-variables-are-written), in this order:

1. The Scenario moves, and the request takes its one random draw.
2. Each write's bucket is checked first. This matters only for an Ephemeral
   Stub after a reload ([When a write fails](#when-a-write-fails)), and it
   draws nothing. Then the value of each Variable is rendered, then each
   write, in the order written, its `key` before its `value`, all against
   the state from before this request, Variables included. So
   `${add(data.visits, 1)}` counts, and a write that reads `vars.NAME` sees
   the Variable as it was before the request.
3. The writes are applied in order, as if to working copies of the
   buckets: a write sees what the writes before it did. New keys are made
   here.
4. The [state bound](#copies-and-the-state-bound) is checked.
5. The Variables and the copies are stored at once.
6. The response is picked, rendered and planned. It sees the data after
   the writes.

The helpers draw for the values of the Variables first, then for each
write's key and value, then for the new `uuid` keys, in write order, then
for the response, so [`fault.seed` and `--seed`](faults.md#seeds) replay
them.

Only a Session's first write to a bucket copies the bucket. Later writes
change the copy in place, and the state bound counts what each adds or
replaces, without measuring the copy again.

Once stored, the writes stand: a delay, a connection Fault, a response
that fails to render, a client that leaves, or a Journal that is off does
not undo them. Each request sees the writes of every request that reached
smock before it, also while that request's delay still runs.

### When a write fails

The writes are all or nothing. When any of steps 2 to 4 fails, nothing is
written, Variables included:

- A key or a value that fails to render gives the [template
  failure](templates.md#missing-values-and-render-errors): 500, with an `at`
  under `/dataWrites/<i>/key` or `/dataWrites/<i>/value`.
- A write that cannot be applied gives 500, with
  `Content-Type: application/json`, the write's pointer and what went
  wrong:

  ```json
  {"error":"data write failed","stub":"visit","at":"/dataWrites/0","message":"the Data bucket \"visits\" holds a number, and \"merge\" needs an object"}
  ```

  These writes cannot be applied:

  - a `merge` whose value is not an object, a `merge` into a bucket that
    holds no object, and an `append` to a bucket that holds no array;
  - a write by key that names a key that no item has;
  - a write that would break the rules of a keyed bucket: an `append` or
    an item `set` or `merge` whose value is not an object, an item `set`
    or `merge` whose value holds another key, an `append` whose key is
    not a key or is another item's, and a `set` without `key` whose value
    is not an array of objects with valid, unique keys;
  - an `append` when no integer key is left (`no new key`).
- Writes that would pass the state bound get 507, as Variables do, and
  count in `smock_state_writes_refused_total`.

After any of these, no response is picked. The Scenario move stands, the
Stub's delay still applies, and a connection Fault still replaces the
answer, as for a template failure.

A gRPC call gets each of these in gRPC's form instead, as Trailers-Only with
the HTTP status 200: INTERNAL `template failed` or `data write failed`, with
the same `templateError` or `dataError` in its Journal entry, and
RESOURCE_EXHAUSTED `state limit reached` ([smock's own
failures](../grpc/unmatched-and-refused-calls.md#smocks-own-failures)).

A write that cannot be applied writes no log line in the default `json` [log
format](../running.md#logs). The `mockoon` format writes the error line of a
[template failure](templates.md#missing-values-and-render-errors), with the
message of the 500's body, just before the request's `Transaction recorded`
line, also with the Journal off:

```json
{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: the Data bucket \"visits\" holds a number, and \"merge\" needs an object","routePath":"/visits","routeUUID":"visit","timestamp":"2026-10-31T09:00:05.000Z"}
```

A 507 from the state bound writes none.

An Ephemeral Stub is not read again at a reload. Its write fails to apply
in the same way, and nothing is written, when a reload removes its
bucket, takes `key` from the bucket of a write with `key`, or gives `key`
to the bucket of a `merge` without `key`. smock checks each write's
bucket this way before any value or key renders, Variables included, and
the check draws nothing. So a value that reads the removed bucket without
`??`, such as `${add(data.visits, 1)}`, does not turn this into a
template failure:

```json
{"error":"data write failed","stub":"eph-1","at":"/dataWrites/0","message":"the Mock has no Data bucket \"visits\" since a reload"}
```

A `set` or `append` without `key` still applies when a reload gives its
bucket `key`, and fails only when what it writes breaks the bucket's
rules. When every write's bucket is still there, the Stub's template
reads of a removed bucket are missing, so `??` gives a fallback.

These are errors when loading, reported by `smock check`, at startup, by
a reload, which then keeps the files it serves, and as 400 `invalid_stub`
for an Ephemeral Stub:

- a bucket that is not one of the buckets of the Stub's Mock;
- an op given a member it does not take, or without one it needs, such as
  `append` with `key` or `set` without `value`;
- `dataWrites` with no write, or with more than 100;
- `key` on a bucket without `key`, and `merge` without `key` on a keyed
  bucket;
- a literal value, one with no `${`, `$each` or `$if`, that already breaks
  its op: a `merge` value that is not an object, an item that `set` or
  `merge` with `key` writes or that `append` adds to a keyed bucket that
  is not an object, a key member of such an item that holds no key, a
  key member of a `set` or `merge` item that holds a key other than a
  literal `key`, and a `set` value without `key` that breaks the rules of
  a keyed bucket.

### Writes in the Journal

Each [Journal](../admin-api.md#the-journal) entry names the buckets its
request wrote, in the order first written, each once, as `dataWritten`.
`dataError` is the `at` and the `message` of a write that failed to
apply, as the 500 gives them, or null. Both are always present, and count
toward the entry's bytes.

- A request whose writes fail to render or to apply, or meet the state
  bound, records `dataWritten: []`, `variablesWritten: []` and
  `responseIndex: null`. A key or a value that fails to render also
  records `templateError`.
- A response that fails to render after the writes were stored lists
  them, since nothing undoes them.

`smock render` and the Admin render operation show the writes a Stub
would make, from sample data, and write nothing ([Rendering a
template](templates.md#rendering-a-template)).

## Data buckets through the Admin API

A test can arrange and inspect the data of its own Session through the
Admin API. Each operation names its Session as other Admin API calls do,
and one without a Session works on the Mock's no-Session space:

- `GET /v1/mocks/{mock}/data` lists the Mock's buckets by name, in
  byte-wise order, without their values. `key` and `newKey` are `null` for
  a bucket without `key`, and `newKey` is `integer` for a keyed bucket that
  gives none. `written` is true when the Session holds its own copy:

  ```json
  {"data":[{"name":"orders","key":"id","newKey":"integer","written":true},{"name":"visits","key":null,"newKey":null,"written":false}],"warnings":[]}
  ```

- `GET /v1/mocks/{mock}/data/{bucket}` reads one, with the value the
  Session reads, its copy or else the initial value:
  `{"bucket":{"name":"visits","key":null,"newKey":null,"written":false,"value":0},"warnings":[]}`.
- `PUT /v1/mocks/{mock}/data/{bucket}` sets the Session's copy. The body
  is the value itself, any JSON. It replaces the copy the Session had, and
  makes a copy even when the value equals the initial one. The reply is the
  bucket, as a read gives it.
- `DELETE /v1/mocks/{mock}/data/{bucket}` drops the Session's copy, so the
  bucket reads its initial value again. The reply is the bucket, as a read
  gives it, also when there was no copy.

So a test in the Session `checkout-42` that sends
`PUT /v1/mocks/shop/data/orders` with `[{"id":1,"status":"paid"}]` gets
that one order from `GET /api/v1/orders`, while another Session still gets
the three orders of `orders.json`. `DELETE /v1/mocks/shop/data/orders`
brings them back for `checkout-42`.

- A Mock that does not exist gets 404 `unknown_mock`, and a bucket that the
  Mock does not declare 404 `unknown_bucket`. Path segments are
  percent-decoded.
- A body that is not JSON gets 400 `malformed_json`, and a set without a
  body 400 `invalid_request`. `--body-limit` bounds the body.
- A value that breaks the rules of a keyed bucket ([Keys and key
  texts](#keys-and-key-texts)) gets 400 `invalid_data`, with each problem
  in the message, and writes nothing.
- A set keeps a number's value, not its text, as a [set of a
  Variable](variables.md#through-the-admin-api) does: `19.990` is stored as
  `19.99` and `1e3` as `1000`. Unlike a Variable's value, a bucket's value
  is not bounded at 1 MiB, since a bucket's writes can grow it past that
  anyway.
- A set counts against [the state bound](#copies-and-the-state-bound): one
  that would pass it gets 507 `state_limit_reached` and writes nothing. A
  drop gives back the bytes the copy counted.
- Another Session's copies are never listed, read, set or dropped, and no
  operation lists the Sessions.
- Each set, and each drop of a copy, writes a log entry that names the
  Mock, the Session and the bucket, but not the value. A drop logs
  `Data bucket copy dropped`:

  ```json
  {"time":"2026-10-22T09:00:00.000Z","level":"info","msg":"Data bucket set","mock":"shop","session":"checkout-42","bucket":"orders"}
  ```

## Copies in resets and reloads

A [reset](../admin-api.md#sessions-and-ephemeral-stubs) drops the copies in
its scope, so that their buckets read their initial values again:

- `{"scope":"session"}` drops the calling Session's copies in every Mock,
  or those of requests without a Session when the call carries none;
- `{"scope":"mock","mock":"shop"}` drops every Session's copies of
  `shop`'s buckets, those of requests without a Session included;
- `{"scope":"all"}` drops every copy.

The reset answers how many copies it dropped, in `removed.dataBuckets`,
and its log entry says the same. Dropped copies give their bytes back to
[the state bound](#copies-and-the-state-bound). So after a test in the
Session `checkout-42` sets its copy of `orders`, `POST /v1/reset` with
`{"scope":"session"}` answers `"dataBuckets":1`, and the Session reads
`orders.json` again.

A [reload](../definition-files.md#reloading) that swaps in new files keeps
each copy whose bucket it did not change, and drops the others:

- A copy is dropped when its Mock is gone, when the new files no longer
  declare its bucket, or when the bucket's initial value or `key` changed.
- The initial values are compared as compact JSON. So moving one between
  `json` and `jsonFile`, or reformatting its file, is no change.
- A change of `newKey` keeps the copies: their data stays valid, and only
  the keys made from then on change.
- A reload that fails, or finds the files unchanged, keeps every copy.

So editing an unrelated Stub keeps the data of tests in progress, but
editing a bucket's initial value resets every Session's copy of it.

## Copies and the state bound

Copies count toward [the state bound](variables.md#the-state-bound),
together with Variables, under one rule:

- A space, one Mock with one Session or with no Session, counts its Mock
  name and its Session key once, plus 64 bytes, while it holds any
  Variable or copy.
- Each copy counts its bucket's name, 64 bytes, and its value: its compact
  JSON as smock writes it, plus 16 bytes for each JSON value in it.
- Initial values do not count. They are part of the definition set, as
  body files are.

So `visits: 7`, the only copy of the Mock `shop` in the Session `run-42`,
counts 74 bytes for its space (4 + 6 + 64) and 87 for itself
(6 + 64 + 1 + 16). A Variable in the same space adds only its own bytes.
`smock_state_bytes` counts the copies too.

- A write that would take the count above the bound writes nothing and
  gets 507. It counts in `smock_state_writes_refused_total`.
- Reads never fail, also when the count is at the bound.
- A dropped copy gives its bytes back, and a space's bytes go when it
  holds nothing more.

Nothing expires a copy, so plan for growth:

- A copy costs the full size of its bucket for each Session that writes to
  it. A large bucket that many Sessions write fills the bound fast.
- Give each virtual user of a load test one Session, and reset it at the
  end.
- A bucket whose initial value alone counts more than the bound refuses
  every write whose copy does not fit, such as a write that leaves the
  bucket as large as it started. `smock check` cannot see this, since it
  does not know the bound.
