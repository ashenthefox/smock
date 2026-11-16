# Variables

This document of the [Definition-file reference](../definition-files.md)
describes Variables: how Stubs write them, how templates read them, how a
test sets them through the Admin API, and the state bound, which holds
them with the copies of [Data buckets](data-buckets.md). It assumes
[Templates](templates.md): each value of a Stub's `variables` is a
template, and templates read Variables as `vars.NAME`.

A *Variable* is a named JSON value that smock keeps per Mock and per
Session. A Stub's `variables` write Variables when the Stub matches, and
templates read them as `vars.NAME`. So a POST can store what a later GET
returns:

```yaml
- id: login
  mock: shop
  request: { method: POST, path: /login }
  variables:
    user: ${body.user}
    previous: ${vars.user ?? null}
  response:
    status: 200
    template: true
    json: { user: "${vars.user}", previous: "${vars.previous}" }
- id: whoami
  mock: shop
  request: { method: GET, path: /me }
  response:
    status: 200
    template: true
    json: { user: "${vars.user ?? null}" }
```

In one Session, `POST /login` with `{"user":"ann"}` gets
`{"user":"ann","previous":null}`, and `GET /me` then gets
`{"user":"ann"}`. Another Session still gets `{"user":null}`.

- `variables` maps the name of each Variable to its value. It sits beside
  `response` or `responses`, so a Stub has one set of writes, whichever
  response is picked.
- A name is 1 to 128 ASCII letters, digits, `_` and `-`.
- A value is any JSON. It is always a [structured
  template](templates.md#structured-templates), whether or not a response
  has `template: true`: `${…}` inserts a value, and `$${` writes `${`. As at
  the root of `json`, a `$if` at its root needs `else`.
- Writing `null` stores null. It does not delete the Variable.
- Variables are kept per Mock and per Session, like Scenario state.
  Requests without a Session share one space per Mock. Each replica keeps
  its own, and they are lost on restart. A reset clears them, and a reload
  keeps them ([Resets and reloads](#resets-and-reloads)). One byte bound
  holds all of them ([The state bound](#the-state-bound)).
- An [Ephemeral Stub](../admin-api.md#sessions-and-ephemeral-stubs) takes
  `variables` too, and writes the Variables of its Session.
- Through the Admin API, a test lists, sets and deletes the Variables of
  its own Session ([Through the Admin API](#through-the-admin-api)).

## Contents

- [When Variables are written](#when-variables-are-written)
- [Reading Variables](#reading-variables)
- [Through the Admin API](#through-the-admin-api)
- [Resets and reloads](#resets-and-reloads)
- [The state bound](#the-state-bound)

## When Variables are written

The values are written at the match decision, as a [Scenario
moves](scenarios.md#when-the-state-moves), in this order:

1. The Scenario moves.
2. The request takes its one random draw (see [The random source and the
   time of a
   request](template-helpers.md#the-random-source-and-the-time-of-a-request)).
3. Every value is rendered, in the order written, against the Variables as
   they were before this request. So `count: ${concat(vars.count ?? '',
   'x')}` adds an `x` with each request, and two values that read each other
   see the old values. The values draw their helper output first, and the
   response's helpers draw on from there, so [`fault.seed` and
   `--seed`](faults.md#seeds) replay them.
4. All the values are written at once, if they fit within [the state
   bound](#the-state-bound).
5. The response is picked, as for any Stub with
   [`responses`](responses.md#several-responses), then rendered. It sees the
   new values.

A Stub with [`dataWrites`](data-buckets.md#writing-buckets-datawrites)
renders the value of each write after the values of its Variables, against
the same state from before the request, and stores the writes with the
Variables, all at once or not at all ([When data is
written](data-buckets.md#when-data-is-written)).

A value that fails to render writes none of the Stub's Variables. The
request gets the [template
failure](templates.md#missing-values-and-render-errors), 500 with an `at`
under `/variables/NAME`, such as
`"at":"/variables/user","message":"body.user is missing"`. No response is
picked. The Scenario move stands, and the delay and the connection Fault
apply as for any template failure. Writes that would pass the state bound
are refused the same way, with 507.

Each value is bounded as a rendered body is: at most 1 MiB of compact JSON,
and at most 10,000 loop iterations. Past either is a render error.

Once written, a value stays: a delay, a connection Fault or a response
that fails to render does not undo the write, and the next request sees
it. Nothing expires a Variable, but the state bound limits what all of
them take.

## Reading Variables

- `vars.NAME` gives the value with its own type, and steps go into it:
  `${vars.cart.items[0].sku}`. It works in every template, the values of
  `variables` included.
- An unset Variable is missing, so `??` gives a fallback:
  `${vars.count ?? 0}`. A Variable set to `null` is present.
- `vars` takes the name of a Variable first: `${vars}` alone and
  `${vars[0]}` are errors when loading. A loop variable cannot be named
  `vars`.
- A name that no Stub in the files writes is not an error, since an
  Ephemeral Stub or the Admin API can write it.
- `smock render` and the Admin render operation read Variables from the
  sample's `vars`, never the live ones, and show the values a Stub would
  write without writing them (see [Rendering a
  template](templates.md#rendering-a-template)).

Each [Journal](../admin-api.md#the-journal) entry records the names of the
Variables the request wrote, in the order written, as `variablesWritten`.
It is empty for a Stub without `variables`, for a request that no Stub
matched, when a value failed to render or a data write failed, and when
the state bound refused the writes.

## Through the Admin API

A test can arrange and inspect the Variables of its own Session through
the Admin API. Each operation names its Session as other Admin API calls
do, and one without a Session works on the Mock's no-Session space:

- `GET /v1/mocks/{mock}/variables` lists them by name, in byte-wise order,
  with their values:
  `{"variables":{"previous":null,"user":"ann"},"warnings":[]}`.
- `PUT /v1/mocks/{mock}/variables/{name}` sets one. The body is the value
  itself, any JSON: `"ann"`, `42` or `{"items":[]}`. It replaces the value
  the Variable had, and `null` stores null. The reply is
  `{"name":"user","value":"ann","warnings":[]}`.
- `DELETE /v1/mocks/{mock}/variables/{name}` deletes one, so `vars.NAME` is
  missing again. The reply is `{"name":"user","warnings":[]}`.

So, for the [`whoami` Stub above](#variables), a test that sends
`PUT /v1/mocks/shop/variables/user` with the body `"ann"` before it calls
`GET /me` gets `{"user":"ann"}`, and can list the Variables afterwards to
check what its requests wrote.

- A Mock that does not exist gets 404 `unknown_mock`.
- A name that is not 1 to 128 ASCII letters, digits, `_` and `-` gets 400
  `invalid_request`, and a set without a body too. A body that is not JSON
  gets 400 `malformed_json`, as for other operations.
- A value that takes more than 1 MiB as compact JSON gets 400
  `invalid_request` and writes nothing, so a set is bounded as each value
  of a Stub's `variables` is.
- A set keeps a number's value, not its text: smock writes it as `json`
  does, so `19.990` is stored as `19.99` and `1e3` as `1000`, and only an
  integer beyond 2^53 keeps its digits. A Stub's `variables` keep the text
  a value renders with instead, such as `19.990` from `toFixed(x, 3)`. To
  keep a number's text through a set, set it as a string, such as
  `"19.990"`, which the arithmetic helpers take as that number.
- A delete of a Variable the Session has not set gets 404
  `unknown_variable`. Another Session's Variables are never listed, set or
  deleted.
- A set counts against [the state bound](#the-state-bound) as a Stub's
  writes do. A delete gives back the bytes the Variable counted.
- Each set and delete writes a log entry that names the Mock, the Session
  and the Variable, but not the value:

  ```json
  {"time":"2026-10-21T09:00:00.000Z","level":"info","msg":"Variable set","mock":"shop","session":"test-a","variable":"user"}
  ```

## Resets and reloads

A [reset](../admin-api.md#sessions-and-ephemeral-stubs) clears the Variables
in its scope, so that a test starts clean:

- `{"scope":"session"}` clears the calling Session's Variables in every
  Mock, or those of requests without a Session when the call carries none;
- `{"scope":"mock","mock":"shop"}` clears every Session's Variables of
  `shop`, those of requests without a Session included;
- `{"scope":"all"}` clears every Variable.

The reset answers how many Variables it cleared, in `removed.variables`,
and its log entry says the same. A cleared Variable is unset, so
`vars.NAME` is missing again.

A [reload](../definition-files.md#reloading) that swaps in new files keeps
every Variable, even one that no Stub writes any more, except those of a
Mock the new files no longer declare, which are dropped. A reload that
fails, or finds the files unchanged, keeps them all. So editing the files
does not wipe the state of a test in progress.

## The state bound

One byte bound holds the per-Session state of the whole process, across
every Mock and Session, so that Variables and the copies of [Data
buckets](data-buckets.md#data-buckets) cannot exhaust a small Pod.

- `--state-max-bytes` or `SMOCK_STATE_MAX_BYTES` sets it, in bytes, from 1
  to 1073741824 (1 GiB), as `--journal-max-bytes` takes.
- Without either, it follows smock's memory limit, as the Journal's byte
  bound does ([ADR
  0004](../adr/0004-journal-byte-bound-follows-the-memory-limit.md)): an
  eighth of the memory limit of smock's cgroup (cgroup v2 `memory.max`),
  rounded down, at least 1 MiB and at most 64 MiB. Without a limit, or
  when it cannot be read, the bound is 64 MiB. Under a 52Mi limit it is
  6.5 MiB; from a 512Mi limit up, it is 64 MiB.
- smock reads the limit once at startup, for this bound and the Journal's,
  and logs the bound with its `source`: `flag`, `variable`, `memoryLimit`
  (an eighth of the limit), `minimum` (1 MiB) or `default` (64 MiB), and
  the `memoryLimit` it read, in bytes or `max`, or `memoryLimitError`, why
  it could not read one:

  ```json
  {"time":"2026-10-21T09:00:00.000Z","level":"info","msg":"state byte bound","maxBytes":6815744,"source":"memoryLimit","memoryLimit":54525952}
  ```

The bound keeps one count, up to date on each write:

- A space, one Mock with one Session or with no Session, counts its Mock
  name and its Session key once, plus 64 bytes, while it holds any Variable
  or [copy of a Data bucket](data-buckets.md#copies-and-the-state-bound).
  The no-Session space has no key to count.
- Each Variable counts its name, 64 bytes, and its value.
- A value counts its compact JSON as smock writes it, plus 16 bytes for
  each JSON value in it: each object, array, string, number, boolean and
  null.
- Names, Session keys and JSON count their bytes in UTF-8.

So `count: 1`, the only Variable of the Mock `shop` in the Session
`run-42`, counts 74 bytes for its space (4 + 6 + 64) and 86 for itself
(5 + 64 + 1 + 16). The fixed bytes keep long Session keys and many tiny
values from taking far more memory than the bound counts. A write that
replaces a value counts the new size in place of the old. When a space
holds nothing more, its bytes go too, so resets and reloads that drop
Variables give their bytes back. Scenario state does not count, and
is not bounded.

A request whose writes would take the count above the bound writes none of
them. Under `smock serve --state-max-bytes 1048576`, with this Stub:

```yaml
- id: add-cart-item
  mock: shop
  request: { method: POST, path: /cart/items }
  variables:
    last: ${body}
  response: { status: 201 }
```

a request whose body would take the count above 1 MiB gets 507, with
`Content-Type: application/json`:

```json
{"error":"state limit reached","stub":"add-cart-item","message":"the writes would take per-Session state from 1048000 to 1049100 bytes, above its bound of 1048576 (--state-max-bytes)"}
```

- No response is picked, and nothing is written.
- The Scenario move stands. The Stub's delay still applies, and a
  connection Fault still replaces the response, as for a template failure.
- The Journal entry records status 507, `responseIndex: null`,
  `variablesWritten: []` and `dataWritten: []`.
- A write that does not grow the count, such as one that replaces a value
  with a smaller one, always fits.
- A gRPC call whose writes would pass the bound gets Trailers-Only
  RESOURCE_EXHAUSTED `state limit reached` instead of the 507, and its
  Journal entry records the HTTP status 200 and the `grpcStatus`
  `RESOURCE_EXHAUSTED` ([smock's own
  failures](../grpc/unmatched-and-refused-calls.md#smocks-own-failures)).

An Admin API set follows the same rule. One that would take the count
above the bound writes nothing and gets 507 `state_limit_reached`, in the
Admin API's error form, with the same message. A delete gives back the
Variable's bytes, and its space's when the space holds nothing more.

Two metrics on the admin port, without labels, show how close the process
is to the bound: `smock_state_bytes`, the bytes the count holds now, and
`smock_state_writes_refused_total`, the writes it refused, each refused
request and each refused Admin API set once. smock reads them when
`/metrics` is scraped. `smock render` and the Admin render operation write
nothing, so they never meet the bound.
