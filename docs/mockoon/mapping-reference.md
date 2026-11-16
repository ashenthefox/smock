# Mapping reference

This is the reference of [Migrating from
Mockoon](../migrating-from-mockoon.md), for looking up smock's counterpart
of one part of an environment; the [worked example](worked-example.md)
explains the translation in order.

These tables map each part of a Mockoon environment that has a
counterpart, and name those that have none.

## Contents

- [Environments and routes](#environments-and-routes)
- [Rules](#rules)
- [Responses](#responses)
- [Template helpers](#template-helpers)
- [Running and operating](#running-and-operating)

## Environments and routes

| Mockoon | smock |
|---|---|
| Environment | A Mock, best in a Definition file of its own. |
| `name` | The Mock's `name`, best short and without spaces, since Admin API paths and `Smock-Mock` carry it. |
| `lastMigration` | Dropped; a Definition file may give `version: 1`. |
| `port` | `smock serve --port`, 8080 by default, shared by every Mock; environments that clients tell apart only by port need Hosts of their own or one smock each ([Environments told apart by port](worked-example.md#environments-told-apart-by-port)). |
| `hostname` | No counterpart: smock listens on every IPv4 address. |
| `endpointPrefix` | Written into each Stub's path. |
| `headers` | Copied into each Stub's `headers` where clients rely on them, quoted where YAML would read a number or a boolean, and, except Content-Type, into the Mock's `noMatch.headers`. |
| `latency` | Added to each Stub's delay Fault; requests that no Stub matches are not delayed. |
| `cors: true` | An `OPTIONS` Stub, declared last, with the three `Access-Control-Allow-*` headers, replaced and extended by the environment headers. |
| `cors: false` | No `OPTIONS` Stub. |
| `tlsOptions` | Nothing to set: smock also serves HTTPS, on port 8443 (`--tls-port`), with a self-signed certificate for `localhost` and every Host unless `--tls-cert-file` and `--tls-key-file` give a PEM certificate and key (convert a PFX file with `openssl pkcs12`). Client certificates are not checked. |
| `proxyMode` and the other `proxy…` fields | No counterpart; the Mockoon CLI logs the requests it proxied with `"requestProxied":true`, which smock's `mockoon` log format never writes ([Logs](../migrating-from-mockoon.md#logs)). |
| `data` (data buckets) | The top-level `data` of a Definition file: a [Data bucket](../definition-files/data-buckets.md#data-buckets) for each, whose `mock` is the environment's Mock ([The CRUD route](worked-example.md#latency-cors-and-the-crud-route)). |
| A bucket's `name` | `name`: 1 to 128 ASCII letters, digits, `_` and `-`, which templates and Stubs use exactly. Mockoon's helpers also find a bucket by its `id`, or by any part of its name, in any case ([Data buckets](worked-example-state.md#data-buckets)). |
| A bucket's `id`, `uuid` | Dropped: smock names a bucket by its `name`. |
| A bucket's `value` | `json`, or `jsonFile` with a file in `defs/files/`: static JSON, never a template. Save templated content as Mockoon generated it ([Behaviour that differs](../migrating-from-mockoon.md#behaviour-that-differs)). |
| A bucket's `documentation` | A YAML comment. |
| `callbacks` | No counterpart. |
| `rootChildren`, `folders` | The order of the Stubs. |
| Route `method` | `method`, in upper case; left out for `all`. |
| Route `endpoint` | `path`, exact or a `pattern` ([Paths and request conditions](worked-example.md#paths-and-request-conditions)). |
| Route `documentation` | A YAML comment. |
| `uuid` | Dropped. |
| `responseMode: null` | Stubs for the responses with rules, then one for the default response. |
| `DISABLE_RULES` | Only the default response, with only the route's method and path as conditions. |
| `FALLBACK` | No Stub for the default response without its rules. |
| `SEQUENTIAL` | A Stub for each response, in order and without its rules, each requiring a state of the route's Scenario and moving it to the next, the last back to `Started` ([Answers that change between requests](worked-example-state.md#answers-that-change-between-requests)). |
| `RANDOM` | One Stub with every response in `responses`, without their rules. Mockoon has no weights; copies of a response become one response whose `weight` is their number ([Random responses](worked-example-state.md#random-responses)). |
| Route `type: http` | Stubs, as above. |
| `type: crud` | A [CRUD Stub](../definition-files/crud-stubs.md#crud-stubs) in the route's place, whose `crud.path` is the prefix and the endpoint, joined ([The CRUD route](worked-example.md#latency-cors-and-the-crud-route)). The responses that the route's rules pick become Stubs before it. Its list takes smock's own parameters. `PUT`, `PATCH` and `DELETE` on the list, and a bucket that is not an array of objects with keys, need ordinary Stubs ([Data buckets](worked-example-state.md#data-buckets)). |
| `type: ws` | No counterpart. |
| `streamingMode`, `streamingInterval` | No counterpart: they belong to WebSocket routes. |

## Rules

| Mockoon rule | smock request condition |
|---|---|
| `query` | `query: { status: inactive }`; a rule on a nested name such as `filter.name` becomes the parameter's literal name, `query: { "filter[name]": Alice }`. |
| `header` | `headers: { X-Api-Key: secret }`, the name in any case. |
| `body` with a path, on a JSON body | `body: { json: { role: admin } }`, a subset match on JSON bodies, with types compared. With `regex`, a pattern in the value's place, `body: { json: { email: { pattern: '.*@example\.com' } } }`, which also meets a number or a boolean by its text, but never `null`, an object or an array ([Paths and request conditions](worked-example.md#paths-and-request-conditions)). A key named `pattern`, alone in its object, takes a pattern as its value: `{ filter: { pattern: { pattern: 'a\.b' } } }`. |
| `body` with a path, on a form body | `body: { form: { role: admin } }`, which, as in Mockoon, needs the form Content-Type. A nested name such as `user.name` becomes the field's literal name, `form: { "user[name]": Alice }`. A Stub reads one format, so a rule that clients meet with JSON and with forms needs a Stub for each. |
| `body` with a path, on an XML body | `body: { xml: { /user/name: Alice } }`: `user.name._text` becomes `/user/name`, and `user._attributes.id` becomes `/user/@id`. smock ignores namespace prefixes, trims the text, and parses the body whatever its Content-Type ([Paths and request conditions](worked-example.md#paths-and-request-conditions)). `_declaration` and array indexes have no counterpart. |
| `body` on a multipart body | No counterpart: a `pattern` on the whole body. |
| `body` without a path | `body: "<the whole body>"`, or a `pattern`. |
| `params` | Part of the path's `pattern`, widened with `[^/]*` so that it stays within its segment. |
| `path` | `path`, exact or a `pattern`. Mockoon also tests the URL with its query string. |
| `method` | `method`, in upper case. |
| `cookie` | `cookies: { session: abc }`, the name compared exactly. The value is compared as sent, where Mockoon decodes it and strips quotes, and every cookie of a repeated name is tested, where Mockoon reads the first ([Paths and request conditions](worked-example.md#paths-and-request-conditions)). |
| Operator `equals` | The value itself; with the type that clients send in a `json` condition, or as a pattern there, which meets a string, a number or a boolean by its text. On an array, `{ $includes: … }`, since Mockoon's `equals` holds when any element does. |
| Operator `regex` | `{ pattern: … }`, widened to match the whole value: `admin` becomes `.*admin.*`, or `[^/]*admin[^/]*` in a path, and `^0+$` becomes `0+`. On an array, `{ $includes: { pattern: … } }`. |
| Operator `regex_i` | The same, with `(?i)` in front. |
| A `modifier` that starts with `$` (JSONPath) | The same path as nested keys in a `json` condition; JSONPath filters, wildcards and array indexes have no counterpart. |
| `rulesOperator: AND` | All the conditions on one Stub. |
| `rulesOperator: OR` | One Stub per rule. |
| `invert` | `{ $not: … }` around the rule's value or pattern, which, like the inverted rule, also holds when the name or key is absent: `headers: { Authorization: { $not: { pattern: 'Bearer\s+\S+.*' } } }`. An inverted rule on the path, the method, `params` or the whole body as text, or one that must hold for a body of the wrong format, turns the route around: the Stubs of the later responses get the rule's condition and go first, and the inverted response's Stub follows them without it ([Paths and request conditions](worked-example.md#paths-and-request-conditions)). |
| Operator `null` | No single condition: a Stub for each case, each with the response. `{ $exists: false }` for an absent name or key, `""` for an empty value, and in a `json` condition also `null`: the rule query `a` null becomes two Stubs, with `query: { a: { $exists: false } }` and `query: { a: "" }`. A body that does not parse as JSON fails all three, though Mockoon's rule holds for it. Inverted: `{ pattern: "(?s).+" }`, which in a `json` condition meets a non-empty string, a number or a boolean, but not an object or an array. |
| Operator `empty_array` | `[]` in a `json` condition, which meets only an empty array. Inverted: `{ $not: [] }`, which, as in Mockoon, a missing key and a value that is not an array also meet. |
| Operator `array_includes` | `{ $includes: … }`, which holds only for an array: `body: { json: { tags: { $includes: admin } } }`. Mockoon compares the elements as text, so `1` meets `1` and `"1"`; `{ $includes: { pattern: "1" } }` does too. |
| Operator `valid_json_schema` | No counterpart. |
| Target `request_number` | A chain of states of the route's Scenario: a Stub for each of the first requests, each moving the Scenario on, then a Stub for the later ones that requires the last state ([Answers that change between requests](worked-example-state.md#answers-that-change-between-requests)). Only the Stubs with `moveTo` count. |
| Targets `global_var`, `data_bucket`, `templating` | No counterpart: conditions read the request only, never a Variable or a Data bucket ([Global variables](worked-example-state.md#global-variables), [Data buckets](worked-example-state.md#data-buckets)). |

## Responses

| Mockoon | smock |
|---|---|
| `statusCode` | `status`, from 200 to 599. |
| `label` | Part of the Stub's `id`, which is unique in the definition set. |
| `headers` | `headers`, a map from each name to a string, or to an array of strings for several `Set-Cookie` values. Names are compared case-insensitively. |
| `bodyType: INLINE` | `json` or `body`. |
| `body` | `json` for JSON, or `body` for text sent as written; with `template: true` when it uses helpers. |
| The default body, `{}` | `json: {}`. A Stub without a body sends an empty one. |
| `bodyType: FILE`, `filePath` | `bodyFile`, relative to `defs/files/`, with a Content-Type in `headers`. A templated `filePath` becomes one Stub per file. Without `template: true`, a 200 serves byte ranges to a `GET` ([Behaviour that differs](../migrating-from-mockoon.md#behaviour-that-differs)). |
| `sendFileAsBody: false` | `Content-Disposition: attachment; filename="<file name>"` in `headers`, if clients need it. |
| `bodyType: DATABUCKET` | `json: "${data.NAME}"`, with `template: true` ([Data buckets](worked-example-state.md#data-buckets)). |
| `databucketID` | On a CRUD route, `crud.bucket`, the bucket's `name`. With `bodyType: DATABUCKET`, the `NAME` in `${data.NAME}`. |
| `crudKey` | The bucket's `key`. Mockoon's default, `id`, is written out. Nested keys, such as `data.id`, have no counterpart. |
| `disableTemplating` | No `template: true`. |
| `fallbackTo404` | A Stub with the path pattern after the Stubs of the files, with 404, the response's headers and its inline body ([Bodies, headers and templates](worked-example.md#bodies-headers-and-templates)). |
| `latency` | `fault: { delay: { fixed: <ms> } }`, with the environment's latency added. |
| `--enable-random-latency` | `fault: { delay: { uniform: { min: 0, max: <ms> } } }`. |
| `default` | The Stub with only the route's conditions, last among the route's Stubs. |
| `callbacks` | No counterpart. |
| `{{status 404}}` | No counterpart: `status` is never templated. `responses` vary the status, at random ([Random responses](worked-example-state.md#random-responses)). |

## Template helpers

smock's expressions are described in
[Templates](../definition-files/templates.md#templates).
Helpers that are not listed here have no counterpart. Where clients need
only a value of the right kind, take a smock helper that gives one, such as
`${fake.words(3)}` for `{{faker 'commerce.productName'}}`; otherwise write a
fixed value. Leaving the member out changes the body's shape.

| Mockoon | smock |
|---|---|
| `{{urlParam 'id'}}` | `${path[n]}`, the segment counted from 0 after the leading `/`; `${number(path[n])}` where the template has no quotes around it. |
| `{{queryParam 'lang' 'en'}}` | `${query.lang ?? 'en'}` |
| `{{header 'X-Request-Id'}}`, `{{header 'Accept-Language' 'en-US'}}` | `${header.x-request-id ?? ''}`, `${header.accept-language ?? 'en-US'}` |
| `{{body 'user.name'}}`, `{{body '$.items[0].sku'}}` | `${body.user.name ?? ''}`, `${body.items[0].sku ?? ''}`, from JSON bodies only. |
| `{{body}}`, without a path | `${bodyText}` |
| `{{bodyRaw 'items'}}` | `body.items` as the value of `$each` or `$if`, or `${body.items}` alone in a `json` string, which keeps its type. |
| `{{cookie 'session'}}`, `{{cookie 'session' 'none'}}` | `${cookie.session ?? ''}`, `${cookie.session ?? 'none'}`, the value as the client sent it. Mockoon strips one pair of quotes and percent-decodes it, so for `session="a%20b"` it gives `a b`, and smock `"a%20b"`, as for [cookie rules](worked-example.md#paths-and-request-conditions). |
| `{{method}}` | `${method}` |
| `{{faker 'string.uuid'}}`, `{{uuid}}`, `{{guid}}` | `${fake.uuid()}` |
| `{{int 1 100}}`, `{{faker 'number.int' min=1 max=100}}` | `${fake.int(1, 100)}` |
| `{{float 1 100}}`, `{{faker 'number.float' min=1 max=100 fractionDigits=2}}` | `${fake.decimal(1, 100, 2)}`, with a set number of decimals. |
| `{{boolean}}`, `{{faker 'datatype.boolean'}}` | `${fake.bool()}` |
| `{{firstName}}`, `{{lastName}}`, `{{faker 'person.firstName'}}`, `{{faker 'person.lastName'}}` | `${fake.firstName()}`, `${fake.lastName()}` |
| `{{faker 'person.fullName'}}` | `${fake.name()}` |
| `{{email}}`, `{{faker 'internet.email'}}` | `${fake.email()}`, always at `example.com`. |
| `{{faker 'string.alphanumeric' 40}}` | `${fake.hex(40)}`, hex digits only, at most 64. |
| `{{faker 'lorem.word'}}`, `{{faker 'lorem.words' 3}}` | `${fake.word()}`, `${fake.words(3)}` |
| `{{oneOf (array 'a' 'b')}}` | `${fake.pick('a', 'b')}` |
| `{{add a b}}`, `{{subtract a b}}`, `{{multiply a b}}` | `${add(a, b)}`, `${subtract(a, b)}`, `${multiply(a, b)}`, exact in decimal: `add(0.1, 0.2)` gives `0.3`, where Mockoon gives `0.30000000000000004`. Each takes two numbers, so `{{add a b c}}` becomes `${add(add(a, b), c)}`. A number may be a string that is a JSON number, such as `query.page`. |
| `{{divide a b}}` | `${divide(a, b)}`, rounded half to even at 10 decimal places: `divide(10, 3)` gives `3.3333333333`, where Mockoon gives `3.3333333333333335`. A divisor of 0 is an error, where Mockoon skips it. |
| `{{modulo a b}}` | `${modulo(a, b)}`, with the sign of `a`, as in Mockoon. A divisor of 0 is an error, where Mockoon gives an empty text. |
| `{{ceil x}}`, `{{floor x}}`, `{{round x}}` | `${ceil(x)}`, `${floor(x)}`, `${round(x)}`. `round` takes a half away from zero: `round(-2.5)` gives `-3`, where Mockoon's `Math.round` gives `-2`. |
| `{{toFixed x 2}}` | `${toFixed(x, 2)}`, the places a literal from 0 to 18, rounded half away from zero in decimal: `toFixed(1.005, 2)` gives `1.01`, where Mockoon gives `1.00`. |
| `{{parseInt x}}` | `${parseInt(x)}`, of a number or a string that is one: `parseInt('12px')` is an error, where Mockoon gives `12`. |
| `{{concat a b}}`, `{{uppercase s}}`, `{{lowercase s}}`, `{{padStart s 6 '0'}}`, `{{padEnd s 6}}`, `{{substr s 0 3}}`, `{{indexOf s 'x'}}`, `{{includes s 'x'}}`, `{{len x}}` | `${concat(a, b)}`, `${uppercase(s)}`, `${lowercase(s)}`, `${padStart(s, 6, '0')}`, `${padEnd(s, 6)}`, `${substr(s, 0, 3)}`, `${indexOf(s, 'x')}`, `${includes(s, 'x')}`, `${len(x)}`. They count code points, where Mockoon counts UTF-16 units ([Behaviour that differs](../migrating-from-mockoon.md#behaviour-that-differs)). `uppercase` and `lowercase` map one code point to one, so `uppercase('straße')` gives `STRAßE`, where Mockoon gives `STRASSE`. smock also has `trim`. |
| `{{replace s 'a' 'b'}}`, `{{replaceAll s 'a' 'b'}}` | `${replace(s, 'a', 'b')}`, `${replaceAll(s, 'a', 'b')}`, with the replacement taken as it is, where Mockoon expands `$&` and `$$` in it. |
| `{{split s ','}}` | `${split(s, ',')}`, an array, for `$each` or a step such as `[0]`. An empty separator splits into code points, where Mockoon splits at spaces, and an empty text gives `[""]`, where Mockoon gives an empty text. |
| `{{join array ', '}}` | `${join(array, ', ')}`. The separator must be given, where Mockoon takes `, ` by default, and a value that is not an array is an error, where Mockoon gives it back unchanged. |
| `{{base64 s}}`, `{{base64url s}}`, `{{base64Decode s}}`, `{{base64urlDecode s}}` | `${base64(s)}`, `${base64url(s)}`, `${base64Decode(s)}`, `${base64urlDecode(s)}`. A block, such as `{{#base64}}id-{{body 'id'}}{{/base64}}`, becomes `${base64(concat('id-', body.id))}`. The decoders are strict: each takes its own alphabet only, and a character outside it, or padding that is not whole or not at the end, is an error, where Mockoon skips such characters and stops at the first `=`. smock also has `urlEncode` and `urlDecode`. |
| `{{jwtPayload token 'sub'}}`, `{{jwtHeader token 'alg'}}` | `${jwtPayload(token).sub ?? ''}`, `${jwtHeader(token).alg ?? ''}`: a step reads a claim, at any depth. Neither tool checks the signature. A value that is not a token is missing, so `?? ''` gives Mockoon's empty text. smock removes `Bearer` in any case, where Mockoon's `jwtHeader` gives an empty text for `bearer …`. |
| `{{now}}` | `${now()}`, in UTC with `Z`, where Mockoon writes local time with an offset, such as `+00:00` ([Behaviour that differs](../migrating-from-mockoon.md#behaviour-that-differs)). |
| `{{now 'yyyy-MM-dd'}}` | `${now('yyyy-MM-dd')}`, in UTC, with the same date-fns tokens, except that `YYYY`, `YY`, `Y`, `DD` and `D` fail when the files load. |
| `{{dateFormat d 'yyyy-MM-dd'}}` | `${dateFormat(d, 'yyyy-MM-dd')}`, in UTC, or at a fixed offset with a third argument, such as `'+09:00'`. A date that smock does not read is missing. |
| `{{dateTimeShift date=d months=1}}`, `{{dateTimeShift days=1 format='yyyy-MM-dd'}}` | `${dateTimeShift(d, 'P1M')}`, `${dateFormat(dateTimeShift(now(), 'P1D'), 'yyyy-MM-dd')}`: an ISO 8601 duration in place of the named amounts, and the result in RFC 3339, for `dateFormat` to format. A month shift stops at the end of the month, where Mockoon's rolls over. |
| `{{#repeat 3}}` | `{ $each: "range(1, 3)", as: i, do: … }`, in `json` only. |
| `{{#each}}` | `$each` over an array, or the values of a query parameter, a header or a cookie, in `json` only. A literal `(array …)` of strings becomes `split(…)` of one text; other literal arrays are written out ([Bodies, headers and templates](worked-example.md#bodies-headers-and-templates)). |
| `{{#if}}`, `{{#switch}}` | `$if`, which compares with `==` or `!=` against a literal, in `json` only: one for each member that the block wraps, and `(eq (queryParam 'c') 'a')` becomes `query.c == 'a'`. |
| `{{setVar}}`, `{{getVar}}` | No counterpart: the expression, written wherever the variable is read. |
| `{{setGlobalVar 'user' (body 'name')}}` | `variables: { user: "${body.name ?? ''}" }` on the Stub, written when the Stub matches, never from a template ([Global variables](worked-example-state.md#global-variables)). |
| `{{getGlobalVar 'user'}}`, `{{getGlobalVar 'user' 'address.city'}}` | `${vars.user ?? ''}`, `${vars.user.address.city ?? ''}`, a path as steps. |
| `{{getEnvVar 'REGION'}}`, `{{getEnvVar 'REGION' 'local'}}` | `${env.REGION ?? ''}`, `${env.REGION ?? 'local'}`, with `smock serve --template-env REGION`. Mockoon reads `MOCKOON_REGION`, and smock `REGION`, once, at startup, and only when `--template-env` lists it ([Environment variables](../definition-files/templates.md#environment-variables)). |
| `{{{x}}}` | `${raw(x)}`, in text templates. |
| `{{stringify x}}` | `${json(x)}` in text templates; in `json`, a string that is exactly `${x}`. |
| `{{data 'orders' '0.item'}}`, `{{data 'orders' '$.[0].item'}}`, `{{data 'orders'}}` | `${data.orders[0].item}`, `${data.orders}`: the bucket named exactly, and a dot path or a JSONPath as steps. An object or an array needs `${json(data.orders)}` in a text template; in `json`, a string that is exactly `${data.orders}` keeps it ([Data buckets](worked-example-state.md#data-buckets)). |
| `{{dataRaw 'orders'}}` | `data.orders` as the value of `$each` or `$if`, or `${data.orders}` alone in a `json` string. |
| `{{setData 'push' 'cart' '' (bodyRaw)}}` and the other operations | A write of the Stub's `dataWrites`, made when the Stub matches: `{ op: append, bucket: cart, value: "${body}" }` ([Data buckets](worked-example-state.md#data-buckets) maps each operation). |

## Running and operating

| Mockoon | smock |
|---|---|
| `mockoon-cli start --data env.json` | `smock serve --dir defs`, with the Admin API token in `SMOCK_ADMIN_TOKEN`. |
| `mockoon-cli start --data openapi.yaml`, which serves an OpenAPI document | `smock import-openapi` once, then `smock serve`: smock never reads OpenAPI when it serves ([Importing OpenAPI](../importing-openapi.md)). |
| `--watch` | Built in: smock reloads changed files without a restart, and keeps serving the current set when the new one is invalid. |
| `mockoon-cli validate` | `smock check defs` |
| `--disable-routes` | Remove the Stubs, or move them out of the definitions directory. |
| `--faker-seed` | `--seed`, or `fault.seed` on a Stub. |
| `--max-request-body-size` | `--body-limit`, 10 MiB by default. |
| The CLI's log lines | `--log-format mockoon` (`SMOCK_LOG_FORMAT=mockoon`), on stdout ([Logs](../migrating-from-mockoon.md#logs)). |
| `--log-transaction` and the transaction logs, `/mockoon-admin/logs` and `/mockoon-admin/events` | The Journal: `POST /v1/journal/query` and `GET /v1/journal/unmatched`. |
| `--disable-log-to-file` | Nothing needed: smock writes no log file. |
| The admin API, under `/mockoon-admin` | The Admin API, on its own port, 9090 by default. Mockoon 9.9.0's admin API needs a bearer token too: `--admin-api-token` sets it, or Mockoon logs the one it generates at startup. |
| `PURGE /mockoon-admin/state` | `POST /v1/reset` with `{"scope":"all"}`, which clears the Ephemeral Stubs, the Journal, every Scenario state, every Variable and every copy of a Data bucket, so that sequences, request counts, global variables and data buckets start over. |
| `PURGE /mockoon-admin/data-buckets` | `POST /v1/reset`, which drops the copies of Data buckets in its scope, with the rest of the scope's state, or a `DELETE` on `/v1/mocks/{mock}/data/{bucket}` for each bucket of the calling Session ([Data buckets](worked-example-state.md#data-buckets)). |
| `GET /mockoon-admin/data-buckets`, `GET /mockoon-admin/data-buckets/{id}` | `GET /v1/mocks/{mock}/data` lists the Mock's buckets, and `GET /v1/mocks/{mock}/data/{bucket}` reads the value that the calling Session reads. A `PUT` there sets the Session's copy, which Mockoon cannot do. |
| `/mockoon-admin/global-vars` | `GET /v1/mocks/{mock}/variables` lists the calling Session's Variables, and `PUT` and `DELETE` on `/v1/mocks/{mock}/variables/{name}` set and delete one ([Global variables](worked-example-state.md#global-variables)). |
| `PURGE /mockoon-admin/global-vars` | `POST /v1/reset`, which also clears Ephemeral Stubs, Journal entries, Scenario states and copies of Data buckets, or a `DELETE` for each Variable. |
| `--env-vars-prefix` | `--template-env`, which lists each name in full; there is no prefix. |
| `/mockoon-admin/env-vars` | No counterpart: smock reads the variables that `--template-env` lists once, at startup. |
| `PUT /mockoon-admin/environment` | Edit the files; smock reloads them. |
| The `mockoon/cli` image | `ghcr.io/hirunefu/smock:<version>`, from a release. |
| `import` | `smock import-openapi <document> --mock <name> --output <file>`, from the same OpenAPI document ([Importing OpenAPI](../importing-openapi.md#notes-for-mockoon-users)). |
| `export` | No counterpart. |
