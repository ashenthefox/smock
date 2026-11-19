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

# --- The positions e2e covers ---------------------------------------------------

# positions <name> <list>: the positions of the list <list>.jsonl that the
# report <name> wrote, as "<file>:<line>:<column> <operator>", one a line,
# into $tmp/<name>.<list>; the runner's own reader of lists
# (scripts/mutation/choice.py) must read the list.
positions() {
  python3 - "$tmp/$1/$2.jsonl" >"$tmp/$1.$2" 2>"$tmp/$1.$2.err" <<'PY' ||
import json, sys
sys.path.insert(0, "scripts/mutation")
import choice
path = sys.argv[1]
choice.read_list(path)
for line in open(path, encoding="utf-8"):
    entry = json.loads(line)
    print(f"{entry['file']}:{entry['line']}:{entry['column']} {entry['operator']}")
PY
    fail "$1: the runner's reader of lists does not read $2.jsonl: $(cat "$tmp/$1.$2.err")"
}

# in_list <name> <list> <position>: the list holds the position, once for
# each of its mutants.
in_list() {
  if grep -qxF -- "$3" "$tmp/$1.$2"; then
    pass "$1: $2 holds $3"
  else
    fail "$1: $2 does not hold $3"
    sed 's/^/     /' "$tmp/$1.$2"
  fi
}

positions fixture covered-by-e2e
positions fixture not-covered-by-e2e

# The rule, as #342 states it.
says fixture "A position counts as covered by e2e when the point that starts the innermost function, then, else or match-arm body around it has a count above zero in the e2e tests' report."
says fixture "| package | positions | covered by e2e | not covered | mutants of the pinned set at covered positions |"
# server: 31 positions, 32 mutants (INT in a comparison makes two at
# 36:21); 9 positions not covered, listed below.
says fixture "| server | 31 | 22 | 9 | 23 |"
says fixture "| cmd/smock | 4 | 2 | 2 | 2 |"
if [ "$(wc -l <"$tmp/fixture.covered-by-e2e")" = 25 ] && [ "$(wc -l <"$tmp/fixture.not-covered-by-e2e")" = 11 ]; then
  pass "fixture: lists 25 mutants at covered positions and 11 at the others"
else
  fail "fixture: lists $(wc -l <"$tmp/fixture.covered-by-e2e") and $(wc -l <"$tmp/fixture.not-covered-by-e2e") mutants"
fi

# A function's body: serve's (e2e 2) and unused's (0), whose BODY site
# starts at its brace.
in_list fixture covered-by-e2e "server/serve.mbt:17:59 BODY"
in_list fixture covered-by-e2e "server/serve.mbt:19:6 IFC"
in_list fixture not-covered-by-e2e "server/serve.mbt:44:45 BODY"
in_list fixture not-covered-by-e2e "server/serve.mbt:45:13 AOR"
# A then that only the in-process tests ran, and an else that e2e ran.
in_list fixture not-covered-by-e2e "server/serve.mbt:20:27 AOR"
in_list fixture covered-by-e2e "server/serve.mbt:22:27 AOR"
# A match arm that ran, and one that did not.
in_list fixture covered-by-e2e "server/serve.mbt:26:20 AOR"
in_list fixture not-covered-by-e2e "server/serve.mbt:25:10 INT"
# A guard's else is an else.
in_list fixture not-covered-by-e2e "server/serve.mbt:18:34 INT"
# After an if whose then-body did not run (34:5), the position is in
# stop's body, which ran.
in_list fixture not-covered-by-e2e "server/serve.mbt:34:17 INT"
in_list fixture covered-by-e2e "server/serve.mbt:39:25 AOR"
# A loop's body is none of the four: its position counts as stop's body,
# though the loop's own point (37:5) is 0.
in_list fixture covered-by-e2e "server/serve.mbt:37:27 AOR"
# A parameter's default value is in its function.
in_list fixture covered-by-e2e "server/serve.mbt:32:52 BOOL"
# A top-level value, outside every function, counts with its package.
in_list fixture covered-by-e2e "server/serve.mbt:50:23 INT"
# A closure is a function: main's body ran, the unused closure's did not.
in_list fixture covered-by-e2e "cmd/smock/main.mbt:8:3 DEL"
in_list fixture not-covered-by-e2e "cmd/smock/main.mbt:7:46 AOR"

# A body that the compiler starts with no point counts as none: without
# the point of the arm 0 (25:10), its position counts as serve's body.
sed 's/ 632 645 / 645 /; s/ 14 1 1 0 1 1 0 1 1 0 1 0 0 0 0 / 13 1 1 0 1 1 0 1 1 1 0 0 0 0 /; s/^BISECT-COVERAGE-4 4 16 server\/serve.mbt 14 /BISECT-COVERAGE-4 4 16 server\/serve.mbt 13 /' \
  "$fixtures/in-process.bisect" >"$tmp/no-point-in-process.bisect"
sed 's/ 632 645 / 645 /; s/ 14 1 2 0 2 0 2 2 2 0 2 1 0 0 0 / 13 1 2 0 2 0 2 2 2 2 1 0 0 0 /; s/^BISECT-COVERAGE-4 4 16 server\/serve.mbt 14 /BISECT-COVERAGE-4 4 16 server\/serve.mbt 13 /' \
  "$fixtures/e2e.bisect" >"$tmp/no-point-e2e.bisect"
report no-point "$tmp/no-point-in-process.bisect" "$tmp/no-point-e2e.bisect"
exits no-point 0
positions no-point covered-by-e2e
in_list no-point covered-by-e2e "server/serve.mbt:25:10 INT"
says no-point "| server | 31 | 23 | 8 | 24 |"
says no-point "- \`server/serve.mbt:25:10\`, a match arm in \`Server::serve\`"

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
