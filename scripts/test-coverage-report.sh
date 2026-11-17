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

# --- A partly covered line -------------------------------------------------

# Line 16 of prng.mbt holds three points, counted 3, 0 and 3: two of them
# are covered, but the line is not. The uncovered point, the then arm's
# abort, is listed with its file, line and column, and its definition.
report partly partly.bisect
exits partly 0
says partly "prng 3 of 4 75.0% 1 1 of 2"
says partly "prng: 1 of 4 points uncovered"
says partly "  prng/prng.mbt:16:19 Generator::below"

# --- The summary, inside and outside server and cmd/smock --------------------

# prng as above; server with 2 of its 6 points covered, on 1 of its 4
# lines; cmd/smock with none of its 4, on 2 lines. The report lists
# cmd/smock first, and its points out of order, as moon_cove may.
report packages packages.bisect
exits packages 0
says packages "cmd/smock 0 of 4 0.0% 4 0 of 2"
says packages "prng 3 of 4 75.0% 1 1 of 2"
says packages "server 2 of 6 33.3% 4 1 of 4"
says packages "Outside server and cmd/smock: 3 of 4 points covered (75.0%), 1 uncovered; lines 1 of 2"
says packages "server and cmd/smock: 2 of 10 points covered (20.0%), 8 uncovered; lines 1 of 6"
says packages "All packages: 5 of 14 points covered (35.7%), 9 uncovered; lines 2 of 8"

# Each uncovered point in its definition: a function with type parameters,
# a method of a trait, and fn main. The column counts characters: the
# point after « is at character 28 of its line, byte 29.
says packages "cmd/smock: 4 of 4 points uncovered"
says packages "  cmd/smock/main.mbt:3:3 main"
says packages "  cmd/smock/main.mbt:3:14 main"
says packages "  cmd/smock/main.mbt:3:18 main"
says packages "  cmd/smock/main.mbt:4:3 main"
says packages "server: 4 of 6 points uncovered"
says packages "  server/serve.mbt:7:3 Server::serve"
says packages "  server/serve.mbt:7:17 Server::serve"
says packages "  server/serve.mbt:8:3 Server::serve"
says packages "  server/serve.mbt:13:28 impl Show for Server with output"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
