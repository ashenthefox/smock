# smock

smock is a mock server for HTTP/1.1, HTTP/2, HTTPS, Server-Sent Events and
gRPC unary calls. It stands in for the services a system depends on, on
Kubernetes and on developers' machines. It is written in MoonBit
([ADR 0001](docs/adr/0001-moonbit-with-c-only-for-tls.md)). The domain
terms are defined in [GLOSSARY.md](GLOSSARY.md).

Definition files declare smock's Mocks and their Stubs, and smock reloads
them when they change. A Stub matches requests by method, path, query
parameters, headers, cookies and body, and its response can use
templates, Variables, Data buckets and Faults. CRUD Stubs serve a Data
bucket as a REST resource,
[LLM responses](docs/definition-files.md#llm-responses) stand in for the
OpenAI Chat Completions, OpenAI Responses and Anthropic Messages APIs, and
[gRPC Stubs](docs/grpc.md) answer unary calls, on the same ports as HTTP,
with replies written as JSON. Tests work in Sessions: through the Admin
API, a test adds Ephemeral Stubs for its Session only, and checks in the
Journal what its system sent. smock comes as a container image, a Helm
chart and Linux binaries.

## Run

Save this Definition file as `defs/users.json`. It declares one Mock,
`users`, with one Stub, `get-user`:

```json
{
  "mocks": [{ "name": "users" }],
  "stubs": [
    {
      "id": "get-user",
      "mock": "users",
      "request": { "method": "GET", "path": "/users/1" },
      "response": {
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": "{\"id\":1,\"name\":\"Alice\"}"
      }
    }
  ]
}
```

Each release publishes the container image, the Helm chart and Linux
binaries ([docs/installing.md](docs/installing.md)).
To run the binary, download the one for your machine (`amd64` or `arm64`)
from the [latest release](https://github.com/hirunefu/smock/releases/latest),
with `<version>` its version without the `v`:

```sh
curl -fLo smock https://github.com/hirunefu/smock/releases/download/v<version>/smock-<version>-linux-amd64
chmod +x smock
SMOCK_ADMIN_TOKEN=change-me ./smock serve --dir defs
```

To run the container image instead, mount `defs` into it
([Container image](docs/installing.md#container-image)):

```sh
export SMOCK_ADMIN_TOKEN=change-me
docker run --rm -e SMOCK_ADMIN_TOKEN -p 8080:8080 -p 9090:9090 \
  -v "$PWD/defs:/defs:ro" ghcr.io/hirunefu/smock:<version> serve --dir /defs
```

A Mock answers the requests for the Hosts it lists in `hosts`, and the
Default Mock answers the rest. A lone Mock is the Default Mock, so `users`
answers `curl localhost:8080/users/1`, with a `Smock-Mock: users;
via=default` header that says no Host matched.

```console
$ curl localhost:8080/users/1
{"id":1,"name":"Alice"}
```

[docs/definition-files.md](docs/definition-files.md#hosts-and-the-default-mock)
describes Hosts and the Default Mock.

A request that no Stub matches gets the Mock's no-match response, with a
`Smock-Near-Miss` header naming the closest Stub and the conditions it
failed, such as `Smock-Near-Miss: get-user; failed=method`.
[When no Stub matches](docs/definition-files.md#when-no-stub-matches)
describes the no-match response and the Near miss.

[docs/definition-files.md](docs/definition-files.md) describes the format,
[docs/running.md](docs/running.md) the settings, the logs and HTTPS, and
[docs/admin-api.md](docs/admin-api.md) how tests add Stubs and check calls.

## Documentation

[docs/README.md](docs/README.md) lists every document, grouped by who
reads it.

### Using smock

- [docs/definition-files.md](docs/definition-files.md) describes the
  format of Definition files: how Stubs match requests, what they
  answer, templates, Variables, Data buckets, CRUD Stubs and Faults, and
  how to write them in YAML.
- [docs/running.md](docs/running.md) describes `smock serve`: its ports
  and protocols, settings, logs, limits and timeouts, the drain and HTTPS.
- [docs/admin-api.md](docs/admin-api.md) describes the Admin API: the
  status, probes and metrics, Sessions and Ephemeral Stubs, and the
  Journal.
- [docs/commands.md](docs/commands.md) describes `smock check`,
  `smock render` and `smock import-openapi`.
- [docs/http2.md](docs/http2.md) says how clients reach smock over
  HTTP/2, h2c on the plain port and h2 on the TLS port, from curl, Go, the
  JVM, browsers and behind a load balancer. It says what a Stub and the
  Journal see of an HTTP/2 request, and how smock bounds what one
  connection can cost.
- [docs/grpc.md](docs/grpc.md) says how a Mock stands in for a gRPC
  service: how to build the Descriptor set it names, what its gRPC Stubs
  can hold, the JSON form of a call's message, reply metadata, status and
  error details, unmatched calls, deadlines, Faults, server reflection and
  health, gRPC's protocol checks, and what smock does not serve.
- [docs/importing-openapi.md](docs/importing-openapi.md) turns an OpenAPI
  document into a Definition file.
- [docs/migrating-from-mockoon.md](docs/migrating-from-mockoon.md) maps
  Mockoon environments, routes, rules, helpers and data buckets onto
  Mocks, Stubs, templates and Data buckets.
- [docs/getting-started-on-gke.md](docs/getting-started-on-gke.md) takes
  a first-time reader to smock answering requests on GKE Autopilot.

### Operating smock

- <a id="verify-the-image"></a><a id="verify-the-helm-chart"></a>
  [docs/installing.md](docs/installing.md) describes the container image,
  the Helm chart and the release binaries, and says how to verify the
  signatures of the image and the chart.
- [charts/smock/README.md](charts/smock/README.md) describes the Helm
  chart and lists every value with its default.
- [SECURITY.md](SECURITY.md) says which releases get security fixes, and
  how to report a vulnerability.
- [CHANGELOG.md](CHANGELOG.md) records what changed in each release.

### Contributing to smock

- [CONTRIBUTING.md](CONTRIBUTING.md) has the contribution policy, the
  repository's layout, the toolchain, and how to build and test smock.

## Licence

Apache-2.0. See [LICENSE](LICENSE). The binary also holds third-party
software under its own licences, which [NOTICE](NOTICE) names. The image
holds both files under `/usr/share/doc/smock/`, and each release attaches
them next to the binaries.
