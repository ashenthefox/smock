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
# real ones do; one e2e test alone fails when it is $FAKE_FAILING_TEST,
# and hangs when it is $FAKE_HANGING_TEST;
# every e2e run fails when $FAKE_E2E_FAILS is set, and every run with
# coverage when $FAKE_COVERAGE_FAILS is. A dry run prints a plan whose C
# compiler is the system's, or with coverage tcc and the system's.
cat >"$tmp/bin/moon" <<'EOF'
#!/bin/sh
if [ "$*" = "version --all" ]; then echo "moon 0.0.0-fake"; exit 0; fi
mutant=
if grep -q "status = 415" engine/range.mbt 2>/dev/null; then mutant="[mutant] "; fi
echo "$mutant$*" >>"$FAKE_LOG"
args=" $* "
case $args in
*" --outline "*) cat "$FAKE_OUTLINE"; exit 0 ;;
*" --enable-coverage "*" --dry-run "*)
  printf '%s\n' "moonc build-package ./a.mbt -enable-coverage" "/opt/moon/bin/internal/tcc -o a.o -c a.c" \
    "/usr/bin/gcc-14 -o b.o -c b.c" "moon tool archive --output x.a"
  exit 0 ;;
*" --dry-run "*)
  printf '%s\n' "moonc build-package ./a.mbt" "/usr/bin/cc -o a.o -c a.c" "/usr/bin/cc -o b.exe b.o" \
    "moon tool archive --output x.a"
  exit 0 ;;
esac
if [ -n "${FAKE_FAIL_WITH_MUTANT-}" ] && [ -n "$mutant" ]; then exit 1; fi
case $args in
*" --build-only "*) exit 0 ;;
esac
# A run with coverage leaves what moon's runs leave in the target
# directory: the compiler's trace of the sources, and one log of counters.
case $args in
*" --enable-coverage "*)
  dir=${args#*" --target-dir "}
  dir=${dir%% *}
  mkdir -p "$dir/native/debug/test/p"
  : >"$dir/native/debug/test/p/p.trace.source"
  : >"$dir/moonbit_coverage_$$.txt"
  if [ -n "${FAKE_COVERAGE_FAILS-}" ]; then echo "Total tests: 5, passed: 4, failed: 1."; exit 2; fi ;;
esac
case $1 in
build) exit 0 ;;
esac
case $args in
*" -i "*)
  if [ -n "${FAKE_HANGING_TEST-}" ] && [ "${args#*" $FAKE_HANGING_TEST "}" != "$args" ]; then
    sleep 60
  fi
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
# moon_cove, which the fake moonrun stands for, reports a total of points.
: >"$tmp/bin/moon_cove.wasm"
cat >"$tmp/bin/moonrun" <<'EOF'
#!/bin/sh
echo "moonrun $*" >>"$FAKE_LOG"
echo "Total: 7/9"
EOF
chmod +x "$tmp/bin/moonrun"

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

# --- alone: each e2e test alone -----------------------------------------------------------

# What moon test --outline prints, for three tests in two files; a name may
# hold quotes.
cat >"$FAKE_OUTLINE" <<'EOF'
   1. smock/smock/e2e b_test.mbt:7 index=0 name="a first test"
   2. smock/smock/e2e b_test.mbt:30 index=1 name="a test that says "hello" twice"
   3. smock/smock/e2e a_test.mbt:12 index=0 name="another file's test"
EOF

measure alone alone --runs 2
exits alone 0
called alone "build --target native cmd/smock
test --target native -p smock/smock/e2e --build-only
test --target native -p smock/smock/e2e --outline
test --target native e2e/b_test.mbt -i 0
test --target native e2e/b_test.mbt -i 1
test --target native e2e/a_test.mbt -i 0
test --target native e2e/b_test.mbt -i 0
test --target native e2e/b_test.mbt -i 1
test --target native e2e/a_test.mbt -i 0"
holds alone alone.json '.ok == true and .runs == 2 and (.method | test("alone"))' "ok, with its method"
holds alone alone.json '.tests | length == 3
  and .[1] == (.[1] + {"file": "b_test.mbt", "line": 30, "index": 1, "name": "a test that says \"hello\" twice", "failures": 0, "timed_out": 0})
  and all(.[]; (.seconds | length == 2) and all(.seconds[]; . >= 0))' \
  "each test, with the time of each of its runs"
holds alone alone.json '.summary | .tests == 3 and .test_runs == 6 and .failed_runs == 0 and .timed_out_runs == 0
  and (.total_seconds, .median_seconds, .p90_seconds, .max_seconds | . >= 0)' \
  "the totals, the median, the 90th percentile and the slowest"
if [ "$(wc -l <"$tmp/alone/alone.tsv")" = 7 ] && head -1 "$tmp/alone/alone.tsv" | grep -q "^run	file	line	index	seconds	exit_status	name$"; then
  pass "alone: writes one line for each run of a test, under a header"
else
  fail "alone: alone.tsv is: $(cat "$tmp/alone/alone.tsv")"
fi

FAKE_FAILING_TEST="e2e/b_test.mbt -i 1" measure alone-fails alone --runs 2
exits alone-fails 1
holds alone-fails alone.json '.ok == false and .summary.failed_runs == 2
  and ([.tests[] | select(.failures > 0) | [.file, .index, .failures]] == [["b_test.mbt", 1, 2]])' \
  "not ok, with the test that failed and how often"
says alone-fails "2 of 6 runs of an e2e test alone failed"
if ls "$tmp/alone-fails/logs/alone/" | grep -q "b_test.mbt-1"; then
  pass "alone-fails: keeps moon's output of the test that failed"
else
  fail "alone-fails: keeps no output of the test that failed: $(ls -R "$tmp/alone-fails/logs" 2>&1)"
fi

started=$(date +%s)
FAKE_HANGING_TEST="e2e/b_test.mbt -i 0" measure alone-hangs alone --timeout 1
exits alone-hangs 1
holds alone-hangs alone.json '.summary.timed_out_runs == 1
  and ([.tests[] | select(.timed_out > 0) | [.file, .index]] == [["b_test.mbt", 0]])' \
  "the test that ran past the time limit"
if [ $(($(date +%s) - started)) -lt 30 ]; then
  pass "alone-hangs: stops the test that hangs, and what it started"
else
  fail "alone-hangs: waited for the test that hangs"
fi

measure alone-one-file alone --file a_test.mbt
exits alone-one-file 0
holds alone-one-file alone.json '[.tests[].file] == ["a_test.mbt"] and .runs == 1' "only the tests of that file, once"

measure alone-none alone --runs 0
exits alone-none 0
called alone-none ""
holds alone-none alone.json '.ok == true and .runs == 0 and .tests == []' "no test, and ok"

# --- rebuild: native rebuilds after one mutant in engine -----------------------------------

# The calls of the rebuild part, with <dir> for the one target directory it
# uses: clean builds, then the same with the mutant applied.
rebuild_calls="build --target native cmd/smock --target-dir <dir>
test --target native -p smock/smock/engine --build-only --target-dir <dir>
test --target wasm-gc -p smock/smock/engine --build-only --target-dir <dir>
[mutant] test --target native -p smock/smock/engine --build-only --target-dir <dir>
[mutant] test --target native -p smock/smock/engine --target-dir <dir>
[mutant] build --target native cmd/smock --target-dir <dir>
[mutant] test --target wasm-gc -p smock/smock/engine --target-dir <dir>"

# rebuilt <name>: the fake moon got the rebuild part's calls, each with the
# same target directory, outside the tree, which is gone afterwards; and
# engine/range.mbt is as it was.
rebuilt() {
  dir=$(sed -n 's/.*--target-dir \([^ ]*\).*/\1/p' "$FAKE_LOG" | sort -u)
  if [ "$(echo "$dir" | wc -l)" = 1 ] && [ "${dir#"$tree"}" = "$dir" ] && [ ! -e "$dir" ]; then
    pass "$1: uses one target directory of its own, and removes it"
  else
    fail "$1: uses the target directories $dir"
  fi
  called "$1" "$(echo "$rebuild_calls" | sed "s|<dir>|$dir|")"
  if cmp -s engine/range.mbt "$tree/engine/range.mbt"; then
    pass "$1: leaves engine/range.mbt as it was"
  else
    fail "$1: changed engine/range.mbt"
  fi
}

measure rebuild rebuild
exits rebuild 0
rebuilt rebuild
holds rebuild rebuild.json '.ok == true and .observed == true' "ok, and the mutant observed"
holds rebuild rebuild.json '.mutant == {"file": "engine/range.mbt", "original": "      status = 416\n", "replacement": "      status = 415\n"}' \
  "the mutant"
holds rebuild rebuild.json '[.clean.cmd, .clean.engine_native, .clean.engine_wasm_gc,
    .mutated.engine_native_build, .mutated.cmd][] | .exit_status == 0 and .seconds >= 0' \
  "each build, timed"
holds rebuild rebuild.json '[.mutated.engine_native_run, .mutated.engine_wasm_gc][]
  | .exit_status == 2 and .tests.failed == 3 and .seconds >= 0' "each run of engine's tests with the mutant, with its failures"

# The mutant's build fails: the tree is restored all the same.
FAKE_FAIL_WITH_MUTANT=1 measure rebuild-fails rebuild
exits rebuild-fails 1
rebuilt rebuild-fails
holds rebuild-fails rebuild.json '.ok == false and .observed == false' "not ok, and nothing observed"

# A mutant that no test would see is not a measurement of a mutant.
mv "$tmp/bin/moon" "$tmp/moon"
cat >"$tmp/bin/moon" <<'EOF'
#!/bin/sh
case " $* " in *" -p smock/smock/engine "*) case " $* " in *" --build-only "*) ;; *) echo "Total tests: 10, passed: 10, failed: 0."; exit 0 ;; esac ;; esac
exec "$(dirname "$0")/../moon" "$@"
EOF
chmod +x "$tmp/bin/moon"
measure rebuild-unseen rebuild
exits rebuild-unseen 1
holds rebuild-unseen rebuild.json '.ok == false and .observed == false' "not ok when no test of engine fails"
says rebuild-unseen "no test of engine failed with the mutant"
mv "$tmp/moon" "$tmp/bin/moon"

# The text the mutant changes is gone: nothing is built.
sed -i 's/status = 416/status = 0 + 416/' "$tree/engine/range.mbt"
measure rebuild-no-text rebuild
exits rebuild-no-text 1
says rebuild-no-text "engine/range.mbt holds the mutant's original text 0 times, not once"
called rebuild-no-text ""
cp engine/range.mbt "$tree/engine/"

# --- coverage: builds and runs with coverage and without ------------------------------

native_only="smock/smock/server smock/smock/defdir smock/smock/watch smock/smock/openssl smock/smock/protobuf-conformance smock/smock/schema"
wasm_gc="smock/smock/buildinfo smock/smock/cookies smock/smock/definitions smock/smock/engine smock/smock/importopenapi smock/smock/llm smock/smock/log smock/smock/metrics smock/smock/prng smock/smock/settings smock/smock/template smock/smock/unicode smock/smock/usage smock/grpc smock/http1 smock/protobuf smock/re2 smock/xml"

# The calls of one mode, with <cov> for its flag, <plan1> and <plan2> for
# the dry runs' target directories, <dir> for its tests' and <bin> for the
# binary's.
mode_calls="test --target native<cov> -p $native_only --build-only --dry-run --target-dir <plan1>
build --target native<cov> cmd/smock --dry-run --target-dir <plan2>
test --target native<cov> -p $native_only --build-only --target-dir <dir>
test --target native<cov> -p $native_only --target-dir <dir>
test --target wasm-gc<cov> -p $wasm_gc --build-only --target-dir <dir>
test --target wasm-gc<cov> -p $wasm_gc --target-dir <dir>
test --target native<cov> -p smock/yaml --build-only --target-dir <dir>
test --target native<cov> -p smock/yaml --target-dir <dir>
build --target native<cov> cmd/smock --target-dir <bin>"

# covered <name>: the fake moon got the calls of the plain mode, then those
# of the coverage mode and the report, each mode in target directories of
# its own, outside the tree and gone afterwards.
covered() {
  dirs=$(sed -n 's/.*--target-dir \([^ ]*\).*/\1/p' "$FAKE_LOG" | awk '!seen[$0]++')
  set -- "$1" $dirs
  if [ $# != 9 ]; then
    fail "$1: uses $(($# - 1)) target directories, not 8: $dirs"
    return
  fi
  # The counters, one log for each run with coverage.
  counters=$(sed -n 's/^moonrun .*\.trace\.source \(.*\) -f summary$/\1/p' "$FAKE_LOG")
  called "$1" "$(echo "$mode_calls" | sed "s|<cov>||; s|<plan1>|$2|; s|<plan2>|$3|; s|<dir>|$4|; s|<bin>|$5|")
$(echo "$mode_calls" | sed "s|<cov>| --enable-coverage|; s|<plan1>|$6|; s|<plan2>|$7|; s|<dir>|$8|; s|<bin>|$9|")
moonrun $tmp/bin/moon_cove.wasm -- $8/native/debug/test/p/p.trace.source $counters -f summary"
  if echo "$counters" | grep -qE "^(-t ${8}/moonbit_coverage_[0-9]+\.txt ?){3}$"; then
    pass "$1: reports the counters of the coverage mode's three runs"
  else
    fail "$1: reports the counters $counters"
  fi
  shift
  for dir in "$@"; do
    if [ -e "$dir" ] || [ "${dir#"$tree"}" != "$dir" ]; then
      fail "$1: leaves a target directory, or uses one in the tree: $dir"
      return
    fi
  done
  pass "coverage: uses target directories of its own, and removes them"
}

measure coverage coverage
exits coverage 0
covered coverage
holds coverage coverage.json '.ok == true' "ok"
holds coverage coverage.json "(.packages.native_only | join(\" \")) == \"$native_only\"
  and (.packages.wasm_gc | join(\" \")) == \"$wasm_gc\" and .packages.yaml_native == [\"smock/yaml\"]" \
  "the packages of each build"
holds coverage coverage.json '[.plain, .coverage][] | [.native_only, .wasm_gc, .yaml_native][] | [.build, .run][]
  | .exit_status == 0 and .seconds >= 0' "each build and run of each mode, timed"
holds coverage coverage.json '[.plain, .coverage][] | [.native_only, .wasm_gc, .yaml_native][] | .run.tests.total == 5' \
  "moon's totals of each run"
holds coverage coverage.json '[.plain.binary, .coverage.binary][] | .exit_status == 0 and .seconds >= 0' \
  "the binary in each mode, timed"
holds coverage coverage.json '.plain.plans | (.native_only | del(.log)) == (.binary | del(.log))
  and (.native_only | .system_cc == 2 and .tcc == 0 and .commands == 4)' \
  "the plain plans' C compiler commands: the system's"
holds coverage coverage.json '.coverage.plans.native_only | .system_cc == 1 and .tcc == 1 and .commands == 4' \
  "the coverage plans' C compiler commands: tcc and the system's"
holds coverage coverage.json '.coverage.report | .exit_status == 0 and .covered == 7 and .points == 9' \
  "the report's total of points covered"
holds coverage coverage.json '.plain | has("report") | not' "no report of the plain mode"

FAKE_COVERAGE_FAILS=1 measure coverage-fails coverage
exits coverage-fails 1
holds coverage-fails coverage.json '.ok == false and .coverage.native_only.run.tests.failed == 1
  and .plain.native_only.run.exit_status == 0' "not ok, with both modes"

echo
echo "test-measure-costs: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
