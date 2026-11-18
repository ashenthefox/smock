#!/bin/sh
# Installs the pinned jsonnet, Jsonnet's Go implementation (go-jsonnet),
# which scripts/check-doc-examples.py runs to export the Jsonnet example of
# docs/definition-files.md, for linux/amd64 or linux/arm64 (this machine's
# architecture), checked against its pinned SHA-256 digest, into a
# directory (default: ~/.local/bin). On GitHub Actions it also adds the
# directory to the PATH of later steps. Nothing is left behind but jsonnet,
# and nothing is configured.
#
# It needs curl, tar and sha256sum.
#
# usage: scripts/install-jsonnet.sh [<directory>]
set -eu

# scripts/check-doc-examples.py reads this line, and runs no other version.
version=0.22.0

case $(uname -m) in
x86_64) asset=linux_amd64 ;;
aarch64 | arm64) asset=linux_arm64 ;;
*)
  echo "install-jsonnet: unsupported machine $(uname -m)" >&2
  exit 1
  ;;
esac

# The SHA-256 of each release asset, as GitHub lists it with the release
# and as the release's checksums.txt gives it.
case $asset in
linux_amd64) digest=e87a93ea44e34da92c15636205c7f2240bf3ac92d00ccb855dbb4e7e03ea6941 ;;
linux_arm64) digest=3016b049254cb92548ba99304b6f44ec3795e6173f908e3ce3c5add57243fe20 ;;
esac

directory=${1:-$HOME/.local/bin}
mkdir -p "$directory"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 -o "$tmp/go-jsonnet.tar.gz" \
  "https://github.com/google/go-jsonnet/releases/download/v$version/go-jsonnet_${version}_$asset.tar.gz"
echo "$digest  $tmp/go-jsonnet.tar.gz" | sha256sum --check --quiet
tar -xzf "$tmp/go-jsonnet.tar.gz" -C "$tmp" jsonnet
install -m 755 "$tmp/jsonnet" "$directory/jsonnet"
echo "install-jsonnet: installed $("$directory/jsonnet" --version) into $directory"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$directory" >>"$GITHUB_PATH"
fi
