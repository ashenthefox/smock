# Admin API

The Admin API is the authenticated interface, on its own port, for
inspecting and changing a running smock. Tests call it to add Ephemeral
Stubs, to set Scenario state, Variables and Data buckets in a Session, and
to check the Journal. Operators call it to read the status, the probes and
the metrics. This document describes every operation.
[Running smock](running.md) says how to start smock, and its
[Settings](running.md#settings) lists the flags that this document names.
The [Definition-file reference](definition-files.md) describes Stubs,
Scenarios, Variables and Data buckets.

The examples call the smock of the README's quick start
([Run](../README.md#run)): its token is `change-me`, and it serves the
`users` Mock with its `get-user` Stub.

The Admin API is JSON over HTTP/1.1 on the admin port, as
[openapi/admin.json](../openapi/admin.json) describes it:

```sh
curl -H "Authorization: Bearer change-me" localhost:9090/v1/status
curl -H "Authorization: Bearer change-me" -d '{"path": "/users/1"}' \
  localhost:9090/v1/stubs/get-user/render
curl localhost:9090/metrics
curl localhost:9090/readyz
```

## Contents

- [Authentication](#authentication)
- [Responses and errors](#responses-and-errors)
- [Status](#status)
- [Probes](#probes)
- [Metrics](#metrics)
  - [Process and cgroup metrics](#process-and-cgroup-metrics)
  - [Request metrics](#request-metrics)
- [Rendering a Stub](#rendering-a-stub)
- [Operations on Ephemeral Stubs, state and the Journal](#operations-on-ephemeral-stubs-state-and-the-journal)
- [Sessions and Ephemeral Stubs](#sessions-and-ephemeral-stubs)
- [The Journal](#the-journal)
  - [Verifying calls and unmatched requests](#verifying-calls-and-unmatched-requests)

## Authentication

Every operation but the [probes](#probes) and [`/metrics`](#metrics)
needs `Authorization: Bearer <token>`. The token comes
from the file `--admin-token-file` names, or from the environment variable
`SMOCK_ADMIN_TOKEN` (it has no flag, so it never shows in the process
list), without the whitespace around it. With authentication on and no
token, `smock serve` logs why and exits with status 1. Setting both the
token file and `SMOCK_ADMIN_TOKEN` is refused the same way, at startup,
rather than one of them silently winning. A
missing or wrong token gets 401 with `WWW-Authenticate: Bearer`; the token
is compared in constant time. `--admin-auth off` turns authentication off
for local use. The `smock starting` log entry says whether it is on
(`"adminAuth":"on"`).

## Responses and errors

Every response, errors included, names the replica that handled it in
`Smock-Replica`: the host name, which in Kubernetes is the Pod's hostname.
Every JSON response has a `warnings` array, which carries a
`per_replica_state` warning when `--replicas` is above 1.

Errors take the form `{"error": <code>, "message": ..., "warnings": [...]}`,
unknown operations (404), unsupported methods (405) and malformed JSON
(400) included.

## Status

`GET /v1/status` shows the version, commit and toolchain, as
`smock --version` prints them, the definition set digest, the result of
the last reload of the Definition files (`null` until the first one), and
the Mocks with their Hosts and which one is the Default Mock.

## Probes

The probes need no token, also when authentication is on. They answer
200 `{"status": "ok", ...}` when they pass and 503 with the error shape
when they fail:

- `GET /startupz` passes once the first definition set has loaded. The
  admin port opens before the definitions load, and until then the probe
  fails with `not_started`, as does every operation that needs the
  definitions.
- `GET /readyz` passes while smock serves, also after a reload that
  failed, since the previous definition set keeps serving. It fails with
  `not_started` before startup completes and with `not_ready` from the
  moment SIGTERM arrives.
- `GET /livez` passes while the event loop answers, during
  [the drain](running.md#the-drain) too, so that Kubernetes does not kill a
  draining Pod early.

## Metrics

`GET /metrics` serves the Prometheus metrics, without a token, also when
authentication is on. `smock_build_info` carries the version, commit and
toolchain as labels; `smock_definition_reloads_total` counts reloads of
the Definition files by result; with HTTPS,
`smock_tls_certificate_expiry_timestamp_seconds` gives when each
certificate expires; `smock_journal_entries`, `smock_journal_bytes` and
`smock_journal_evictions_total` show the [Journal](#the-journal)'s size
and evictions, without labels; `smock_state_bytes` and
`smock_state_writes_refused_total` show the bytes of per-Session state
that [the state bound](definition-files.md#the-state-bound) counts,
Variables and copies of Data buckets, and the writes it refused, from
requests, CRUD Stubs and Admin API sets, without labels;
`smock_log_lines_dropped_total` counts smock's own log lines that the
`mockoon` log format dropped because 1,024 of them were waiting for
stdout ([Logs](running.md#logs)), and stays 0 in the `json` format.

### Process and cgroup metrics

What smock's process and its cgroup use is read when `/metrics` is
scraped, so serving requests costs nothing for it. The standard process
metrics of Prometheus's client libraries: `process_cpu_seconds_total`
(user and system, from `/proc/self/stat`, to the hundredth of a second),
`process_resident_memory_bytes` (`VmRSS` of `/proc/self/status`) and
`process_start_time_seconds`. How long smock's main thread, which serves
every request, was ready to run but waited for a CPU,
`smock_process_scheduling_delay_seconds_total` (`run_delay` of
`/proc/self/schedstat`, to the nanosecond), and how many times the kernel
took the CPU from it while it could still run,
`smock_process_involuntary_context_switches_total`
(`nonvoluntary_ctxt_switches` of `/proc/self/status`). With a CPU limit,
both include the time the CFS quota held smock back. The CPU time the
hypervisor gave to something else while the machine's CPUs had something
to run, `smock_node_cpu_steal_seconds_total` (`steal` of `/proc/stat`, to
the hundredth of a second): the machine's, all its CPUs together, not
smock's, and 0 on bare metal; in a container, its node's. With how long
the quota held smock back, `smock_cgroup_cpu_throttled_seconds_total`
below, they tell a smock that waited for a CPU on a busy node (a delay
well beyond the throttled time, or steal time) from one that needed more
CPU (a delay about the throttled time). On cgroup v2, the metrics of
smock's own cgroup, the one `/proc/self/cgroup` names: from its `cpu.stat`,
`smock_cgroup_cpu_usage_seconds_total` (to the microsecond) and, with a
CPU limit, `smock_cgroup_cpu_periods_total`,
`smock_cgroup_cpu_throttled_periods_total` and
`smock_cgroup_cpu_throttled_seconds_total`, how often and how long the
CFS quota held it back; from its `memory.peak`,
`smock_cgroup_memory_peak_bytes`, the most memory it has used, all that
`memory.max` limits. In a Kubernetes container the cgroup is the
container's, so they show smock's CPU, throttling and peak memory where
nothing outside the Pod can read its cgroup, as on GKE Autopilot; outside
one, the cgroup may hold other processes too. A metric whose file smock
cannot read when it starts is left out; one whose file it cannot read
or understand at a scrape keeps the value it last read, and `/metrics`
answers all the same.

### Request metrics

The request traffic on the plain and TLS ports is in
`smock_requests_total` and the latency histogram
`smock_request_duration_seconds` (from the request being read in full to
the last byte of its response, so injected delays and Server-Sent Event
streams count; buckets from 100 µs to 5 minutes), labelled only by `mock`
and `stub`, and in `smock_unmatched_requests_total`, labelled only by
`mock`. A Stub from a Definition file is labelled by its ID, every
Ephemeral Stub by `stub="ephemeral"`, and a request that matched no Stub
by `stub=""`. A request is labelled with the Mock that answered it, the
Default Mock included, or `mock=""` when no Mock did. gRPC calls count as
requests, with the same labels. A gRPC call that a Mock's built-in health
or reflection service answered counts under its Mock with `stub=""` too,
but it is not an unmatched request, and the Journal does not record it
([The Journal and the metrics](grpc.md#the-journal-and-the-metrics)).
A request the protocol layer rejects (HTTP/1.1: 400, 413, 431, 501 or
505, such as a malformed head or a body over `--body-limit`; HTTP/2: 400,
413 or 431 on its stream; a gRPC call: 405, 400, or 200 with the gRPC
status UNIMPLEMENTED, INTERNAL or RESOURCE_EXHAUSTED, as
[Protocol checks and limits](grpc.md#protocol-checks-and-limits)
lists them) counts with `mock=""` and `stub=""`, timed from the read that
brought it; it is not an unmatched request, and the Journal does not
record it. Labels never carry a path, Host, method, status, gRPC status
or Session, so the number of series stays bounded by the Definition
files. A request is counted once its response is written; the Admin API,
probes and `/metrics` are not counted. Only the `mockoon` log format logs
requests: a `Transaction recorded` line for each request counted here,
except those the protocol layer rejects and the answers of gRPC's
built-in services. The `json` format logs none.

## Rendering a Stub

`POST /v1/stubs/{id}/render` renders a Stub's response for the sample
request in the body, against the definitions the replica serves now, as
[`smock render`](commands.md#smock-render) does. The optional `time` and
`seed` query parameters give the time (RFC 3339) and the seed of the random
source, and `response` the index of one of a Stub's `responses` to render;
the rendering shows those it used, the values the Stub's `variables` would
write, and the writes its `dataWrites` would make. It writes nothing.

## Operations on Ephemeral Stubs, state and the Journal

- `/v1/mocks/{mock}/stubs` adds, lists and deletes Ephemeral Stubs, and
  `POST /v1/reset` clears them, Journal entries, Scenario state, Variables
  and copies of Data buckets ([below](#sessions-and-ephemeral-stubs)).
- `GET /v1/mocks/{mock}/scenarios` lists the calling Session's Scenarios of
  a Mock, with their states, and `PUT /v1/mocks/{mock}/scenarios/{scenario}`
  sets the state of one ([below](#sessions-and-ephemeral-stubs)).
- `GET /v1/mocks/{mock}/variables` lists the calling Session's Variables of
  a Mock, and `PUT` and `DELETE /v1/mocks/{mock}/variables/{name}` set and
  delete one ([below](#sessions-and-ephemeral-stubs)).
- `GET /v1/mocks/{mock}/data` lists a Mock's Data buckets, and `GET`,
  `PUT` and `DELETE /v1/mocks/{mock}/data/{bucket}` read, set and drop the
  calling Session's copy of one ([below](#sessions-and-ephemeral-stubs)).
- `POST /v1/journal/query` lists the calling Session's requests from the
  [Journal](#the-journal), `POST /v1/journal/verify` checks how many of
  them there were, and `GET /v1/journal/unmatched` lists those that no
  Stub answered, with their Near misses
  ([below](#verifying-calls-and-unmatched-requests)).

## Sessions and Ephemeral Stubs

A test names its *Session* in the W3C `baggage` header of its requests, in
the `smock-session` member, and Admin API calls name theirs the same way,
as do gRPC calls, in their `baggage` metadata
([Sessions](grpc.md#sessions)).
Through the Admin API, a test adds *Ephemeral Stubs* to a Mock from the
Definition files, for its Session only:

```sh
curl -H "Authorization: Bearer change-me" -H "baggage: smock-session=checkout-42" \
  -d '{"request":{"method":"GET","path":"/users/1"},"response":{"status":503}}' \
  localhost:9090/v1/mocks/users/stubs
curl -H "baggage: smock-session=checkout-42" localhost:8080/users/1   # 503
curl localhost:8080/users/1                                           # 200, from the file
```

- The Session key is the value of the first `smock-session` member of the
  `baggage` headers, combined, trimmed and percent-decoded; properties after
  `;` are ignored. A missing or empty value, or a `baggage` header that is
  not W3C Baggage, means no Session. `--session-header` and
  `--session-member` name another header or member.
- An Ephemeral Stub has the shape of a Stub in a Definition file, without
  `id` and `mock`: the path names the Mock, and smock assigns the ID,
  `eph-<n>`, and returns it. Its body must be inline. It is validated like a
  Stub from a Definition file: problems get 400 `invalid_stub` with the
  messages `smock check` gives. A Mock that does not exist gets 404
  `unknown_mock`: Mocks come only from Definition files. An Ephemeral Stub
  whose exact path names a method of its Mock's Descriptor set is a gRPC
  Stub, which answers only gRPC calls
  ([Ephemeral gRPC Stubs](grpc.md#ephemeral-grpc-stubs)).
- Requests with the Session try its Ephemeral Stubs of the Mock before any
  Stub from the Definition files: by their own `priority`, the newest first
  among equal priorities. Other Sessions never see them. Requests without a
  Session form their own space, and Ephemeral Stubs added without a Session
  apply only to them. An Ephemeral Stub can be the Near miss, named by its
  ID in `Smock-Near-Miss`.
- The Session also keeps its own state of each
  [Scenario](definition-files.md#scenarios). An Ephemeral Stub may
  carry a `scenario` clause, as a Stub in a Definition file does, even on a
  Scenario that no file names, and shares the Session's state with the
  file Stubs that name the same Scenario. Deleting the Ephemeral Stub
  leaves the state as it is; a reset clears it.
- `GET /v1/mocks/{mock}/scenarios` lists the calling Session's Scenarios of
  the Mock, those its file Stubs and the Session's own Ephemeral Stubs
  name, by name. Each has its current `state` and its known `states`:
  `Started` first, then every state those Stubs name for it. When the
  Session deletes the Ephemeral Stubs that named a Scenario, but still
  holds a state for it, the Scenario stays listed, with `["Started"]` as
  its known states, so that a test can reset it.
  `PUT /v1/mocks/{mock}/scenarios/{scenario}` with `{"state":"Paid"}` sets
  the state for the calling Session, so that a test can start in the middle
  of a flow; `{"state":"Started"}` resets one Scenario. A Scenario that the
  list does not show gets 404 `unknown_scenario`, and a state outside the
  known states 400 `unknown_state`, so a typo cannot leave a Scenario in a
  state that nothing matches.
- The Session keeps its own [Variables](definition-files.md#variables)
  of each Mock too, which a Stub's `variables` write and templates read as
  `vars.NAME`. `GET /v1/mocks/{mock}/variables` lists the calling Session's
  Variables of the Mock, by name, with their values.
  `PUT /v1/mocks/{mock}/variables/{name}` with a JSON value as the body,
  such as `"ann"`, sets one, so that a test can arrange the state its
  requests read, and `DELETE` deletes one. A name that is not 1 to 128
  ASCII letters, digits, `_` and `-` gets 400 `invalid_request`, and so
  does a value above 1 MiB of compact JSON; a Variable the Session has not
  set gets 404 `unknown_variable`, and a set that would pass
  [the state bound](definition-files.md#the-state-bound) 507
  `state_limit_reached`.
- The Session keeps its own copy of each
  [Data bucket](definition-files.md#data-buckets) it writes to, and
  reads the bucket's initial value until then. The copy lives until a
  reset, a reload that drops it, a `DELETE` or a restart.
  `GET /v1/mocks/{mock}/data` lists the Mock's buckets, with whether the
  Session holds a copy of each; `GET /v1/mocks/{mock}/data/{bucket}` reads
  one with the value the Session reads; `PUT` with a JSON value as the body
  sets the Session's copy, so that a test can arrange its data; and
  `DELETE` drops the copy, so the bucket reads its initial value again. A
  bucket the Mock does not declare gets 404 `unknown_bucket`, a value that
  breaks a keyed bucket's rules 400 `invalid_data`, and a set that would
  pass the state bound 507 `state_limit_reached`
  ([Session copies](definition-files.md#session-copies)).
- `GET` lists and `DELETE /v1/mocks/{mock}/stubs/{id}` deletes the calling
  Session's Ephemeral Stubs of the Mock. `POST /v1/reset` with
  `{"scope":"session"}` clears the calling Session's Ephemeral Stubs,
  [Journal](#the-journal) entries, Scenario state,
  [Variables](definition-files.md#variables) and copies of Data
  buckets of every Mock, and its eviction count;
  `{"scope":"mock","mock":"users"}` every Session's of one Mock, even one
  that a reload removed while the Journal holds its entries; and
  `{"scope":"all"}` all of them, and every eviction count. Without a
  Session, `{"scope":"session"}` clears the no-Session space. A Scenario
  whose state is cleared is back in `Started`, a cleared Variable is
  unset, and a bucket whose copy is dropped reads its initial value again.
  It answers how many of each it removed, in `removed`: `ephemeralStubs`,
  `journalEntries`, `scenarioStates`, `variables` and `dataBuckets`.
- Ephemeral Stubs live in the process that received them, until a reset or
  a restart. They survive a [reload](definition-files.md#reloading) of
  the Definition files, except those of a Mock the new files no longer
  declare.
- Adding and deleting an Ephemeral Stub, setting a Scenario's state,
  setting and deleting a Variable, setting a Data bucket, dropping a copy
  and resetting each write a log entry (`Ephemeral Stub added`,
  `Ephemeral Stub deleted`, `Scenario state set`, `Variable set`,
  `Variable deleted`, `Data bucket set`, `Data bucket copy dropped`,
  `reset`); requests write none.

## The Journal

smock records the requests it receives in the *Journal*, so that a test can
check what its system sent. A test queries its own Session's entries:

```sh
curl -H "Authorization: Bearer change-me" -H "baggage: smock-session=checkout-42" \
  -d '{"filter":{"mock":"users","method":"GET","path":"/users/1"},"limit":10}' \
  localhost:9090/v1/journal/query
```

- Each entry records the Session, the Host, the Mock and whether the
  Default Mock answered; the method, target, HTTP version, header fields
  and body; the Stub that answered, or the Near miss with what each failed
  condition expects and what the request sent, each with `stubSource`:
  `file` for a Stub from a Definition file, `ephemeral` for an Ephemeral
  Stub, so that equal IDs cannot be confused; the
  [Scenario](definition-files.md#seeing-what-moved) move the Stub
  made, as `scenario`, with its name and the states it moved from and to;
  the index of the response the Stub gave among its
  [`responses`](definition-files.md#several-responses), as
  `responseIndex`; the names of the
  [Variables](definition-files.md#variables) the request wrote, as
  `variablesWritten`; the names of the [Data
  buckets](definition-files.md#writing-buckets-datawrites) it wrote,
  as `dataWritten`, and why a data write failed, as `dataError`; the
  operation a [CRUD Stub](definition-files.md#crud-stubs) served and
  its key, as `crud`; the status, or the connection Fault; when the
  request was received and how long the response took; and the digest of
  the definition set that answered. A request for a Host that no Mock
  answers is recorded too, with no Mock; one the protocol layer rejects
  (HTTP/1.1: 400, 413, 431, 501 or 505; HTTP/2: 400, 413 or 431 on its
  stream; gRPC: 405, 400, or 200 with the gRPC status UNIMPLEMENTED,
  INTERNAL or RESOURCE_EXHAUSTED) is not.
- A gRPC call is recorded as a `POST` to its method's path, such as
  `/helloworld.Greeter/SayHello`, with its metadata as header fields and
  its message, decoded into JSON, as the body, whose `size` counts the
  octets received. Its entry adds `grpcStatus`, the name of the gRPC
  status the call got, such as `OK`, `NOT_FOUND` or `UNIMPLEMENTED`, while
  its `status` is 200, the HTTP status that gRPC sends with every gRPC
  status. An HTTP request's entry has no `grpcStatus`. A filter finds calls as it finds
  requests, by `POST`, the method's path and the metadata as headers,
  `-bin` values without their base64 padding. The answers of a Mock's
  built-in health and reflection services are not recorded
  ([The Journal and the metrics](grpc.md#the-journal-and-the-metrics)).
- A request is in the Journal as soon as its client has the whole
  response: smock records it just before it writes the response's last
  bytes, so a query made right after a call always finds it. A stream of
  Server-Sent Events is recorded when its last event is written, and a
  request ended by a connection Fault when the connection closes.
- The filter takes a Mock, a method, a path and headers, with the
  semantics of Stub conditions (exact, `{ "pattern": … }`, and `$not` and
  `$exists` for headers), and a time range on when the request was
  received: `since` (included) and `until` (excluded), as RFC 3339
  date-times. Every member is optional. Entries
  come oldest first, at most `limit` of them (100 by default, at most
  10000); `more` says whether more passed the filter.
- Each entry has a sequence number, `seq`: 1 for the first entry the
  process records, then one more for each entry after it, whatever its
  Session. To fetch the next page, a query gives `"after"` the `seq` of the
  last entry it got, with the same filter; no entry is lost or repeated,
  even among requests received in the same millisecond.
- The Journal is one ring buffer per process, bounded by entry count and by
  bytes (`--journal-max-entries`, `--journal-max-bytes`), and keeps at most
  4 KiB of each body (`--journal-body-limit`), cut at a character boundary
  when the body is UTF-8. The Near miss of an entry keeps the values of
  form fields and XML paths up to the same limit in total, each counting
  32 bytes more, so that many small values cannot outgrow the bound. When
  the Journal is full, the oldest entries are evicted, and smock counts
  the evicted entries of each Session: `evicted` in the query's result
  says how many of the calling Session's entries may be missing. Requests
  without a Session have their own count. A Session's count is kept until
  that Session, or everything, is reset (a reset of one Mock keeps it), so
  the counts grow with the number of Sessions whose entries were evicted.
- `--journal off` records nothing, and a Mock with `"journal": false`
  ([docs/definition-files.md](definition-files.md#turning-the-journal-off-for-a-mock))
  records none of its requests, so that a high-rate load test pays nothing
  for recording. A query while the Journal is off, or whose filter names
  such a Mock, gets 409 `journal_off` rather than entries that cannot be
  trusted. Only those are refused: a filter that names no Mock is answered
  from the requests that were recorded, which leave out those of Mocks
  whose Journal is off.
- The Journal survives a [reload](definition-files.md#reloading) of
  the Definition files; each entry keeps the digest of the set that
  answered it. It lives in the process that received the requests, until a
  reset or a restart.
- The byte bound follows smock's memory limit, so that the Journal fits a
  small Pod ([ADR 0004](adr/0004-journal-byte-bound-follows-the-memory-limit.md)).
  `--journal-max-bytes` or `SMOCK_JOURNAL_MAX_BYTES` always wins. Without
  either, smock reads the memory limit of its own cgroup at startup:
  `memory.max` of the cgroup v2 that `/proc/self/cgroup` names, under
  `/sys/fs/cgroup`, which in a container on a Kubernetes node with cgroup
  v2 is the container's memory limit. The bound is a quarter of that
  limit, rounded down, at least 1 MiB, so that a tiny limit still records
  something, and at most 64 MiB. Without a limit (`max`), or when it
  cannot be read, as on a cgroup v1 host, the bound is 64 MiB. Under a
  52Mi limit it is 13 MiB, which holds about 8,400 entries of the
  [benchmark](../bench/README.md)'s request mix (each counts about 1.6
  KB); from a 256Mi limit up, it is 64 MiB.
- smock logs the bound it uses at startup, with its `source`: `flag`,
  `variable`, `memoryLimit` (a quarter of the limit), `minimum` (1 MiB) or
  `default` (64 MiB), and the `memoryLimit` it read, in bytes or `max`, or
  `memoryLimitError`, why it could not read one:

  ```json
  {"time":"2026-10-14T09:00:00.000Z","level":"info","msg":"journal byte bound","maxBytes":13631488,"source":"memoryLimit","memoryLimit":54525952}
  ```

### Verifying calls and unmatched requests

A test checks that its system sent a request exactly, at least or at most
N times. It gives the same filter as a query, and exactly one of
`exactly`, `atLeast` and `atMost`:

```sh
curl -H "Authorization: Bearer change-me" -H "baggage: smock-session=checkout-42" \
  -d '{"filter":{"method":"POST","path":"/orders"},"exactly":1}' \
  localhost:9090/v1/journal/verify
# {"ok":true,"count":1,"evicted":0,"reason":null,"warnings":[]}
```

- `count` is how many of the calling Session's entries pass the filter;
  other Sessions' requests are never counted. A check that fails is still
  a 200 response, with `ok` false and `reason` `count`.
- Verification never trusts a count that may be wrong. When the Journal
  bound has evicted any of the Session's entries since its last reset
  (`evicted` above 0), `exactly` and `atMost` fail with `reason` `evicted`,
  whatever the count. `atLeast` is still decided by the count, because
  eviction can only lower it. A Session reset clears the eviction count.
- Like a query, verification while the Journal is off, or whose filter
  names a Mock whose Journal is off, gets 409 `journal_off`. A filter that
  names no Mock counts only the requests that were recorded, so none of
  such a Mock's.

`GET /v1/journal/unmatched` lists the calling Session's requests that no
Stub answered, oldest first, at most `limit` of them (a query parameter,
100 by default, at most 10000), in the same form as a query's entries; the
`after` query parameter pages through them as a query's `after` does. Each
carries its full Near miss: the closest Stub, and every condition it
failed with what the Stub expects and what the request sent. A request for
a Host that no Mock answers is among them, with no Mock and no Near miss.
It gets 409 `journal_off` while the Journal is off globally; the unmatched
requests of a Mock whose Journal is off were not recorded, so they are not
listed.
