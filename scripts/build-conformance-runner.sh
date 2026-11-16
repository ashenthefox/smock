#!/bin/sh
# Builds protobuf's conformance_test_runner, which scripts/check-conformance.sh
# runs against smock/protobuf (conformance/README.md), from the pinned
# protobuf release, and installs it into a directory (default:
# ~/.local/bin). protobuf publishes no runner binary, so CI builds it once
# and caches it (.github/workflows/build-test.yml, job protobuf-conformance).
#
# Every source is checked against its pinned SHA-256 digest: protobuf's
# source archive, and the archives of the two libraries the runner needs,
# Abseil and JsonCpp, at the versions this protobuf release names in
# cmake/dependencies.cmake. CMake builds them from those archives, so the
# build fetches nothing else. The runner's generated code comes from the
# protoc of the same release, which scripts/install-protoc.sh installs into
# a temporary directory. Nothing is left behind but the runner, and nothing
# is configured.
#
# It needs curl, tar, unzip, sha256sum, CMake 3.16 or later and a C++17
# compiler; it uses Ninja when it finds it. The build takes about 1.5 GB in
# $TMPDIR (default: /tmp), and as many compile jobs as
# CMAKE_BUILD_PARALLEL_LEVEL says (default: one per CPU), each of which may
# take 1.5 GB of memory or more.
#
# usage: scripts/build-conformance-runner.sh [<directory>]
set -eu
cd "$(dirname "$0")/.."

# The protobuf release, and the SHA-256 of its source archive, as GitHub
# lists it with the release. scripts/install-protoc.sh must pin the same
# version.
version=36.2
protobuf_digest=3d9642a662d10e68ebae5e53f14dcce5105684212d5078f8e0d47d1ab3ae6b64
# Abseil's release that protobuf 36.2 names, and the SHA-256 of its release
# archive, as GitHub lists it with the release.
absl_version=20250512.1
absl_digest=9b7a064305e9fd94d124ffa6cc358592eb42b5da588fb4e07d09254aa40086db
# JsonCpp's tag that protobuf 36.2 names, and the SHA-256 of GitHub's
# archive of the tag, as the Bazel Central Registry pins it.
jsoncpp_version=1.9.6
jsoncpp_digest=f93b6dd7ce796b13d02c108bc9f79812245a82e577581c4c9aabe57075c90ea2

protoc_version=$(sed -n 's/^version=//p' scripts/install-protoc.sh)
if [ "$protoc_version" != "$version" ]; then
  echo "build-conformance-runner: scripts/install-protoc.sh pins protoc $protoc_version, not $version; pin one protobuf release in both" >&2
  exit 1
fi

directory=${1:-$HOME/.local/bin}
mkdir -p "$directory"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# fetch <name> <url> <digest>: downloads <url>, checks its SHA-256 digest
# and unpacks it into $tmp/<name>.
fetch() {
  curl -fsSL --retry 3 -o "$tmp/$1.tar.gz" "$2"
  echo "$3  $tmp/$1.tar.gz" | sha256sum --check --quiet
  mkdir "$tmp/$1"
  tar -xzf "$tmp/$1.tar.gz" -C "$tmp/$1" --strip-components=1
  rm "$tmp/$1.tar.gz"
}

fetch protobuf "https://github.com/protocolbuffers/protobuf/releases/download/v$version/protobuf-$version.tar.gz" "$protobuf_digest"
fetch absl "https://github.com/abseil/abseil-cpp/releases/download/$absl_version/abseil-cpp-$absl_version.tar.gz" "$absl_digest"
fetch jsoncpp "https://github.com/open-source-parsers/jsoncpp/archive/refs/tags/$jsoncpp_version.tar.gz" "$jsoncpp_digest"
# The protoc that GITHUB_PATH would otherwise gain is for this build only.
GITHUB_PATH="" scripts/install-protoc.sh "$tmp/protoc" >/dev/null

generator=""
if command -v ninja >/dev/null 2>&1; then
  generator="-G Ninja"
fi
# Only the runner and what it links: no tests, no protoc, no upb and no
# zlib. FETCHCONTENT_SOURCE_DIR_* makes CMake take Abseil and JsonCpp from
# the archives above instead of cloning them, and
# protobuf_FORCE_FETCH_DEPENDENCIES keeps it from taking installed ones.
# protobuf links the runner with JsonCpp's shared library, so the runner
# finds it in its own directory ($ORIGIN), where it is installed beside it.
# shellcheck disable=SC2086,SC2016 # the generator is two words, or none; $ORIGIN is the linker's
cmake -S "$tmp/protobuf" -B "$tmp/build" $generator \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_STANDARD=17 \
  -Dprotobuf_BUILD_CONFORMANCE=ON \
  -Dprotobuf_BUILD_TESTS=OFF \
  -Dprotobuf_BUILD_LIBUPB=OFF \
  -Dprotobuf_WITH_ZLIB=OFF \
  -Dprotobuf_INSTALL=OFF \
  -Dprotobuf_FORCE_FETCH_DEPENDENCIES=ON \
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DFETCHCONTENT_SOURCE_DIR_ABSL="$tmp/absl" \
  -DFETCHCONTENT_SOURCE_DIR_JSONCPP="$tmp/jsoncpp" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_INSTALL_RPATH='$ORIGIN' \
  -DWITH_PROTOC="$tmp/protoc/bin/protoc" >"$tmp/configure.log" ||
  {
    cat "$tmp/configure.log" >&2
    exit 1
  }
cmake --build "$tmp/build" --target conformance_test_runner \
  --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"
install -s -m 755 "$tmp/build/conformance_test_runner" "$directory/conformance_test_runner"
install -s -m 644 "$tmp/build/_deps/jsoncpp-build/src/lib_json/libjsoncpp.so.26" "$directory/libjsoncpp.so.26"
# Given an option it does not know, the runner prints its usage: so it
# loads and starts.
usage=$("$directory/conformance_test_runner" --help 2>&1 || true)
if ! printf '%s\n' "$usage" | grep -q '^Usage: conformance-test-runner'; then
  printf 'build-conformance-runner: %s/conformance_test_runner does not start:\n%s\n' "$directory" "$usage" >&2
  exit 1
fi
echo "build-conformance-runner: installed protobuf $version's conformance_test_runner, with the JsonCpp library it loads, into $directory"
