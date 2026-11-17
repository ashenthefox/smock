#!/bin/sh
# Tests of the script that runs the e2e tests a given number of times
# (scripts/repeat-e2e.sh), which the e2e repeat workflow runs: that it runs
# moon's e2e tests once for each run, from the repository's root, whatever
# a run gave; that it keeps each run's output; that its summary says which
# runs passed, which failed and why, and which tests failed in which runs;
# that it exits with 1 when a run failed; and that it refuses wrong
# arguments.
#
# moon is a fake that answers each run as the test tells it, so no test
# runs: FAKE_RUNS lists, for each run in turn and separated by `;`, `pass`,
# `crash` (exit status 3, with no test named), or the failed tests, as
# `<file>:<line>=<name>`, joined by `+`. For the run that the time limit stops, a fake timeout
# exits as timeout does then, without running moon. It needs nothing but a
# POSIX shell and the tools the script uses.
#
# usage: scripts/test-repeat-e2e.sh
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)

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

# The fake moon. It logs its arguments and the directory it runs in, one
# line for each run, to $tmp/moon.log, and counts the runs in $tmp/count.
mkdir "$tmp/bin"
cat >"$tmp/bin/moon" <<'SH'
#!/bin/sh
n=$(($(cat "$FAKE_DIR/count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/count"
echo "$(pwd) $*" >>"$FAKE_DIR/moon.log"
outcome=$(echo "$FAKE_RUNS" | cut -d ';' -f "$n")
echo "the output of run $n"
case $outcome in
pass)
  echo "Total tests: 3, passed: 3, failed: 0."
  exit 0
  ;;
crash)
  echo "error: the test process ended"
  exit 3
  ;;
esac
echo "$outcome" | tr '+' '\n' | while IFS='=' read -r test name; do
  echo "[smock/smock] test $test (\"$name\") failed"
  echo "expect test failed at $test"
done
echo "Total tests: 3, passed: 1, failed: 2."
exit 2
SH
chmod +x "$tmp/bin/moon"
export FAKE_DIR="$tmp"

# The fake timeout, for the run that the time limit stops.
mkdir "$tmp/stopping"
cat >"$tmp/stopping/timeout" <<'SH'
#!/bin/sh
echo "$*" >"$FAKE_DIR/timeout.args"
exit 124
SH
chmod +x "$tmp/stopping/timeout"

# repeat <name> <FAKE_RUNS> <arguments>...: runs the script with the fakes,
# its output into $tmp/<name>.out and its exit status into
# $tmp/<name>.status, with the run count and moon's log reset.
repeat() {
  name=$1
  export FAKE_RUNS="$2"
  shift 2
  rm -f "$tmp/count" "$tmp/moon.log"
  status=0
  PATH="$tmp/bin:$PATH" scripts/repeat-e2e.sh "$@" >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
}

# expect_status <name> <status>
expect_status() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2: $(cat "$tmp/$1.out")"
  fi
}

# expect_file <name> <file> <expected text>: the file holds exactly the text.
expect_file() {
  if [ ! -f "$2" ]; then
    fail "$1: wrote no $2"
  elif [ "$(cat "$2")" = "$3" ]; then
    pass "$1: $(basename "$2") is as expected"
  else
    fail "$1: $(basename "$2") is not as expected:
--- expected
$3
--- written
$(cat "$2")"
  fi
}

# expect_output <name> <text>: the script printed a line with the text.
expect_output() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    pass "$1: says \"$2\""
  else
    fail "$1: does not say \"$2\" but: $(cat "$tmp/$1.out")"
  fi
}

# --- Every run passes ----------------------------------------------------------

repeat all-pass "pass;pass;pass" 3 "$tmp/all-pass"
expect_status all-pass 0
expect_file all-pass "$tmp/all-pass/summary.md" "# e2e tests, 3 runs

- run 1: passed
- run 2: passed
- run 3: passed

Every run passed."
expect_file all-pass "$tmp/moon.log" "$root test --target native -p smock/smock/e2e
$root test --target native -p smock/smock/e2e
$root test --target native -p smock/smock/e2e"
for n in 1 2 3; do
  expect_file all-pass "$tmp/all-pass/run-$n.log" "the output of run $n
Total tests: 3, passed: 3, failed: 0."
done
if [ "$(find "$tmp/all-pass" -type f | wc -l)" -eq 4 ]; then
  pass "all-pass: leaves only the logs and the summary"
else
  fail "all-pass: leaves other files: $(find "$tmp/all-pass" -type f)"
fi
expect_output all-pass "repeat-e2e: run 3 of 3: passed"

# The logs sort in the order of the runs.
repeat twelve-runs "pass;pass;pass;pass;pass;pass;pass;pass;pass;pass;pass;pass" 12 "$tmp/twelve"
expect_status twelve-runs 0
if [ -f "$tmp/twelve/run-01.log" ] && [ -f "$tmp/twelve/run-12.log" ] && [ ! -f "$tmp/twelve/run-1.log" ]; then
  pass "twelve-runs: names the logs run-01.log to run-12.log"
else
  fail "twelve-runs: names the logs $(ls "$tmp/twelve")"
fi

# A directory relative to where the script is started from.
mkdir "$tmp/elsewhere"
(
  cd "$tmp/elsewhere"
  rm -f "$tmp/count"
  FAKE_RUNS=pass PATH="$tmp/bin:$PATH" "$root/scripts/repeat-e2e.sh" 1 relative >/dev/null 2>&1
) && status=0 || status=$?
if [ "$status" -eq 0 ] && [ -f "$tmp/elsewhere/relative/summary.md" ]; then
  pass "relative: writes into a directory relative to where it is started"
else
  fail "relative: exits with $status, and writes: $(ls -R "$tmp/elsewhere")"
fi

# --- Runs that fail --------------------------------------------------------------

repeat some-fail \
  "pass;e2e/a_test.mbt:10=a test+e2e/b_test.mbt:20=b: \"quoted\";e2e/a_test.mbt:10=a test" \
  3 "$tmp/some-fail"
expect_status some-fail 1
expect_file some-fail "$tmp/some-fail/summary.md" '# e2e tests, 3 runs

- run 1: passed
- run 2: failed (exit status 2): e2e/a_test.mbt:10, e2e/b_test.mbt:20
- run 3: failed (exit status 2): e2e/a_test.mbt:10

2 of 3 runs failed.

The tests that failed, with the runs they failed in:

- e2e/a_test.mbt:10 ("a test"): 2, 3
- e2e/b_test.mbt:20 ("b: "quoted""): 2'
if [ "$(wc -l <"$tmp/moon.log")" -eq 3 ]; then
  pass "some-fail: runs on after a failed run"
else
  fail "some-fail: ran moon $(wc -l <"$tmp/moon.log") times, not 3"
fi
if grep -qF '[smock/smock] test e2e/b_test.mbt:20 ("b: "quoted"") failed' "$tmp/some-fail/run-2.log"; then
  pass "some-fail: keeps what the failed run printed"
else
  fail "some-fail: run-2.log is: $(cat "$tmp/some-fail/run-2.log")"
fi
expect_output some-fail "repeat-e2e: run 2 of 3: failed (exit status 2): e2e/a_test.mbt:10, e2e/b_test.mbt:20"

# A run that ends badly without naming a test.
repeat crash "crash;pass" 2 "$tmp/crash"
expect_status crash 1
expect_file crash "$tmp/crash/summary.md" "# e2e tests, 2 runs

- run 1: failed (exit status 3)
- run 2: passed

1 of 2 runs failed."

# A run that the time limit stops.
rm -f "$tmp/timeout.args"
status=0
FAKE_RUNS=pass PATH="$tmp/stopping:$tmp/bin:$PATH" scripts/repeat-e2e.sh --run-limit 5 1 "$tmp/stopped" >"$tmp/stopped.out" 2>&1 || status=$?
echo "$status" >"$tmp/stopped.status"
expect_status stopped 1
expect_file stopped "$tmp/stopped/summary.md" "# e2e tests, 1 runs

- run 1: failed, stopped after 5 minutes

1 of 1 runs failed."
expect_file stopped "$tmp/timeout.args" "--kill-after=30s 5m moon test --target native -p smock/smock/e2e"

# --- Wrong arguments ---------------------------------------------------------------

for case in "no-arguments|" "one-argument|3" "three-arguments|3 $tmp/x y" \
  "limit-without-runs|--run-limit 5"; do
  name=${case%%|*}
  # shellcheck disable=SC2086 # the arguments are split on purpose
  repeat "$name" pass ${case#*|}
  expect_status "$name" 2
  expect_output "$name" "usage: scripts/repeat-e2e.sh [--run-limit <minutes>] <runs> <directory>"
done
for runs in 0 01 -3 x 1001 2.5 ""; do
  repeat "runs-$runs" pass "$runs" "$tmp/wrong"
  expect_status "runs-$runs" 2
  expect_output "runs-$runs" "the number of runs should be a whole number from 1 to 1000, not: $runs"
done
for limit in 0 x 361; do
  repeat "limit-$limit" pass --run-limit "$limit" 1 "$tmp/wrong"
  expect_status "limit-$limit" 2
  expect_output "limit-$limit" "--run-limit should be a whole number of minutes from 1 to 360, not: $limit"
done
if [ ! -e "$tmp/wrong" ] && [ ! -e "$tmp/moon.log" ]; then
  pass "wrong arguments: run nothing and write nothing"
else
  fail "wrong arguments: ran moon or wrote $tmp/wrong"
fi

echo
echo "test-repeat-e2e: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
