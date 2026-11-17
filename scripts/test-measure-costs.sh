#!/bin/sh
# Tests of the measurement of the tests' costs (scripts/measure-costs.py)
# against a fake moon and a fake moonrun, in a copy of the script beside a
# copy of engine/range.mbt, whose mutant the rebuild part applies. The fakes
# take no time and record each call, so the tests check which commands each
# part runs, in which order and on which tree, and what it writes; the
# times themselves come from the runs on CI's runners.
#
# It needs python3 and jq.
#
# usage: scripts/test-measure-costs.sh
#
# The fakes' scripts below are written with the shell's own $ and quotes,
# which this shell must leave as they are.
# shellcheck disable=SC2016
set -eu
cd "$(dirname "$0")/.."
repo=$(pwd)

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

# --- The fakes ----------------------------------------------------------------------

mkdir -p "$tmp/bin"
# The fake moon writes each call to $FAKE_LOG, with "[mutant]" before it
# when engine/range.mbt holds the rebuild part's mutant. A run of tests
# prints moon's total line: engine's tests fail with the mutant, as the
# real ones do; one e2e test alone fails when it is $FAKE_FAILING_TEST;
# every e2e run fails when $FAKE_E2E_FAILS is set.
cat >"$tmp/bin/moon" <<'EOF'
#!/bin/sh
if [ "$*" = "version --all" ]; then echo "moon 0.0.0-fake"; exit 0; fi
mutant=
if grep -q "status = 415" engine/range.mbt 2>/dev/null; then mutant="[mutant] "; fi
echo "$mutant$*" >>"$FAKE_LOG"
args=" $* "
case $args in
*" --outline "*) cat "$FAKE_OUTLINE"; exit 0 ;;
esac
if [ -n "${FAKE_FAIL_WITH_MUTANT-}" ] && [ -n "$mutant" ]; then exit 1; fi
case $args in
*" --build-only "*) exit 0 ;;
esac
case $1 in
build) exit 0 ;;
esac
case $args in
*" -i "*)
  if [ -n "${FAKE_FAILING_TEST-}" ] && [ "${args#*" $FAKE_FAILING_TEST "}" != "$args" ]; then
    echo "Total tests: 1, passed: 0, failed: 1."
    exit 2
  fi
  echo "Total tests: 1, passed: 1, failed: 0."
  exit 0 ;;
*" -p smock/smock/engine "*)
  if [ -n "$mutant" ]; then echo "Total tests: 10, passed: 7, failed: 3."; exit 2; fi ;;
*" -p smock/smock/e2e "*)
  if [ -n "${FAKE_E2E_FAILS-}" ]; then echo "Total tests: 5, passed: 4, failed: 1."; exit 2; fi ;;
esac
echo "Total tests: 5, passed: 5, failed: 0."
EOF
chmod +x "$tmp/bin/moon"

# The tree the script runs in: a copy of it, and of the file that the
# rebuild part changes.
tree=$tmp/tree
mkdir -p "$tree/scripts" "$tree/engine"
cp scripts/measure-costs.py "$tree/scripts/"
cp engine/range.mbt "$tree/engine/"

export FAKE_LOG="$tmp/moon.log"
export FAKE_OUTLINE="$tmp/outline.txt"
export PATH="$tmp/bin:$PATH"
unset MEASURE_JOB_STARTED MOON_CC MOON_AR MOON_CC_WRAPPER 2>/dev/null || true

# measure <name> <part> [option...]: runs the part in the tree, with the
# fake moon's log emptied first, its output into $tmp/<name>.out and its
# exit status into $tmp/<name>.status; what it writes goes to $tmp/<name>/.
measure() {
  name=$1
  part=$2
  shift 2
  : >"$FAKE_LOG"
  status=0
  (cd "$tree" && python3 scripts/measure-costs.py "$part" "$tmp/$name" "$@") >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
}

# exits <name> <status>: the part exited with that status.
exits() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2: $(cat "$tmp/$1.out")"
  fi
}

# holds <name> <file> <jq expression> <what>: the JSON file the part wrote
# makes the expression true.
holds() {
  if jq -e "$3" "$tmp/$1/$2" >/dev/null 2>&1; then
    pass "$1: $4"
  else
    fail "$1: not $4 ($3): $(cat "$tmp/$1/$2" 2>&1 | head -c 2000)"
  fi
}

# called <name> <expected calls>: the fake moon got exactly these calls, one
# per line, in this order.
called() {
  if [ "$(cat "$FAKE_LOG")" = "$2" ]; then
    pass "$1: runs moon as it should"
  else
    fail "$1: runs moon as $(cat "$FAKE_LOG"), not as $2"
  fi
}

# says <name> <text>: the part's output says it.
says() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    pass "$1: says \"$2\""
  else
    fail "$1: does not say \"$2\" but: $(cat "$tmp/$1.out")"
  fi
}

# --- e2e: every e2e test in one process -------------------------------------------------

MEASURE_JOB_STARTED=$(($(date +%s) - 100)) measure e2e e2e --runs 3
exits e2e 0
called e2e "build --target native cmd/smock
test --target native -p smock/smock/e2e --build-only
test --target native -p smock/smock/e2e --build-only
test --target native -p smock/smock/e2e
test --target native -p smock/smock/e2e
test --target native -p smock/smock/e2e"
holds e2e e2e.json '.ok == true' "ok"
holds e2e e2e.json '[.cmd_build, .e2e_build, .noop][] | .exit_status == 0 and .seconds >= 0' \
  "the builds and the build with nothing to do, each timed"
holds e2e e2e.json '.runs | length == 3 and all(.[]; .exit_status == 0 and .seconds >= 0
  and .tests == {"total": 5, "passed": 5, "failed": 0})' "three runs, each timed, with moon's totals"
holds e2e e2e.json '.machine.seconds_since_job_start >= 100' "how long the job had run before it"
holds e2e e2e.json '.machine | (.machine | type == "string") and .cpus > 0 and (.moon | test("0.0.0-fake"))' \
  "the machine, its CPUs and the toolchain"
if [ -s "$tmp/e2e/logs/e2e/run-1.log" ] && grep -qF "Total tests: 5" "$tmp/e2e/logs/e2e/run-1.log"; then
  pass "e2e: keeps moon's output of each run"
else
  fail "e2e: keeps no output of the first run"
fi

measure e2e-jobs e2e --runs 1 --jobs 1
called e2e-jobs "build --target native cmd/smock -j 1
test --target native -p smock/smock/e2e --build-only -j 1
test --target native -p smock/smock/e2e --build-only -j 1
test --target native -p smock/smock/e2e"

FAKE_E2E_FAILS=1 measure e2e-fails e2e --runs 2
exits e2e-fails 1
holds e2e-fails e2e.json '.ok == false and (.runs | length == 2)
  and all(.runs[]; .exit_status == 2 and .tests.failed == 1)' "not ok, with both runs and their failures"
says e2e-fails "2 of 2 runs of every e2e test failed"

MOON_CC=gcc measure moon-cc e2e --runs 1
exits moon-cc 2
says moon-cc "MOON_CC is set"
called moon-cc ""

echo
echo "test-measure-costs: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
