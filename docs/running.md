# Running smock

`smock serve` runs smock. This document describes its startup, ports and
protocols, its settings, its logs, its limits and timeouts, the drain on
SIGTERM, HTTPS and the `Date` header. It is for anyone who runs smock, on
a developer's machine or on Kubernetes. The commands in this document use
the `defs` directory and the `users` Mock of the README's quick start, and
need its `SMOCK_ADMIN_TOKEN` set: without a token, `smock serve` exits
with status 1 ([Authentication](admin-api.md#authentication)).

Related documents:

- The README's [Run](../README.md#run) is the quick start, for a first
  run.
- [Installing smock](installing.md) describes the container image, the
  Helm chart and the release binaries.
- [Admin API](admin-api.md) describes the operations that smock serves on
  the admin port.
- [Commands](commands.md) describes smock's other commands:
  `smock check`, `smock render` and `smock import-openapi`.
- The [Definition-file reference](definition-files.md) describes the
  Definition files in the directory that `--dir` names.
- [HTTP/2](http2.md) says more about the limits, the timeouts, the logs
  and the drain over HTTP/2, and the [gRPC guide](grpc.md) about gRPC
  calls.
- The Helm chart's [README](../charts/smock/README.md) says how its
  values set the same settings.

## Contents

- [Startup, ports and protocols](#startup-ports-and-protocols)
- [Settings](#settings)
- [Logs](#logs)
- [Limits and timeouts](#limits-and-timeouts)
  - [Over HTTP/2](#over-http2)
  - [The write timeout](#the-write-timeout)
- [The drain](#the-drain)
- [HTTPS](#https)
  - [Rotating certificates](#rotating-certificates)
  - [Certificates for single Mocks](#certificates-for-single-mocks)
  - [Certificate expiry](#certificate-expiry)
  - [The self-signed certificate](#the-self-signed-certificate)
- [The `Date` header](#the-date-header)

## Startup, ports and protocols

`smock serve` listens on the admin port, reads the Definition files in the
definitions directory, then listens on the plain port and on the TLS port.
Each port's `listening` log entry names the protocols it serves:
`["http/1.1", "h2c"]` on the plain port, `["h2", "http/1.1"]` on the TLS
port (`["http/1.1"]` with `--tls-http2 off`) and `["http/1.1"]` on the
admin port. The plain and TLS ports serve gRPC unary calls beside HTTP,
over h2c and h2: an HTTP/2 request whose `content-type` is
`application/grpc`, alone or followed by `+` or `;`, is a gRPC call
([Ports and detection](grpc.md#ports-and-detection)). gRPC has no
port of its own, and the admin port never serves it.
It polls the directory every second and swaps in the new definition set
when the files change, ConfigMap updates included; an invalid set is
reported and the current one keeps serving
([docs/definition-files.md](definition-files.md#reloading)).

## Settings

`smock serve --help` lists the settings:

| Flag | Variable | Default |
|---|---|---|
| `--dir` | `SMOCK_DIR` | none: one empty Default Mock |
| `--port` | `SMOCK_PORT` | 8080 (0 picks a free port) |
| `--tls-port` | `SMOCK_TLS_PORT` | 8443 (0 picks a free port) |
| `--tls-cert-file` | `SMOCK_TLS_CERT_FILE` | none: a generated self-signed certificate |
| `--tls-key-file` | `SMOCK_TLS_KEY_FILE` | none: a generated self-signed certificate |
| `--tls-mock-certs` | `SMOCK_TLS_MOCK_CERTS` | none: no Mock has a certificate of its own ([Certificates for single Mocks](#certificates-for-single-mocks)) |
| `--tls-http2` | `SMOCK_TLS_HTTP2` | `on`: ALPN on the TLS port offers `h2`, then `http/1.1`; `off` offers `http/1.1` alone, which turns gRPC over TLS off too ([h2 on the TLS port](http2.md#h2-on-the-tls-port)) |
| `--admin-port` | `SMOCK_ADMIN_PORT` | 9090 (0 picks a free port) |
| `--admin-auth` | `SMOCK_ADMIN_AUTH` | `on`: the Admin API needs a bearer token; `off` for local use |
| `--admin-token-file` | `SMOCK_ADMIN_TOKEN_FILE` | none: the token comes from `SMOCK_ADMIN_TOKEN` |
| `--replicas` | `SMOCK_REPLICAS` | 1: above 1, every Admin API response warns that state is per replica |
| `--session-header` | `SMOCK_SESSION_HEADER` | `baggage`: the W3C Baggage header that carries the [Session](admin-api.md#sessions-and-ephemeral-stubs) |
| `--session-member` | `SMOCK_SESSION_MEMBER` | `smock-session`: the member of that header whose value is the Session key |
| `--log-format` | `SMOCK_LOG_FORMAT` | `json` by default (stderr, smock's own shape), or `mockoon` (stdout, the Mockoon CLI's shape, [for Mockoon users](migrating-from-mockoon.md#logs)) |
| `--body-file-dir` | `SMOCK_BODY_FILE_DIR` | `files` |
| `--template-env` | `SMOCK_TEMPLATE_ENV` | none: templates read no environment variable; a comma-separated list of names lets them read those as `env.NAME`, with values read once at startup ([Environment variables](definition-files.md#environment-variables)) |
| `--header-size-limit` | `SMOCK_HEADER_SIZE_LIMIT` | 16384 bytes (16 KiB): larger request heads get 431; over HTTP/2, a larger header list, counted as RFC 7541 counts it, gets 431 on its stream, and a header block over twice the limit closes the connection ([Header lists](http2.md#header-lists)); it also bounds each block of a gRPC reply's metadata, counted the same way: a static reply over it does not load, and a rendered one gets INTERNAL ([Metadata size](grpc.md#metadata-size)) |
| `--header-count-limit` | `SMOCK_HEADER_COUNT_LIMIT` | 100 header fields: more get 431 |
| `--body-limit` | `SMOCK_BODY_LIMIT` | 10485760 bytes (10 MiB): longer bodies get 413; over HTTP/2, per stream, on that stream alone ([Request bodies](http2.md#request-bodies)); a gRPC call gets RESOURCE_EXHAUSTED instead, and its message's decoded JSON is held to the limit too ([The body limit](grpc.md#the-body-limit)), and to 32,768 values and 4 more for each octet of the message ([The values a message may print](grpc.md#the-values-a-message-may-print)) |
| `--http2-max-concurrent-streams` | `SMOCK_HTTP2_MAX_CONCURRENT_STREAMS` | 100, from 1 to 1000: the most streams an HTTP/2 connection may have in progress at once; a stream past it gets RST_STREAM `REFUSED_STREAM` ([Limits and timeouts](http2.md#limits-and-timeouts)) |
| `--read-timeout-ms` | `SMOCK_READ_TIMEOUT_MS` | 30000: a request must arrive whole within 30 s of its first byte, or, when it was pipelined behind a response, of that response; over HTTP/2, a stream whose request is late gets RST_STREAM `CANCEL` alone ([Limits and timeouts](http2.md#limits-and-timeouts)) |
| `--idle-timeout-ms` | `SMOCK_IDLE_TIMEOUT_MS` | 60000: a connection that waits 60 s for a request closes |
| `--write-timeout-ms` | `SMOCK_WRITE_TIMEOUT_MS` | 30000: a connection closes when a write to it makes no progress for 30 s, as when the client stops reading; over HTTP/2, also when a response waits that long for the client to widen the connection window, and a stream whose own window stays at zero that long gets RST_STREAM `CANCEL` alone ([Timeouts](http2.md#timeouts)) |
| `--drain-timeout-ms` | `SMOCK_DRAIN_TIMEOUT_MS` | 20000: how long smock drains after SIGTERM before it cuts what is still running |
| `--seed` | `SMOCK_SEED` | none: smock picks the seed of its random generator, from 0 to 9007199254740991, and logs it ([Faults](definition-files.md#seeds)) |
| `--journal` | `SMOCK_JOURNAL` | `on`: requests are recorded in the [Journal](admin-api.md#the-journal); `off` records none |
| `--journal-max-entries` | `SMOCK_JOURNAL_MAX_ENTRIES` | 10000: beyond it, the oldest entries are evicted |
| `--journal-max-bytes` | `SMOCK_JOURNAL_MAX_BYTES` | a quarter of smock's memory limit (cgroup v2 `memory.max`), at least 1048576 bytes (1 MiB) and at most 67108864 (64 MiB); 64 MiB without a limit ([The Journal](admin-api.md#the-journal)): beyond it, the oldest entries are evicted |
| `--journal-body-limit` | `SMOCK_JOURNAL_BODY_LIMIT` | 4096 bytes (4 KiB): the most of a request body an entry keeps, and of the form and XML values its Near miss keeps, in total |
| `--state-max-bytes` | `SMOCK_STATE_MAX_BYTES` | an eighth of smock's memory limit (cgroup v2 `memory.max`), at least 1048576 bytes (1 MiB) and at most 67108864 (64 MiB); 64 MiB without a limit ([The state bound](definition-files.md#the-state-bound)): the most bytes the per-Session state of the whole process takes; a request or an Admin API set whose writes would pass it gets 507, and a gRPC call RESOURCE_EXHAUSTED ([smock's own failures](grpc.md#smocks-own-failures)) |

## Logs

smock logs one JSON object per line, in one of two formats. In the `json`
format, the default, log entries go to stderr in smock's own shape: `time`,
`level` and `msg`, then the entry's fields. It logs nothing per request.
In the `mockoon` format (`--log-format mockoon`), every line goes to
stdout instead, in the Mockoon CLI's envelope: `app` (always `"smock"`),
`level`, `message` and `timestamp`, with the entry's fields beside them
and the keys sorted at every depth. smock then also writes the Mockoon
CLI's lines: `Server started on port <port>`, with the plain port, for
each Mock once every listener is open; a `Transaction recorded` line for
each request a Mock handles, over HTTP/1.1 and HTTP/2 alike, after an
`Error while serving the content: …` line when the Stub's template or
data write failed; and `Server stopped` for each Mock when the drain
ends. It writes nothing to stderr but usage errors. Each line is written
whole, by one write, also to a pipe, and no buffer holds it back.
Container runtimes read stdout all the time. A request's lines are
written before its connection takes its next request, so a reader of
stdout that stops reading holds up each connection with a line to
write, while every other connection goes on. Over HTTP/2, the lines of
the streams answered at once are written before the connection reads
again, and a stream whose response waited, for a delay, its events or
the client's windows, writes its own as it ends
([Logs](http2.md#logs)).
smock's own lines then wait in a queue of up to 1,024 lines: one beyond
it is dropped and counted in `smock_log_lines_dropped_total`.
The `mockoon` format costs CPU. In the benchmark on an M1 laptop, smock
spent about 8 to 11 µs more CPU on each HTTP/1.1 request than in `json`,
40% to 90% more, and about 7 to 10 µs more on each HTTP/2 request, 20%
to 50% more. Up to the target rates, every step stayed within the
performance targets but one: under 1 CPU, HTTP/2 over TLS at 30,000
requests/s used 88% of the CPU rather than 64%, and in one of two runs
its p99 rose to 14 ms and its p99.9 to 25 ms, past the targets. At
20,000 it kept the latency of `json`. Under a CPU limit it runs out
sooner: the most HTTP/1.1 kept up with fell from 4,000 to 2,000
requests/s under 50m, and from 20,000 to 12,500 under 250m, the next
steps down in the benchmark.
[docs/migrating-from-mockoon.md](migrating-from-mockoon.md#logs)
lists the lines and how they differ from the Mockoon CLI's.

The four lines of the Mockoon CLI (`Server started on port …`,
`Transaction recorded`, `Error while serving the content: …` and
`Server stopped`) and the envelope of every line in the `mockoon` format
(stdout, one object per line, `app`, `level`, `message` and `timestamp`,
keys sorted) are a stable contract, since they copy an outside format.
Any change to their messages, keys, key order or value forms, a new key
included, is a breaking change: the CHANGELOG lists it under Changed, and
the release notes call it out. A fix that makes a line match the Mockoon
CLI's more closely is such a change too, made the same way. smock's own
log entries, in either format, are a diagnostic aid: their messages and
fields may change in any release, unlike the Definition file format and
the Admin API, which are versioned (`v1`). A usage error, such as an
unknown flag, a missing argument or an invalid setting value, is not a
log entry: in either format, smock writes it to stderr as plain text,
before any log entry, and exits with status 2.

## Limits and timeouts

The limits and timeouts are settings: [Settings](#settings) gives the
default of each, and the status that a request over a limit gets.

A request over a limit gets its status with `Connection: close`, then the
connection closes; a timeout, read, idle or write, closes the connection
without a response. A request rejected this way gets no log line in either
format, and neither does a read or an idle timeout. A write timeout is not
logged either, but in the `mockoon` format the request whose response it
cut short still gets its `Transaction recorded` line.

Known limitation: after answering a request with 400, 413, 431, 501 or 505,
smock closes the connection without reading the rest of the request. A
client that is still sending it, such as a body over `--body-limit`, may
then get a connection reset instead of the error response. smock would
need to close only its sending side first (a half-close), which the async
library it is built on does not offer yet. Over HTTP/2, such a response
ends only its stream, so the connection stays open and the client gets it.

### Over HTTP/2

Over HTTP/2, smock also bounds what a client can make one connection cost,
such as a flood of PING, SETTINGS or CONTINUATION frames, or of streams
reset as soon as they open (Rapid Reset). A connection that
passes such a bound gets GOAWAY `ENHANCE_YOUR_CALM` and closes, and smock
logs one line for it, at level `warn`, that names the pattern, such as
`{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING"}`.
No metric counts it. See [Defences](http2.md#defences).

Over HTTP/2, a body over `--body-limit` gets 413 on its stream alone, and
the connection's other streams go on. When the client is still sending the
body, RST_STREAM `NO_ERROR` follows the 413, to stop the upload. See
[Request bodies](http2.md#request-bodies). Since the limit applies to
each stream, one HTTP/2 connection can hold request bodies of up to
`--http2-max-concurrent-streams` × `--body-limit` in memory at once: about
1 GiB with the defaults (100 × 10 MiB). For a small Pod, lower either flag
([Limits and timeouts](http2.md#limits-and-timeouts)). A gRPC call
over the limit gets RESOURCE_EXHAUSTED with `:status` 200 instead of 413,
as gRPC servers answer it, and the JSON that smock decodes its message
into is held to the limit as well
([The body limit](grpc.md#the-body-limit)). That JSON may also hold
at most 32,768 values, and 4 more for each octet of the message, which
bounds the memory that a small message costs once its JSON is parsed. No
flag changes that bound
([The values a message may print](grpc.md#the-values-a-message-may-print)).

Over HTTP/2, a request over a header limit gets 431 on its stream alone,
and the connection stays open. The read timeout applies to each stream
alone, from the first frame of its request: a stream whose request is
late gets RST_STREAM `CANCEL`, and the connection's other streams go on.
The idle timeout applies to a connection with no stream in progress, and
sends GOAWAY before the connection closes. See
[Limits and timeouts](http2.md#limits-and-timeouts). A stream that
gets 400, 413 or 431, or is reset because its request is late, never
reaches a Mock, so it gets no `Transaction recorded` line in the
`mockoon` format. Nor does a stream refused past
`--http2-max-concurrent-streams`, or one the client resets before its
request has arrived.

### The write timeout

The write timeout runs while a write waits on the client to take its
bytes, on every port and for every write: a response, whole or in part,
each event of an event stream, a `100 Continue`, a rejection and an Admin API
reply. It starts again each time the write goes on, so a client that reads
slowly but steadily gets the whole response, however long it takes in all.
A write goes on once the client has read enough to free room in the
socket's send buffer: about a third of it, on Linux. On the TLS port, it
goes on a whole TLS record, up to 16 KiB, at a time. smock's own waits,
such as a delay or the time between the events of an event stream, do not
count.
smock sends no `close_notify` on a TLS connection the write timeout closes.

Over HTTP/2, the write timeout also runs while a response body waits for
the client to widen its flow-control windows. When the connection window
stays at zero that long, the connection closes, without GOAWAY. When only
a stream's own window does, that stream gets RST_STREAM `CANCEL`, and the
connection's other streams go on. Each WINDOW_UPDATE for the window waited
for, and each SETTINGS frame that raises the initial window of the
streams, starts it again, so a client that widens its windows slowly but
steadily gets the whole response. A client that stops reading makes smock
stop reading too, once what smock has queued for the connection and not
yet written passes 16 KiB, so the client cannot make it hold its
responses. See [Timeouts](http2.md#timeouts) and
[The output bound](http2.md#the-output-bound).

## The drain

On SIGTERM, smock drains instead of dropping requests, so that a rolling
update does not fail the tests running against the old Pod. SIGINT and
SIGHUP do not drain: they end smock at once, cutting whatever is in
flight, so that Ctrl-C stops a local smock promptly.

- [`/readyz`](admin-api.md#probes) fails from the moment the signal
  arrives, and the gRPC health service of each Mock that turns it on
  says NOT_SERVING ([The drain](grpc.md#the-drain)). The plain and TLS
  listeners close, so new connections are refused, and idle HTTP/1.1
  keep-alive connections close at once.
- Responses in progress finish with `Connection: close`, and their
  connections close after them. Server-Sent Event streams and pending
  delays go on. Over HTTP/1.1, an event stream whose client has gone away
  counts too, until smock next writes an event to it and notices, which an
  event's long delay can put off until the drain timeout.
- Each HTTP/2 connection, idle or not, gets GOAWAY, then a PING. Once the
  client answers the PING, or a second later at most, a second GOAWAY names
  the last stream smock received. The HTTP/2 streams up to it finish, as
  above, and the client sends the others again on a new connection. Once
  no HTTP/2 stream is in progress, the connection closes
  ([The drain](http2.md#the-drain)).
- smock exits with status 0 as soon as nothing is in flight, and at the
  latest when the drain timeout (`--drain-timeout-ms`) expires: what is still
  running then is cut. Keep the Pod's `terminationGracePeriodSeconds` above
  it. On Kubernetes, also delay SIGTERM with a preStop sleep, so that
  Services stop sending new connections before the listeners close; the
  Helm chart does both.
- The admin port serves until exit, so the probes can be read during the
  drain. Log entries mark the start of the drain (`drain started`, with
  `timeoutMs`) and its end (`drain ended`, with `connectionsCut`, the number
  of connections still open when the timeout expired). The `mockoon` format
  also writes `Server stopped` for each Mock served, right after
  `drain ended`.

## HTTPS

With a certificate and its key, smock also serves HTTPS on the TLS port, with
the same Mocks as the plain port. Both are PEM files, for example the
`tls.crt` and `tls.key` of a Kubernetes Secret:

```sh
smock serve --dir defs --tls-cert-file /etc/smock/tls/tls.crt --tls-key-file /etc/smock/tls/tls.key
```

- The certificate file holds the leaf certificate, then its intermediate
  certificates, as cert-manager writes it; smock sends the whole chain. The
  key may be RSA or ECDSA, in PKCS#8, PKCS#1 or SEC1 PEM, and must not be
  encrypted.
- Setting only one of the two files, a file that cannot be read or holds no
  usable PEM, or a key that does not belong to the certificate stops
  `smock serve` with a log entry that says why, and exit status 1 (2 for a
  missing partner setting).
- ALPN offers `h2`, then `http/1.1`, for every certificate. A client that
  offers `h2` gets HTTP/2, and one that offers only `http/1.1`, or no ALPN,
  gets HTTP/1.1 ([h2 on the TLS port](http2.md#h2-on-the-tls-port)).
  `--tls-http2 off` offers `http/1.1` alone.
  TLS 1.2 and 1.3 are accepted. Over TLS 1.2, `h2` is left out when the
  suite is one HTTP/2 prohibits, such as a CBC suite
  ([TLS 1.2](http2.md#tls-12)).
- The Host header, or `:authority` over HTTP/2, chooses the Mock, as on the
  plain port; SNI does not.
- The `listening` log entry of the TLS port names the certificate and key
  files.

### Rotating certificates

smock polls the certificate and key files every second, as it polls the
definitions directory ([Reloading](definition-files.md#reloading)). It
reads them once they have stayed the same for 250 ms, so a certificate and
its key written less than 250 ms apart are loaded together, within about
1.25 s, and a Secret update (which swaps the `..data` symlink) counts as a
change. Written further apart, as by two `cp` commands typed one after the
other, they can be read apart: smock logs one "TLS certificate reload
failed" entry and keeps presenting the previous pair until the other file
arrives. To rotate a pair in one step, write both files into a new
directory and swap a symlink to it, as a Secret update does. When a pair
changes, smock loads it without a restart: new handshakes get the new
certificate, and open connections carry on with the one they started with.
A changed pair that cannot be used (a file that cannot be read or holds no
usable PEM, or a key that does not belong to the certificate) is not
swapped in, and smock keeps presenting the previous one. Either way one log
entry names the pair (`"mock":""` for the default certificate) and the new
certificate's expiry:

```json
{"time":"…","level":"info","msg":"TLS certificate reloaded","mock":"","certFile":"/etc/smock/tls/tls.crt","keyFile":"/etc/smock/tls/tls.key","expiry":"2027-01-01T00:00:00.000Z"}
{"time":"…","level":"error","msg":"TLS certificate reload failed","mock":"","certFile":"/etc/smock/tls/tls.crt","keyFile":"/etc/smock/tls/tls.key","expiry":null,"error":"certificate file: no PEM certificate found"}
```

### Certificates for single Mocks

By default every handshake gets one certificate, the default certificate
of `--tls-cert-file` and `--tls-key-file`, usually with a SAN for
each Host. `--tls-mock-certs` (`SMOCK_TLS_MOCK_CERTS`) gives single Mocks
their own certificates, as a JSON object that maps each Mock name to its
certificate and key files:

```sh
smock serve --dir defs --tls-cert-file /etc/smock/tls/tls.crt --tls-key-file /etc/smock/tls/tls.key \
  --tls-mock-certs '{"users":{"certFile":"/etc/smock/users/tls.crt","keyFile":"/etc/smock/users/tls.key"}}'
```

- A handshake whose SNI is one of the Hosts of a listed Mock, compared as
  Hosts are (case-insensitively, without a trailing dot), gets that Mock's
  certificate. A handshake without SNI, or whose SNI is no Host of a listed
  Mock, gets the default certificate: `--tls-cert-file`, or without it the
  generated self-signed certificate ([below](#the-self-signed-certificate)).
- SNI follows the Hosts of the definition set served, reloads included. It
  only chooses the certificate: the Host header, or `:authority` over
  HTTP/2, still chooses the Mock.
  Definition files never refer to certificates.
- A listed Mock that the Definition files do not declare is not an error,
  since Mocks come and go on reload: its certificate is chosen for nothing
  until a reload declares the Mock, and smock logs a warning
  (`TLS certificate for a Mock that is not declared`) each time it goes
  missing, at startup included.
- Each pair is loaded at startup, and one that cannot be loaded stops
  `smock serve` with exit status 1, as for the default pair. A value that is
  not such a JSON object, or an entry without both files, exits with
  status 2.
- Each pair rotates as the default certificate does.

### Certificate expiry

The metric `smock_tls_certificate_expiry_timestamp_seconds`
([Metrics](admin-api.md#metrics)) gives when each certificate the TLS port
presents expires (its notAfter), in seconds since the Unix epoch: `mock=""`
for the default certificate, the generated self-signed one included, and
`mock="<name>"` for a Mock's own. It follows rotations and new self-signed
certificates, so an alert on it notices a renewal that stopped working
before clients fail.

### The self-signed certificate

Without default certificate files, smock still serves HTTPS on the TLS
port, with a self-signed certificate it generates at startup, for local
use. It is the default certificate, so with `--tls-mock-certs` the listed
Mocks' Hosts get their own certificates by SNI and every other handshake
gets this one:

- The certificate covers `localhost`, `127.0.0.1`, `::1` and every Host of
  every Mock. Hosts that are IP addresses are IP address names, the others
  DNS names, so a client that trusts the certificate can call any Mock by
  its Host.
- Its key is a new ECDSA P-256 key. Both are generated with OpenSSL and
  held only in memory; nothing is written to disk, so a read-only root
  filesystem is fine. The certificate is valid for 365 days.
- When a reload changes the set of Hosts, smock generates a new certificate
  for new connections; open connections keep theirs. A reload that keeps
  the Hosts, and a failed reload, keep the certificate.
- A log entry at startup and at each new certificate gives its SHA-256
  fingerprint and its names:
  `{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"AB:12:…","names":["localhost","127.0.0.1","::1","users.example.com"]}`.
  To trust it, read it from the handshake, for example with
  `openssl s_client -connect 127.0.0.1:8443 </dev/null | openssl x509 >smock.pem`
  and `curl --cacert smock.pem https://localhost:8443/`, and check its
  fingerprint against the log with `openssl x509 -in smock.pem -noout -fingerprint -sha256`.
- With default certificate files configured, nothing is generated.

## The `Date` header

Every final response smock sends, on every port, carries a `Date` header
with the current time, such as `Date: Thu, 22 Oct 2026 14:37:10 GMT`. A
Stub that gives its own `Date` gets that one instead. The interim
`100 Continue` carries none.
