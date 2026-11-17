#!/bin/sh
# Runs the e2e tests (moon test --target native -p smock/smock/e2e) a given
# number of times, one run after another, and keeps what each run printed.
# A timing test that fails once in ten runs passes most single runs of CI,
# so a change to one is shown to hold by many runs on CI's runners: the e2e
# repeat workflow (.github/workflows/e2e-repeat.yml) runs this script there.
#
# Every run goes ahead whatever the runs before it gave. Into the directory,
# which it creates, it writes:
#
# - run-<n>.log, what run n printed, n from 1, with as many digits as the
#   number of runs has;
# - summary.md, a line for each run, `passed`, or `failed` with the tests
#   that failed, as `file:line`, then each test that failed, with its name
#   and the runs it failed in.
#
# A run that moon reports no failed test of, but that exits with another
# status than 0, failed all the same: summary.md shows its exit status, and
# its log what went wrong. A run that takes over --run-limit minutes (30 by
# default) is stopped, and fails. Build the tests and cmd/smock first
# (moon test ... --build-only, moon build --target native cmd/smock), so
# that every run tests the same build and none spends its time compiling.
#
# usage: scripts/repeat-e2e.sh [--run-limit <minutes>] <runs> <directory>
#
# It exits with 0 when every run passed, 1 when a run failed, and 2 when its
# arguments are wrong.
set -eu

usage() {
  echo "usage: scripts/repeat-e2e.sh [--run-limit <minutes>] <runs> <directory>" >&2
  exit 2
}

# Whether $1 is a whole number from 1 to $2, written without leading zeros.
is_count() {
  case $1 in
  '' | 0* | *[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le "${#2}" ] && [ "$1" -le "$2" ]
}

limit=30
if [ "${1:-}" = --run-limit ]; then
  [ $# -ge 2 ] || usage
  limit=$2
  shift 2
fi
[ $# -eq 2 ] || usage
runs=$1
out=$2
if ! is_count "$runs" 1000; then
  echo "repeat-e2e: the number of runs should be a whole number from 1 to 1000, not: $runs" >&2
  exit 2
fi
if ! is_count "$limit" 360; then
  echo "repeat-e2e: --run-limit should be a whole number of minutes from 1 to 360, not: $limit" >&2
  exit 2
fi
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$(dirname "$0")/.."

summary=$out/summary.md
# Each failure of a test, one line each: <file:line>, tab, <run>, tab, <name>.
failures=$out/.failures
# Removed when the script ends, also on an error, so that only the logs and
# the summary are kept.
trap 'rm -f "$failures" "$out/.run"' EXIT
: >"$failures"
{
  echo "# e2e tests, $runs runs"
  echo
} >"$summary"

failed_runs=0
n=1
while [ "$n" -le "$runs" ]; do
  run=$(printf "%0${#runs}d" "$n")
  log=$out/run-$run.log
  status=0
  timeout --kill-after=30s "${limit}m" \
    moon test --target native -p smock/smock/e2e >"$log" 2>&1 || status=$?
  # moon names a failed test `[<module>] test <file>:<line> ("<name>") failed`.
  sed -n 's/^\[[^]]*\] test \([^ ]*:[0-9][0-9]*\) ("\(.*\)") failed.*$/\1\t'"$run"'\t\2/p' \
    "$log" | sort -u >"$out/.run"
  if [ "$status" -eq 0 ] && [ ! -s "$out/.run" ]; then
    line="passed"
  else
    failed_runs=$((failed_runs + 1))
    case $status in
    124 | 137) line="failed, stopped after $limit minutes" ;;
    *) line="failed (exit status $status)" ;;
    esac
    if [ -s "$out/.run" ]; then
      line="$line: $(cut -f 1 "$out/.run" | paste -sd , - | sed 's/,/, /g')"
      cat "$out/.run" >>"$failures"
    fi
  fi
  echo "- run $run: $line" >>"$summary"
  echo "repeat-e2e: run $run of $runs: $line"
  n=$((n + 1))
done

{
  echo
  if [ "$failed_runs" -eq 0 ]; then
    echo "Every run passed."
  else
    echo "$failed_runs of $runs runs failed."
    if [ -s "$failures" ]; then
      echo
      echo "The tests that failed, with the runs they failed in:"
      echo
      sort -t "$(printf '\t')" -k1,1 -k2,2 "$failures" | awk -F '\t' '
        $1 != test { if (test != "") print "- " test " (\"" name "\"): " runs; test = $1; name = $3; runs = $2; next }
        { runs = runs ", " $2 }
        END { if (test != "") print "- " test " (\"" name "\"): " runs }'
    fi
  fi
} >>"$summary"

[ "$failed_runs" -eq 0 ]
