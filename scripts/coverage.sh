#!/bin/sh
# Point coverage of the in-process tests, per package: the coverage
# ledger's measuring tool (spec #275).
#
# It runs every package's in-process tests with coverage instrumentation,
# in a target directory of its own, reads the toolchain's bisect report,
# and prints for each package the points covered and uncovered, with line
# figures beside them (scripts/coverage-report.py). A coverage build and a
# plain build in one target directory would rebuild each other.
#
# - Every package that builds on wasm-gc runs there, except yaml: its test
#   of 1,024 levels of nesting overflows wasm-gc's stack when instrumented.
# - yaml and the native-only packages run natively, server's white-box
#   tests and the testees of protobuf's conformance suite and of the YAML
#   test suite (protobuf-conformance, yaml-test-suite) included, with at
#   most two build jobs: an instrumented native build of the engine needs
#   more than 2 GB at the default number of jobs.
# - e2e does not run: its tests run the binary, which writes no coverage.
# - The mutation runner's fixture module (scripts/mutation/fixture) does
#   not run: it is not a member of the workspace, and moon builds none of
#   its packages from the root.
# - cmd/smock has no tests. Its points come from an instrumented build of
#   the binary that nothing runs, so all of them count as uncovered.
#
# The bisect report is read with the toolchain's coverage reader
# (moon_cove.wasm, run by moonrun) directly, given this run's trace sources
# and runtime logs. `moon coverage report` ignores the target directory:
# its reader takes every trace source and runtime log under the directory
# it runs in, so it finds nothing in a target directory outside the tree,
# and mixes in those of any other run inside it, such as one in _build.
# `moon coverage analyze` is not used: it runs the tests of every package,
# e2e included, and deletes the runtime logs.
#
# The target directory is kept between runs, so that a run rebuilds only
# what changed; each run first removes the runtime logs of the last one.
# The reader reads every trace source in it, so after removing a package,
# remove the target directory too: the report refuses a file that is not
# in the tree. The bisect report is <target directory>/coverage.bisect.
#
# moon's output goes to stderr, and the report alone to stdout. It exits
# with the status of the first step that fails, such as a test or a build,
# and with 2 when it is run wrongly.
#
# usage: scripts/coverage.sh [--target-dir <dir>] [--jobs <n>]
#   --target-dir  the target directory, _coverage unless given
#   --jobs        the most build jobs of the native steps at once, 2 unless given
set -eu
cd "$(dirname "$0")/.."

usage() {
  echo "usage: $0 [--target-dir <dir>] [--jobs <n>]" >&2
  exit 2
}

dir=_coverage
jobs=2
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case $1 in
  --target-dir) dir=$2 ;;
  --jobs) jobs=$2 ;;
  *) usage ;;
  esac
  shift 2
done

# Whether the package in directory $1 builds on wasm-gc: its moon.pkg names
# no supported targets, or names wasm-gc among them, as scripts/check-no-io.sh
# reads it.
on_wasm_gc() {
  ! grep -q 'supported_targets' "$1/moon.pkg" || grep -q 'supported_targets.*wasm-gc' "$1/moon.pkg"
}

wasm_gc=""
native=yaml
for package in $(git ls-files '*moon.pkg' | sed 's|/\{0,1\}moon\.pkg$||' | sort); do
  case $package in
  yaml | e2e | cmd/smock | scripts/mutation/fixture/*) ;;
  *)
    if on_wasm_gc "$package"; then
      wasm_gc="$wasm_gc $package"
    else
      native="$native $package"
    fi
    ;;
  esac
done

mkdir -p "$dir"
rm -f "$dir"/moonbit_coverage_*.txt "$dir/coverage.bisect"

# shellcheck disable=SC2086 # one argument for each package
moon test --target wasm-gc --enable-coverage --target-dir "$dir" $wasm_gc >&2
# shellcheck disable=SC2086
moon test --target native --enable-coverage --target-dir "$dir" -j "$jobs" $native >&2
moon build --target native --enable-coverage --target-dir "$dir" -j "$jobs" cmd/smock >&2

# Each test executable that ran wrote one runtime log into the target
# directory, and each instrumented build of a package one trace source:
# where its points are.
set --
for log in "$dir"/moonbit_coverage_*.txt; do
  set -- "$@" -t "$log"
done
bin=$(dirname "$(command -v moonrun)")
find "$dir" -name '*.trace.source' -exec \
  moonrun "$bin/moon_cove.wasm" -- -f bisect -o "$dir/coverage.bisect" "$@" {} + >&2

python3 scripts/coverage-report.py "$dir/coverage.bisect"
