# A worked example: answers that change between requests

This document is the second part of the worked example of [Migrating from
Mockoon](../migrating-from-mockoon.md). It builds on [the first
part](worked-example.md), whose table lists the example's routes, and
translates the two whose answers change between requests, `GET exports/:id`
and `POST password/reset`, with Scenarios; then `RANDOM` routes, global
variables and data buckets, which smock serves with `responses`, Variables
and Data buckets. Its commands expect both servers started as in [The
result](worked-example-result.md): Mockoon on port 3000, and smock on 8080,
with its Admin API on 9090 and the token `change-me`. The notes at the top
of [the guide](../migrating-from-mockoon.md), on where the commands run
and which smock they need (0.3.0 or later), hold here too.

## Contents

- [Answers that change between requests](#answers-that-change-between-requests)
  - [Random responses](#random-responses)
  - [Global variables](#global-variables)
  - [Data buckets](#data-buckets)

## Answers that change between requests

A `SEQUENTIAL` route serves its responses in turn, and from the first
again after the last; it ignores their rules and which one is the
default. A `request_number` rule tests the number of the route's
request, counted from 1. Both count every request that the route
answers, whatever the response, with one count for each route that all
clients share. The count starts over when Mockoon restarts, and on
`PURGE /mockoon-admin/state`
([multiple responses](https://mockoon.com/docs/latest/route-responses/multiple-responses/),
[server state](https://mockoon.com/docs/latest/admin-api/server-state/)).

In smock, the Stubs of such a route share a
[Scenario](../definition-files/scenarios.md#scenarios). A Stub's `scenario`
clause names the Scenario, the state it `requires`, and the state it moves
the Scenario to (`moveTo`) when it answers. Every Scenario starts in the
state `Started`. Give each route a Scenario of its own, as Mockoon gives
each route its own count.

`GET exports/:id` is `SEQUENTIAL`. Each of its responses becomes a Stub
with the route's method and path, in order and without rules. The first
Stub requires `Started`, and each later one a state named after its
response. Each Stub moves the Scenario to the state of the next one, and
the last moves it back to `Started`, which closes the cycle:

```yaml
- id: get-export-running
  mock: users-api
  request: { method: GET, path: { pattern: "/api/v1/exports/[^/]+" } }
  scenario: { name: export, requires: Started, moveTo: done }
  response: { status: 200, json: { status: running } }

- id: get-export-done
  mock: users-api
  request: { method: GET, path: { pattern: "/api/v1/exports/[^/]+" } }
  scenario: { name: export, requires: done, moveTo: Started }
  response: { status: 200, json: { status: done } }
```

`GET /api/v1/exports/7` then answers `running`, `done`, `running`, and
so on. As in Mockoon, `GET /api/v1/exports/8` takes the next turn of the
same cycle. Without the `moveTo` of the last Stub, the Scenario stays at
`done`, which suits a client that polls until a job is done; Mockoon has
no such mode.

`POST password/reset` gives the first two requests 202 and every later
one 429. "The first N answers, then another" becomes a chain of states:
a Stub for each of the first N requests, each moving the Scenario on to a
state that counts it, then a Stub for the other answer, which requires
the last state and stays there:

```yaml
- id: reset-password-sent-1
  mock: users-api
  request: { method: POST, path: /api/v1/password/reset }
  scenario: { name: password-reset, requires: Started, moveTo: sent once }
  response: { status: 202, json: { message: sent } }

- id: reset-password-sent-2
  mock: users-api
  request: { method: POST, path: /api/v1/password/reset }
  scenario: { name: password-reset, requires: sent once, moveTo: sent twice }
  response: { status: 202, json: { message: sent } }

- id: reset-password-limited
  mock: users-api
  request: { method: POST, path: /api/v1/password/reset }
  scenario: { name: password-reset, requires: sent twice }
  response:
    status: 429
    headers: { Retry-After: "60" }
    json: { error: too many requests }
```

A state differs from Mockoon's count in three ways:

- **It is kept per Session and per replica.** Mockoon keeps one count
  for each route of the environment, and every client moves it. smock
  keeps a Scenario's state per
  [Session](../admin-api.md#sessions-and-ephemeral-stubs), so concurrent
  tests each walk their own flow, and requests without a Session share
  a state of their own. Each replica keeps its own state, so tests that
  rely on Scenarios need one replica, or session affinity. Started side
  by side, the two answer these requests differently:

  ```sh
  curl localhost:8080/api/v1/exports/7                                      # running
  curl -H "baggage: smock-session=test-a" localhost:8080/api/v1/exports/7   # running
  curl localhost:8080/api/v1/exports/7                                      # done
  ```

  Mockoon, on port 3000, answers `running`, `done` and `running`: the
  second request takes the next turn of the one count. In smock, it
  starts the Session `test-a`'s own cycle, and the third request finds
  the cycle without a Session where the first left it.
- **Only a Stub with `moveTo` moves it.** Mockoon counts every request
  that the route answers. A Stub without a clause answers in every state
  and moves nothing. So when a route has a 400 for a malformed request
  as well, Mockoon counts the 400s towards `request_number`, and smock
  does not.
- **A reset starts it over.** `POST /v1/reset` with `{"scope":"session"}`
  clears the calling Session's Ephemeral Stubs, Journal entries,
  Scenario states, Variables and copies of Data buckets, which sends its
  Scenarios back to `Started`. `{"scope":"all"}` clears every Session's,
  as `PURGE /mockoon-admin/state` starts Mockoon's counts over, clears its
  global variables and resets its data buckets. A reset answers how many
  states, Variables and copies it cleared, in `removed.scenarioStates`,
  `removed.variables` and `removed.dataBuckets`.
  `PUT /v1/mocks/users-api/scenarios/export` with `{"state":"Started"}`
  starts one Scenario over, the calling Session's export cycle, and leaves
  its other Scenarios where they are. A test can also start over with a
  new Session, whose Scenarios are all in `Started`. Like Mockoon's
  counts, states are lost on restart.

  ```sh
  curl -H "Authorization: Bearer change-me" -H "baggage: smock-session=test-a" \
    -d '{"scope":"session"}' localhost:9090/v1/reset
  curl -H "baggage: smock-session=test-a" localhost:8080/api/v1/exports/7   # running
  curl -X PUT -H "Authorization: Bearer change-me" -H "baggage: smock-session=test-a" \
    -d '{"state":"Started"}' localhost:9090/v1/mocks/users-api/scenarios/export
  curl -H "baggage: smock-session=test-a" localhost:8080/api/v1/exports/7   # running
  ```

A state is a name that Stubs give, not data: it cannot keep a value from
a request, and templates cannot read it. Three other kinds of route
answer differently from one request to the next: a `RANDOM` route, a
route that reads a global variable, and a route that reads or writes a
data bucket. smock has `responses`, Variables and Data buckets for them.
The example environment has none of them but [its CRUD
route](worked-example.md#latency-cors-and-the-crud-route), so the Stubs
below are not in its file.

### Random responses

A `RANDOM` route serves any of its responses, each as likely as the others,
and ignores their rules and which one is the default ([multiple
responses](https://mockoon.com/docs/latest/route-responses/multiple-responses/)).
Its responses go into one Stub, as
[`responses`](../definition-files/responses.md#several-responses), without
their rules. Mockoon's `RANDOM` has no weights: Mockoon's [issue
1016](https://github.com/mockoon/mockoon/issues/1016) asks for them, and
duplicated responses are the workaround there. smock takes integer weights,
so the copies of a response become one response whose weight is their
number. Say the example had a `RANDOM` route `GET profile`, with a 200 and
`{ "id": 7, "name": "Ann" }` three times and a 503 with `Retry-After: 5`
once. It becomes:

```yaml
- id: get-profile
  mock: users-api
  request: { method: GET, path: /api/v1/profile }
  responses:
    - { weight: 3, status: 200, json: { id: 7, name: Ann } }
    - { weight: 1, status: 503, headers: { Retry-After: "5" }, json: { error: unavailable } }
```

- As from Mockoon, about three requests in four get the 200, and the
  others the 503 and its `Retry-After`. Without copies, every response
  keeps the default weight of 1.
- Mockoon picks with JavaScript's `Math.random`, which `--faker-seed` does
  not seed, so no run can be repeated. smock picks from the request's one
  random draw, so [`fault.seed` and
  `--seed`](../definition-files/faults.md#seeds) replay the picks.
- Each response keeps its own status, headers, body and `template`. The
  conditions, the `fault` and the `scenario` clause stay one per Stub, so
  responses with latencies of their own share one delay.
- The [Journal](../admin-api.md#the-journal) records which response each
  request got, as `responseIndex`, and `smock render` with `--response 1`
  renders the 503 ([Checking the
  migration](../migrating-from-mockoon.md#checking-the-migration)). A test
  that needs the 503 on a given call, rather than by chance, adds an
  Ephemeral Stub that gives it for its Session ([Sessions and Ephemeral
  Stubs](../admin-api.md#sessions-and-ephemeral-stubs)).

### Global variables

A global variable keeps a value that one request sets for later ones
([global
variables](https://mockoon.com/docs/latest/variables/global-variables/)).
Templates set it with `setGlobalVar` and read it with `getGlobalVar`. Say
the example had a route `POST login`, whose body template sets `user`, and a
route `GET me`, which reads it:

```text
{{setGlobalVar 'user' (body 'name')}}{ "message": "logged in" }
{ "name": "{{getGlobalVar 'user'}}" }
```

In smock, a Stub's `variables` write
[Variables](../definition-files/variables.md#variables) when the Stub
matches, and templates read them as `vars.NAME`. `?? ''` gives the empty
text that Mockoon gives for a value that is not there:

```yaml
- id: login
  mock: users-api
  request: { method: POST, path: /api/v1/login }
  variables:
    user: ${body.name ?? ''}
  response: { status: 200, json: { message: logged in } }

- id: get-me
  mock: users-api
  request: { method: GET, path: /api/v1/me }
  response:
    status: 200
    template: true
    json: { name: "${vars.user ?? ''}" }
```

```sh
curl -H "baggage: smock-session=test-a" -d '{"name":"Ann"}' localhost:8080/api/v1/login
curl -H "baggage: smock-session=test-a" localhost:8080/api/v1/me   # {"name":"Ann"}
curl localhost:8080/api/v1/me                                      # {"name":""}
```

A Variable differs from a global variable in five ways:

- **It is kept per Mock and Session.** Mockoon keeps one set of global
  variables for each environment, and every client reads and writes it.
  smock keeps Variables per Mock and per Session, as it keeps Scenario
  states, so the last request above, which names no Session, does not
  see `Ann`. Each replica keeps its own.
- **A Stub field sets it, when the Stub matches.** Mockoon sets a global
  variable while a template renders. smock writes a Stub's `variables` at
  the match decision, before the delay and before the response is
  built, and the response sees the new values. No template sets a
  Variable, and no condition reads one, as the `global_var` rule target
  does in Mockoon.
- **It holds any JSON value, written as a template.** Each value of
  `variables` is a template, rendered against the Variables as they were
  before the request, so `count: ${add(vars.count ?? 0, 1)}` counts
  requests. A path that `getGlobalVar` takes becomes steps:
  `{{getGlobalVar 'user' 'address.city'}}` becomes
  `${vars.user.address.city ?? ''}`. One byte bound holds every Variable,
  and a request whose writes would pass it gets 507
  ([The state bound](../definition-files/variables.md#the-state-bound)).
- **Resets clear it.** `POST /v1/reset` clears the Variables in its scope,
  as `PURGE /mockoon-admin/state` and `PURGE /mockoon-admin/global-vars`
  clear Mockoon's ([Resets and
  reloads](../definition-files/variables.md#resets-and-reloads)). A reload
  of the files keeps them, except those of a Mock that the files no longer
  declare, and both tools lose them on restart.
- **The Admin API lists and sets it.** `GET /v1/mocks/users-api/variables`
  lists the calling Session's Variables, which Mockoon's Admin API cannot do
  for global variables, and `PUT` and `DELETE` on
  `/v1/mocks/users-api/variables/user` set and delete one ([Through the
  Admin API](../definition-files/variables.md#through-the-admin-api)).

### Data buckets

Beyond [CRUD routes](worked-example.md#latency-cors-and-the-crud-route),
Mockoon's templates read data buckets with the `data` and `dataRaw` helpers
and write them with `setData`, and a response with `bodyType: DATABUCKET`
serves a bucket whole ([using data
buckets](https://mockoon.com/docs/latest/data-buckets/using-data-buckets/)).
In smock, templates read a bucket as `data.NAME`, and a Stub's
[`dataWrites`](../definition-files/data-buckets.md#writing-buckets-datawrites)
write it when the Stub matches. Say the example had a bucket `visits`
holding `0`, and a route `POST visit` whose body template counts the calls:

```text
{{setData 'inc' 'visits'}}{ "visits": {{data 'visits'}} }
```

It becomes a bucket and a Stub:

```yaml
data:
  - { mock: users-api, name: visits, json: 0 }

stubs:
  - id: visit
    mock: users-api
    request: { method: POST, path: /api/v1/visit }
    dataWrites:
      - { op: set, bucket: visits, value: "${add(data.visits, 1)}" }
    response: { status: 200, template: true, json: { visits: "${data.visits}" } }
```

```sh
curl -X POST -H "baggage: smock-session=test-a" localhost:8080/api/v1/visit   # {"visits":1}
curl -X POST -H "baggage: smock-session=test-a" localhost:8080/api/v1/visit   # {"visits":2}
curl -X POST localhost:8080/api/v1/visit                                       # {"visits":1}
```

The value of a write is rendered against the data from before the
request, and the response reads the data after it, so the Stub counts as
the route does. Each `setData` operation becomes a write:

| Mockoon | smock |
|---|---|
| `{{setData 'set' 'cart' '' (bodyRaw)}}` | `{ op: set, bucket: cart, value: "${body}" }` |
| `{{setData 'merge' 'profile' '' (bodyRaw)}}` | `{ op: merge, bucket: profile, value: "${body}" }`, a shallow merge into the object that the bucket holds. |
| `{{setData 'push' 'cart' '' (bodyRaw)}}` | `{ op: append, bucket: cart, value: "${body}" }`, onto the array that the bucket holds. |
| `{{setData 'del' 'cart'}}` | `{ op: set, bucket: cart, value: null }`, or `[]` for a bucket with `key`, which holds an array. |
| `{{setData 'inc' 'visits' '' 2}}`, `{{setData 'dec' 'visits'}}` | `{ op: set, bucket: visits, value: "${add(data.visits, 2)}" }`, `{ op: set, bucket: visits, value: "${subtract(data.visits, 1)}" }` |
| `{{setData 'invert' 'enabled'}}` | `{ op: set, bucket: enabled, value: { $if: data.enabled, then: false, else: true } }` |
| A path into the value, such as `{{setData 'set' 'profile' 'address.city' 'Kyoto'}}` | No counterpart, except one item of a bucket with `key`: `set`, `merge` and `remove` take the item's `key`, where Mockoon takes its index, so `{{setData 'del' 'orders' '0'}}` becomes `{ op: remove, bucket: orders, key: "1" }` for the first order, whose `id` is 1. |

A Data bucket differs from a data bucket of Mockoon in five ways:

- **It is kept per Mock and Session.** Mockoon keeps one value for each
  bucket, which every client reads and writes. A smock Session reads the
  initial value until it first writes to the bucket, which gives it a
  copy of its own. Requests without a Session share one copy, and each
  replica keeps its own copies. So the last request above, which names no
  Session, counts from the start.
- **A Stub field writes it, when the Stub matches.** Mockoon writes while a
  template renders, and a CRUD route writes after the response's latency.
  smock writes at the match decision, before the delay and before the
  response is built, all of a Stub's writes and Variables or none of them. A
  write that cannot be applied, such as an `append` to a bucket that holds
  no array, answers 500 `data write failed`, where `setData` does nothing
  ([When a write
  fails](../definition-files/data-buckets.md#when-a-write-fails)). No
  condition reads a bucket, as the `data_bucket` rule target does in
  Mockoon.
- **It is named exactly.** Mockoon's helpers find a bucket by its `id`,
  or by any part of its name, in any case, so `{{data 'ord'}}` reads the
  bucket `orders`. `data.orders` names it in full, and a name that the
  Mock does not declare is an error when the files load.
- **Its initial value is static JSON.** Mockoon renders a bucket's content
  as a template ([Behaviour that
  differs](../migrating-from-mockoon.md#behaviour-that-differs)).
- **Resets drop it, and the Admin API sets it.** `POST /v1/reset` drops the
  copies in its scope, as `PURGE /mockoon-admin/data-buckets` resets
  Mockoon's buckets. A reload keeps a copy unless its bucket's initial value
  or `key` changed ([Copies in resets and
  reloads](../definition-files/data-buckets.md#copies-in-resets-and-reloads)),
  and both tools lose them on restart. `GET /v1/mocks/users-api/data` lists
  the Mock's buckets, and `GET`, `PUT` and `DELETE` on
  `/v1/mocks/users-api/data/visits` read, set and drop the calling Session's
  copy ([Data buckets through the Admin
  API](../definition-files/data-buckets.md#data-buckets-through-the-admin-api)).
  Mockoon's Admin API reads buckets, but cannot set one.

A CRUD Stub serves only a bucket with `key`, at its list path and its
item paths. Two kinds of CRUD route need ordinary Stubs instead:

- **`PUT`, `PATCH` and `DELETE` on the whole list.** A CRUD Stub does not
  match them, so they reach later Stubs. A `PUT` replaces the list with
  `set`, and a `DELETE` empties it with `set` to `[]`, where Mockoon
  leaves the bucket with no value:

  ```yaml
  - id: replace-orders
    mock: users-api
    request: { method: PUT, path: /api/v1/orders }
    dataWrites:
      - { op: set, bucket: orders, value: "${body}" }
    response: { status: 200, template: true, json: "${data.orders}" }

  - id: delete-orders
    mock: users-api
    request: { method: DELETE, path: /api/v1/orders }
    dataWrites:
      - { op: set, bucket: orders, value: [] }
    response: { status: 200, json: {} }
  ```

  A `PATCH` on the list becomes an `append` of `${body}` when clients
  send one item. Mockoon adds each item of an array body, which a write
  cannot do.
- **A bucket that is not an array of objects with keys.** Mockoon serves
  an object, a number or a text whole, at the route's path and at any item
  path, and the elements of an array of other values by index. Stubs
  that read `data.NAME` and write with `set` and `merge` serve such a
  bucket at its path:

  ```yaml
  data:
    - { mock: users-api, name: settings, json: { theme: light, lang: en } }

  stubs:
    - id: get-settings
      mock: users-api
      request: { method: GET, path: /api/v1/settings }
      response: { status: 200, template: true, json: "${data.settings}" }

    - id: replace-settings
      mock: users-api
      request: { method: PUT, path: /api/v1/settings }
      dataWrites:
        - { op: set, bucket: settings, value: "${body}" }
      response: { status: 200, template: true, json: "${data.settings}" }

    - id: update-settings
      mock: users-api
      request: { method: PATCH, path: /api/v1/settings }
      dataWrites:
        - { op: merge, bucket: settings, value: "${body}" }
      response: { status: 200, template: true, json: "${data.settings}" }
  ```

  Elements read by index have no counterpart, since a template's index
  is a number written in it.

The walk-through ends in [The result](worked-example-result.md), which shows
the whole Definition file.
