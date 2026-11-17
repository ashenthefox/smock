#!/bin/sh
# Tests of the recomputed cost model (scripts/estimate-costs.py) on made-up
# measurements of two architectures, in the shape that
# scripts/measure-costs.py writes. Each expected value was worked out by
# hand from the formulas and constants in estimate-costs.py's docstring,
# which come from the cost model of #275; the working is beside each case.
#
# It needs python3.
#
# usage: scripts/test-estimate-costs.sh
set -eu
cd "$(dirname "$0")/.."

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

# measurements <dir> <machine> <setup> <cmd build> <e2e build> <runs> <p90>
#   <rebuild: engine native build, run, cmd, engine wasm-gc>
#   <coverage, plain then with coverage: native-only build, run, wasm-gc
#   build, run, yaml build, run, binary> <report> <covered> <points>
#   <C compiler commands planned, plain then with coverage: native-only
#   system, tcc, binary system, tcc; then the native-only packages' test
#   programs started, plain then with coverage: as executables, through tcc>
# writes the four parts' files of one architecture into <dir>; the runs are
# comma-separated, and a p90 of "-" leaves the part alone out.
measurements() {
  python3 - "$@" <<'EOF'
import json, sys
from pathlib import Path

(out, machine, setup, cmd_build, e2e_build, runs, p90, native_build, native_run, cmd, wasm_gc,
 coverage, report, covered, points, plans) = sys.argv[1:]
out = Path(out)
out.mkdir(parents=True)

def step(seconds, status=0, tests=None):
    found = {"command": "moon ...", "seconds": float(seconds), "exit_status": status, "timed_out": False, "log": "x.log"}
    if tests:
        found["tests"] = dict(zip(("total", "passed", "failed"), tests))
    return found

def write(part, result):
    result["part"] = part
    result["machine"] = {"machine": machine, "cpus": 4, "moon": "moon 0.0.0", "seconds_since_job_start": float(setup)}
    (out / f"{part}.json").write_text(json.dumps(result))

write("e2e", {"cmd_build": step(cmd_build), "e2e_build": step(e2e_build), "noop": step(0.5),
              "runs": [step(run, 0, (637, 637, 0)) for run in runs.split(",")], "ok": True})
if p90 != "-":
    write("alone", {"runs": 1, "tests": [], "ok": True, "summary": {
        "tests": 637, "test_runs": 637, "failed_runs": 0, "timed_out_runs": 0,
        "total_seconds": 300.0, "median_seconds": 0.5, "p90_seconds": float(p90), "max_seconds": 9.0}})
write("rebuild", {"clean": {"cmd": step(cmd_build), "engine_native": step(30), "engine_wasm_gc": step(3)},
                  "mutated": {"engine_native_build": step(native_build), "engine_native_run": step(native_run, 2, (684, 673, 11)),
                              "cmd": step(cmd), "engine_wasm_gc": step(wasm_gc, 2, (684, 673, 11))},
                  "observed": True, "ok": True})
times = [float(t) for t in coverage.split(",")]
counts = [int(c) for c in plans.split(",")]
result = {"ok": True}
for mode, (nb, nr, wb, wr, yb, yr, b), (ns, nt, bs, bt), (se, st) in (
        ("plain", times[:7], counts[:4], counts[8:10]), ("coverage", times[7:], counts[4:8], counts[10:])):
    result[mode] = {
        "native_only": {"build": step(nb), "run": step(nr, 0, (300, 300, 0)),
                        "started": {"executables": se, "tcc": st}},
        "wasm_gc": {"build": step(wb), "run": step(wr, 0, (1500, 1500, 0))},
        "yaml_native": {"build": step(yb), "run": step(yr, 0, (200, 200, 0))},
        "binary": step(b),
        "plans": {"native_only": {"commands": 40, "system_cc": ns, "tcc": nt},
                  "binary": {"commands": 20, "system_cc": bs, "tcc": bt}},
        "ok": True}
result["coverage"]["report"] = {**step(report), "covered": int(covered), "points": int(points)}
write("coverage", result)
EOF
}

# estimate <name> <dir>...: runs the estimate, its output into $tmp/<name>.out
# and its exit status into $tmp/<name>.status.
estimate() {
  name=$1
  shift
  status=0
  python3 scripts/estimate-costs.py "$@" >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
}

# says <name> <line>: the output holds the line, whole.
says() {
  if grep -qxF -- "$2" "$tmp/$1.out"; then
    pass "$1: says \"$2\""
  else
    fail "$1: does not say \"$2\" but:
$(cat "$tmp/$1.out")"
  fi
}

exits() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2: $(cat "$tmp/$1.out")"
  fi
}

# amd64: setup 30 s, cmd/smock 50 s, e2e package 100 s, runs 40, 44, 42 s
# (median E = 42), p90 alone q = 2.0 s; engine's wasm-gc mutant W = 4.5 s;
# coverage: native-only 30+10 plain, 40+15 coverage (run ratio 15/10 = 1.5),
# wasm-gc 5+3 and 6+5, yaml 2+1 and 5+2, binary 40 and 60, report 3 s.
measurements "$tmp/amd64" x86_64 30 50 100 40,44,42 2.0 8 2 9 4.5 \
  30,10,5,3,2,1,40,40,15,6,5,5,2,60 3 7 9 0,12,0,1,0,12,0,1,0,6,0,6
# arm64: setup 40, cmd/smock 150, e2e 250, runs 70, 71, 70 (E = 70), q = 3.0,
# W = 5.1; coverage: native-only 90+12 and 110+18 (ratio 1.5), wasm-gc 6+4
# and 7+6, yaml 4+1.5 and 6+2, binary 120 and 140, report 4 s.
measurements "$tmp/arm64" aarch64 40 150 250 70,71,70 3.0 35 2.5 33 5.1 \
  90,12,6,4,4,1.5,120,110,18,7,6,6,2,140 4 8 9 30,0,30,0,30,0,30,0,6,0,6,0

estimate both --run-url https://github.com/hirunefu/smock/actions/runs/1 "$tmp/amd64" "$tmp/arm64"
exits both 0
says both "Run: https://github.com/hirunefu/smock/actions/runs/1"

# --- What was measured ---------------------------------------------------------------

says both "| Every e2e test in one process, median of 3 runs | 42.0 s (40.0 to 44.0) | 70.0 s (70.0 to 71.0) | 34.7 s |"
says both "| Each e2e test alone: median, 90th percentile, slowest | 0.50, 2.00, 9.00 s | 0.50, 3.00, 9.00 s | not measured |"
says both "| The checkout and the setup | 30.0 s | 40.0 s | not measured |"
says both "| cmd/smock, built from clean | 50.0 s | 150.0 s | not measured |"
says both "| The e2e package, built after cmd/smock | 100.0 s | 250.0 s | 76.8 s, one build job, not from clean |"
# 8 + 2 and 35 + 2.5
says both "| engine's native tests after one mutant: rebuild and run | 10.0 s | 37.5 s | 33.6 s |"
says both "| cmd/smock after one mutant in engine: rebuild | 9.0 s | 33.0 s | 31.6 s, after a server mutant |"
says both "| engine's wasm-gc tests after one mutant: rebuild and run | 4.5 s | 5.1 s | 3.0 s |"
# 30 + 10 and 40 + 15; 90 + 12 and 110 + 18
says both "| The native-only packages' tests, built and run: plain, with coverage | 40.0 s, 55.0 s | 102.0 s, 128.0 s | not measured, 61.7 s |"
says both "| The pure packages' tests on wasm-gc but yaml's, built and run: plain, with coverage | 8.0 s, 11.0 s | 10.0 s, 13.0 s | 5.0 s, 5.6 s, every pure package |"
says both "| yaml's tests natively, built and run: plain, with coverage | 3.0 s, 7.0 s | 5.5 s, 8.0 s | not measured |"
says both "| The binary, built from clean: plain, with coverage | 40.0 s, 60.0 s | 120.0 s, 140.0 s | 31.9 s, 40.1 s |"
says both "| System C compiler commands planned, plain and with coverage: native-only packages' tests, binary | 0, 0 and 0, 0 | 30, 30 and 30, 30 | not measured |"
says both "| tcc commands planned, plain and with coverage: native-only packages' tests, binary | 12, 1 and 12, 1 | 0, 0 and 0, 0 | not measured |"
says both "| The native-only packages' test programs, started plain and with coverage: as executables, through tcc | 0, 6 and 0, 6 | 6, 0 and 6, 0 | not measured |"
says both "| The coverage build works: its tests pass, and the points it covers | yes, 7 of 9 | yes, 8 of 9 | yes |"

# --- The recomputed estimate -------------------------------------------------------------

# A server mutant: m = E + 0.774 x 2q + 2 x 0.032 x (1.25E + 4).
# amd64: 42 + 3.096 + 0.064 x 56.5 = 42 + 3.096 + 3.616 = 48.712.
# arm64: 70 + 4.644 + 0.064 x 91.5 = 70 + 4.644 + 5.856 = 80.5.
says both "| A server mutant through e2e | about 35 s locally | 48.7 s | 80.5 s |"
# 2,617 x m: 127,479.304 s = 35.41 h; 210,668.5 s = 58.52 h.
says both "| The operator-level run, serially | about 25 h | 35.41 h | 58.52 h |"
# Each job: setup + cmd/smock + e2e package + 2E, then ceil(2617 / 20) = 131
# mutants. amd64: 30 + 50 + 100 + 84 = 264, + 131 x 48.712 = 6,645.272 s
# = 1.85 h. arm64: 40 + 150 + 250 + 140 = 580, + 131 x 80.5 = 11,125.5 s
# = 3.09 h.
says both "| The operator-level run on 20 jobs | 1.5 to 2.5 h | 1.85 h | 3.09 h |"
# ceil(396 / 20) = 20 mutants a job: 264 + 974.24 = 1,238.24 s = 20.6 min;
# 580 + 1,610 = 2,190 s = 36.5 min.
says both "| The BODY audit on 20 jobs | not estimated | 20.6 min | 36.5 min |"
# setup + binary with coverage + e2e package + E x 1.5 + report:
# 30 + 60 + 100 + 63 + 3 = 256 s = 4.3 min; 40 + 140 + 250 + 105 + 4 = 539 s
# = 9.0 min.
says both "| The e2e coverage job | not estimated | 4.3 min | 9.0 min |"
# setup + every coverage build and run + report: 30 + 55 + 11 + 7 + 3 = 106 s
# = 1.8 min; 40 + 128 + 13 + 8 + 4 = 193 s = 3.2 min.
says both "| The coverage job on every push | about 2 to 3 min | 1.8 min | 3.2 min |"
# (1.0 to 1.2 h) x (W / 3.0) / 1.7: x 0.882 = 0.88 to 1.06 h; x 1.0.
says both "| The weekly run on 20 shards | about 1 to 1.2 h | 0.88 to 1.06 h | 1.00 to 1.20 h |"

says both "The coverage job on every push takes 106 s on linux/amd64 and 193 s on linux/arm64. linux/amd64 is faster, and at 106 s the job fits beside CI's longest job, the arm64 native tests (267 and 270 s in #273's two runs)."

# --- Decision 6 -------------------------------------------------------------------------------

says both "- The single-process e2e run on linux/amd64: 42.0 s, within the band (60 s or less)."
says both "- The operator-level run on 20 jobs on linux/amd64: 1.85 h, within the band (at most 2.5 h)."

# --- Outside the band ----------------------------------------------------------------------

# Runs 64, 66, 65: E = 65, T = 85.25, m = 65 + 3.096 + 5.456 = 73.552; each
# job 30 + 50 + 100 + 130 = 310, + 131 x 73.552 = 9,945.312 s = 2.76 h.
measurements "$tmp/slow" x86_64 30 50 100 64,66,65 2.0 8 2 9 4.5 \
  30,10,5,3,2,1,40,40,15,6,5,5,2,60 3 7 9 0,12,0,1,0,12,0,1,0,6,0,6
estimate slow "$tmp/slow" "$tmp/arm64"
exits slow 0
says slow "- The single-process e2e run on linux/amd64: 65.0 s, outside the band (60 s or less)."
says slow "- The operator-level run on 20 jobs on linux/amd64: 2.76 h, outside the band (at most 2.5 h)."

# --- At the band's limits, and just past them ---------------------------------------------

# The e2e run at 60 s is within the band, and at 60.1 s outside.
measurements "$tmp/at-60" x86_64 30 50 100 60,60,60 2.0 8 2 9 4.5 \
  30,10,5,3,2,1,40,40,15,6,5,5,2,60 3 7 9 0,12,0,1,0,12,0,1,0,6,0,6
estimate at-60 "$tmp/at-60"
says at-60 "- The single-process e2e run on linux/amd64: 60.0 s, within the band (60 s or less)."
measurements "$tmp/past-60" x86_64 30 50 100 60.1,60.1,60.1 2.0 8 2 9 4.5 \
  30,10,5,3,2,1,40,40,15,6,5,5,2,60 3 7 9 0,12,0,1,0,12,0,1,0,6,0,6
estimate past-60 "$tmp/past-60"
says past-60 "- The single-process e2e run on linux/amd64: 60.1 s, outside the band (60 s or less)."

# With E = 42, a job spends 50 + 100 + 84 + 131 x 48.712 = 6,615.272 s
# besides its setup; a setup of 2,384.728 s makes the run 9,000 s, 2.50 h,
# within the band, and 36 s more 9,036 s, 2.51 h, outside it.
measurements "$tmp/at-2.5" x86_64 2384.728 50 100 40,44,42 2.0 8 2 9 4.5 \
  30,10,5,3,2,1,40,40,15,6,5,5,2,60 3 7 9 0,12,0,1,0,12,0,1,0,6,0,6
estimate at-2.5 "$tmp/at-2.5"
says at-2.5 "- The operator-level run on 20 jobs on linux/amd64: 2.50 h, within the band (at most 2.5 h)."
measurements "$tmp/past-2.5" x86_64 2420.728 50 100 40,44,42 2.0 8 2 9 4.5 \
  30,10,5,3,2,1,40,40,15,6,5,5,2,60 3 7 9 0,12,0,1,0,12,0,1,0,6,0,6
estimate past-2.5 "$tmp/past-2.5"
says past-2.5 "- The operator-level run on 20 jobs on linux/amd64: 2.51 h, outside the band (at most 2.5 h)."

# The coverage job fits beside CI's longest job up to its 267 s: with the
# native-only packages' coverage build at 201 s, 30 + 216 + 11 + 7 + 3 = 267
# s; at 202 s, 268 s.
measurements "$tmp/job-267" x86_64 30 50 100 40,44,42 2.0 8 2 9 4.5 \
  30,10,5,3,2,1,40,201,15,6,5,5,2,60 3 7 9 0,12,0,1,0,12,0,1,0,6,0,6
estimate job-267 "$tmp/job-267"
says job-267 "The coverage job on every push takes 267 s on linux/amd64. At 267 s the job fits beside CI's longest job, the arm64 native tests (267 and 270 s in #273's two runs)."
measurements "$tmp/job-268" x86_64 30 50 100 40,44,42 2.0 8 2 9 4.5 \
  30,10,5,3,2,1,40,202,15,6,5,5,2,60 3 7 9 0,12,0,1,0,12,0,1,0,6,0,6
estimate job-268 "$tmp/job-268"
says job-268 "The coverage job on every push takes 268 s on linux/amd64. At 268 s the job takes longer than CI's longest job, the arm64 native tests (267 and 270 s in #273's two runs), so CI's wall time would grow."

# --- Without the times of each test alone -------------------------------------------------

# A kill's confirmation is then two whole runs: q = E, so m = 42 + 0.774 x 84
# + 3.616 = 42 + 65.016 + 3.616 = 110.632.
measurements "$tmp/no-alone" x86_64 30 50 100 40,44,42 - 8 2 9 4.5 \
  30,10,5,3,2,1,40,40,15,6,5,5,2,60 3 7 9 0,12,0,1,0,12,0,1,0,6,0,6
estimate no-alone "$tmp/no-alone" "$tmp/arm64"
exits no-alone 0
says no-alone "| A server mutant through e2e | about 35 s locally | 110.6 s | 80.5 s |"
says no-alone "linux/amd64 has no time of each test alone, so a kill's confirmation is taken as two whole runs there."

# --- What it cannot use ------------------------------------------------------------------

estimate no-dir "$tmp/no-such-dir"
exits no-dir 1
if grep -qF "no-such-dir has no e2e.json" "$tmp/no-dir.out"; then
  pass "no-dir: says which directory has no measurement"
else
  fail "no-dir: says $(cat "$tmp/no-dir.out")"
fi

estimate only-arm64 "$tmp/arm64"
exits only-arm64 0
says only-arm64 "- linux/amd64 was not measured, so decision 6's band cannot be read."

echo
echo "test-estimate-costs: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
