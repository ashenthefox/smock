#!/bin/sh
# Installs the pinned grpcurl, the gRPC client that scripts/check-grpcurl.sh
# runs, for linux/amd64 or linux/arm64 (this machine's architecture), checked
# against its pinned SHA-256 digest, into a directory (default:
# ~/.local/bin). On GitHub Actions it also adds the directory to the PATH of
# later steps. Nothing is left behind but grpcurl, and nothing is
# configured.
#
# It needs curl, tar and sha256sum.
#
# usage: scripts/install-grpcurl.sh [<directory>]
set -eu

version=1.9.4

# grpcurl names its release assets by architecture: x86_64, but arm64.
case $(uname -m) in
x86_64) asset=linux_x86_64 ;;
aarch64 | arm64) asset=linux_arm64 ;;
*)
  echo "install-grpcurl: unsupported machine $(uname -m)" >&2
  exit 1
  ;;
esac

# The SHA-256 of each release asset, as GitHub lists it with the release
# and as grpcurl_1.9.4_checksums.txt gives it.
case $asset in
linux_x86_64) digest=97e13d58d2733a0e62cd2571d1d5f0c02823f0d25282f08bddedf1ad9c5d1736 ;;
linux_arm64) digest=ad66227d90631da5428b4a5ccf28d63846f0f15649d8b2367df044a59edbb617 ;;
esac

directory=${1:-$HOME/.local/bin}
mkdir -p "$directory"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 -o "$tmp/grpcurl.tar.gz" \
  "https://github.com/fullstorydev/grpcurl/releases/download/v$version/grpcurl_${version}_$asset.tar.gz"
echo "$digest  $tmp/grpcurl.tar.gz" | sha256sum --check --quiet
tar -xzf "$tmp/grpcurl.tar.gz" -C "$tmp" grpcurl
install -m 755 "$tmp/grpcurl" "$directory/grpcurl"
# grpcurl prints its version to stderr.
echo "install-grpcurl: installed $("$directory/grpcurl" -version 2>&1) into $directory"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$directory" >>"$GITHUB_PATH"
fi
