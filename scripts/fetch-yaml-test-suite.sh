#!/bin/sh
# Fetches yaml-test-suite's data release data-2022-01-17, the cases that
# scripts/check-yaml-test-suite.sh runs against smock's YAML parser
# (yaml-test-suite/README.md), checks it against its pinned SHA-256 digest,
# and unpacks it into a directory (default: _build/yaml-test-suite), in
# place of whatever the directory held. The repository holds none of the
# suite: NOTICE names it, under the MIT License.
#
# The release is a tag of the suite's data branch, which holds one
# directory for each case: its input, in.yaml; the events a YAML parser
# reads from it, test.event; and the JSON it reads as, in.json, or a file
# error where the input is not YAML. Nothing is left behind but the
# directory, and nothing is configured.
#
# It needs curl, tar and sha256sum.
#
# usage: scripts/fetch-yaml-test-suite.sh [<directory>]
set -eu
cd "$(dirname "$0")/.."

release=data-2022-01-17
# The SHA-256 of GitHub's archive of the tag. The suite publishes no
# archive of its own and lists no digest.
digest=ccae49c1d010d27c20d315969a97752f95b14642fc1e73755db4eb2df4bb0256

directory=${1:-_build/yaml-test-suite}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 -o "$tmp/suite.tar.gz" \
  "https://github.com/yaml/yaml-test-suite/archive/refs/tags/$release.tar.gz"
echo "$digest  $tmp/suite.tar.gz" | sha256sum --check --quiet
mkdir "$tmp/suite"
tar -xzf "$tmp/suite.tar.gz" -C "$tmp/suite" --strip-components=1

rm -rf "$directory"
mkdir -p "$(dirname "$directory")"
mv "$tmp/suite" "$directory"
# The cases are the directories that hold in.yaml; find does not follow
# the links of the release's directories name/ and tags/ to them.
cases=$(find "$directory" -name in.yaml | wc -l)
echo "fetch-yaml-test-suite: unpacked yaml-test-suite's $release, $cases cases, into $directory"
