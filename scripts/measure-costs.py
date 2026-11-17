#!/usr/bin/env python3
"""Measures on this machine what the cost model of the test review (#275)
guesses, as .github/workflows/measure-costs.yml does on CI's runners.

usage: python3 scripts/measure-costs.py <part> <out dir> [--runs N] [--jobs N]
         [--file NAME]... [--timeout S]

Each part writes <out dir>/<part>.json, keeps moon's output under
<out dir>/logs/<part>/, and exits 1 when a measurement failed, after it has
written what it measured. A time is the wall time of one moon command, from
its start to its exit, measured here.

  e2e   Builds cmd/smock and the e2e package in the default target
        directory, _build, where the e2e harness builds the binary it runs;
        builds the e2e package again, with nothing to do, which times moon's
        own work around a run; then runs every e2e test in one process,
        `--runs` times (3 by default): moon runs a package's async tests ten
        at a time, in one process.
  alone Runs each e2e test alone, in a moon process of its own, one after
        another, `--runs` times (1 by default; 0 runs none), since moon prints
        no time per test: alone.tsv has one line for each run of a test, and
        alone.json each test's times and their totals, median, 90th
        percentile (nearest rank) and slowest. `--file` keeps the tests of one
        file, and `--timeout` is the time limit of one test (300 s).
  rebuild
        In a target directory of its own, builds cmd/smock and engine's
        tests, native and wasm-gc, from clean; then applies one mutant to
        engine (MUTANT below) and times the native rebuild of engine's
        tests, their run, the rebuild of cmd/smock, which holds engine, and
        the wasm-gc rebuild and run of engine's tests. The mutant is undone
        afterwards, also when a build fails or the job is cancelled, and
        both runs must fail, or the mutant was not built.
  coverage
        Builds and runs, plain and then with --enable-coverage, each mode in
        target directories of its own and from clean: the tests of the
        native-only packages, those of the pure packages on wasm-gc but
        yaml, yaml's natively, and the binary. For each mode it also counts,
        in moon's dry run of the native-only packages' tests and of the
        binary, the commands that run the system's C compiler and those
        that run tcc: on amd64, moon's debug builds skip the system's C
        compiler. With coverage, moon_cove reports the points covered, which
        tells that the coverage build works.

It refuses to run when a variable that gives moon another C compiler, a
wrapper of it or flags is set (MOON_CC, MOON_AR, MOON_CC_WRAPPER): on amd64,
moon's native debug builds skip the system C compiler, and the measurement
is of the builds as CI's test job makes them.

scripts/estimate-costs.py recomputes the cost model from what the parts
write on two architectures. scripts/test-measure-costs.sh tests this script
against a fake moon.
"""

import argparse
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The variables through which moon takes another C compiler, a wrapper of
# it, or flags.
COMPILER_VARIABLES = ("MOON_CC", "MOON_AR", "MOON_CC_WRAPPER")

TOTALS = re.compile(r"Total tests: (\d+), passed: (\d+), failed: (\d+)\.")


def machine():
    """What a part records about the machine and the toolchain."""
    try:
        moon = subprocess.run(
            ["moon", "version", "--all"], cwd=ROOT, capture_output=True, text=True
        ).stdout.strip()
    except OSError as error:
        moon = f"moon version failed: {error}"
    started = os.environ.get("MEASURE_JOB_STARTED")
    return {
        "machine": platform.machine(),
        "cpus": os.cpu_count(),
        "moon": moon,
        # Set by the workflow at the job's start: the checkout and the setup
        # come before the first measurement.
        "seconds_since_job_start": round(time.time() - int(started), 1) if started else None,
    }


def totals(text):
    """moon's last total line in text, or None."""
    found = TOTALS.findall(text)
    if not found:
        return None
    total, passed, failed = (int(n) for n in found[-1])
    return {"total": total, "passed": passed, "failed": failed}


def timed(command, log, timeout=None):
    """Runs command in the repository, its output into log, and returns what
    happened: the command, its wall time in seconds, its exit status (None
    when it timed out) and moon's totals when it printed them. A command
    that runs past the timeout is killed with every process it started."""
    log.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    with open(log, "w") as output:
        process = subprocess.Popen(
            command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True
        )
        try:
            status = process.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            status = None
            timed_out = True
    seconds = round(time.monotonic() - start, 3)
    step = {
        "command": " ".join(command),
        "seconds": seconds,
        "exit_status": status,
        "timed_out": timed_out,
        "log": str(log),
    }
    found = totals(log.read_text(errors="replace"))
    if found:
        step["tests"] = found
    return step


def passed(step):
    return step["exit_status"] == 0


def jobs(args):
    return ["-j", str(args.jobs)] if args.jobs else []


def write(out, part, result):
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"{part}.json"
    path.write_text(json.dumps(result, indent=2) + "\n")
    return path


def part_e2e(out, args):
    logs = out / "logs" / "e2e"
    result = {"part": "e2e", "machine": machine(), "fresh_target_dir": not (ROOT / "_build").exists()}
    result["cmd_build"] = timed(["moon", "build", "--target", "native", "cmd/smock", *jobs(args)], logs / "cmd-build.log")
    build_e2e = ["moon", "test", "--target", "native", "-p", "smock/smock/e2e", "--build-only", *jobs(args)]
    result["e2e_build"] = timed(build_e2e, logs / "e2e-build.log")
    result["noop"] = timed(build_e2e, logs / "noop.log")
    result["runs"] = []
    if passed(result["cmd_build"]) and passed(result["e2e_build"]):
        for run in range(1, args.runs + 1):
            result["runs"].append(
                timed(["moon", "test", "--target", "native", "-p", "smock/smock/e2e"], logs / f"run-{run}.log")
            )
    failures = sum(not passed(run) for run in result["runs"])
    result["ok"] = passed(result["cmd_build"]) and passed(result["e2e_build"]) and failures == 0
    write(out, "e2e", result)
    if failures:
        print(f"measure-costs: {failures} of {len(result['runs'])} runs of every e2e test failed", file=sys.stderr)
    if not result["ok"]:
        return 1
    return 0


OUTLINE = re.compile(r'^\s*\d+\.\s+(\S+)\s+(\S+):(\d+)\s+index=(\d+)\s+name="(.*)"\s*$')

ALONE_METHOD = (
    "Each e2e test runs alone, in a moon test process of its own "
    "(moon test --target native e2e/<file> -i <index>), one test after another. "
    "Its time is the wall time of that command, so it holds moon's own work around "
    "a run (the e2e part's noop) and the harness's build of cmd/smock, which has "
    "nothing to do. A test that runs past the time limit is stopped with every "
    "process it started."
)


def nearest_rank(values, share):
    """The nearest-rank percentile: the smallest value that at least `share`
    of the values are at or below."""
    ordered = sorted(values)
    rank = max(1, -(-len(ordered) * share // 1))
    return ordered[int(rank) - 1]


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def part_alone(out, args):
    logs = out / "logs" / "alone"
    result = {"part": "alone", "machine": machine(), "method": ALONE_METHOD, "runs": args.runs, "tests": []}
    if args.runs == 0:
        result["ok"] = True
        write(out, "alone", result)
        return 0
    result["builds"] = [
        timed(["moon", "build", "--target", "native", "cmd/smock", *jobs(args)], logs / "cmd-build.log"),
        timed(
            ["moon", "test", "--target", "native", "-p", "smock/smock/e2e", "--build-only", *jobs(args)],
            logs / "e2e-build.log",
        ),
    ]
    outline = subprocess.run(
        ["moon", "test", "--target", "native", "-p", "smock/smock/e2e", "--outline"],
        cwd=ROOT, capture_output=True, text=True,
    ).stdout
    (logs / "outline.txt").write_text(outline)
    tests = []
    for line in outline.splitlines():
        found = OUTLINE.match(line)
        if found and (not args.file or found.group(2) in args.file):
            tests.append(
                {"file": found.group(2), "line": int(found.group(3)), "index": int(found.group(4)),
                 "name": found.group(5), "seconds": [], "failures": 0, "timed_out": 0}
            )
    result["tests"] = tests
    if not all(passed(step) for step in result["builds"]) or not tests:
        result["ok"] = False
        write(out, "alone", result)
        print("measure-costs: the e2e package did not build, or lists no test", file=sys.stderr)
        return 1
    with open(out / "alone.tsv", "w") as table:
        table.write("run\tfile\tline\tindex\tseconds\texit_status\tname\n")
        for run in range(1, args.runs + 1):
            for test in tests:
                log = logs / f"{test['file']}-{test['index']}-run-{run}.log"
                step = timed(
                    ["moon", "test", "--target", "native", f"e2e/{test['file']}", "-i", str(test["index"])],
                    log, timeout=args.timeout,
                )
                test["seconds"].append(step["seconds"])
                if step["timed_out"]:
                    test["timed_out"] += 1
                elif passed(step) and step.get("tests") == {"total": 1, "passed": 1, "failed": 0}:
                    log.unlink()
                else:
                    test["failures"] += 1
                status = "timeout" if step["timed_out"] else step["exit_status"]
                table.write(
                    f"{run}\t{test['file']}\t{test['line']}\t{test['index']}\t{step['seconds']}\t{status}\t{test['name']}\n"
                )
                table.flush()
    each = [median(test["seconds"]) for test in tests]
    failed_runs = sum(test["failures"] for test in tests)
    timed_out_runs = sum(test["timed_out"] for test in tests)
    result["summary"] = {
        "tests": len(tests),
        "test_runs": len(tests) * args.runs,
        "failed_runs": failed_runs,
        "timed_out_runs": timed_out_runs,
        # Over each test's median, when a test runs more than once.
        "total_seconds": round(sum(each), 3),
        "median_seconds": median(each),
        "p90_seconds": nearest_rank(each, 0.9),
        "max_seconds": max(each),
    }
    result["ok"] = failed_runs == 0 and timed_out_runs == 0
    write(out, "alone", result)
    if failed_runs:
        print(f"measure-costs: {failed_runs} of {len(tests) * args.runs} runs of an e2e test alone failed", file=sys.stderr)
    if timed_out_runs:
        print(f"measure-costs: {timed_out_runs} runs of an e2e test alone ran past {args.timeout} s", file=sys.stderr)
    return 0 if result["ok"] else 1


# The mutant the rebuild part applies: engine-range-001 of the mutation
# prototype's sample (#275), an INT mutant that engine's tests kill. engine
# is in cmd/smock, so the binary rebuilds too.
MUTANT = {"file": "engine/range.mbt", "original": "      status = 416\n", "replacement": "      status = 415\n"}


def part_rebuild(out, args):
    logs = out / "logs" / "rebuild"
    result = {"part": "rebuild", "machine": machine(), "mutant": MUTANT}
    source = ROOT / MUTANT["file"]
    text = source.read_text()
    count = text.count(MUTANT["original"])
    if count != 1:
        result["ok"] = False
        write(out, "rebuild", result)
        print(
            f"measure-costs: {MUTANT['file']} holds the mutant's original text {count} times, not once",
            file=sys.stderr,
        )
        return 1
    target = Path(tempfile.mkdtemp(prefix="measure-rebuild-"))
    in_target = ["--target-dir", str(target)]
    build_cmd = ["moon", "build", "--target", "native", "cmd/smock", *in_target, *jobs(args)]
    engine = ["moon", "test", "--target", "native", "-p", "smock/smock/engine"]
    engine_wasm_gc = ["moon", "test", "--target", "wasm-gc", "-p", "smock/smock/engine"]
    build_only = ["--build-only", *in_target, *jobs(args)]
    try:
        result["clean"] = {
            "cmd": timed(build_cmd, logs / "clean-cmd.log"),
            "engine_native": timed([*engine, *build_only], logs / "clean-engine-native.log"),
            "engine_wasm_gc": timed([*engine_wasm_gc, *build_only], logs / "clean-engine-wasm-gc.log"),
        }
        mutated = {}
        if all(passed(step) for step in result["clean"].values()):
            source.write_text(text.replace(MUTANT["original"], MUTANT["replacement"]))
            try:
                mutated["engine_native_build"] = timed([*engine, *build_only], logs / "engine-native-build.log")
                mutated["engine_native_run"] = timed([*engine, *in_target], logs / "engine-native-run.log")
                mutated["cmd"] = timed(build_cmd, logs / "cmd.log")
                mutated["engine_wasm_gc"] = timed([*engine_wasm_gc, *in_target], logs / "engine-wasm-gc.log")
            finally:
                source.write_text(text)
        result["mutated"] = mutated
    finally:
        shutil.rmtree(target, ignore_errors=True)
    # Both runs of engine's tests must fail with the mutant: one that no test
    # sees is not the build of a mutant this measures.
    runs = [mutated.get("engine_native_run"), mutated.get("engine_wasm_gc")]
    result["observed"] = all(run and run.get("tests", {}).get("failed", 0) > 0 for run in runs)
    builds = [*result["clean"].values(), mutated.get("engine_native_build"), mutated.get("cmd")]
    result["ok"] = all(step and passed(step) for step in builds) and result["observed"]
    write(out, "rebuild", result)
    if all(step and passed(step) for step in builds) and not result["observed"]:
        print("measure-costs: no test of engine failed with the mutant", file=sys.stderr)
    return 0 if result["ok"] else 1


# What the coverage part builds and runs: the native-only packages that have
# tests (cmd/smock has none, and the binary is built on its own), every
# pure package on wasm-gc but yaml, and yaml natively, since one of its tests
# overflows wasm-gc's stack when it is instrumented (#275, step 2).
NATIVE_ONLY = [
    "smock/smock/server", "smock/smock/defdir", "smock/smock/watch", "smock/smock/openssl",
    "smock/smock/protobuf-conformance", "smock/smock/schema",
]
WASM_GC = [
    "smock/smock/buildinfo", "smock/smock/cookies", "smock/smock/definitions", "smock/smock/engine",
    "smock/smock/importopenapi", "smock/smock/llm", "smock/smock/log", "smock/smock/metrics",
    "smock/smock/prng", "smock/smock/settings", "smock/smock/template", "smock/smock/unicode",
    "smock/smock/usage", "smock/grpc", "smock/http1", "smock/protobuf", "smock/re2", "smock/xml",
]
YAML_NATIVE = ["smock/yaml"]

# A C compiler other than tcc, by its file name: cc, gcc, clang, c++ or g++,
# with a prefix such as x86_64-linux-gnu- or a suffix such as -14.
SYSTEM_CC = re.compile(r"(?:.*-)?(?:cc|gcc|clang|c\+\+|g\+\+)(?:-[0-9.]+)?")
REPORT_TOTAL = re.compile(r"Total: (\d+)/(\d+)")


def compilers(plan):
    """How many commands a dry run's plan holds, and how many of them run
    tcc or the system's C compiler."""
    counts = {"commands": 0, "system_cc": 0, "tcc": 0}
    for line in plan.splitlines():
        words = [os.path.basename(word.strip("'\"")) for word in line.split()[:3]]
        if not words:
            continue
        counts["commands"] += 1
        if "tcc" in words:
            counts["tcc"] += 1
        elif SYSTEM_CC.fullmatch(words[0]):
            counts["system_cc"] += 1
    return counts


def planned(command, log):
    """The C compilers of the commands moon would run for command from
    clean: its dry run in an empty target directory."""
    target = Path(tempfile.mkdtemp(prefix="measure-plan-"))
    try:
        found = subprocess.run(
            [*command, "--dry-run", "--target-dir", str(target)], cwd=ROOT, capture_output=True, text=True
        )
    finally:
        shutil.rmtree(target, ignore_errors=True)
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(found.stdout + found.stderr)
    return {**compilers(found.stdout), "exit_status": found.returncode, "log": str(log)}


def coverage_mode(mode, out, args):
    """What the coverage part measures in one mode, plain or coverage."""
    logs = out / "logs" / "coverage"
    flag = ["--enable-coverage"] if mode == "coverage" else []
    native = ["moon", "test", "--target", "native", *flag]
    wasm_gc = ["moon", "test", "--target", "wasm-gc", *flag]
    binary = ["moon", "build", "--target", "native", *flag, "cmd/smock"]
    result = {
        "plans": {
            "native_only": planned([*native, "-p", *NATIVE_ONLY, "--build-only"], logs / f"{mode}-plan-native-only.txt"),
            "binary": planned(binary, logs / f"{mode}-plan-binary.txt"),
        }
    }
    target = Path(tempfile.mkdtemp(prefix=f"measure-{mode}-"))
    target_binary = Path(tempfile.mkdtemp(prefix=f"measure-{mode}-binary-"))
    in_target = ["--target-dir", str(target)]
    try:
        for name, command, packages in (
            ("native_only", native, NATIVE_ONLY),
            ("wasm_gc", wasm_gc, WASM_GC),
            ("yaml_native", native, YAML_NATIVE),
        ):
            result[name] = {
                "build": timed(
                    [*command, "-p", *packages, "--build-only", *in_target, *jobs(args)], logs / f"{mode}-{name}-build.log"
                ),
                "run": timed([*command, "-p", *packages, *in_target], logs / f"{mode}-{name}-run.log"),
            }
        result["binary"] = timed([*binary, "--target-dir", str(target_binary), *jobs(args)], logs / f"{mode}-binary.log")
        if mode == "coverage":
            # moon coverage report reads _build alone, so moon_cove, which it
            # runs, gets this target directory's traces and counters here.
            cove = Path(shutil.which("moon")).resolve().parent / "moon_cove.wasm"
            counters = []
            for log in sorted(target.glob("moonbit_coverage_*.txt")):
                counters += ["-t", str(log)]
            traces = [str(trace) for trace in sorted(target.rglob("*.trace.source"))]
            report = timed(["moonrun", str(cove), "--", *traces, *counters, "-f", "summary"], logs / "report.log")
            found = REPORT_TOTAL.search(Path(report["log"]).read_text(errors="replace"))
            report["covered"] = int(found.group(1)) if found else None
            report["points"] = int(found.group(2)) if found else None
            result["report"] = report
    finally:
        shutil.rmtree(target, ignore_errors=True)
        shutil.rmtree(target_binary, ignore_errors=True)
    steps = [result[name][step] for name in ("native_only", "wasm_gc", "yaml_native") for step in ("build", "run")]
    steps.append(result["binary"])
    if mode == "coverage":
        steps.append(result["report"])
    # A coverage build works when its tests pass and the report counts points.
    result["ok"] = all(passed(step) for step in steps) and (mode != "coverage" or (result["report"]["points"] or 0) > 0)
    return result


def part_coverage(out, args):
    result = {
        "part": "coverage",
        "machine": machine(),
        "packages": {"native_only": NATIVE_ONLY, "wasm_gc": WASM_GC, "yaml_native": YAML_NATIVE},
    }
    for mode in ("plain", "coverage"):
        result[mode] = coverage_mode(mode, out, args)
    result["ok"] = result["plain"]["ok"] and result["coverage"]["ok"]
    write(out, "coverage", result)
    for mode in ("plain", "coverage"):
        if not result[mode]["ok"]:
            print(f"measure-costs: a build, a run or the report of the {mode} mode failed", file=sys.stderr)
    return 0 if result["ok"] else 1


PARTS = {"e2e": part_e2e, "alone": part_alone, "rebuild": part_rebuild, "coverage": part_coverage}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("part", choices=sorted(PARTS))
    parser.add_argument("out", type=Path, help="the directory the part writes to")
    parser.add_argument("--runs", type=int, default=None, help="how many runs (e2e: 3)")
    parser.add_argument("--jobs", type=int, default=None, help="moon's -j for the builds")
    parser.add_argument("--file", action="append", help="alone: only the tests of this e2e file (repeatable)")
    parser.add_argument("--timeout", type=float, default=300, help="alone: the time limit of one test, in seconds")
    args = parser.parse_args()
    if args.runs is None:
        args.runs = {"e2e": 3}.get(args.part, 1)
    # A cancelled job's SIGTERM ends the part through its finally blocks,
    # which undo the rebuild part's mutant.
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    set_variables = [name for name in COMPILER_VARIABLES if name in os.environ]
    if set_variables:
        print(
            f"measure-costs: {', '.join(set_variables)} is set: the measurement is of the C "
            "compiler that moon chooses itself",
            file=sys.stderr,
        )
        return 2
    return PARTS[args.part](args.out.resolve(), args)


if __name__ == "__main__":
    sys.exit(main())
