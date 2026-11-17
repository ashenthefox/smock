# Contributing to smock

Bug reports and proposals are welcome as
[issues](https://github.com/hirunefu/smock/issues). Before a pull request
that changes code, open an issue and talk the approach over there, so that
the work fits where smock is going. Report a vulnerability privately, as
[SECURITY.md](SECURITY.md) says.

This document is for people who work on smock itself. It describes the
repository's layout, the pinned MoonBit toolchain, how to build and test
smock, how to measure the tests' costs on CI's runners, and the release
benchmark, and says where making a release is described. The
[Contributing to smock](docs/README.md#contributing-to-smock) list in
docs/README.md names the other documents for contributors: the
architecture decisions (ADRs), the glossary and the maintainer's
checklists.

## Contents

- [Layout](#layout)
- [Toolchain](#toolchain)
- [Build and test](#build-and-test)
- [Test costs on CI's runners](#test-costs-on-cis-runners)
- [Benchmark](#benchmark)
- [Making a release](#making-a-release)

## Layout

The repository is a MoonBit workspace (`moon.work`) of seven modules:

| Directory | Module | What it is |
|---|---|---|
| `.` | `smock/smock` | smock itself. Its parts are packages of this module. |
| `grpc/` | `smock/grpc` | gRPC's wire rules: the content type, the 5-octet prefix that frames each message, the seventeen status codes with their names, the percent-encoding of a status message, the rules of reply metadata, and a call's `-bin` values without their padding. |
| `http1/` | `smock/http1` | The HTTP/1.1 codec. |
| `protobuf/` | `smock/protobuf` | Protobuf's wire format, a reader of Descriptor sets (FileDescriptorSets) that checks them and indexes their messages, fields, enums and methods for lookups, messages decoded into JSON and encoded from it, the well-known types in their ProtoJSON forms included, gRPC's `google.rpc.Status` encoded with error details, and JSON values checked against a field's type as smock prints it (documented in `protobuf/README.mbt.md`). |
| `re2/` | `smock/re2` | RE2-syntax regular expressions. |
| `xml/` | `smock/xml` | An XML parser that refuses DTDs, with simple paths that select values (documented in `xml/README.mbt.md`). |
| `yaml/` | `smock/yaml` | Safe-subset YAML: `parse` turns a document into the tree `@json.parse` gives for the equivalent JSON, and `write` turns a tree into a document, with comments, that `parse` reads back as the same tree. `parse` also has a YAML 1.2 mode for OpenAPI documents, which Definition files never use (documented in `yaml/yaml.mbt`). |

The six protocol modules do no I/O and do not depend on smock, so they can
be published on mooncakes on their own. `scripts/check-no-io.sh` checks
that.

`fixtures/protobuf/` holds the Descriptor sets and protobuf messages that
tests read, and the descriptor of gRPC's `health.proto` that smock embeds,
beside the `.proto` files they are built from.
`scripts/gen-protobuf-fixtures.sh` rebuilds them with the pinned protoc,
which `scripts/install-protoc.sh` installs, and CI checks on every push
that the committed ones are what their sources build; the README there
says how to add one.

Packages of `smock/smock`:

- `cmd/smock`: the `smock` binary. It ends with a status through
  `moonbitlang/x`'s `@sys.exit`, since neither core nor
  `moonbitlang/async` exposes one; smock itself binds no C for it.
- `settings`: the settings of `smock serve`, each a flag with a matching
  `SMOCK_<NAME>` environment variable, and the arguments of `smock check`,
  `smock render` and `smock import-openapi`; also the rule that derives the
  Journal's byte bound from a memory limit, which `server` reads from the
  cgroup at startup.
- `definitions`: reads a definition set, given as (name, bytes) pairs of
  JSON and YAML files, into an immutable snapshot, or into diagnostics
  (file, JSON Pointer, message). Its validation is written by hand and
  follows the JSON Schema. The snapshot holds each Mock's Stubs in matching
  order and their match index, which finds the Stubs a request can match
  by its method and exact path, each response's templates, parsed, and
  each Mock's Descriptor set, decoded.
- `engine`: decides the response to each request from the snapshot,
  including its Faults, and renders a named Stub's response for a sample
  request, for `smock render` and the Admin render operation. It also holds
  the Ephemeral Stubs, the Scenario state, the Variables and the copies of
  Data buckets per Mock and Session, and the Journal, with its bound,
  eviction counts and query filter, applies the Admin API operations on
  them (verification and the unmatched requests included), and reads the Session a request carries in its W3C Baggage header. `Engine(snapshot, match_index=false)` tries every Stub in
  matching order instead of using the index; tests check the index against
  it.
- `template`: response templates: text templates (`${ expr }` in a body,
  a body file, a header value or an event field) and structured templates
  (`json` with `$each` and `$if`), the expression grammar, the helpers by
  family (fake data with its word and name lists, time and dates,
  conversions, strings, encodings, JWTs, and arithmetic in exact decimal
  with integers only), and escaping by media type. It parses a template
  once, with the values of the environment variables `--template-env`
  lists, which its caller reads, and renders it for a request, the time,
  one 64-bit draw and the Variables and Data buckets it reads, and writes
  JSON with smock's own number form, compact for responses and indented
  for the files `smock import-openapi` writes. It renders the values of a
  Stub's `variables` as JSON too.
- `importopenapi`: converts an OpenAPI document into a Definition file,
  for `smock import-openapi`. It takes the documents as (name, bytes)
  pairs and returns the names of the documents it still needs, or the
  file's bytes with the warnings, or the errors, each with a JSON Pointer
  into a document. The output's name picks YAML, written with
  `smock/yaml` and with comments that map Stubs back to the document, or
  JSON. `cmd/smock` reads the documents it asks for, under `--ref-dir`,
  and writes the file. Before it returns a file, it loads it with
  `definitions`, as `smock check` would. Its parts, one file each, are
  listed in `importopenapi/import.mbt`.
- `llm`: LLM responses. It writes a reply declared by its content in one
  LLM API's wire form, from the declaration's strings, the request's JSON
  body, the time and the ids generator, and returns the headers smock sets
  with the body. It also holds each API's vocabulary and the load checks
  that `definitions` uses. It imports neither `definitions` nor `engine`,
  and draws no wait.
- `prng`: the seeded pseudo-random generator that Fault decisions and
  template helpers draw from. Its sequence for a seed is fixed, the same on
  every target.
- `cookies`: reads the cookies of a request from its `Cookie` fields, for
  cookie conditions, the Near miss and the `cookie` root of templates, so
  that all of them read cookies by the same rules.
- `unicode`: simple case mapping and the White_Space property, for the
  template helpers `uppercase`, `lowercase` and `trim`, from the data of
  one pinned Unicode version (18.0.0). `scripts/gen-unicode-data.py`
  generated the data from the Unicode Character Database; it changes only
  with a new format version.
- `defdir`: reads the definitions directory and loads it, for
  `smock serve`, `smock check` and `smock render`, and takes the stamp of
  it that a poll compares (native).
- `server`: the listeners, the HTTP/1.1 and HTTP/2 connection loops and
  the Admin API (native). HTTP/2's framing, header compression and
  connection state come from the `http2` package of moonbitstack/moonhttp
  ([ADR 0005](docs/adr/0005-http2-comes-from-moonhttp.md)).
  On the TLS port the same loop reads and writes through a TLS stream; on
  the admin port it answers the Admin API. It reloads rotated certificates,
  and reads the SNI name from the ClientHello before OpenSSL sees it, so that
  the name chooses the certificate without a C callback. Its one C
  function, in `server/reset.c`, sets `SO_LINGER` so that the reset Fault
  ends a connection with an RST, the exception ADR 0001 makes for it.
- `watch`: polls the definitions directory and the certificate files
  every second, so that `server` can reload them (native). It uses no
  file-system events until a release of the async runtime fixes its file
  watcher ([Reloading](docs/definition-files.md#reloading) says why). Its
  `Schedule` keeps the poll interval, the 250 ms quiet period that lets a
  change settle before it is read, and the 10 s after which a change that
  never settles is read all the same, and decides which stamps lead to a
  read. It does no I/O and reads no clock. A poll reads nothing unless the
  `Stamp` of what the caller reads (the names it lists, and where the
  files it reads really are and their times) may have changed since the
  last one. It first takes a glance at the change time of each file and
  directory the last stamp looked at, one call each, and takes the stamp
  only when one changed, or every 10 s.
- `metrics`: the metrics registry: counters, gauges and histograms with
  fixed label names, rendered in the Prometheus text format. Features
  register their metrics in the one registry `smock serve` keeps.
- `usage`: understands what Linux says a process and its cgroup use, and
  how long the process waited for a CPU, in `/proc/self/stat`,
  `/proc/self/status`, `/proc/self/schedstat` and a cgroup v2's `cpu.stat`
  and `memory.peak`, for the process and cgroup metrics; the machine's
  steal time in `/proc/stat`; and where `/proc/self/cgroup` puts the
  process's cgroup, for those and for the memory limit the Journal's bound
  follows. It does no I/O: `server` reads the files and hands it their
  text.
- `openssl`: smock's own bindings to OpenSSL, the one C library ADR 0001
  allows (native). A TLS connection there does no I/O: it takes the bytes
  that arrive from the peer and hands out the bytes to send, and `server`
  carries them over the socket. It also generates self-signed certificates
  in memory. Its C is `openssl/openssl.c`. Its ALPN callback picks the
  server's first protocol that the client offers, and leaves `h2` out over
  a TLS 1.2 suite that HTTP/2 prohibits. The client side
  (`openssl/client.mbt`) offers ALPN: the e2e tests speak HTTP/2 over the
  TLS port with it, and the bindings' own tests run a client and a server
  in memory under the sanitizers, some with the client held to TLS 1.2 and
  chosen suites. That file also tells which protocol ALPN selected, which
  `server` asks of each TLS connection.
- `testcerts`: a test PKI (a root CA, an intermediate CA, RSA and ECDSA
  leaf chains for `localhost` and `127.0.0.1`, and ECDSA leaf chains for
  `users.example.com` and `orders.example.com`, each leaf with its own fixed
  expiry), used only by tests. `scripts/gen-test-certificates.sh`
  regenerates it.
- `log`: the JSON logger, one object per line, in smock's own shape or in
  the Mockoon CLI's envelope, the Mockoon-equivalent lines, and the RFC 3339
  times it writes, which the Admin API and the CLI also read.
- `buildinfo`: the version, commit and toolchain the binary was built with.
- `e2e`: tests that run the `smock` binary as a black box (native).
- `protobuf-conformance`: the testee of protobuf's conformance suite, a
  program built on `smock/protobuf`, with the list of the suite's cases
  that the module fails (native). smock's image does not hold it.
  `scripts/check-conformance.sh` runs the suite on it
  ([protobuf-conformance/README.md](protobuf-conformance/README.md)).
- `schema`: a test over every Definition-file fixture in
  `schema/v1/fixtures/` that needs no `smock` binary: each, written as YAML
  by `smock/yaml`, reads back as the same tree (native).

A package that does I/O or uses FFI declares `supported_targets = "native"`.
Every other package also builds for `wasm-gc`, and CI tests it there. The
packages that decide a response, `definitions`, `engine`, `template` and
`llm`, the ones they import, `prng`, `cookies`, `unicode` and `log`, and the
OpenAPI converter, `importopenapi`, must stay that way:
`scripts/check-no-io.sh` fails if one of them leaves out `wasm-gc`, reads
the environment, binds C or imports a package that does I/O.

`openapi/admin.json` is the OpenAPI 3.1 document of the Admin API, the
contract for it as the JSON Schema is for Definition files; a client can be
generated from it in any language.

`Dockerfile` packs the release binary into the container image, and
`.github/workflows/release.yml` publishes the image and the release binaries
(see [docs/installing.md](docs/installing.md)).
`charts/smock/` is the Helm chart, which the release workflow publishes too
(see [Helm chart](docs/installing.md#helm-chart)).

`schema/v1/definitions.json` is the JSON Schema of Definition files, the
contract for their format. `.github/workflows/schema-pages.yml` publishes it
on GitHub Pages, and `schema/v1/fixtures/` holds the Definition files that
CI checks with both the Schema and smock.

`bench/` is the release benchmark, and `.github/workflows/benchmark.yml`
runs it when started by hand; `scripts/gke-bench.sh` runs it on GKE
Autopilot before an integration branch is merged into `main` (see
[Benchmark](#benchmark)).

`.github/workflows/measure-costs.yml` measures what the tests cost on CI's
runners when started by hand, with `scripts/measure-costs.py`, and
`scripts/estimate-costs.py` recomputes the test review's cost model from
it (see [Test costs on CI's runners](#test-costs-on-cis-runners)).

`scripts/h2spec/` holds the Definition file that CI serves to h2spec, the
HTTP/2 conformance tool, and the lists of h2spec's cases that do not pass on
the plain port and on the TLS port, each with its reason (see
[Build and test](#build-and-test)).

`scripts/grpcurl/` holds the definition set that CI serves to grpcurl, a
real gRPC client, and the calls grpcurl makes, each with what it prints
(see [Build and test](#build-and-test)).

## Toolchain

The MoonBit toolchain version is pinned in `.moonbit-version`, and CI installs
exactly that version, as does the release workflow; the release notes name
it. A weekly run also builds and tests with the latest stable MoonBit,
the modules smock imports included, and opens an issue when that fails
(`.github/workflows/latest-toolchain.yml`). A scheduled run builds nothing
when the latest toolchain is the pinned one and a CI run on a push of
`main`'s head, the commit the scheduled run checks out, succeeded and was
last updated within 7 days, since it would only repeat that run
(`scripts/latest-toolchain-plan.sh`); a run started by hand always builds.
moonbitstack/moonhttp is pinned to one exact version, and raised only on
purpose ([Upgrading moonhttp](docs/releasing.md#upgrading-moonhttp)).

## Build and test

To run a commit that no release holds yet, build it from a checkout:

```sh
moon build --target native
SMOCK_ADMIN_TOKEN=change-me _build/native/debug/build/smock/smock/cmd/smock/smock.exe serve --dir defs
```

The tests and checks:

```sh
moon test --target native      # every module
moon test --target wasm-gc     # every package that does no I/O
moon check --deny-warn --target all
moon fmt --check
moon bench -p smock/smock/engine --release   # match index lookups: 100 vs 10,000 Stubs
scripts/check-no-io.sh         # no I/O in the protocol modules, the packages that decide a response and the OpenAPI converter
scripts/check-no-c.sh          # the C boundary of ADR 0001, in smock and in the modules it resolves (after moon check; needs jq)
scripts/check-moonhttp-pin.sh  # the build resolves the moonhttp that moon.mod names (needs jq)
scripts/check-notice.sh        # NOTICE names the toolchain and every module the build resolves (needs jq)
scripts/test-dependency-checks.sh    # the three checks above, on copies of the modules they read (after moon check; needs jq)
scripts/test-openssl-asan.sh   # the OpenSSL bindings under AddressSanitizer and LeakSanitizer
scripts/build-release.sh       # dist/smock
dist/smock --version
scripts/check-schema.sh dist/smock   # the JSON Schema and smock agree
scripts/install-h2spec.sh      # the pinned h2spec, into ~/.local/bin
scripts/check-h2spec.sh dist/smock   # h2spec's conformance cases against the plain and TLS ports (needs h2spec, python3 and jq)
scripts/install-grpcurl.sh     # the pinned grpcurl, into ~/.local/bin
scripts/check-grpcurl.sh dist/smock  # grpcurl calls smock on the plain and TLS ports, and the gRPC guide shows those calls (needs grpcurl, curl and jq)
scripts/test-check-grpcurl.sh dist/smock   # that check fails on each difference
docker build --tag smock:dev .
scripts/smoke-test-image.sh smock:dev 0.0.0-dev <commit> "moonc <version>"   # the container image
scripts/test-helm-chart-on-kind.sh smock:dev   # the chart on a kind cluster (needs kind, kubectl and helm)
scripts/check-release-workflow.sh    # the release workflow publishes only for tags (needs yq and jq)
scripts/test-release-notes.sh        # the release notes, with CHANGELOG.md's links at the release's tag
scripts/test-release-gates.sh        # the release workflow's checks that CI passed on a tag's commit and that the tag names moon.mod's version (needs jq)
scripts/check-benchmark-workflow.sh  # the benchmark workflow runs only by hand (needs yq and jq)
scripts/check-measure-costs-workflow.sh   # the workflow that measures the tests' costs runs only by hand, with no C flags (needs yq and jq)
scripts/test-check-measure-costs-workflow.sh   # that check, on copies of the workflow changed one thing at a time (needs yq and jq)
scripts/test-measure-costs.sh        # the measurement of the tests' costs, against a fake moon (needs python3 and jq)
scripts/test-estimate-costs.sh       # the cost model recomputed from made-up measurements (needs python3)
scripts/check-ci-artifacts.sh        # when CI's jobs and steps run, and that it keeps the release binaries only from a run whose every job passed (needs yq and jq)
scripts/test-check-ci-artifacts.sh   # that check, on copies of the workflows changed one thing at a time (needs yq and jq)
scripts/test-ci-plan.sh              # the plan that skips the tests on main of a tree that already passed (needs git and jq)
scripts/test-latest-toolchain-plan.sh   # the plan that skips the weekly run with the latest MoonBit when it would repeat CI (needs jq)
scripts/test-sbom.sh                 # the SBOM scripts, and the check that the SBOM and NOTICE agree (needs jq)
scripts/test-h2spec-verdict.sh       # how a run of h2spec is judged against its list of cases
scripts/test-check-schema.sh         # the JSON Schema cross-check, with a fake validator and a fake smock (needs jq)
python3 scripts/check-doc-links.py   # the documents' links into the repository lead to a file, and to a heading when they name one (needs git)
scripts/test-check-doc-links.sh      # that check, on small trees (needs python3 and git)
scripts/check-openapi.sh             # the Admin API document is valid OpenAPI 3.1
python3 bench/gen_definitions.py --check   # the benchmark's committed definitions are what their generator writes
scripts/install-protoc.sh            # the pinned protoc, into ~/.local/bin, with its well-known types
PROTOC=~/.local/bin/protoc scripts/gen-protobuf-fixtures.sh --check   # the protobuf fixtures are what their sources build
PROTOC=~/.local/bin/protoc scripts/test-protobuf-fixtures.sh          # that check, on a copy of the working tree
python3 -m unittest discover -s bench -p test_compare.py -v   # the benchmark's comparison of two runs, which the merge checklist reads
python3 scripts/check-kept-tests.py   # every test that the keep list, mutation/kept-tests.toml, names is still there (needs Python 3.11 or later)
scripts/test-check-kept-tests.sh     # that check, on small trees
helm lint --strict charts/smock --set adminAuth.tokenSecret.name=smock-admin-token   # the Helm chart passes helm's lint (needs helm)
scripts/test-helm-chart.sh           # rendering tests of the Helm chart (needs helm, yq and jq)
python3 -m unittest discover -s bench -p test_gke_script.py -v   # scripts/gke-bench.sh against fake gcloud, kubectl and docker commands, about 5 minutes
scripts/build-conformance-runner.sh  # protobuf's conformance runner, from the pinned release, into ~/.local/bin (needs CMake and a C++17 compiler)
scripts/check-conformance.sh         # protobuf's conformance suite against smock/protobuf, judged by protobuf-conformance/failure_list.txt
scripts/check-llm-sdks.sh dist/smock # the official LLM SDKs, pinned by hash, read smock's LLM responses (needs python3 and PyPI)
```

`scripts/test-helm-chart.sh` renders `charts/smock` for each delivery mode
of the Definition files and each Admin API authentication and TLS option,
and checks the manifests, the Restricted Pod Security Standard included,
and that the chart's README lists every value with its default.
`scripts/test-helm-chart-on-kind.sh` creates a kind cluster, checks every
delivery mode against Kubernetes' own Pod Security admission, installs the
chart with the image into a namespace that enforces the Restricted
standard, and checks that a Stub answers and that a ConfigMap update is
served without a Pod restart; it deletes the cluster afterwards. CI splits
it in two, so that the cluster is created while smock builds:
`--start <state directory>` starts creating the cluster in the background
and returns, and `--cluster <state directory> <image>` waits for it and
does the rest. `scripts/install-kubernetes-tools.sh` installs the pinned
helm, kubectl and kind that CI uses.

`scripts/check-schema.sh` runs the external validator check-jsonschema
once over all the fixtures, through `uvx` (or `pipx`), and needs `jq`;
`scripts/check-openapi.sh` runs openapi-spec-validator the same way, on
the Admin API document. The Admin API tests in `e2e/` check
every response against `openapi/admin.json` (`e2e/contract_test.mbt`).
`e2e/import_openapi_golden_test.mbt` imports `openapi/admin.json`, the
example of [docs/importing-openapi.md](docs/importing-openapi.md) and the
OAI's Petstore (`e2e/golden/documents/`) with the binary, and compares each
result with its committed golden file. A change to what the import writes,
or to one of these documents, regenerates the golden file in the same
change, with the command that the failing test prints. The goldens in
`engine/llm_golden_*_test.mbt` compare what `llm` Stubs send with the
examples of the vendors' documents, through the comparison in
`engine/llm_golden_test.mbt`. Each example is copied there with its source
and the date it was read. Those from OpenAI's OpenAPI document come with
its licence, MIT. Anthropic's documents and OpenAI's guides grant none, so
their examples are short excerpts, used as test data only. Each golden
names the fields and events where smock differs on purpose; any other
difference fails the test. `e2e/mockoon_golden_test.mbt` compares smock's
lines in the `mockoon` log format with lines that the Mockoon CLI wrote in
a local trial, in `e2e/golden/mockoon/` with a note of their source, after
one rule for each difference decided on purpose; any other difference
fails the test. Adding a fixture file under
`schema/v1/fixtures/` adds it to the cross-check; the README there says
which directory a fixture belongs in.

`mutation/kept-tests.toml` is the keep list of the test review
([#275](https://github.com/hirunefu/smock/issues/275)): the tests that
removal rule (C) keeps for a reason that the kill matrix cannot see,
each with its reason and the source of what it checks, and for each reason
the searches that found its tests. A removal batch never proposes a test
on it. `scripts/check-kept-tests.py` fails when a test that the list names
is no longer there, so a change that renames, moves or removes a listed
test changes the list in the same commit.

`scripts/check-h2spec.sh` runs h2spec 2.6.0, the HTTP/2 conformance tool,
against a smock binary: every case of its `generic`, `http2` and `hpack`
sections, strict cases included, against the plain port, as h2c, and then
against the TLS port, as h2 by ALPN, with the self-signed certificate,
which h2spec does not verify. `scripts/check-h2spec.sh dist/smock tls` runs
one port alone. Both ports take under a second on CI's runners. smock serves `scripts/h2spec/definitions`, where a Stub at
`/`, the path h2spec requests, answers every method with 200 and a body of
4 KiB; without a body, h2spec would skip its flow-control cases.
`scripts/h2spec/plain.txt` and `scripts/h2spec/tls.txt` list the cases that
do not pass on each port, each with its reason: a case that h2spec skips, a case left out,
whose outcome does not count, or a case that fails until the issue named
beside it is done. A case that fails or is skipped without being listed so
fails the run, and so does a listed case that h2spec no longer has. The
output lists every listed case with its outcome and reason, and names each
listed case that passed, so that it can come off the list. h2spec checks
RFC 7540 and RFC 7541 only; the e2e tests cover what RFC 9113 adds to the
rules for header fields.

h2spec publishes a Linux binary for amd64 only. `scripts/install-h2spec.sh`
installs h2spec 2.6.0 into a directory, `~/.local/bin` unless one is given:
on amd64, the release binary, checked against its SHA-256; on arm64, a
build from h2spec's `v2.6.0` tag, checked against the tag's commit, with Go
1.27.3, which it downloads, checks against its SHA-256 and removes again.
The build needs `git` and downloads about 70 MB. `scripts/check-h2spec.sh`
runs the h2spec it finds on `PATH`. On either architecture, then:

```sh
scripts/install-h2spec.sh
scripts/build-release.sh
scripts/check-h2spec.sh dist/smock
```

`scripts/check-grpcurl.sh` calls a smock binary with grpcurl 1.9.4, a
real gRPC client. smock serves `scripts/grpcurl/definitions`: the Mock of
the [gRPC guide's quick start](docs/grpc.md#quick-start), with reflection
and health on, and a second Mock, so that only grpcurl's `-authority`
reaches the first. Each file of `scripts/grpcurl/calls` is one call: its
grpcurl command, as the guide writes it for the plain port, then what
grpcurl prints, and its exit status when it is not 0. Each call runs on
the plain port over h2c, and on the TLS port over h2 with the self-signed
certificate, which grpcurl's `-insecure` does not verify. They list and
describe the services through reflection, call with JSON and metadata,
make the same calls with `-protoset` and no reflection, print an error's
details with `-format-error`, check health through reflection, call
another Host, and call in a Session whose Ephemeral Stub the script adds
first. Any difference fails the run, which shows it and what grpcurl
printed. The script also checks the guide: each grpcurl command the guide
shows must be one of these calls, the output it shows after one must be
what grpcurl prints, and it must show the set's Definition file.
`scripts/test-check-grpcurl.sh` checks that each kind of difference fails
the check. To add a call, add its file, run the script, and compare what
it prints with what the file says. `scripts/install-grpcurl.sh` installs
grpcurl 1.9.4, checked against its SHA-256, into a directory,
`~/.local/bin` unless one is given, on linux/amd64 and linux/arm64:

```sh
scripts/install-grpcurl.sh
scripts/build-release.sh
scripts/check-grpcurl.sh dist/smock
```

CI runs all of these but `moon bench` and the tests of
`scripts/gke-bench.sh` on each push to a branch and on each pull request
(`.github/workflows/ci.yml`). It does not run on a pushed tag, since the
release workflow checks that CI passed on the tagged commit
([What a tag does](docs/releasing.md#what-a-tag-does)), nor on a push to a
`dependabot/**` branch, whose pull request runs it. A newer push to a
branch or a pull request cancels the run of the older one; on `main`,
every commit keeps its run. The job `scripts` runs the commands from
`scripts/check-release-workflow.sh` to `scripts/test-helm-chart.sh`, which
need no build of smock, on linux/amd64; a step that fails does not stop
the steps after it, so that one run shows every failure.
`.github/workflows/build-test.yml` runs the rest, in jobs that run side by
side:

- `checks`, on linux/amd64 alone: `scripts/check-moonhttp-pin.sh`,
  `moon fmt --check`, `moon check`, `scripts/check-no-io.sh`,
  `scripts/check-no-c.sh`, `scripts/check-notice.sh`,
  `scripts/test-dependency-checks.sh` and the tests on wasm-gc. None of
  them runs native code: the checks read text or run only the compiler's
  front end, and the tests run on wasm-gc. So they give the same answer
  on either machine.
- `test`, on linux/amd64 and linux/arm64: `moon test --target native`.
- `release-test`, on both: the engine's tests in a release build, and
  `scripts/test-openssl-asan.sh`.
- `release`, on both: the commands from `scripts/build-release.sh` to
  `scripts/test-helm-chart-on-kind.sh`, which build the release binary and
  the image and check both, and the check of the image's SBOM. h2spec and
  `scripts/test-check-grpcurl.sh` run on linux/amd64 alone: h2spec
  publishes a Linux binary for amd64 only, and the test checks the grpcurl
  check's own logic, which is the same on every machine. The job starts
  creating the kind cluster before it builds
  (`scripts/test-helm-chart-on-kind.sh --start`), so that the cluster is
  ready when the image is.
- `protobuf-conformance`, on linux/amd64: protobuf's conformance suite,
  with a runner that CI builds once and caches
  ([protobuf-conformance/README.md](protobuf-conformance/README.md)).
- `llm-sdks`, the SDK job, on linux/amd64 once `release` has passed:
  `scripts/check-llm-sdks.sh`, with the amd64 release binary built there,
  reads smock's [LLM
  responses](docs/definition-files/llm-responses.md#llm-responses) with
  the vendors' official SDKs, as applications call them
  ([llm-sdks/README.md](llm-sdks/README.md)).

`release` hands each release binary over as the workflow artifact
`release-linux-<arch>`. Then the job `keep` of `ci.yml`, which runs after
the jobs of `build-test.yml` and the job `scripts`, and only when each of
them that ran has passed and the run was not cancelled, keeps the binary of
each architecture for 7 days as `smock-linux-amd64` and `smock-linux-arm64`,
for a machine that cannot build it
([On GKE Autopilot](bench/README.md#on-gke-autopilot)). A run in which a
job failed keeps none; re-running its failed jobs within 7 days of the
run, or the whole run, keeps them once every job has passed.

On a push to `main` that merges a branch, the job `plan` skips `checks`,
`test` and `release-test` when the merge's tree is the merged branch
head's and a CI run on a push of that head, to a branch other than
`main`, succeeded and was last updated within 24 hours
(`scripts/ci-plan.sh`). That run tested the same tree, the workflows and
scripts included. `release`, `protobuf-conformance`, `llm-sdks` and the
job `scripts` run in every run, so `main`'s binaries are built and checked
from `main`'s own commit, and `keep` keeps them once every job has passed.
Every other run, and a run whose plan fails, runs every job.

`.github/workflows/bench-tests.yml` runs the tests of `scripts/gke-bench.sh`
(`bench/test_gke_script.py`), which take about four minutes, only on a push
or pull request that changes that script, `scripts/install-oha.sh`,
`scripts/build-release.sh`, `Dockerfile`, `bench/` or the workflow itself.

The native build links OpenSSL 3 (on Debian and Ubuntu, `libssl-dev`).
`prebuild.py`, which `moon` runs with `python3` before every native build,
adds `-lssl -lcrypto` to every executable that uses the bindings, tests
included, because link flags in a library's own `moon.pkg` do not reach the
packages that import it. It also compiles every executable that holds the
engine with `-ffp-contract=off`, so that a release build on arm64 does not
fuse floating-point multiply-adds and a seeded delay is the same as on
wasm-gc; CI tests the engine in a release build to check it. And it brings
the build information that `smock --version` reports up to date, so every
native build, release or not, names the commit checked out and the
toolchain in use.

Most tests drive the engine through its public interface, with in-memory
Definition files, a fixed clock and a seeded random source
(`engine/harness_test.mbt`). The tests in `e2e/` run the binary itself: each
one first runs `moon build --target native cmd/smock`, then starts smock with
its own temporary definitions directory and port 0 for each port, so they
run in parallel (`e2e/harness_test.mbt`). They need `moon`, `moonc`, `git`,
`kill`, `mkfifo` and `openssl` on `PATH`. The HTTPS tests use clients that
trust only the root CA of `testcerts`, and the HTTP/1.1 tests run on both
the plain and the TLS port. The HTTP/2 tests use moonhttp's client side
over TCP to the plain port, or over TLS to the TLS port through the OpenSSL
bindings' client side, which offers ALPN (`e2e/http2_harness_test.mbt`).
The tests of the generated certificate (`e2e/self_signed_test.mbt`) read it
from the handshake with `openssl s_client` and then trust only it.
The test of the Journal's byte bound under a memory limit
(`e2e/journal_bound_test.mbt`) starts smock in a systemd user scope with
`MemoryMax`, as the benchmark does, so it needs `systemd-run` and a systemd
user manager with the `memory` controller delegated to it (see
[Run it on your machine](bench/README.md#run-it-on-your-machine)). Where a
scope cannot get the limit, it prints why it skipped and passes.

`moon` runs the async tests of a package in one process, on one event
loop, ten at a time. A test that computes without an await holds up the
timers and reads of every other test running then: in `e2e`, one that
computed for half a second made the timing tests beside it fail. So an e2e
test computes for no more than about 20 ms between awaits, and even ten
such tests in a row delay a timer less than the timing tests allow. A
timing test takes the time it measures from before it sends the request:
taken after an await, that time can come late, and what follows then looks
early, which the timing tests do not allow. Build a large input once, in a
top-level `let`, which runs as the test process starts, and cheaply: with
`String::make`, `Bytes::make` or by doubling, not with `String::repeat`,
which appends one piece at a time. The harness writes a large file 1 MiB
at a time. A check that must compute for longer, and needs no `smock`,
goes in a package of its own, whose tests get a process of their own, as
`schema` does.

`SMOCK_VERSION` and `SMOCK_COMMIT` set the version and the commit that a
native build, such as `scripts/build-release.sh`, records in the binary.

## Test costs on CI's runners

`.github/workflows/measure-costs.yml` measures on CI's runners what the
cost model of the test review
([#275](https://github.com/hirunefu/smock/issues/275)) guesses. It runs on
a linux/amd64 and a linux/arm64 runner, and only when started by hand. It
sets no variable that gives moon another C compiler or flags: on amd64,
moon's native debug builds skip the system's C compiler, and the
measurement is of the builds as CI's test job makes them.
`scripts/measure-costs.py` measures in four parts:

- `e2e`: every e2e test run in one process, three times by default, after
  the builds of `cmd/smock` and the e2e package.
- `alone`: each e2e test run alone, in a `moon` process of its own
  (`moon test --target native e2e/<file> -i <index>`), since `moon` prints
  no time per test and runs a package's async tests ten at a time in one
  process. Each time holds moon's own work around a run, which the part
  `e2e` measures as a build with nothing to do.
- `rebuild`: from clean, in a target directory of its own, the native
  rebuild of engine's tests and of `cmd/smock` after one mutant in engine,
  and engine's tests on wasm-gc after it.
- `coverage`: builds and runs, plain and with `--enable-coverage`, of the
  native-only packages' tests, the pure packages' tests on wasm-gc but
  yaml's, yaml's natively, and the binary, each mode from clean; whether
  moon plans the system's C compiler or tcc for them; and the points the
  coverage build covers.

Start it from the Actions tab, or with `gh`. GitHub starts a workflow by
hand only once it is on the default branch; `--ref` picks the commit it
measures:

```sh
gh workflow run measure-costs.yml --ref main -f e2e-runs=3 -f alone-runs=1
```

`alone-runs=0` leaves the part `alone` out. Each architecture's results
are kept as the artifact `measurements-linux-amd64` or
`measurements-linux-arm64`, also when a measurement fails, and the job's
summary shows them. `scripts/estimate-costs.py` recomputes the cost model
from both, and prints it as Markdown with where it falls against decision
6's band:

```sh
gh run download <run id> --dir measurements
python3 scripts/estimate-costs.py --run-url <run link> \
  measurements/measurements-linux-amd64 measurements/measurements-linux-arm64
```

Each part also runs on a developer's machine:
`python3 scripts/measure-costs.py <part> <out dir>`, with `--jobs` for
moon's build jobs and `--file` for the tests of one e2e file alone. The
part `rebuild` changes `engine/range.mbt` while it runs, and puts it back
afterwards.

## Benchmark

`bench/` is the release benchmark. It measures smock's real request path,
realistic requests matched against a definition set with many Stubs with
the Journal on, over HTTP/1.1 and HTTP/2, at fixed arrival rates under the
CPU and memory limits of small GKE Autopilot Pods, and checks the
provisional performance targets. A gRPC variant of its definitions
measures gRPC unary calls over h2c in a run of its own, held to no target
([gRPC calls in the benchmark](bench/README.md#grpc-calls-in-the-benchmark)).
[bench/README.md](bench/README.md) says how to run it on a machine, on GKE
Autopilot and in CI, what a run writes and how to compare runs. The
[chart's sizing table](charts/smock/README.md#sizing) has what it measured.

## Making a release

[docs/releasing.md](docs/releasing.md) describes how a release is made and
published, for the maintainer, and which dependencies Dependabot keeps up
to date.
