# Installing smock

Each release of smock publishes a container image, a Helm chart and Linux
binaries for amd64 and arm64. The image and the chart are signed with
cosign. This document is for whoever installs smock, on a machine or on
Kubernetes. It describes the image, the chart and the binaries and what
each needs to run, and says how to verify the signatures of the image and
the chart and how to fetch the image's SBOM.

For a first run, see the README's quick start, [Run](../README.md#run).
[Running smock](running.md) describes `smock serve` and lists its
settings. The chart's own [README](../charts/smock/README.md) lists its
values, and [Getting started on GKE](getting-started-on-gke.md) walks
through an installation on GKE Autopilot, step by step.

## Contents

- [Container image](#container-image)
- [Helm chart](#helm-chart)
- [Release binaries](#release-binaries)
- [Verify the image](#verify-the-image)
- [Verify the Helm chart](#verify-the-helm-chart)

## Container image

Each release publishes the image `ghcr.io/hirunefu/smock:<version>` for
linux/amd64 and linux/arm64. The image of each architecture it is made of
also keeps a tag of its own, `<version>-amd64` and `<version>-arm64`; use
`<version>`, which picks the one for the machine. The image is distroless
(`gcr.io/distroless/base-debian13`): it holds the smock binary, what the
binary links dynamically (glibc and OpenSSL 3), and smock's `LICENSE` and
`NOTICE` under `/usr/share/doc/smock/`, and has no shell. smock runs
as UID 65532 and writes nothing to the filesystem, so the root filesystem can
be read-only:

```sh
export SMOCK_ADMIN_TOKEN=change-me
docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges \
  -e SMOCK_ADMIN_TOKEN -p 8080:8080 -p 9090:9090 -v "$PWD/defs:/defs:ro" \
  ghcr.io/hirunefu/smock:<version> serve --dir /defs
```

The image's command is `serve`; arguments replace it (`... smock:<version>
--version`). Like any `smock serve`, it needs the Admin API token, from
`SMOCK_ADMIN_TOKEN` or from a mounted file that `--admin-token-file` names
(such as a Kubernetes Secret). The image exposes the plain port 8080, the TLS
port 8443 and the admin port 9090. Files mounted into the container must be
readable by UID 65532.

To run a commit that no release holds yet, build the image from a checkout
with `scripts/build-release.sh` and `docker build --tag smock:dev .`, or
from the release binary that CI keeps for 7 days after each push (the
`smock-linux-amd64` and `smock-linux-arm64` artifacts of its run), copied to
`dist/smock`. Push it to a registry the cluster can pull from, then install
the chart below from the checkout's `charts/smock`, with `image.repository`
and `image.tag` naming that image.

## Helm chart

Each release also publishes the Helm chart `oci://ghcr.io/hirunefu/charts/smock`,
with the release's version as its version and app version, so it runs the
image of the same release:

```sh
kubectl create secret generic smock-admin-token --from-literal=token="$(openssl rand -hex 32)"
helm install smock oci://ghcr.io/hirunefu/charts/smock --version <version> \
  --set adminAuth.tokenSecret.name=smock-admin-token \
  --set-file 'definitions.configMap.files.users\.yaml=mocks/users.yaml'
```

The Definition files come from a ConfigMap by default, and a ConfigMap
update reaches the running smock through its reload, without a restart
(with body files, a file added, removed or renamed restarts the Pods); a
git-sync sidecar or an OCI image volume can deliver them instead. The Pods
meet the Restricted Pod Security Standard, run one replica with one CPU
core and 1 GiB by default (requests equal to limits, valid on GKE Autopilot
as they are), and get the Admin API token and the TLS certificates,
the default one and those of single Mocks, from Secrets. Before SIGTERM,
smock's container sleeps in a preStop hook (5 s by default) while the Pod
leaves its Services' endpoints, and the Pod's grace period covers that sleep
and [the drain](running.md#the-drain); the hook's `sleep` action needs
Kubernetes 1.30 or later.
[charts/smock/README.md](../charts/smock/README.md) describes the
chart and lists every value with its default.

## Release binaries

Each GitHub release has the binaries `smock-<version>-linux-amd64` and
`smock-<version>-linux-arm64`, the same builds as in the image; smock runs
on Linux only. They link glibc and OpenSSL 3 dynamically, so they need
glibc 2.34 or later and OpenSSL 3 at run time: on Debian and Ubuntu, the
`libssl3` package (`libssl3t64` on newer releases). Debian 12, Ubuntu 22.04,
RHEL 9 and their successors have both. Make the downloaded file executable
with `chmod +x`. The release notes name the MoonBit toolchain the release
was built with, which `smock --version` also prints.

To run a commit that no release holds yet, build the binary from a
checkout: [Build and test](../CONTRIBUTING.md#build-and-test) in
CONTRIBUTING.md says how.

## Verify the image

The image and the image of each architecture are signed with cosign, without
a key: each signature's certificate names the release workflow at the
release's tag. The release signs with cosign 3, which stores signatures as
OCI 1.1 referrers, so verify with cosign 3 or later:

```sh
cosign verify ghcr.io/hirunefu/smock:<version> \
  --certificate-identity https://github.com/hirunefu/smock/.github/workflows/release.yml@refs/tags/v<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The image of each architecture has an SPDX SBOM, attached as a signed
attestation. It lists the packages of the distroless base and smock itself:
the binary with the release's version, the commit and MoonBit toolchain it
was built from, the MoonBit modules compiled into it, the MoonBit native
runtime, mimalloc and simdutf, which come with the toolchain and are linked
into it, and its dynamic link to the base's OpenSSL. It also lists the
modules that the build resolves but compiles nothing from, such as
moondate, mooncrypt and moonbase, which moonhttp imports: smock depends on
them (`DEPENDS_ON`), but does not link them. Each module has the version
the build resolves and the licence of its own module file. The runtime,
mimalloc and simdutf have the licences that [NOTICE](../NOTICE) gives them.
The runtime has the toolchain's version and mimalloc the one NOTICE gives;
simdutf's is `NOASSERTION`, since the toolchain does not record it. To
verify the SBOM of the linux/arm64 image and save it as `smock.spdx.json`
(use `amd64` for linux/amd64):

```sh
digest=$(docker buildx imagetools inspect --raw ghcr.io/hirunefu/smock:<version> |
  jq -r '.manifests[] | select(.platform.architecture == "arm64") | .digest')
cosign verify-attestation --type spdxjson \
  --certificate-identity https://github.com/hirunefu/smock/.github/workflows/release.yml@refs/tags/v<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "ghcr.io/hirunefu/smock@$digest" | jq -r .payload | base64 -d | jq .predicate >smock.spdx.json
```

The same `cosign verify` flags verify that architecture's signature with
`"ghcr.io/hirunefu/smock@$digest"`. The GitHub release also has the SBOMs as
files, `smock-<version>-linux-<arch>.spdx.json`.
`scripts/verify-image.sh ghcr.io/hirunefu/smock:<version>` runs all of these
checks. It expects every module that NOTICE names, so run it from a
checkout of the image's own tag. The SBOMs of 0.3.0 and earlier releases do
not list the runtime, mimalloc and simdutf, so check an image of 0.3.0 or
earlier with the script from its own tag, such as
`git show v0.3.0:scripts/verify-image.sh`.

## Verify the Helm chart

The Helm chart is signed the same way, with cosign and without a key: the
signature's certificate names the release workflow at the release's tag.
Verify it with cosign 3 or later, naming the chart without `oci://`:

```sh
cosign verify ghcr.io/hirunefu/charts/smock:<version> \
  --certificate-identity https://github.com/hirunefu/smock/.github/workflows/release.yml@refs/tags/v<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The release workflow runs the same check with
`scripts/verify-chart.sh ghcr.io/hirunefu/charts/smock:<version>`. The
charts of 0.3.0 and earlier releases are not signed.
