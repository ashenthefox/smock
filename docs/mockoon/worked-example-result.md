# A worked example: the result

This document ends the worked example of [Migrating from
Mockoon](../migrating-from-mockoon.md), whose steps are in [the first
part](worked-example.md) and [the second](worked-example-state.md). It shows
the Definition file that they build,
[`defs/users-api.yaml`](../examples/from-mockoon/defs/users-api.yaml), in
place of the environment
[`mockoon/users-api.json`](../examples/from-mockoon/mockoon/users-api.json),
then the answers of Mockoon and smock to the same requests, both started in
`docs/examples/from-mockoon/`. The notes at the top of [the
guide](../migrating-from-mockoon.md), on where the commands run and which
smock they need (0.3.0 or later), hold here too.

The whole Definition file:

```yaml
# The Mockoon environment ../mockoon/users-api.json as a Definition file.
# Each group of Stubs is one Mockoon route, in the environment's order.
mocks:
  - name: users-api
    hosts: [localhost, users-api]

# The data bucket "orders", with its initial value. Its key is the CRUD
# route's crudKey.
data:
  - mock: users-api
    name: orders
    key: id
    json: [{ id: 1, item: book }, { id: 2, item: pen }]

stubs:
  # GET users: lists the users; ?status=inactive lists the inactive ones.
  # The response with a rule comes first, the default response last.
  - id: list-inactive-users
    mock: users-api
    request: { method: GET, path: /api/v1/users, query: { status: inactive } }
    response:
      status: 200
      headers: { Content-Type: application/json }
      bodyFile: inactive-users.json

  - id: list-users
    mock: users-api
    request: { method: GET, path: /api/v1/users }
    response:
      status: 200
      headers: { Content-Type: application/json }
      bodyFile: users.json
    fault:
      delay: { fixed: 300 }

  # GET users/:id: the 404 for IDs made of zeros, then the default response.
  - id: get-user-missing
    mock: users-api
    request: { method: GET, path: { pattern: "/api/v1/users/0+" } }
    response: { status: 404, json: { error: not found } }

  - id: get-user
    mock: users-api
    request: { method: GET, path: { pattern: "/api/v1/users/[^/]+" } }
    response:
      status: 200
      template: true
      json:
        id: ${path[3]}
        name: ${fake.name()}
        lang: ${query.lang ?? 'en'}

  # POST users: both rules (AND) on one Stub, the default response last.
  - id: create-user
    mock: users-api
    request:
      method: POST
      path: /api/v1/users
      headers: { X-Api-Key: secret }
      body: { json: { role: admin } }
    response:
      status: 201
      template: true
      json:
        id: ${fake.uuid()}
        name: ${body.name ?? ''}

  - id: create-user-forbidden
    mock: users-api
    request: { method: POST, path: /api/v1/users }
    response: { status: 403, json: { error: forbidden } }

  # orders: a CRUD route on the data bucket "orders". It lists, creates,
  # reads, replaces, updates and deletes orders.
  - id: orders
    mock: users-api
    crud: { bucket: orders, path: /api/v1/orders }

  # GET exports/:id: SEQUENTIAL, so its responses take turns. Each answer
  # moves the Scenario "export" to the next one, and the last back to
  # Started.
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

  # POST password/reset: a request_number rule gives the first two requests
  # 202 and every later one 429. The Scenario "password-reset" counts them.
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

  # cors: true answers every OPTIONS request. Last, so that it is not
  # named as the Near miss of requests that other Stubs nearly match.
  - id: preflight
    mock: users-api
    request: { method: OPTIONS }
    response:
      status: 200
      headers:
        Access-Control-Allow-Origin: "*"
        Access-Control-Allow-Methods: GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS
        Access-Control-Allow-Headers: Content-Type, Origin, Accept, Authorization, Content-Length, X-Requested-With
```

Started side by side, with
`mockoon-cli start --data mockoon/users-api.json --port 3000` and
`SMOCK_ADMIN_TOKEN=change-me smock serve --dir defs`, the two answer:

| Request | Mockoon | smock |
|---|---|---|
| `GET /api/v1/users` | 200 after about 0.3 s, the bytes of `users.json` | The same. |
| `GET /api/v1/users?status=inactive` | 200, the bytes of `inactive-users.json` | The same. |
| `GET /api/v1/users/42?lang=ja` | 200, `{ "id": "42", "name": "<fake name>", "lang": "ja" }` | 200, `{"id":"42","name":"<fake name>","lang":"ja"}` |
| `GET /api/v1/users/000` | 404, `{ "error": "not found" }` | 404, `{"error":"not found"}` |
| `POST /api/v1/users` with `X-Api-Key: secret` and the JSON `{"name":"Alice","role":"admin"}` | 201, `{ "id": "<UUID>", "name": "Alice" }` | 201, `{"id":"<UUID>","name":"Alice"}` |
| The same with `"role":"viewer"` | 403, `{ "error": "forbidden" }` | 403, `{"error":"forbidden"}` |
| `OPTIONS /api/v1/users` | 200, the three CORS headers, no body | 200, the three CORS headers, no body and no Content-Type |
| `GET /api/v1/orders` | 200, the two orders, `X-Total-Count: 2`, `X-Filtered-Count: 2` | The same. |
| `GET /api/v1/orders/1` | 200, `{"id":1,"item":"book"}` | The same. |
| `POST /api/v1/orders` with the JSON `{"item":"pencil"}`, then `GET /api/v1/orders/3` | 201, `{"item":"pencil","id":3}`, then 200 with the new order | The same, and the 201 carries `Location: /api/v1/orders/3`. |
| `GET /api/v1/exports/7`, three times | 200, `{ "status": "running" }`, then `done`, then `running` again | 200, `{"status":"running"}`, then `done`, then `running` again |
| `POST /api/v1/password/reset`, three times | 202, `{ "message": "sent" }`, twice, then 429, `Retry-After: 60` and `{ "error": "too many requests" }` | 202, `{"message":"sent"}`, twice, then 429, `Retry-After: 60` and `{"error":"too many requests"}` |

Mockoon's JSON responses, and its `OPTIONS` answer, carry
`Content-Type: application/json; charset=utf-8`; smock's JSON responses
carry `application/json`, and its `OPTIONS` answer none.

The guide goes on with [Behaviour that
differs](../migrating-from-mockoon.md#behaviour-that-differs).
