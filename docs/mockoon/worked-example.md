# A worked example: from the routes to the CRUD route

This document starts the worked example of [Migrating from
Mockoon](../migrating-from-mockoon.md), which translates one Mockoon
environment into a Definition file step by step; it takes the steps from the
environment's routes to its CRUD route. It comes after the guide's [How the
models differ](../migrating-from-mockoon.md#how-the-models-differ), whose
terms it uses. The notes at the top of the guide, on where the commands
run and which smock they need, hold here too.

The environment `users-api`, in
[`mockoon/users-api.json`](../examples/from-mockoon/mockoon/users-api.json),
has the prefix `api/v1`, `cors: true`, the environment header
`Content-Type: application/json`, and six routes:

| Route | Responses, in order | Rules |
|---|---|---|
| `GET users` | 200 with the file `users.json` and 300 ms of latency (the default); 200 with the file `inactive-users.json` | On the second: query `status` equals `inactive`. |
| `GET users/:id` | 200 with an inline template (the default); 404 | On the 404: params `id` regex `^0+$`. |
| `POST users` | 201 with an inline template; 403 (the default) | On the 201: header `X-Api-Key` equals `secret`, AND body `role` equals `admin`. |
| CRUD `orders` | The data bucket `orders`, `[{"id":1,"item":"book"},{"id":2,"item":"pen"}]` | None. |
| `GET exports/:id`, `SEQUENTIAL` | 200 with `{ "status": "running" }` (the default); 200 with `{ "status": "done" }` | None. |
| `POST password/reset` | 202 with `{ "message": "sent" }`; 429 with `Retry-After: 60` and `{ "error": "too many requests" }` (the default) | On the 202: `request_number` regex `^[12]$`. |

The two inline templates are:

```text
{ "id": "{{urlParam 'id'}}", "name": "{{faker 'person.fullName'}}", "lang": "{{queryParam 'lang' 'en'}}" }
{ "id": "{{faker 'string.uuid'}}", "name": "{{body 'name'}}" }
```

The steps below, and those of [Answers that change between
requests](worked-example-state.md), turn it into
[`defs/users-api.yaml`](../examples/from-mockoon/defs/users-api.yaml), shown
whole in [The result](worked-example-result.md). They apply to any
environment.

## Contents

- [List the routes Mockoon serves](#list-the-routes-mockoon-serves)
- [Declare the Mock](#declare-the-mock)
- [Environments told apart by port](#environments-told-apart-by-port)
- [One Stub per response](#one-stub-per-response)
- [Paths and request conditions](#paths-and-request-conditions)
- [Bodies, headers and templates](#bodies-headers-and-templates)
- [Latency, CORS and the CRUD route](#latency-cors-and-the-crud-route)

## List the routes Mockoon serves

- Mockoon tries routes in the order of the environment's `rootChildren`,
  with each folder's `children` in its place, depth first; the order of
  the `routes` array does not count. Folders change only the order,
  never a path
  ([folders](https://mockoon.com/docs/latest/api-endpoints/folders/)).
- A route switched off in the desktop app is still in the file, since
  Mockoon keeps those switches in the app's settings, and
  `--disable-routes` switches routes off for one CLI run. Leave such
  routes out. A file with an older `lastMigration` may still mark routes
  `"enabled": false`: the desktop app keeps them off, but Mockoon CLI 9.x
  drops the field and serves them, so leave them out only where they
  were meant to stay off.
- Check each route against [What smock does not
  do](../migrating-from-mockoon.md#what-smock-does-not-do). Here every route
  has a counterpart, the CRUD route included
  ([below](#latency-cors-and-the-crud-route)).

## Declare the Mock

One environment becomes one Mock, best in a Definition file of its own:

```yaml
mocks:
  - name: users-api
    hosts: [localhost, users-api]
```

`hosts` lists the Hosts that clients send: `localhost` for a local run,
and `users-api` for clients that reach smock by that name, such as
through a Kubernetes Service. Hosts are compared without the port, so a
request for `users-api:3000` reaches this Mock too. As the only Mock,
`users-api` is also the Default Mock: a request for any other Host
reaches it as well, and its response carries
`Smock-Mock: users-api; via=default`.

Keep the Mock's `name` short and without spaces, such as `shop-api` for
an environment named `shop-api (provisional sample)`: the name is part
of Admin API paths, such as `/v1/mocks/shop-api/stubs`, and of the
`Smock-Mock` header, percent-encoded where it is not an HTTP token.

The environment's `port` and `hostname` have no place in the file. smock
listens on every IPv4 address (`0.0.0.0`), on the port that `smock serve
--port` gives, 8080 by default. Mockoon's `hostname` is the address Mockoon
listens on ([listening
hostname](https://mockoon.com/docs/latest/server-configuration/listening-hostname/)),
and has no counterpart.

## Environments told apart by port

The example has one environment, so its file does not change here.
Mockoon serves each environment on a port of its own, and clients often
tell two environments apart only by port, such as `localhost:3000` and
`localhost:3001`. smock compares Hosts without the port, so there are two
ways to keep them apart:

- **One smock, with a Mock for each environment, told apart by Host.**
  Each Host belongs to one Mock, so only one of them can list
  `localhost`; the other needs a name of its own. With two Mocks, neither
  is the Default Mock unless one is marked `default: true`, and a request
  for a Host that no Mock lists, such as `127.0.0.1`, gets 404
  `no Mock for this Host`. So mark the Mock that lists `localhost`:

  ```yaml
  mocks:
    - name: shop-api
      hosts: [localhost, shop-api]
      default: true
    - name: auth-service
      hosts: [auth-service]
  ```

  Clients of `auth-service` must then send that Host: through DNS, a
  Kubernetes Service of that name, an `/etc/hosts` entry, or a `Host`
  header, as in `curl -H 'Host: auth-service' localhost:8080/auth/me`. A
  client of `auth-service` that still sends the Host `localhost`, such as
  one whose port 3001 was mapped to smock's, reaches `shop-api` without a
  sign. Its requests get `shop-api`'s answers, or a 404 whose
  `Smock-Near-Miss` names a `shop-api` Stub, and no `Smock-Mock` header,
  since `localhost` is `shop-api`'s own Host. In `GET /v1/journal/unmatched`
  ([Checking the
  migration](../migrating-from-mockoon.md#checking-the-migration)), the
  entry's `host` and `mock` show the mix-up.
- **One smock for each environment.** Give each smock its own
  definitions directory with one Mock. Each Mock can then list
  `localhost`, and as the only Mock it is also the Default Mock of its
  smock, so clients keep their Host and their port. Each smock needs its
  own plain, TLS and Admin API ports; a second one on a port in use exits
  with `cannot listen` and `Address already in use`:

  ```sh
  export SMOCK_ADMIN_TOKEN=change-me
  smock serve --dir defs/shop-api --port 3000 --tls-port 3443 --admin-port 9090 &
  smock serve --dir defs/auth-service --port 3001 --tls-port 3444 --admin-port 9091 &
  ```

  In Docker, run one container for each, with `-p 3000:8080` and
  `-p 3001:8080`.

## One Stub per response

Mockoon serves the first response, in order, whose rules pass, and skips
responses without rules; when none passes, it serves the default response,
the one flagged as default or else the first ([multiple
responses](https://mockoon.com/docs/latest/route-responses/multiple-responses/),
[source](https://github.com/mockoon/mockoon/blob/fbeb141da66954019db89266c748aabc582d1897/packages/commons-server/src/libs/response-rules-interpreter.ts)).
So, for each route, in order:

1. Write a Stub for each response that has rules, in their order, with
   the route's method and path and the rules as conditions. Rules joined
   with AND go on one Stub; rules joined with OR, Mockoon's default, need
   one Stub each.
2. Write the default response last, with only the route's method and
   path as conditions. A default response with rules gets both: a Stub
   with its rules in its place in step 1, and this one.
3. Drop the other responses without rules: Mockoon never serves them.

The route's response mode changes this:

- `DISABLE_RULES`: only the default response, without its rules.
- `FALLBACK`: everything but the Stub of step 2. A request that passes no
  rule then goes on to the next route in Mockoon, and to the next Stubs
  in smock.
- `SEQUENTIAL`: a Stub for each response, in order and without its rules,
  each moving a Scenario on to the next ([Answers that change between
  requests](worked-example-state.md#answers-that-change-between-requests)).
- `RANDOM`: one Stub, with the route's method and path, that gives every
  response in `responses`, without their rules
  ([Random responses](worked-example-state.md#random-responses)).

In the example, `GET users` lists its default response first, but the
Stub of the response with a rule, `list-inactive-users`, comes before the
default's, `list-users`. In `POST users`, the response with two AND rules
becomes `create-user`, before the default `create-user-forbidden`.

Every Stub needs an `id`, unique in the whole definition set. A
response's `label` is a start, but a label may be empty, and labels such
as "Default" repeat from route to route, so build the ID from the route
too. A route's `documentation` becomes a YAML comment, and the `uuid`s
are dropped.

## Paths and request conditions

A route's path is the prefix and the endpoint, joined: `api/v1` and
`users` give `path: /api/v1/users`. An endpoint with parameters becomes a
pattern, in RE2 syntax, which must match the whole path
([pattern conditions](../definition-files/matching.md#pattern-conditions)):

| Mockoon endpoint | smock `path` |
|---|---|
| `users/:id` | `{ pattern: "/api/v1/users/[^/]+" }` |
| `users{/:id}`, or `users/:id?` in the older syntax | `{ pattern: "/api/v1/users(/[^/]+)?" }` |
| `files/*` | `{ pattern: "/api/v1/files/.+" }` |

A template reads a parameter by its position, not by its name:
`${path[n]}` is segment `n` of the path, counted from 0 after the leading
`/`, the prefix included. So `{{urlParam 'id'}}` becomes `${path[3]}` in
`/api/v1/users/42`. A wildcard's tail cannot be read as one value, only
segment by segment or as part of the whole `${path}`.

A `params` rule becomes part of the path pattern. The regex `^0+$` on
`id` gives the pattern `/api/v1/users/0+` of `get-user-missing`, which
comes before `get-user` just as the 404 response comes before the
default. A regex anchored at one end, or at neither, is widened with
`[^/]*`, which stays within the segment: `^DISC-` on `products/:sku`
gives `/api/v1/products/DISC-[^/]*`. Widened with `.*`, it would also
match `/api/v1/products/DISC-1/x`, a path that the route never takes.
The query rule of `GET users` becomes `query: { status: inactive }`, and
the two AND rules of `POST users` become `headers: { X-Api-Key: secret }`
and `body: { json: { role: admin } }` on one Stub.

Seven things need care when translating rules;
[Rules](mapping-reference.md#rules) maps every kind:

- **A Mockoon regex matches anywhere in the value; a smock pattern
  matches the whole value.** `^0+$` drops its anchors, and `admin`
  becomes `.*admin.*`, or `[^/]*admin[^/]*` in a path pattern. RE2 has no
  lookaround and no backreferences, and smock supports no `\p{…}`
  classes.
- **Mockoon's `equals` compares text; a `json` condition compares
  types.** The rule body `count` equals `1` holds for `{"count":1}` and
  for `{"count":"1"}`, but `{ json: { count: 1 } }` only for the first,
  so write values with the type that clients send. Where they send both,
  a pattern meets both, since it reads a number or a boolean by its text:
  `{ json: { count: { pattern: "1" } } }`. An array that contains the
  value also meets a Mockoon `equals` rule, while a `json` array needs
  every element, in order. For "contains", write `$includes`:
  `{ json: { tags: { $includes: b } } }` holds when an element of `tags`
  is `"b"`. It never holds for a value that is not an array, which the
  `equals` rule also meets, so where clients send `tags` as a single
  value too, add a Stub with `tags: b`.
- **Mockoon reads JSON and form bodies with the same rules; each smock body
  condition reads one format.** Mockoon parses a body by its Content-Type,
  and a rule's path reads whatever came out. In smock, `json` reads JSON,
  `form` reads `application/x-www-form-urlencoded` forms, and `xml` reads
  XML. So the rule body `role` equals `admin` becomes `body: { json: { role:
  admin } }` for clients that send JSON, and `body: { form: { role: admin }
  }` for clients that send forms; when clients send both, write a Stub for
  each. A form field's name is literal, as a query parameter's is: the rule
  `user.name`, which Mockoon reads from the field `user[name]`, becomes
  `form: { "user[name]": Alice }`. As in Mockoon, a body is read as a form
  only when its Content-Type says it is one, though smock compares the media
  type in any case, and Mockoon only in lower case. A multipart body can be
  matched only by a pattern on the whole body ([Behaviour that
  differs](../migrating-from-mockoon.md#behaviour-that-differs)).
- **A regex on a field of a JSON body becomes a pattern in the field's
  place.** The rule body `email` regex `@example\.com$` becomes:

  ```yaml
  body: { json: { email: { pattern: '.*@example\.com' } } }
  ```

  A path such as `user.email`, or `$.user.email`, becomes nested keys,
  `{ user: { email: { pattern: … } } }`, and rules on several fields
  joined with AND go into one `json` condition. As in Mockoon, the
  pattern reads a string after its escapes are decoded, so it meets
  `"ann\u0040example.com"`, and it reads a number or a boolean by its
  text, so `123.*` meets `12345` and `1\.5` meets `1.50`. Three things
  still differ. Mockoon reads numbers as JavaScript does, which rounds
  `9007199254740993` to `9007199254740992` and reads `1e400` as
  `Infinity`; smock keeps every digit of an integer, and reads a number
  beyond a 64-bit float's range as written. Mockoon reads `null` as empty
  text and an object as `[object Object]`, and tests each element of an
  array; a smock pattern never meets `null`, an object or an array. A
  regex on the elements of an array becomes `$includes` with a pattern,
  `{ tags: { $includes: { pattern: "a.*" } } }`. An array index in the
  path, such as `items.0`, has no counterpart: a `json` array needs every
  element, and `$includes` finds an element wherever it sits.

  A body key named `pattern`, alone in its object and given a string, makes
  that object a pattern. For the rule body `filter.pattern` equals `a.b`, `{
  filter: { pattern: a.b } }` is a pattern on `filter` itself, which never
  meets the object that clients send. Nest a pattern in it instead: `{
  filter: { pattern: { pattern: 'a\.b' } } }` ([json
  conditions](../definition-files/matching.md#how-a-stub-matches-a-request)).
- **A rule on an XML body names an element by an XML path.** Mockoon turns
  an XML body into an object with xml-js, so its paths end in `_text` or
  name `_attributes`. An `xml` condition names elements and attributes by a
  path instead: `user.name._text` becomes `/user/name`, and
  `user._attributes.id` becomes `/user/@id`, as in `body: { xml: {
  /user/name: Alice, /user/@id: "7" } }` ([XML
  bodies](../definition-files/matching.md#xml-bodies)). The values differ in
  four ways. Mockoon keeps namespace prefixes, so a rule on
  `soap:Envelope.soap:Body.u:GetUser.u:id._text` fails when a client writes
  `S:Envelope`; smock ignores prefixes, and the path is
  `/Envelope/Body/GetUser/id`. Mockoon compares the text as written, without
  CDATA or the text of child elements, so `<name> Alice </name>` fails
  `Alice`; smock trims an element's text, and includes both. When an element
  repeats, Mockoon's path reaches an array and fails, unless an index such
  as `user.name.1._text` picks one; smock's path holds when any one of them
  meets the condition, and has no indexes. And Mockoon reads a body as XML
  only with the Content-Type `application/xml`, `text/xml` or
  `application/soap+xml`, while smock parses it whatever its Content-Type.
  Rules on `_declaration` have no counterpart.
- **A cookie rule becomes a `cookies` condition on the value as sent.**
  The rule cookie `session` equals `abc` becomes
  `cookies: { session: abc }`. Mockoon decodes the value and strips
  surrounding quotes, so its rule `abc` also meets `session="abc"`, and
  a rule `a b` meets `session=a%20b`. smock compares the value as the
  client sent it: write that form, such as `session: a%20b`, or a
  pattern that meets each form, such as `{ pattern: '"?abc"?' }`.
  Mockoon also trims spaces around `=` and reads only the first cookie
  of a name that repeats; smock does not trim there, and tests every
  cookie of the name. Both compare names case and all
  ([Cookies](../definition-files/matching.md#cookies)).
- **An inverted rule becomes `$not`.** `{ $not: … }` around the rule's
  value or pattern holds when the rule's condition does not, so, like
  the inverted rule, it holds when the name or key is absent. Take a
  route `GET accounts/:id` in another environment, `accounts-api`, also
  with the prefix `api/v1`. Its responses are a 401 with the inverted
  rule header `Authorization` regex `^Bearer\s+\S+`, a 404 for params
  `id` equals `0`, and the default 200. They become three Stubs, in the
  same order:

  ```yaml
  - id: account-unauthorized
    mock: accounts-api
    request:
      method: GET
      path: { pattern: "/api/v1/accounts/[^/]+" }
      headers: { Authorization: { $not: { pattern: 'Bearer\s+\S+.*' } } }
    response: { status: 401, json: { error: unauthorized } }

  - id: account-unknown
    mock: accounts-api
    request: { method: GET, path: /api/v1/accounts/0 }
    response: { status: 404, json: { error: unknown } }

  - id: account-found
    mock: accounts-api
    request: { method: GET, path: { pattern: "/api/v1/accounts/[^/]+" } }
    response: { status: 200, json: { id: 1 } }
  ```

  A request without `Authorization`, or with `Basic …`, gets the 401
  from both.

  Two kinds of inverted rule still need the route turned around. `$not`
  goes only where a value goes, so an inverted rule on the path, the
  method, `params` or the whole body as text has no place for it. And a
  body of the wrong format fails every condition on it, `$not` included:
  a body that is not JSON fails `json`, one whose Content-Type is not a
  form's fails `form`, and one that is not XML fails `xml`. Mockoon's
  inverted rule holds for such a body, so a `POST` without a body gets
  the inverted response from Mockoon, and the next Stub's from smock.
  Where clients send such bodies, turn the route around too.

  To turn a route around, give the rule's condition to the Stubs of the
  responses after the inverted one, since Mockoon reaches them only when
  that condition holds, and move them in front of the inverted response's
  Stub, which drops the condition and becomes the general Stub. Responses
  before it keep their place. For the inverted rule body `role` equals
  `admin` on a 403, followed by the default 200, the 200's Stub gets
  `body: { json: { role: admin } }` and goes first, and the 403's Stub
  follows it without a body condition.

## Bodies, headers and templates

- **Templates.** Mockoon renders every inline body, and every file of a
  text type, as a Handlebars template unless `disableTemplating` is set.
  smock renders a response only with `template: true`. A JSON body
  becomes `json`, where a string that is exactly one `${…}` keeps the
  value's type, or `body`, text sent as written. The template of
  `GET users/:id` becomes:

  ```yaml
  template: true
  json:
    id: ${path[3]}
    name: ${fake.name()}
    lang: ${query.lang ?? 'en'}
  ```

  [Template helpers](mapping-reference.md#template-helpers) maps the
  helpers. Mockoon's request helpers give an empty string for a value that
  the request lacks. In smock a missing value is an error, answered with 500
  and `template failed`, unless `??` gives a fallback, as in `${body.name ??
  ''}`. In templated content, a literal `${` is written `$${`.
- **Types.** Where the Handlebars template has no quotes around a value,
  as in `"id": {{urlParam 'id'}}`, Mockoon sends a number, `"id": 42`,
  while `id: ${path[3]}` gives the string `"42"`. Write
  `id: ${number(path[3])}` there. A number built from a helper and text,
  such as `{{faker 'number.int' min=5 max=60}}.99`, is computed with an
  arithmetic helper: `price: ${add(fake.int(5, 60), 0.99)}` gives a
  number such as `6.99`.
- **Structure.** `$if` and `$each` work only in `json`, and each gives one
  value. So an `{{#if}}` around several members becomes one `$if` for
  each member, with the condition repeated, and
  `{{#if (eq (queryParam 'currency') 'JPY')}}` becomes
  `$if: query.currency == 'JPY'`:

  ```yaml
  price:
    $if: query.currency == 'JPY'
    then: 1200
    else: 9.99
  currency:
    $if: query.currency == 'JPY'
    then: JPY
    else: EUR
  ```

  smock has no array literals, but `split` makes an array of strings
  from a literal text. So `{{#each (array 'SKU-1' 'SKU-2')}}` becomes
  `$each: "split('SKU-1,SKU-2', ',')"`, and an `{{add @index 1}}` in it
  becomes `${add(loop.index, 1)}`. An array of numbers or objects is
  written out, one element after the other. `{{setVar}}` has no
  counterpart: write its expression wherever `{{getVar}}` reads the
  variable.
- **Quoting.** In block style, as above, `${…}` needs no quotes. In a
  flow mapping, `{ id: ${path[3]} }` fails with
  `expected , or } in a flow mapping`; write `{ id: "${path[3]}" }`. A
  comma ends a value there too, so quote any value that has one, text or
  expression: `{ message: If it exists, we sent a mail. }` fails with
  `empty value: write null, or "" for an empty string`, and
  `{ message: "If it exists, we sent a mail." }` and
  `{ $each: "range(1, 3)", as: i, do: "${i}" }` work. Quote a header
  value that YAML would read as a number or a boolean, such as
  `Retry-After: "120"` and `Access-Control-Allow-Credentials: "true"`;
  unquoted, it fails with `must be a string or an array of strings`.
- **Headers.** Mockoon sends the environment's headers with every response,
  and a response's own headers replace those of the same name. `Set-Cookie`
  is the exception: Mockoon sends every value, the environment's first.
  smock has no environment headers: copy the ones that clients rely on into
  each Stub's `headers`, and, except Content-Type, into the Mock's
  `noMatch.headers` for the requests that no Stub matches ([Behaviour that
  differs](../migrating-from-mockoon.md#behaviour-that-differs)). Here that
  is only `Content-Type: application/json`, which a `json` body gets by
  itself and the two body-file Stubs set. smock's YAML rejects anchors,
  aliases and merge keys (`anchors (&) are not supported`), so Stubs cannot
  share headers within a file; when many Stubs need the same headers, or the
  same delay, generate the file from a language that exports JSON ([another
  configuration
  language](../definition-files.md#writing-definition-files-in-another-configuration-language)).
  Several `Set-Cookie` values become one name with an array of them, in the
  order Mockoon sends them:

  ```yaml
  headers:
    Set-Cookie:
      - session=abc; Path=/; HttpOnly
      - theme=dark; Path=/
  ```

  For any other key that a response lists more than once, Mockoon sends
  only the last value, so give the name that value as a string.
- **Empty bodies.** A new Mockoon response has the body `{}`. A Stub
  writes that as `json: {}`, since a Stub without a body sends an empty
  one.
- **Files.** A `FILE` body goes into `defs/files/`, and the Stub names it in
  `bodyFile`, relative to `files/`. Mockoon reads a relative `filePath` from
  the environment file's directory, so keep only the path below
  `defs/files/`: the example's `../defs/files/users.json` becomes `bodyFile:
  users.json`, and so would a `filePath` of `files/users.json`. Mockoon
  derives the Content-Type from the file's extension and smock does not, so
  set it. With Mockoon's default `sendFileAsBody: false`, Mockoon also sends
  `Content-Disposition: attachment` with the file's name: add that header if
  clients need it (the example's files have `sendFileAsBody` set to true). A
  body file is a template only with `template: true`, and must then be
  UTF-8. As in Mockoon, an untemplated body file answers Range requests
  ([file
  serving](https://mockoon.com/docs/latest/response-configuration/file-serving/)).
  smock serves a single byte range of a 200 to a GET, and a malformed
  `Range` gets the whole body with 200, where Mockoon answers 400 ([Range
  requests](../definition-files/responses.md#range-requests); [Behaviour
  that differs](../migrating-from-mockoon.md#behaviour-that-differs) has the
  other differences).
- **A templated file path and `fallbackTo404`.** A Stub names one fixed
  body file, and a missing body file makes the definition set invalid,
  which `smock check` reports. For a `filePath` such as
  `files/invoices/{{urlParam 'id'}}.pdf` on the route `invoices/:id/pdf`,
  write one Stub for each file that exists, with its exact path, then a
  Stub with the path pattern for the others. With `fallbackTo404`,
  Mockoon answers those with 404, the response's own headers and its
  inline body, and, with `sendFileAsBody: false`, a
  `Content-Disposition` with the requested name:

  ```yaml
  - id: invoice-a1
    mock: users-api
    request: { method: GET, path: /api/v1/invoices/A1/pdf }
    response:
      status: 200
      headers:
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="A1.pdf"
      bodyFile: invoices/A1.pdf

  - id: invoice-not-found
    mock: users-api
    request: { method: GET, path: { pattern: "/api/v1/invoices/[^/]+/pdf" } }
    response:
      status: 404
      template: true
      headers:
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="${path[3]}.pdf"
      body: '{ "error": "invoice_not_found" }'
  ```

  Each new file then needs a Stub of its own.
- **Data buckets.** A `DATABUCKET` body becomes `json: "${data.NAME}"`,
  with `template: true`, which answers what the bucket holds for the
  request's Session ([Data buckets](worked-example-state.md#data-buckets)).

## Latency, CORS and the CRUD route

- **Latency.** Mockoon adds the environment's `latency` to each
  response's own. In smock, a delay is a Fault on the Stub, so
  `list-users` gets `fault: { delay: { fixed: 300 } }`. Mockoon's
  environment latency also delays the requests that no route answers;
  smock delays only the requests that a Stub with a delay matches.
  `--enable-random-latency`, which draws each latency from 0 to the
  value set, becomes `delay: { uniform: { min: 0, max: 300 } }`.
- **CORS.** With `cors: true`, Mockoon answers each `OPTIONS` request
  that no route takes with 200, an empty body and three
  `Access-Control-Allow-*` headers
  ([CORS](https://mockoon.com/docs/latest/server-configuration/cors/)),
  then adds the environment headers, which replace those of the same
  name. The Stub `preflight`, in [The result](worked-example-result.md),
  does the same; it has the three defaults because this environment's only
  header is `Content-Type`, which an answer without a body does not need.
  When the environment headers hold CORS headers, start from the defaults
  and let the environment's CORS headers replace and extend them. With
  `Access-Control-Allow-Origin: http://localhost:5173` and
  `Access-Control-Allow-Credentials: true` among them, Mockoon's answer
  has those two and the default `Allow-Methods` and `Allow-Headers`.
  With the defaults alone, smock would send `*` and no
  `Allow-Credentials`, and a browser then refuses a request with
  credentials.

  `preflight` comes last, so that it is not named as the Near miss of
  requests that other Stubs nearly match: on a tie in failed conditions, the
  Near miss is the Stub tried first. Since it has only one condition, its
  method, it is still the Near miss of a request that fails two or more
  conditions of every other Stub, such as `HEAD /api/v1/status`, which gets
  `Smock-Near-Miss: preflight; failed=method`. The CRUD Stub `orders` fails
  only its path for a method that it serves, so `DELETE /api/v1/status`
  names `orders`. The CORS example in [When no Stub
  matches](../definition-files/matching.md#when-no-stub-matches)
  gives its preflight Stub a second condition, `headers: {
  Access-Control-Request-Method: { pattern: ".+" } }`, which every preflight
  meets. The 404 for that `HEAD` then names `list-users`, which fails its
  method and path, but an `OPTIONS` request without that header, which
  Mockoon answers, gets 404.

  Mockoon adds CORS headers to other responses, its 404 for a request that
  no route takes included, only when they are among the environment headers.
  In that case, copy them into the Stubs, into the CRUD Stub's
  `crud.headers` ([below](#latency-cors-and-the-crud-route)), and into the
  Mock's `noMatch.headers` for its no-match response ([Behaviour that
  differs](../migrating-from-mockoon.md#behaviour-that-differs)).
- **The CRUD route.** The data bucket becomes a [Data
  bucket](../definition-files/data-buckets.md#data-buckets) of the Mock, in
  the file's top-level `data`, and the CRUD route becomes a [CRUD
  Stub](../definition-files/crud-stubs.md#crud-stubs), in the route's place:

  ```yaml
  data:
    - mock: users-api
      name: orders
      key: id
      json: [{ id: 1, item: book }, { id: 2, item: pen }]

  stubs:
    # …
    - id: orders
      mock: users-api
      crud: { bucket: orders, path: /api/v1/orders }
  ```

  The bucket's content goes into `json`, or, for a large one, into a file in
  `defs/files/` that `jsonFile` names. `key` is the route's `crudKey`,
  written out when it is Mockoon's default, `id`. `crud.path` is the route's
  prefix and endpoint, joined, and `crud.bucket` names the bucket that the
  route's `databucketID` links. As the route does, the CRUD Stub lists and
  creates orders at `/api/v1/orders`, and reads, replaces, updates and
  deletes one at `/api/v1/orders/<id>`, with Mockoon's statuses, and with
  `X-Total-Count` and `X-Filtered-Count` on a list. Some answers differ in
  their details ([Behaviour that
  differs](../migrating-from-mockoon.md#behaviour-that-differs)).

  Each Session reads and writes its own copy of the bucket, and requests
  without a Session share one ([Data
  buckets](worked-example-state.md#data-buckets)). So a test sees the orders
  it creates, and other tests do not:

  ```sh
  curl -H "baggage: smock-session=checkout-42" -d '{"item":"pencil"}' localhost:8080/api/v1/orders   # 201
  curl -H "baggage: smock-session=checkout-42" localhost:8080/api/v1/orders/3                       # 200
  curl localhost:8080/api/v1/orders/3                                                                # 404
  ```

  A Stub before the CRUD Stub takes over the requests it matches. So the
  route's other responses, which its rules pick in place of the CRUD
  operation, become ordinary Stubs before the CRUD Stub, and so does a route
  that Mockoon's docs place above the CRUD route to override one operation.
  `smock check` warns about such a Stub with a method and an exact path
  after the CRUD Stub, where it never answers ([Order and
  overrides](../definition-files/crud-stubs.md#order-and-overrides)).

  Mockoon adds the environment headers to the route's answers. When they
  hold CORS headers, give them to the CRUD Stub in `crud.headers`, which
  go on every answer, errors included. A browser reads `X-Total-Count`
  and `X-Filtered-Count` of a cross-origin answer only when
  `Access-Control-Expose-Headers` names them, which Mockoon does not
  send by itself:

  ```yaml
  - id: orders
    mock: users-api
    crud:
      bucket: orders
      path: /api/v1/orders
      headers:
        Access-Control-Allow-Origin: http://localhost:5173
        Access-Control-Allow-Credentials: "true"
        Access-Control-Expose-Headers: X-Total-Count, X-Filtered-Count
  ```

  `preflight` stays: a CRUD Stub does not answer `OPTIONS`.

  A list reads smock's own parameters, not Mockoon's ([List
  queries](../definition-files/crud-stubs.md#list-queries)), so change the
  queries that clients send:

  | Mockoon | smock |
  |---|---|
  | `item_eq=book` | `item=book`, on a top-level member only. |
  | `sort=item`, `sort=item&order=asc` | `$sort=item` |
  | `sort=item&order=desc` | `$sort=-item` |
  | `page=3&limit=20` | `$offset=40&$limit=20`: `$offset` is `(page - 1) * limit`. |
  | `page=3` | `$offset=20&$limit=10`, with Mockoon's default `limit` of 10 written out. |
  | `limit=20` | `$limit=20` |
  | `search`, and the operators `_ne`, `_gt`, `_gte`, `_lt`, `_lte`, `_like`, `_start` and `_end` | No counterpart. |

  `GET /api/v1/orders?item_eq=book` thus becomes `GET
  /api/v1/orders?item=book`, which answers only the book, with
  `X-Total-Count: 2` and `X-Filtered-Count: 1`, as Mockoon does. A parameter
  that Mockoon does not read, such as jQuery's `_`, is ignored there, but
  filters in smock: no order has a member of that name, so the list is `[]`,
  with `X-Filtered-Count: 0`. A query that keeps Mockoon's parameters, such
  as `item_eq=book`, gets `[]` the same way. Where a client cannot change
  its query, an ordinary Stub before the CRUD Stub answers its lists ([List
  queries](../definition-files/crud-stubs.md#list-queries) shows one).

  Both counts keep Mockoon's meanings on every list: `X-Total-Count` is
  the number of items in the bucket, and `X-Filtered-Count` the number
  that pass the filters, before paging. json-server 0.17 gives
  `X-Total-Count` the second meaning, and sends it only with its paging
  parameters, so a client written for it reads the number that passes
  the filters there. Point such a client at `X-Filtered-Count`.

The walk-through goes on in [Answers that change between
requests](worked-example-state.md), with the example's last two routes.
