#!/usr/bin/env python3
"""Measures on this machine what the cost model of the test review (#275)
guesses, as .github/workflows/measure-costs.yml does on CI's runners.

usage: python3 scripts/measure-costs.py <part> <out dir> [--runs N] [--jobs N]

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
import signal
import subprocess
import sys
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


PARTS = {"e2e": part_e2e}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("part", choices=sorted(PARTS))
    parser.add_argument("out", type=Path, help="the directory the part writes to")
    parser.add_argument("--runs", type=int, default=None, help="how many runs (e2e: 3)")
    parser.add_argument("--jobs", type=int, default=None, help="moon's -j for the builds")
    args = parser.parse_args()
    if args.runs is None:
        args.runs = {"e2e": 3}.get(args.part, 1)
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
