# Contributing to smock

Bug reports and proposals are welcome as
[issues](https://github.com/hirunefu/smock/issues). Before a pull request
that changes code, open an issue and talk the approach over there, so that
the work fits where smock is going. Before merging a contributor's pull
request, the maintainer pushes its branch here, so that the
[weakening report](#the-weakening-report) runs on it. Report a
vulnerability privately, as [SECURITY.md](SECURITY.md) says.

This document is for people who work on smock itself. It describes the
repository's layout, the pinned MoonBit toolchain, how to build and test
smock, how its tests are judged, the mutation runner, the weakening
report, how to measure the tests' costs on CI's runners, and the
release benchmark, and says where making a release is described. The
[Contributing to smock](docs/README.md#contributing-to-smock) list in
docs/README.md names the other documents for contributors: the
architecture decisions (ADRs), the glossary and the maintainer's
checklists.

## Contents

- [Layout](#layout)
- [Toolchain](#toolchain)
- [Build and test](#build-and-test)
- [How tests are judged](#how-tests-are-judged)
- [Mutation runner](#mutation-runner)
- [The weakening report](#the-weakening-report)
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
  with a new format version. A workflow checks that the data is still what
  the script writes ([Build and test](#build-and-test)).
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
- `yaml-test-suite`: the testee of the YAML test suite, a program built on
  `smock/yaml` that reads each case in both of the parser's modes, with
  each mode's list of the suite's cases that do not pass (native). smock's
  image does not hold it. `scripts/check-yaml-test-suite.sh` runs the
  suite on it ([yaml-test-suite/README.md](yaml-test-suite/README.md)).
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

`.github/workflows/e2e-repeat.yml`, started by hand, runs the e2e tests
many times on one runner, to show that a timing test holds on CI's
runners (see [Build and test](#build-and-test)).

`scripts/h2spec/` holds the Definition file that CI serves to h2spec, the
HTTP/2 conformance tool, and the lists of h2spec's cases that do not pass on
the plain port and on the TLS port, each with its reason (see
[Build and test](#build-and-test)).

`scripts/grpcurl/` holds the definition set that CI serves to grpcurl, a
real gRPC client, and the calls grpcurl makes, each with what it prints
(see [Build and test](#build-and-test)).

`scripts/coverage-tests/` holds the small bisect reports, and the small
source tree they describe, that test the coverage report of
`scripts/coverage.sh` (see [Build and test](#build-and-test)).

`scripts/mutation/` holds the mutation runner, its site finder, and the
module their tests run on, `scripts/mutation/fixture`, which is not a
member of the workspace (see [Mutation runner](#mutation-runner)).

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
scripts/coverage.sh            # point coverage of the in-process tests, per package (needs python3)
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
scripts/check-e2e-repeat-workflow.sh       # the e2e repeat workflow runs only by hand, as many times as asked, on the architecture asked for (needs yq and jq)
scripts/test-check-e2e-repeat-workflow.sh  # that check, on copies of the workflow changed one thing at a time (needs yq and jq)
scripts/test-repeat-e2e.sh           # the script that runs the e2e tests again and again, with a fake moon
scripts/check-unicode-data-workflow.sh   # the Unicode data workflow runs when its files change and weekly, and runs the generator's check (needs yq and jq)
scripts/test-check-unicode-data-workflow.sh   # that check, on copies of the workflow changed one thing at a time (needs yq and jq)
scripts/check-ci-artifacts.sh        # when CI's jobs and steps run, and that it keeps the release binaries only from a run whose every job passed (needs yq and jq)
scripts/test-check-ci-artifacts.sh   # that check, on copies of the workflows changed one thing at a time (needs yq and jq)
scripts/test-ci-plan.sh              # the plan that skips the tests on main of a tree that already passed (needs git and jq)
scripts/test-latest-toolchain-plan.sh   # the plan that skips the weekly run with the latest MoonBit when it would repeat CI (needs jq)
scripts/check-branch-checks-workflow.sh   # the branch checks workflow writes the weakening report on each push to a branch but main (needs yq and jq)
scripts/test-check-branch-checks-workflow.sh   # that check, on copies of the workflow changed one thing at a time (needs yq and jq)
python3 scripts/weakening-report.py --base origin/main   # what this branch weakens, against its merge base with main (needs git)
scripts/test-weakening-report.sh     # the weakening report, on small git histories (needs python3 and git)
scripts/test-sbom.sh                 # the SBOM scripts, and the check that the SBOM and NOTICE agree (needs jq)
scripts/test-h2spec-verdict.sh       # how a run of h2spec is judged against its list of cases
scripts/test-yaml-test-suite-verdict.sh   # how a run of yaml-test-suite is judged against its lists of cases
scripts/test-check-schema.sh         # the JSON Schema cross-check, with a fake validator and a fake smock (needs jq)
scripts/test-coverage-report.sh      # the coverage report, on small bisect reports (needs python3)
python3 scripts/check-doc-links.py   # the documents' links into the repository lead to a file, and to a heading when they name one (needs git)
scripts/test-check-doc-links.sh      # that check, on small trees (needs python3 and git)
scripts/check-openapi.sh             # the Admin API document is valid OpenAPI 3.1
python3 bench/gen_definitions.py --check   # the benchmark's committed definitions are what their generator writes
python3 scripts/gen-unicode-data.py --check   # unicode/data.mbt is what its generator writes (downloads from unicode.org)
scripts/install-protoc.sh            # the pinned protoc, into ~/.local/bin, with its well-known types
PROTOC=~/.local/bin/protoc scripts/gen-protobuf-fixtures.sh --check   # the protobuf fixtures are what their sources build
PROTOC=~/.local/bin/protoc scripts/test-protobuf-fixtures.sh          # that check, on a copy of the working tree
python3 -m unittest discover -s bench -p test_compare.py -v   # the benchmark's comparison of two runs, which the merge checklist reads
helm lint --strict charts/smock --set adminAuth.tokenSecret.name=smock-admin-token   # the Helm chart passes helm's lint (needs helm)
scripts/test-helm-chart.sh           # rendering tests of the Helm chart (needs helm, yq and jq)
python3 -m unittest discover -s bench -p test_gke_script.py -v   # scripts/gke-bench.sh against fake gcloud, kubectl and docker commands, about 5 minutes
scripts/build-conformance-runner.sh  # protobuf's conformance runner, from the pinned release, into ~/.local/bin (needs CMake and a C++17 compiler)
scripts/check-conformance.sh         # protobuf's conformance suite against smock/protobuf, judged by protobuf-conformance/failure_list.txt
scripts/fetch-yaml-test-suite.sh     # the pinned release of the YAML test suite, into _build/yaml-test-suite
scripts/check-yaml-test-suite.sh     # the YAML test suite against smock/yaml in both modes, judged by yaml-test-suite/safe.txt and openapi.txt (fetches the suite first)
scripts/check-llm-sdks.sh dist/smock # the official LLM SDKs, pinned by hash, read smock's LLM responses (needs python3 and PyPI)
python3 -m unittest discover -s scripts/mutation -v   # the mutation runner and its site finder, on a module whose mutants are known (needs git, moon and moonc)
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

`scripts/coverage.sh` runs every package's in-process tests with
coverage, in a target directory of its own, `_coverage` unless
`--target-dir` names another, and prints each package's points covered
of all, its uncovered points with their file, line and definition, and
line figures beside them; a line counts as covered only when every point
on it is. A summary gives the totals inside and outside `server` and
`cmd/smock`, which only the binary runs. The packages that build on
wasm-gc run there, except `yaml`, whose deepest nesting test overflows
wasm-gc's stack when instrumented; `yaml` and the native-only packages
run natively, with at most two build jobs (`--jobs`). `e2e` does not run.
`cmd/smock` has no tests, so its points come from an instrumented build
that nothing runs. The first run builds everything with coverage and
takes a few minutes; a later run rebuilds only what changed. It reads
every trace source in the target directory, so remove the directory
after removing a package.

CI runs all of these but `moon bench`, `scripts/coverage.sh` and the tests
of `scripts/gke-bench.sh` on each push to a branch and on each pull request
(`.github/workflows/ci.yml`). It does not run on a pushed tag, since the
release workflow checks that CI passed on the tagged commit
([What a tag does](docs/releasing.md#what-a-tag-does)), nor on a push to a
`dependabot/**` branch, whose pull request runs it. A newer push to a
branch or a pull request cancels the run of the older one; on `main`,
every commit keeps its run. The job `scripts` runs the commands from
`scripts/check-release-workflow.sh` to `scripts/test-helm-chart.sh`, which
need no build of smock, on linux/amd64; a step that fails does not stop
the steps after it, so that one run shows every failure. The job
`yaml-test-suite` runs `scripts/check-yaml-test-suite.sh` beside it, on
linux/amd64: it fetches the suite and builds the testee
([yaml-test-suite/README.md](yaml-test-suite/README.md)).
`.github/workflows/build-test.yml` runs the rest, in jobs that run side by
side:

- `checks`, on linux/amd64 alone: `scripts/check-moonhttp-pin.sh`,
  `moon fmt --check`, `moon check`, `scripts/check-no-io.sh`,
  `scripts/check-no-c.sh`, `scripts/check-notice.sh`,
  `scripts/test-dependency-checks.sh`, the tests on wasm-gc and the tests
  of the mutation runner. None of them runs native code: the checks read
  text or run only the compiler's front end, and the tests run on
  wasm-gc. So they give the same answer on either machine.
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
the jobs of `build-test.yml` and the jobs `scripts` and `yaml-test-suite`,
and only when each of them that ran has passed and the run was not
cancelled, keeps the binary of each architecture for 7 days as
`smock-linux-amd64` and `smock-linux-arm64`,
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
jobs `scripts` and `yaml-test-suite` run in every run, so `main`'s
binaries are built and checked from `main`'s own commit, and `keep` keeps
them once every job has passed.
Every other run, and a run whose plan fails, runs every job.

`.github/workflows/bench-tests.yml` runs the tests of `scripts/gke-bench.sh`
(`bench/test_gke_script.py`), which take about four minutes, only on a push
or pull request that changes that script, `scripts/install-oha.sh`,
`scripts/build-release.sh`, `Dockerfile`, `bench/` or the workflow itself.

`.github/workflows/unicode-data.yml` runs
`python3 scripts/gen-unicode-data.py --check`. It downloads the pinned
version of the Unicode Character Database from unicode.org, and fails when
`unicode/data.mbt` is not what the script writes from it. The table records
the SHA-256 of each file it comes from, so a file that unicode.org now
serves with other bytes fails it too. It runs on a push or pull request
that changes the table, the script or the workflow itself, once a week
(Tuesdays, 04:23 UTC), and when started by hand. It does not run in
`ci.yml`: a network failure would fail the job `scripts`, and `keep` would
keep no binaries. The job `scripts` runs
`scripts/check-unicode-data-workflow.sh` and its test on every push; they
check when the workflow runs and what it runs.

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

A timing test that fails once in ten runs passes most single runs of CI.
The e2e repeat workflow (`.github/workflows/e2e-repeat.yml`) runs the e2e
tests a given number of times, one run after another, on one runner of the
architecture asked for, and keeps what each run printed, with a summary of
the runs that failed and the tests that failed in each, as the artifact
`e2e-repeat-linux-<arch>`. It runs only when started by hand, from the
Actions tab or with:

```sh
gh workflow run e2e-repeat.yml -f arch=amd64 -f runs=30
```

`scripts/repeat-e2e.sh <runs> <directory>` does the same on a machine, once
the e2e tests and `cmd/smock` are built.

`SMOCK_VERSION` and `SMOCK_COMMIT` set the version and the commit that a
native build, such as `scripts/build-release.sh`, records in the binary.

## How tests are judged

The test review ([#275](https://github.com/hirunefu/smock/issues/275))
judges smock's tests by what they would catch, not by a percentage.
[ADR 0006](docs/adr/0006-tests-are-judged-by-four-ledgers.md) records the
decision and why. This section holds the rules, for anyone who writes,
changes or removes a test. The review builds its tooling step by step:
until the coverage wrapper, the mutation runner and the branch checks
exist, the ledgers are kept by hand and none of them stops a merge, but
the rules for writing and removing tests apply already.

### Terms

- **Point**: an instrumentation point of moon's coverage, at a
  function's first statement, a then, else or match-arm body, or a call.
  It is covered when its counter is above zero.
- **Pure package**: a package of code that builds on wasm-gc. There are
  19: `buildinfo`, `cookies`, `definitions`, `engine`, `grpc`, `http1`,
  `importopenapi`, `llm`, `log`, `metrics`, `prng`, `protobuf`, `re2`,
  `settings`, `template`, `unicode`, `usage`, `xml` and `yaml`.
  `testcerts` builds there too, but it is data only, so it is not one.
  The native-only packages are `server`, `cmd/smock`, `defdir`, `watch`,
  `openssl`, `protobuf-conformance`, `schema` and `e2e`.
- **Protocol packages**: `http1`, `grpc`, `yaml`, `re2`, `xml` and
  `protobuf`.
- **Site**: one change that one operator can make at one place.
  **Position**: a place that holds one or more sites. **Mutant**: the
  source with one site's change applied. A mutant **survives** when every
  test passes with it.
- **Pinned set**: one mutant per position, its alternative chosen by the
  rule of operator set v1 (two for INT in a comparison or an index).
  **Full set**: every alternative that an operator of v1 defines, at
  every position. The pinned set is part of it.
- **Equivalent mutant**: a mutant that no input can tell from the
  original.
- **BODY mutant**: a function's body replaced by a default value of its
  return type. A function whose BODY mutant survives is
  **pseudo-tested**.
- **Schema binary**: one build that holds many mutants, each switched on
  only when an environment variable, read once at startup, names it. It
  has nothing to do with the `schema` package.
- **Kill matrix**: for each mutant, the tests that kill it.
- **Exclusion**: an entry of the exclusion list that accepts an uncovered
  point or a surviving mutant, with a category and a reason.
- **Unexplained survivor**: a survivor that no test kills, no code change
  removed and no current exclusion other than DEFERRED covers. A survivor
  whose only covering entry is stale is **stale-covered**: the merge check
  reports it without stopping the merge, and the weekly run, the release
  check and every count for L4 treat it as unexplained.

### The four ledgers

"100%" means that nothing is left unexplained in four ledgers. No
percentage is a target or a gate: scores are reported per package, and
never gated. Each baseline below was measured at d953f320.

1. **Coverage**, necessary but not sufficient: no uncovered point in
   scope, outside exclusions that carry a reason. The measure is moon's
   point coverage, read from the bisect report (the default format of
   `moon coverage report`). Line figures overstate coverage, since a line
   that is only partly covered counts as covered, so they are only shown
   beside it. Baseline: 819 points uncovered outside `server` and
   `cmd/smock`; `server` 6.8% covered; `cmd/smock` 0%.
2. **Mutation**: no unresolved survivor over the pinned set. A survivor
   is resolved by a test that kills it, by a code change (a survivor can
   prove code redundant), or by a reviewed entry in the exclusion list.
   Baseline: of 250 mutants sampled from the pure packages, 243 compiled,
   and 77.4% of those were killed; of the 229 that are not equivalent,
   89.1% were killed when the importers' tests ran too.
3. **Boundaries**: every limit that a spec or smock's documents state is
   tested at the limit and just past it, with the smallest input that
   crosses it. A limit in the code that no document states is a finding:
   once the maintainer confirms it, the documents state it, and it is
   tested like the others. Baseline: about 33 of the 40 most important
   limits tested on both sides.
4. **Use cases**: every documented feature has an automated test, or a
   recorded manual check with its reason. Every Definition-file example
   in the documents passes `smock check` in CI. Every message a user can
   see is asserted at least once. Baseline: of 99 documented features, 93
   covered, 2 partly and 4 not; 70 of the 71 whole Definition files in the
   documents pass once given the context they leave out; 22 messages, 20
   of which a user can see, and the top-level help asserted by no test.

**Scope.** All non-test source of the workspace, except generated files
(the Unicode data table and the build information) and the test
certificates, which are data. A definition leaves the scope only through
the exclusion list, with a category, a reason and the maintainer's
approval. Its sites still appear in the site counts and in the counts of
sites skipped.

### The ladder

A package climbs four levels:

- **L1, coverage**: no uncovered point outside exclusions, in the pure
  packages and in the small native-only ones (`defdir`, `watch`,
  `openssl`, `protobuf-conformance`). `server` and `cmd/smock` get no
  percentage: the pure parsers that move out of `server`, into a package
  without I/O, are covered in full in-process, and the rest is reported
  from e2e coverage.
- **L2, no pseudo-tested function**: every BODY mutant is killed or
  excluded.
- **L3, changed lines**: no unexplained survivor on the lines a branch
  changes.
- **L4, per package**: no unexplained survivor over the pinned set. The
  weekly run executes exactly this set, so it verifies L4.

All 19 pure packages go to L4, in two stages: first `yaml`, `http1`,
`xml`, `re2`, `grpc`, `cookies`, `settings`, `metrics`, `usage` and
`prng`, then the other nine. `server` and `cmd/smock` get coverage through
e2e, a BODY audit and, if the measurements on CI's runners bear out the
estimate, mutants at operator level through e2e, monthly and before each
release.

L4 and a release read the pinned set alone. The monthly run over the full
set is report-only: its survivors at the other alternatives are listed
apart, and they stop no merge and no release, and do not count towards
L4.

### Operator set v1

The operators that make the mutants are pinned as a version, v1. A
change to them, the rule that picks an alternative included, needs the
maintainer's approval, and shows in the weekly report.

- **BODY**: a function's body replaced by a default value of its return
  type.
- **ROR**: a comparison, always with the boundary alternative: `<` and
  `<=` swap, and `>` and `>=` swap.
- **IFC**: a condition or guard forced to true or to false.
- **LCR**: `&&` and `||` swap.
- **NOT**: a prefix `!` removed.
- **DEL**: a statement deleted.
- **BOOL**: `true` and `false` swap.
- **AOR**: `+` and `-` swap, and `*` and `/`, in their compound
  assignments too.
- **INT**: an integer literal, with both n+1 and n-1 where it is an
  operand of a comparison or an index, and one replacement elsewhere.
- **STR**: a string literal replaced by the empty string or with one
  character changed, in the protocol packages, in `server` and in `log`'s
  line writers. A mock server's behaviour is mostly strings: header
  names, content types, JSON keys, status texts and log lines.

The pinned set holds one mutant per position, two for INT in a comparison
or an index, and a fixed rule chooses the alternative, so that a runner
cannot pick those that are easiest to kill. The full set adds every other
alternative: both of IFC's, all of INT's and both of STR's. One mutant
per line, chosen by operator priority, would not do: of the 24 survivors
of the sample first read as real, it would have picked another site for
16.

The pinned set takes these alternatives, for the reasons that
[ADR 0006](docs/adr/0006-tests-are-judged-by-four-ledgers.md) gives:

- **IFC** takes the alternative under which the code that the condition
  guards never runs: false for the condition of an `if` or an `else if`
  (its then-branch never runs), of a loop (its body never runs) and for a
  match arm's guard (the arm never matches), and true for the condition
  of a `guard` statement (its `else` never runs). The full set adds the
  other.
- **STR** changes one character: the first character of the literal's
  text, outside any interpolation, becomes `_`, or `-` when it already is
  `_`. An empty literal becomes `"_"`. The full set adds the empty string.
- **INT** has three alternatives: n+1, n-1, and 0 where n is not 0.
  Outside comparisons and indexes, the pinned set takes n+1, or n-1 where
  n+1 does not fit the literal's type. The full set adds the others there,
  and 0 in comparisons and indexes.
- **ROR** swaps only `<` and `<=`, and `>` and `>=`. It does not swap `==`
  and `!=`, in either set.

Sites come from a parser, not from a lexer. For each package, each report
gives the number of sites that each rule skipped (no default value for
BODY, a string outside STR's scope, FFI) beside the number of survivors,
so that a "zero" always says what it is zero of. Each mutant has a stable
id: its file, its enclosing definition, its operator, its original text,
its replacement text and its ordinal. A report, an exclusion and a commit
message name a mutant by that id.

### Outcomes and kill credit

- **Killed**: a test fails with the mutant on.
- **Timed out**: the run takes longer than 1.25 times the baseline run
  plus 4 s. A confirmed time-out counts as killed, and is listed.
- **Unviable**: the mutant does not compile. It counts neither as killed
  nor as survived.
- **Survived**: every test passes.

**Kill confirmation.** A kill counts only when the failing tests fail
again with the mutant on and pass with it off. A time-out counts only
when the mutant times out again and the run without it finishes within
the limit; otherwise it is recorded as unconfirmed. The baseline runs
twice before any mutant. The runner records each test's flake rate, and a
test above the flake threshold, which the maintainer sets, gives no kill
credit until it is fixed.

**Kill credit for a pure package.** Any wasm-gc test of any package of
the workspace gives credit. The package's own tests run first. For the
survivors, the tests of every package that imports it, directly or
through another package, run too: in the sample, `engine`'s tests alone
killed 16 of the 25 survivors in `template`'s comparison code. An e2e
test gives no credit for a pure package. Only the kill-matrix mode, for a
package heading into a removal batch and for a snapshot audit, runs every
covering test for every mutant.

**Kill credit for a native-only package.** In-process and e2e tests give
credit.

**Backend.** The verdicts for pure packages are taken on wasm-gc. A site
that uses an unchecked array access is also judged natively on amd64,
because wasm-gc traps where the native binary does not, and for such a
site the native verdict decides.

The runner never passes `-u` to `moon test`.

### Exclusions

The exclusion list is one file in the repository. No attribute in the
source excludes a mutant. An entry names its mutant by its id, and gives a
category, a reason and who reviewed it. Only the maintainer fills in the
reviewer, in a commit that the maintainer makes or acknowledges at the
merge. An entry goes stale when the text of its definition changes. Stale
entries are triaged again in a batch, which the first weekly run that
lists them opens as an issue. The uncovered points that the coverage
ledger accepts are in the same list, under the same categories:

- **EQUIVALENT**: an equivalent mutant, through the three steps below. The
  entry records the result of comparing the compiler's output and the
  adversarial attempt: the agent context that made it and the tests it
  tried.
- **ARID**: code whose change no user, document or test could notice,
  kept narrow: capacity hints, the fill values of empty arrays, abort
  messages. Logs, metrics and timeouts are features of a mock server, so
  they are not arid.
- **UNREACHABLE**: only for an arm that an invariant guards with an
  abort, or with a written argument that the maintainer approves.
- **FAULT**: reached only through an OpenSSL or file-system failure. It
  has nothing to do with a Stub's Fault. No C seam is added to inject
  such failures ([ADR 0001](docs/adr/0001-moonbit-with-c-only-for-tls.md)).
- **UB-NATIVE**: a mutant whose effect on the native binary is undefined,
  such as an unchecked array access out of bounds, so that no test can
  pin it there.
- **DEFERRED**: carries an issue number, and still counts as unresolved.

Dead code is deleted, not excluded, with the maintainer's approval.

An equivalence claim reaches the maintainer in three steps:

1. **Automatic.** The compiler's output for the mutated package is
   compared with the original's. Identical output marks the mutant
   equivalent, or a duplicate of another mutant.
2. **Adversarial.** For each claim that remains, a separate agent context
   tries to write a test that kills the mutant, from the spec.
3. **The maintainer.** What survives both goes to the maintainer: every
   entry in the protocol packages, and one in five of the others, as a
   sample. The maintainer draws the sample after the batch is frozen, so
   that its author cannot know which entries will be read. If a sampled
   entry is rejected, its author triages the whole batch again, and the
   maintainer draws a new sample.

### Rules for the work

- **The oracle rule.** Each expected value a test adds comes from a named
  source: a spec section, a sentence of smock's documents, an issue's
  acceptance criterion, the output of a reference tool (protoc, the RE2
  reference, an official SDK), or the maintainer. The test, or its name,
  cites it. A snapshot is a fine form for the value, and the source
  decides its content: a snapshot that `moon test -u` fills is checked
  against its source before it is committed. A test that disagrees with
  the current code becomes an issue. It is never made green with `-u`.
- **Extend first.** Before adding a test, extend the existing test of the
  same behaviour. Random and differential tests exist already: `re2`'s
  comparison of its DFA with the Pike VM on random patterns, and
  `http1`'s tests of split invariance and random garbage. Work on
  properties converts and extends them, and adds no parallel tests.
- **Roles.** An agent that kills survivors may delete code only when a
  survivor proves it redundant, and with the maintainer's approval.
  Outside the removal batches, no change deletes, skips or weakens an
  existing test: a test that should go is proposed for a removal batch.
- **The weakening report.** For each branch, against its merge base with
  `main`, it lists the tests deleted; the assertion lines removed or
  changed in tests that stay; the snapshot lines changed; the skip
  attributes added; the package settings that stop a test from running on
  wasm-gc; and any change to what decides a verdict: the exclusion list,
  the operator set, the runner and its committed data, the coverage
  floors and scope, the flake threshold, the lists of packages at L4 and
  of tests kept, the merge and release checks, and the mutation and
  coverage workflows. The maintainer acknowledges it at the merge.
- **The mutator is governed too.** A ratchet on each package's number of
  sites, compared per definition: a package's sites may drop by at most
  as many as the base tree had in the definitions that a change deletes
  or changes, and any other drop needs the maintainer's approval. A
  forced-fail self-test: a mutant switched on must be observable, or the
  run fails. A weekly canary replays the 250 mutants sampled at
  d953f320, whose verdicts are known, on that commit with the toolchain
  pinned there, and the maintainer accepts each difference once it is
  explained.
- **The held-out measure.** A set of mutants that no check gates on and
  that no agent writing tests ever sees: operators outside v1, such as
  swapped arguments and replaced match arms, and realistic mutants written
  by hand or by a model. It is kept outside the repository, on the
  maintainer's machine, and runs there. Nothing about a single mutant
  becomes public, only kill rates. Its mutants are keyed as exclusions
  are, so that they apply to later commits, and those whose text is gone
  are counted beside the rate. Its kill rate, measured at d953f320, at
  step 2's baseline, after steps 1, 3 and 5, after stage 1 and in each
  removal batch, is reported to the maintainer as the outcome of the
  review.
- **Seeds.** Each property runs with a fixed seed committed beside it: on
  every push, in mutation runs and in kill confirmations. Each week a
  separate job writes a random seed into a working copy, the way the
  runner applies a mutant, and prints it; a failure is rerun by
  committing that seed. No test reads the environment for a seed, so
  `scripts/check-no-io.sh` stays as it is.
- **Where the checks run.** smock merges branches locally, ticket
  branches into integration branches and those into `main`, and opens no
  pull requests; only Dependabot does. So the changed-lines job and the
  weakening report run on pushes to every branch but `main`, against the
  merge base with `main`, in a workflow of their own, which CI's job
  `keep` never waits for. An outside contributor's pull request goes the
  same way: before merging it, the maintainer pushes its branch here. The
  stop is in the merge procedure. It reports only, at first; once a
  package reaches L4, an unexplained survivor on lines of that package
  that the branch changes stops the merge into `main`. A script reads the
  report of the run on the branch head, as the release checks that CI
  passed on a tag's commit, and the
  [checklist before merging into main](docs/merging-into-main.md) gains
  it when the script exists. A diff too large for the changed-lines job
  is reported as not covered, and runs whole in a run started by hand;
  the merge check reads whichever run covered the whole diff.
- **Releases.** For the packages at L4, the latest weekly run over the
  pinned set must also show no unexplained survivor before a release, on
  the tag's commit or on an ancestor whose later changes the changed-lines
  reports cover or touch no non-test source of a package at L4. The
  release checks it before it publishes, beside the check that CI passed
  on the tag's commit
  ([What a tag does](docs/releasing.md#what-a-tag-does)). So a release may
  wait for one weekly run.
- **Bulk runs go to Actions**: the baseline of 1,000 mutants, the weekly
  and monthly runs, `server` through e2e, and the kill matrices. On a
  developer's machine, only single mutants and the diff mode run, which
  checks one change's lines, and two named exceptions: step 1's replay of
  the 250 sampled mutants and the held-out runs on the maintainer's
  machine.

### Snapshot audits

When a package's turn comes to climb to L4, about ten of its snapshots
are audited. They are drawn, with a seed the maintainer picks, among the
tests that alone kill some mutant in a kill-matrix run of the package, at
least half of them from tests that the work added. A separate agent
context, one that wrote none of that package's tests under these rules,
checks each against its source. The maintainer reads only the snapshots
that this context finds in disagreement with their source, and each of
those becomes an issue (a bug) or a corrected test.

Step 1's tests close the gaps that the review found before it had any
tooling. Every expected value they add is checked the same way: before
the merge into `main`, a separate agent context that wrote none of them
checks each value against the source it cites. The maintainer reads only
the values that this context finds in disagreement with their source,
and those whose source it finds unclear. Each disagreement becomes an
issue (a bug) or a corrected test, as in an audit.

### What makes a good test

- It drives a public interface, and survives a refactor that keeps the
  behaviour. The seams are the existing ones: in-process tests of a
  package's public interface (the harness in `engine/harness_test.mbt`
  for the engine), and e2e tests that run the binary over real sockets.
  The one new seam is the package without I/O that receives `server`'s
  pure parsers.
- Its expected value comes from a named source, which the test or its
  name cites (the oracle rule).
- A limit is tested at the limit and just past it, with the smallest
  input that crosses it. A recogniser is tested with inputs that almost
  match as well as with matches.
- It checks one behaviour, and the existing test of that behaviour is
  extended before a new one is added.
- e2e is for what only the binary shows: the process and its CLI,
  sockets, TLS, reloads, logs, the HTTP/2 loop, gRPC's wire behaviour,
  and the Admin API's routing, authentication and contract. The engine's
  semantics belong in the engine's in-process tests. The rule of about
  20 ms between awaits ([Build and test](#build-and-test)) still holds.
- A time bound is relative to the competing event or to the configured
  value, never to the runner's speed. A bound that says "X happens before
  Y" is written relative to Y, or to the configured value, for example
  under three times it. A fixed number stays only where a document states
  it as a tolerance, such as the 100 ms before a gRPC call's deadline in
  which a client's reset does not count
  ([Resets and the connection's defences](docs/grpc/state-and-faults.md#resets-and-the-connections-defences)).
- A property is grounded in a spec, as a round trip or agreement with a
  reference, reports its input classes, and shrinks.
- Killing a mutant is not enough: a test written for a survivor still
  states the behaviour from its source. The held-out measure checks that
  the tests did not merely fit the operators.
- Tests to learn from: `http1`'s split-invariance and random-garbage
  tests; `re2`'s conformance table; the codec tests on protoc's fixtures;
  the protobuf conformance job's failure list, as a model of a skip list;
  the goldens; the settings boundary pairs; `llm`'s size test (exactly
  1 MiB is within the bound, and one byte more is over it); the engine
  harness's fixed clock and seeded random source.

The e2e package may be built locally with one build job, so that work on
e2e tests need not go through CI:

```sh
moon test --target native -p smock/smock/e2e --build-only -j 1
```

Mutants, though, run locally only one at a time or in the diff mode, and
in the two exceptions that [Rules for the work](#rules-for-the-work)
names: every larger run goes to Actions.

### Removing a test

A test may go only under (A) or (B), and never when (C) holds.

- **(A) Mechanically redundant.** With the test removed, three sets stay
  the same:
  - the mutants killed over the full set, counting only tests in the same
    layer or a lower one: an e2e kill never justifies removing a unit
    test;
  - the covered points;
  - the trace links, derived mechanically: from the commit that
    introduced the test block (following moves and copies across files),
    to the ticket in its subject, to that issue's acceptance criteria.
- **(B) Negative value.** It pins an implementation detail that a
  refactor keeping the behaviour would break, or restates a constant that
  no spec, document or user fixes. The default is to rewrite it, not to
  delete it.
- **(C) Keep reasons.** The test is:
  - the only test of a feature, an acceptance criterion, a rule of an ADR,
    a documented limit, or an Admin API reply's endpoint and status;
  - the only regression test of a closed bug;
  - the only e2e test of a feature a user sees;
  - a documented example that nothing else runs;
  - one of the deliberate overlaps: the HTTP/2 rules of
    [ADR 0005](docs/adr/0005-http2-comes-from-moonhttp.md), the contract
    checker's own tests, the goldens, the in-process codec tests on
    protoc's fixtures, the settings boundary pairs, and the reload tests
    with symlinks;
  - a test of a constant that a spec fixes;
  - a test that the backends agree, or a test in a release build, such as
    the engine's tests of seeded floating-point results;
  - a test of behaviour that a dependency provides.

  The tests kept for the last four reasons are named in a list.

An e2e test goes only when operator-level mutants of the `server` code on
its path are killed by the tests that remain, or when a named test at a
lower seam, together with one remaining e2e test, checks each of its
claims about the wire. Without a run at operator level, only the second
way is open.

Each removal batch comes with its proof: the kill matrix, the point sets
and the trace links before and after, as CI artifacts, with an empty
difference; a replay of the real bug fixes
([#264](https://github.com/hirunefu/smock/issues/264),
[#60](https://github.com/hirunefu/smock/issues/60) and
[#59](https://github.com/hirunefu/smock/issues/59)) that first checks
that the full suite fails on each, and then checks the reduced one (a fix that cannot be reverted cleanly is replayed by bringing its
bug back in the smallest way, or left out with the maintainer's
approval); small commits that name the tests that take over; the
maintainer's approval; and a new measurement of the held-out set.

These never justify removing a test: coverage alone, text similarity,
smell detectors, a target count, or CI's speed.

## Mutation runner

The test review ([#275](https://github.com/hirunefu/smock/issues/275))
judges the tests by mutants: copies of the source with one small change
each, which a good test should notice. The mutation runner makes them for
a package, runs the package's own tests on wasm-gc against each, and
reports the mutants that survive. It has two parts, which only a line
format joins:

- `scripts/mutation/sites.py`, the site finder, reads source and prints
  one site per line, as JSON: the mutant's id, its file, its enclosing
  definition, its operator, its original text, its replacement text, its
  ordinal and its position (line and column). A **site** is one change
  that one operator can make at one place.
- `scripts/mutation/run.py`, the runner, makes one mutant of each site
  that the finder prints, builds and tests it, and writes the records and
  the report.

The operators so far are three of operator set v1, the pinned set of the
review: ROR, a comparison with its boundary alternative (`<` and `<=` swap,
and `>` and `>=` swap); BOOL (`true` and `false` swap); and NOT (a prefix
`!` removed). Each gives one mutant per position. Test files, test blocks
and generated files have no sites. A generated file is one whose first
line says `// Generated by <what>. Do not edit.`, as the Unicode data
table (`unicode/data.mbt`), the build information
(`buildinfo/build_info.mbt`), the test certificates
(`testcerts/testcerts.mbt`) and the descriptor of gRPC's `health.proto`
(`server/health_set.mbt`) do.

**How sites are found.** Sites come from a parser, not from a lexer or a
regular expression, so that a string, a comment, a pattern or a range that
looks like an operator is never taken for one. The parser is the pinned
compiler's own: `moonc compile -dsource -show-loc <file>` writes the
file's parse tree beside it, with the position of every node, which gives
each operator's position and the extent of its operands. The finder copies
each file into a temporary directory and reads the tree there; the
compiler then fails to type the file, which it reads without its package,
and only a parse error fails the finder. This was chosen over a MoonBit
parser library, such as moonbitlang/parser, for two reasons:

- It parses exactly what the pinned compiler builds. A library has a
  grammar of its own, which can lag behind the compiler: the latest
  moonbitlang/parser when this was decided, 0.4.7, came out before moonc
  v0.10.20.
- It adds no module. moon resolves nothing new, so `NOTICE`, the image's
  SBOM and the dependency checks (`scripts/check-notice.sh`,
  `scripts/check-no-c.sh`, `scripts/check-moonhttp-pin.sh`) stay as they
  are.

What it costs: `-show-loc` is not in moonc's `-help`, and the format of
the tree is documented nowhere, so a new toolchain may change either. The
finder checks every site's original text against the source at the
position the tree gives, and fails rather than guess. Its tests run in
CI's job `checks`, which the weekly run with the latest MoonBit runs too,
so a change shows within a week. Should the dump go, a finder built on
moonbitlang/parser can replace this one without a change to the runner,
which reads only the finder's lines. That finder would be a module of its
own outside the workspace and away from the binary's modules, so its
dependencies would still not reach `NOTICE`, the SBOM or the dependency
checks, which read the modules the workspace resolves.

**Ids.** A mutant's id is its file, its enclosing definition, its
operator, its original text, its replacement text and its ordinal, joined
by commas, as in `usage/usage.mbt,resident_bytes,ROR,<=,<,0`. Inside a
field, a `\` escapes a comma or a `\`, and `\n`, `\r` and `\t` stand for
those characters. The definition is the top-level one that holds the
site: `f`, `Type::f`, `impl Trait for Type with f`, `impl Trait with f`
for a trait's default, the name of a `let`, a `const`, a type or a trait,
or `main` or `init`. The ordinal counts, from 0,
the sites of the same file, definition, operator and texts that come
before it, so an id stays the same as long as the definition's sites of
that kind keep their order. A report, an exclusion and a commit message
name a mutant by its id.

**A run.** For each worker (`--workers`, 1 unless given), the runner
copies the workspace, the files git tracks and the untracked ones it does
not ignore, into `_build/mutation/tree-<n>`, and builds there into
`_build/mutation/target-<n>`: a build directory at a stable path, with a
target directory of the runner's own, so that a plain build and a mutant
build never rebuild each other. For each package, it first builds and runs
the package's tests without a mutant, and stops if they fail. Then, for
each mutant, it writes the mutated file into the tree, builds the
package's tests with `moon test --target wasm-gc -p <package>
--build-only`, and runs them. It checks the build's exit status, so a
mutant that does not build never runs the binary of an earlier build, and
it never passes `-u`. Each mutant's outcome is one of:

- **killed**: a test failed;
- **timed out**: the run took longer than 1.25 times the run without a
  mutant plus 4 s, and was stopped. Time-outs are listed apart: until a
  later step of the review confirms them, they do not count as killed;
- **unviable**: the mutant does not build. It counts neither as killed
  nor as survived;
- **survived**: every test passed.

It writes into `_build/mutation/out/`: `mutants.jsonl`, one record per
mutant with its site, its outcome, the tests that killed it, the backend
and the timings; `summary.json`, per package, the counts of each outcome
and the run without a mutant; and `report.md`, the summaries, the
time-outs, and each survivor's diff with its whole enclosing definition,
which the runner also prints. `--work` and `--out` choose other
directories.

To see the sites of a package, and to run one mutant, or the few mutants
of a small package (they need python3, git, moon and moonc):

```sh
python3 scripts/mutation/sites.py usage
python3 scripts/mutation/run.py --mutant 'usage/usage.mbt,resident_bytes,ROR,<=,<,0' usage
python3 scripts/mutation/run.py usage
```

Run only that much on a laptop. Bulk runs, over many packages or the
weekly and monthly sets, go to GitHub Actions, through the workflows that
later steps of the review add.

The tests (`python3 -m unittest discover -s scripts/mutation -v`) run the
finder and the runner on `scripts/mutation/fixture`, a module that is not
a member of the workspace. In its package `calc`, each site's mutant has a
known outcome, given beside the site with its reason: some are killed, a
few survive, and one times out. The package `shapes` holds a site in each
kind of definition, and look-alikes that are not sites. `moon fmt --check`
at the root does not read the fixture: run `moon fmt` inside it after a
change.

## The weakening report

Before the maintainer merges a branch into `main`, they read what it
weakens. On each push to a branch other than `main` and Dependabot's, the
branch checks workflow (`.github/workflows/branch-checks.yml`) runs
`scripts/weakening-report.py` against the branch's merge base with
`main`. The job takes seconds. It writes the report to the job summary
and keeps it as the artifact `weakening-report` for 90 days. It only
reports: it passes whatever the report lists, and fails only when the
report cannot be written or kept. The workflow is not part of `ci.yml`,
so `keep` never waits for it.

The report lists:

- **Tests deleted**: each test block of the base that its package no
  longer has. A test whose name changed is followed to the new test of
  its package that holds most of its body, or whose name is much like its
  own, as when a test is extended.
- **Assertions removed or changed in tests that stay**: in each test, and
  in each function or constant of a test file, that the head still has,
  the lines it removes or changes that assert something. Those are a call
  of `inspect`, `debug_inspect`, `json_inspect`, an `assert_` function,
  `fail`, `abort` or `panic`, a `guard`, an `if` whose block fails, and a
  line that compares two values. So an exact comparison made weaker and
  an upper bound raised show here. A line added inside an assertion is
  not listed, since extending a test adds such lines.
- **Snapshot lines changed**: the lines a test removes from, changes in or
  adds to a snapshot. A snapshot is the `content=` of `inspect`,
  `debug_inspect` or `json_inspect`, a constant or a variable that a
  `content=` names, or a file in `__snapshot__`.
- **Skip attributes and target settings added**: a `#skip` or `#cfg`
  attribute that a test gains, a package whose supported targets no
  longer let its tests run on wasm-gc, and a test file that its package's
  `targets` no longer build for wasm-gc.
- **Files that decide a verdict changed**: each change to a file that
  `scripts/verdict-files.txt` names, with its diff, and each change to
  that list.

`scripts/verdict-files.txt` names, by path, every file that decides a
verdict: the mutation runner and its data, the exclusion list, the
coverage wrapper with its floors and scope, the canary's verdicts, the
lists of packages at L4 and of tests kept, the merge and release checks,
the mutation and coverage workflows, and the lists of cases that
protobuf's conformance suite and h2spec may fail. Most of these files do
not exist yet: the list fixes the paths they will have, and each line
names the issue that creates them. A change that adds a file that decides
a verdict puts it at a path the list names, or adds its path to the list
in the same change. The report reads the base's list and the head's, so
a file still shows when the same change takes its path off the list.

The report reads MoonBit by its lines and by `moon fmt`'s layout, not as
the compiler does. So it may list a line that weakens nothing, such as a
comparison in a helper's loop. A changed call of a helper that asserts is
not listed, unless the call is an assertion itself; a change to the
helper's own lines is. It reads only the MoonBit tests: the tests of the
scripts are not in it.

To read it for a branch before pushing it:

```sh
python3 scripts/weakening-report.py --base origin/main
```

An outside contributor's pull request goes the same way as the project's
own branches: before merging it, the maintainer pushes its branch to a
branch here, so that the branch checks run on it. Dependabot's pull
requests keep their own path
([Before merging into main](docs/merging-into-main.md)).

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
