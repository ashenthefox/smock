#!/bin/sh
# Coverage from the e2e tests, merged with the in-process tests' (#342;
# CONTRIBUTING.md, "Coverage from the e2e tests"): the job that the weekly
# mutation run calls (.github/workflows/coverage-e2e.yml), and that runs
# here as well.
#
# - scripts/coverage.sh runs every package's in-process tests with
#   coverage in the target directory, and builds there the instrumented
#   binary: cmd/smock with coverage, the native debug build that #276
#   found to work, as CI's job coverage builds it.
# - The e2e package is a plain build, in moon's own target directory, so
#   that the e2e tests' own process writes no coverage: its calls of
#   openssl's TLS client, log's time parser, http1's date cache and re2
#   are not smock's behaviour.
# - The e2e tests run with SMOCK_E2E_BINARY naming the instrumented binary
#   and SMOCK_COVERAGE_DUMP naming <target directory>/e2e, where the
#   harness keeps the counters of each smock process it starts (#341).
# - moon_cove, the toolchain's coverage reader, reads those logs, joined
#   into one, with the target directory's trace sources, the same that
#   made the in-process tests' report.
# - scripts/coverage-e2e.py writes the report, with the times of the
#   steps above, into <out>.
#
# It reports only: a failed e2e test fails nothing, and the report names
# it. It exits with the status of a step without which there is no
# report, such as a build, an in-process test or the reader, and with 2
# when it is run wrongly. moon's output goes to stderr, and the report
# alone to stdout.
#
# usage: scripts/coverage-e2e.sh --out <dir> [--target-dir <dir>] [--jobs <n>]
#   --out         where the report and what it is made of go
#   --target-dir  the coverage build's target directory, _coverage unless given
#   --jobs        the most build jobs at once, 2 unless given
set -eu
cd "$(dirname "$0")/.."

usage() {
  echo "usage: $0 --out <dir> [--target-dir <dir>] [--jobs <n>]" >&2
  exit 2
}

out=""
dir=_coverage
jobs=2
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case $1 in
  --out) out=$2 ;;
  --target-dir) dir=$2 ;;
  --jobs) jobs=$2 ;;
  *) usage ;;
  esac
  shift 2
done
[ -n "$out" ] || usage

mkdir -p "$out"
: >"$out/times.txt"
started=$(date +%s)
# took <what>: records the time since the last step, a tab and <what>.
took() {
  now=$(date +%s)
  printf '%s\t%s\n' "$((now - started))" "$1" >>"$out/times.txt"
  started=$now
}

scripts/coverage.sh --target-dir "$dir" --jobs "$jobs" >"$out/in-process.txt"
cp "$dir/coverage.bisect" "$out/in-process.bisect"
took "the in-process tests with coverage, and the instrumented binary"

moon test --target native -p smock/smock/e2e --build-only -j "$jobs" >&2
took "the e2e tests' build"

rm -rf "$dir/e2e"
mkdir -p "$dir/e2e"
status=0
SMOCK_E2E_BINARY="$dir/native/debug/build/smock/smock/cmd/smock/smock.exe" SMOCK_COVERAGE_DUMP="$dir/e2e" \
  moon test --target native -p smock/smock/e2e -j "$jobs" >"$out/e2e-tests.txt" 2>&1 || status=$?
cat "$out/e2e-tests.txt" >&2
took "the e2e tests, with the instrumented binary"

# The reader counts a file of several sets of counters as it counts the
# files apart, and a run leaves hundreds of logs.
find "$dir/e2e" -name '*.txt' -exec cat {} + >"$dir/e2e.txt"
bin=$(dirname "$(command -v moonrun)")
find "$dir" -name '*.trace.source' -exec \
  moonrun "$bin/moon_cove.wasm" -- -f bisect -o "$out/e2e.bisect" -t "$dir/e2e.txt" {} + >&2
took "the e2e tests' bisect report"

python3 scripts/coverage-e2e.py report --in-process "$out/in-process.bisect" --e2e "$out/e2e.bisect" \
  --out "$out" --tests "$out/e2e-tests.txt" --tests-status "$status" --times "$out/times.txt"
