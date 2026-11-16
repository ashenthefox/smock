# Documentation

These are smock's documents, grouped by who reads them. The
[README](../README.md) says what smock is and has the quick start, and
[GLOSSARY.md](../GLOSSARY.md) defines the terms every document uses,
such as Mock, Stub and Session.

## Using smock

- [running.md](running.md) describes `smock serve`: its startup, ports
  and protocols, its settings, its logs, its limits and timeouts, the
  drain on SIGTERM, HTTPS and the `Date` header.
- [admin-api.md](admin-api.md) describes the Admin API: its token, the
  status, the probes and the metrics, rendering a Stub, and how tests add
  Ephemeral Stubs in a Session and check in the Journal what was called.
- [commands.md](commands.md) describes the commands that do not serve:
  `smock check`, `smock render` and `smock import-openapi`.
- [definition-files.md](definition-files.md) opens the Definition-file
  reference. It says how smock reads a definitions directory, and
  describes what concerns the definition set as a whole: Hosts and the
  Default Mock, the JSON Schema, reloading, `smock check` and its
  warnings, writing Definition files in YAML, editor support and other
  configuration languages. The documents in
  [definition-files/](definition-files/) describe the rest of the format:
  - [definition-files/matching.md](definition-files/matching.md) says how
    a Stub matches a request: its conditions, RE2 patterns, `$not` and
    `$exists`, the operators of `json` conditions, cookies, form fields
    and paths into XML, which Stub answers, what a request that no Stub
    matches gets, and how a Mock turns its Journal off.
  - [definition-files/scenarios.md](definition-files/scenarios.md)
    describes Scenarios, the named states that decide which Stubs can
    match: when a state moves, the state each Session keeps, Ephemeral
    Stubs' Scenarios, what states cost, and how the Journal and the Near
    miss show a move.
  - [definition-files/responses.md](definition-files/responses.md)
    describes a Stub's `response`: its status, headers, inline bodies and
    body files with their byte ranges, Server-Sent Events, JSON bodies,
    and several responses picked by weight.
  - [definition-files/faults.md](definition-files/faults.md) describes
    Faults: delays drawn from a distribution, connection Faults, and the
    seeds that give a Stub the same draws in every run.
  - [definition-files/llm-responses.md](definition-files/llm-responses.md)
    describes LLM responses, which stand in for an LLM API, and the
    fields of `llm`: streams, chunks, timing, usage and stop reasons, ids,
    templates, the size bound, paths and compatible endpoints, model lists
    and prompts in the Journal.
  - [definition-files/llm-tool-calls.md](definition-files/llm-tool-calls.md)
    describes the tool calls an LLM reply makes, broken arguments
    included, and agent loops over each API, with follow-ups and
    conversations of several turns.
  - [definition-files/llm-apis.md](definition-files/llm-apis.md) describes
    the replies of OpenAI Responses and Anthropic Messages: their streams,
    their tool calls, and the incomplete replies of Responses.
  - [definition-files/llm-errors.md](definition-files/llm-errors.md) says
    how a Stub fails an LLM call: with an error in the middle of a stream,
    or before the reply, such as a 401, a 429 with `Retry-After` or a 529,
    and how the official SDKs retry.
  - [definition-files/templates.md](definition-files/templates.md)
    describes response templates: inserting values, structured templates,
    escaping, missing values and render errors, environment variables,
    errors when loading, and rendering a template.
  - [definition-files/template-helpers.md](definition-files/template-helpers.md)
    describes the template helpers, by kind: fake data, time, conversions,
    strings, arrays, encodings, JWTs, dates and arithmetic.
  - [definition-files/variables.md](definition-files/variables.md)
    describes Variables, which keep a value from one request for the next:
    when they are written, how templates read them, the Admin API, resets
    and reloads, and the state bound.
  - [definition-files/data-buckets.md](definition-files/data-buckets.md)
    describes Data buckets: declaring one with its initial values, keys,
    reading buckets in templates, each Session's copy, writing with
    `dataWrites`, the Admin API, and what resets, reloads and the state
    bound do to the copies.
  - [definition-files/crud-stubs.md](definition-files/crud-stubs.md)
    describes CRUD Stubs, which serve a Data bucket as a REST resource:
    their paths, reads, list queries with filters, sorting and paging,
    writes, overrides, headers, Faults, Journal entries, Ephemeral CRUD
    Stubs and load errors.
  - [definition-files/grpc.md](definition-files/grpc.md) describes the
    gRPC fields of Definition files: a Mock's Descriptor sets, health
    service and reflection, and a gRPC Stub's fields, reply status,
    metadata, error details and conditions.
- [http2.md](http2.md) says how clients reach smock over HTTP/2, h2c on
  the plain port and h2 on the TLS port, from curl, Go, the JVM, browsers
  and behind a load balancer. It says what a Stub and the Journal see of
  an HTTP/2 request, and how smock bounds what one connection can cost.
- [grpc.md](grpc.md) says how a Mock stands in for a gRPC service: a
  first call, which requests are gRPC calls, how to build the Descriptor
  set that the Mock names, what smock checks in it and what it keeps, the
  Mock's `grpc` field, what a gRPC Stub can hold, Ephemeral ones included,
  how smock serves a call, and what smock does not serve. The guide's
  other documents are in [grpc/](grpc/):
  - [grpc/messages.md](grpc/messages.md) describes a call's message and a
    reply as JSON: well-known types, Struct and Value, Any, conditions on
    the message, the forms smock prints, and proto2 types.
  - [grpc/metadata-and-status.md](grpc/metadata-and-status.md) describes
    the metadata of a call and of a reply, a call's Session, how a reply
    gives its status, message and error details, how large its metadata
    may be, and Trailers-Only replies.
  - [grpc/state-and-faults.md](grpc/state-and-faults.md) says how
    Scenarios, Variables, Data buckets and weighted responses work over
    gRPC, how a call's deadline meets a Stub's delay, and which status
    each Fault gives a client.
  - [grpc/unmatched-and-refused-calls.md](grpc/unmatched-and-refused-calls.md)
    says what an unmatched call gets, its Near miss trailer included, what a
    call gets when its Stub cannot serve its content, why smock neither
    decompresses nor compresses, and which calls gRPC's rules and smock's
    limits refuse.
  - [grpc/rendering-and-journal.md](grpc/rendering-and-journal.md) says
    how `smock render` shows a gRPC Stub's reply with no client, and what
    a call leaves in the Journal and the metrics.
  - [grpc/services-and-connections.md](grpc/services-and-connections.md)
    describes the reflection and health services a Mock can turn on, and
    idle channels, keepalive PINGs and the drain.
- [importing-openapi.md](importing-openapi.md) turns an OpenAPI document
  into a Definition file with `smock import-openapi`: a quick start,
  validating the document first, the Mock and its Hosts, selecting
  responses, regenerating with overrides, problems and exit codes, notes
  for Mockoon and Prism users, and the command's limits. The guide's
  other documents are in [openapi/](openapi/):
  - [openapi/what-is-generated.md](openapi/what-is-generated.md)
    describes the Definition file the command writes: paths with
    parameters, servers and base paths, the main response and the others,
    bodies from examples and samples from schemas, response headers, and
    IDs and conditions that repeat.
  - [openapi/references-and-yaml.md](openapi/references-and-yaml.md)
    describes the `$ref` references the command follows, within the
    document and into other files, bundling with another tool a document
    whose references name URLs or too many files, and how it reads YAML.
- [migrating-from-mockoon.md](migrating-from-mockoon.md) turns a Mockoon
  environment into Definition files. It says what smock does not do, how
  the two models differ, which behaviour differs, how to check the
  migration and run smock where Mockoon ran, and how smock writes
  Mockoon's log lines. The worked example and the mapping reference are
  in [mockoon/](mockoon/):
  - [mockoon/worked-example.md](mockoon/worked-example.md) takes the
    example environment from the list of its routes, through its Mock,
    Stubs, paths, bodies and templates, to its latency, CORS and CRUD
    route.
  - [mockoon/worked-example-state.md](mockoon/worked-example-state.md)
    goes on with the routes whose answers change between requests, with
    Scenarios, random responses, global variables and data buckets.
  - [mockoon/worked-example-result.md](mockoon/worked-example-result.md)
    holds the example's whole Definition file, and a table of Mockoon's
    and smock's answers to the same requests.
  - [mockoon/mapping-reference.md](mockoon/mapping-reference.md) puts
    smock's counterpart beside each Mockoon feature, in tables:
    environments and routes, rules, responses, template helpers, and
    running and operating.
- [getting-started-on-gke.md](getting-started-on-gke.md) takes a reader
  who is new to smock to smock answering requests on GKE Autopilot.
- [examples/](examples/) holds the files that the OpenAPI and Mockoon
  guides use, and a Definition file written in Jsonnet.
- [`openapi/admin.json`](../openapi/admin.json) is the OpenAPI document
  of the Admin API, from which a client can be generated.
- [`schema/v1/definitions.json`](../schema/v1/definitions.json) is the
  JSON Schema of Definition files, for editors and validators.

## Operating smock

- [charts/smock/README.md](../charts/smock/README.md) describes the Helm
  chart: where the Definition files come from, the Admin API token and
  TLS, probes, sizing, and every value with its default.
- [installing.md](installing.md) describes what each release publishes,
  the container image, the Helm chart and the Linux binaries, and says
  how to verify the signatures of the image and the chart and fetch the
  image's SBOM.
- [SECURITY.md](../SECURITY.md) says which releases get security fixes,
  and how to report a vulnerability.
- [CHANGELOG.md](../CHANGELOG.md) records what changed in each release.

## Contributing to smock

- [CONTRIBUTING.md](../CONTRIBUTING.md) has the contribution policy, and
  describes the modules and packages, the pinned MoonBit toolchain, and
  how to build and test smock.
- [bench/README.md](../bench/README.md) describes the release benchmark:
  how to run it on a machine, on GKE Autopilot and in CI, what a run
  writes, and how to compare runs.
- [llm-sdks/README.md](../llm-sdks/README.md) describes the SDK job,
  which reads smock's LLM responses with the vendors' official SDKs in
  CI: what it checks, how to run it, and how to raise a pin.
- [merging-into-main.md](merging-into-main.md) is the maintainer's
  checklist before an integration branch is merged into `main`.
- [releasing.md](releasing.md) says how the maintainer makes a release,
  and how the dependency updates that Dependabot proposes are merged.
- [adr/](adr/) holds the architecture decisions, one file each:
  - [ADR 0001](adr/0001-moonbit-with-c-only-for-tls.md) writes smock in
    MoonBit, with C only for TLS.
  - [ADR 0002](adr/0002-definition-files-are-the-source-of-truth.md)
    makes the Definition files the source of truth, with no state shared
    between replicas.
  - [ADR 0003](adr/0003-one-process-per-pod.md) runs one smock process
    per Pod, and scales by adding Pods.
  - [ADR 0004](adr/0004-journal-byte-bound-follows-the-memory-limit.md)
    makes the Journal's default byte bound follow the memory limit.
  - [ADR 0005](adr/0005-http2-comes-from-moonhttp.md) takes HTTP/2's
    framing, HPACK and connection state from moonbitstack/moonhttp, a
    MoonBit module with no I/O and no C.
- [GLOSSARY.md](../GLOSSARY.md) defines the domain terms, and the words
  to avoid for each.
- [`schema/v1/fixtures/README.md`](../schema/v1/fixtures/README.md) says
  which directory a fixture of the JSON Schema cross-check belongs in.
- [`xml/README.mbt.md`](../xml/README.mbt.md) documents the XML parser
  and paths behind `xml` conditions, a module that does not depend on
  smock.
- [`re2/README.mbt.md`](../re2/README.mbt.md) documents the RE2-syntax
  regular expressions behind pattern conditions, a module that does not
  depend on smock.
- [`protobuf/README.mbt.md`](../protobuf/README.mbt.md) and
  [`grpc/README.mbt.md`](../grpc/README.mbt.md) document the protobuf
  codec and gRPC's wire rules behind gRPC calls, two modules that do not
  depend on smock.
  [`fixtures/protobuf/README.md`](../fixtures/protobuf/README.md) says how
  the Descriptor sets that tests read are built, and
  [`protobuf-conformance/README.md`](../protobuf-conformance/README.md)
  how protobuf's conformance suite checks the codec.
- [agents/](agents/) tells coding agents where issues live, which triage
  labels to use, and how to read the glossary and the ADRs.
