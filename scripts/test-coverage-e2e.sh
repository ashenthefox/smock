#!/bin/sh
# Tests of the e2e coverage report (scripts/coverage-e2e.py), which
# scripts/coverage-e2e.sh runs on the in-process tests' and the e2e
# tests' bisect reports. Each test runs the report on the small reports
# committed in scripts/coverage-tests/e2e/, over the small source tree
# beside them and the compiler's parse trees of its server and cmd/smock
# files, and checks its exit status, what it prints and what it writes.
#
# The fixture's points are where the pinned compiler put them, in the
# format moon_cove writes (BISECT-COVERAGE-4); their counts are set by
# hand, as scripts/coverage-tests/e2e/README.md lists them. The expected
# values are counted by hand from those files, by the rules of #342: a
# point is reached when its count is above 0 in either report, and a
# position counts as covered by e2e when the point that starts the
# innermost function, then, else or match-arm body around it has a count
# above zero in the e2e tests' report.
#
# usage: scripts/test-coverage-e2e.sh
set -eu
cd "$(dirname "$0")/.."

fixtures=scripts/coverage-tests/e2e
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
pass() {
  passed=$((passed + 1))
  echo "ok   $*"
}
fail() {
  failed=$((failed + 1))
  echo "FAIL $*"
}

# report <name> <in-process report> <e2e report> [option]...: runs the
# report over $fixtures/tree, its output into $tmp/<name>.out, its files
# into $tmp/<name>/ and its exit status into $tmp/<name>.status.
report() {
  name=$1
  in_process=$2
  e2e=$3
  shift 3
  status=0
  python3 scripts/coverage-e2e.py report --root "$fixtures/tree" --trees "$fixtures/trees" \
    --in-process "$in_process" --e2e "$e2e" --out "$tmp/$name" "$@" >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
}

# exits <name> <status>: the report <name> exited with <status>.
exits() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# says <name> <line>: the report <name> printed <line>, where any run of
# spaces matches any other.
says() {
  want=$(printf '%s\n' "$2" | tr -s ' ')
  if tr -s ' ' <"$tmp/$1.out" | grep -qxF -- "$want"; then
    pass "$1: says $2"
  else
    fail "$1: does not say $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# --- Points reached in-process, by e2e and by either, per package --------------

report fixture "$fixtures/in-process.bisect" "$fixtures/e2e.bisect"
exits fixture 0
says fixture "| package | points | in-process | e2e | either | unreached |"
# cmd/smock: no in-process test; e2e reaches all but the unused closure's
# body, 7:41.
says fixture "| cmd/smock | 9 | 0 (0.0%) | 8 (88.9%) | 8 (88.9%) | 1 |"
# prng: only e2e reaches it, the then of next not.
says fixture "| prng | 3 | 0 (0.0%) | 2 (66.7%) | 2 (66.7%) | 1 |"
# server: in-process reaches 7 of 14, e2e 8; the then at 20:5 only
# in-process, the else at 22:5 and stop's body at 33:3 only e2e.
says fixture "| server | 14 | 7 (50.0%) | 8 (57.1%) | 9 (64.3%) | 5 |"
says fixture "| watch | 3 | 2 (66.7%) | 2 (66.7%) | 2 (66.7%) | 1 |"
says fixture "| all | 29 | 9 (31.0%) | 20 (69.0%) | 21 (72.4%) | 8 |"

# --- Reports it cannot read together --------------------------------------------

# broken <name> <in-process text> <e2e text> <message>: the report of the
# two texts exits with 2 and says <message>.
broken() {
  printf '%s\n' "$2" >"$tmp/$1-in-process.bisect"
  printf '%s\n' "$3" >"$tmp/$1-e2e.bisect"
  report "$1" "$tmp/$1-in-process.bisect" "$tmp/$1-e2e.bisect"
  exits "$1" 2
  says "$1" "coverage-e2e: $4"
}

# Two reports made of other trace sources: the points differ.
broken other-points "BISECT-COVERAGE-4 1 13 prng/prng.mbt 3 103 122 139 3 0 0 0" \
  "BISECT-COVERAGE-4 1 13 prng/prng.mbt 2 103 139 2 1 1" \
  "the two reports do not hold the same points: prng/prng.mbt differs"
broken other-files "BISECT-COVERAGE-4 1 13 prng/prng.mbt 3 103 122 139 3 0 0 0" \
  "BISECT-COVERAGE-4 1 15 watch/watch.mbt 3 128 153 174 3 1 0 1" \
  "the two reports do not hold the same points: prng/prng.mbt is in one only"
broken not-a-report "BISECT-COVERAGE-4 1 13 prng/prng.mbt 3 103 122 139 3 0 0 0" \
  '<?xml version="1.0"?>' \
  "$tmp/not-a-report-e2e.bisect: not a bisect report of format 4 (BISECT-COVERAGE-4)"

echo "test-coverage-e2e: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
