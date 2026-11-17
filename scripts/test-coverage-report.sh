#!/bin/sh
# Tests of the coverage report (scripts/coverage-report.py), which
# scripts/coverage.sh runs on the toolchain's bisect report. Each test runs
# the report on a small bisect report committed in scripts/coverage-tests/,
# in the format moon_cove writes (BISECT-COVERAGE-4), over the small source
# tree beside it, and checks its exit status and what it prints.
#
# The expected values are counted by hand from those files, by the rules of
# the coverage ledger (spec #275 and its ticket #296): a point is covered
# when its count is above 0, and a line counts as covered only when every
# point on it is, so that a partly covered line never counts as covered.
#
# usage: scripts/test-coverage-report.sh
set -eu
cd "$(dirname "$0")/.."

fixtures=scripts/coverage-tests
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

# report <name> <report> [option]...: runs the report on
# $fixtures/<report> over $fixtures/tree into $tmp/<name>.out, and its exit
# status into $tmp/<name>.status.
report() {
  name=$1
  file=$2
  shift 2
  status=0
  python3 scripts/coverage-report.py --root "$fixtures/tree" "$@" "$fixtures/$file" \
    >"$tmp/$name.out" 2>&1 || status=$?
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
# spaces matches any other, so that the columns' widths do not matter.
says() {
  want=$(printf '%s\n' "$2" | tr -s ' ')
  if tr -s ' ' <"$tmp/$1.out" | grep -qxF -- "$want"; then
    pass "$1: says $2"
  else
    fail "$1: does not say $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# --- Points covered of all, per package ------------------------------------

# Every point of prng's four has a count above 0, on its two lines.
report covered covered.bisect
exits covered 0
says covered "prng 4 of 4 100.0% 0 2 of 2"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
