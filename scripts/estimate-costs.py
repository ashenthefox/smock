#!/usr/bin/env python3
"""Recomputes the cost model of the test review (#275) from what
.github/workflows/measure-costs.yml measured on CI's runners, and prints it
as Markdown, for the spec issue.

usage: python3 scripts/estimate-costs.py [--run-url URL] <dir>...

Each <dir> holds what scripts/measure-costs.py wrote on one architecture:
one of the run's artifacts, measurements-linux-amd64 or
measurements-linux-arm64. The architecture comes from the machine each part
recorded.

The formulas, for one architecture, in seconds. The constants come from the
spec's cost model (#275) unless they say otherwise; everything printed is an
estimate built on the measurements.

  E   the median of the runs of every e2e test in one process
  q   the 90th percentile of the times of each e2e test alone; without
      them, E
  T   a mutant's time limit, 1.25 E + 4 (Outcomes)
  m   a server mutant through e2e with one schema binary: one whole e2e run;
      a killed mutant's confirmation runs the failing tests again with the
      mutant on and with it off, taken as two runs of a test at q; a timed
      out one runs to T, again to T, and once without the mutant, E:
        m = E + K x 2q + F x 2T
      with K = 0.774, the share of the prototype's compiled mutants that
      were killed, and F = 8 / 250, the share that ran into the time limit
  O   what each job of a sharded run spends before its mutants: the
      checkout and the setup, the builds of cmd/smock (for the schema
      binary) and of the e2e package, and the double baseline, 2E
  The operator-level run: serially P x m, and on J jobs O + ceil(P / J) x m,
      with P = 2,617 positions in server and cmd/smock (Scope; positions
      that e2e does not cover would not run) and J = 20 jobs
  The BODY audit: O + ceil(N / J) x m, with N = 396, the top-level functions
      and trait methods in server and cmd/smock at d953f320 (counted for
      this estimate; step 2's runner gives operator set v1's own count)
  The e2e coverage job: the checkout and the setup, the binary built with
      coverage, the e2e package, E times the ratio of the native-only
      packages' test run with coverage to their plain run, and the report
  The coverage job on every push: the checkout and the setup, every build
      and run with coverage (the native-only packages, the pure packages on
      wasm-gc, yaml natively) and the report
  The weekly run: the spec's 1 to 1.2 hours, which took a runner as 1.7
      times slower than the local machine, scaled by the measured ratio of
      engine's wasm-gc mutant (rebuild and run) to the local 3.0 s

Decision 6's band (#276): a single-process e2e run of 60 s or less on
amd64, and an operator-level run of at most 2.5 hours on 20 jobs.

scripts/test-estimate-costs.sh tests this script on made-up measurements.
"""

import argparse
import json
import math
import sys
from pathlib import Path

KILLED = 0.774
TIMED_OUT = 8 / 250
POSITIONS = 2617
BODY_MUTANTS = 396
JOBS = 20
WEEKLY_HOURS = (1.0, 1.2)
WEEKLY_RUNNER_FACTOR = 1.7
LOCAL_ENGINE_WASM_GC_MUTANT = 3.0
# CI's longest job, the arm64 native tests, in #273's two runs.
CI_LONGEST_JOB = (267, 270)
BAND_E2E = 60
BAND_OPERATOR_HOURS = 2.5

ARCHITECTURES = {"x86_64": "linux/amd64", "aarch64": "linux/arm64"}


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def read(directory):
    """The parts that one architecture's measurement wrote."""
    directory = Path(directory)
    if not (directory / "e2e.json").exists():
        raise SystemExit(f"estimate-costs: {directory} has no e2e.json")
    parts = {}
    for part in ("e2e", "alone", "rebuild", "coverage"):
        path = directory / f"{part}.json"
        if path.exists():
            parts[part] = json.loads(path.read_text())
    machine = parts["e2e"]["machine"]["machine"]
    parts["name"] = ARCHITECTURES.get(machine, machine)
    return parts


def step_seconds(parts, *path):
    """The seconds of the step at path, or None when it was not measured."""
    found = parts
    for key in path:
        if not isinstance(found, dict) or key not in found:
            return None
        found = found[key]
    return found["seconds"] if found else None


def figures(parts):
    """What the estimate takes from one architecture's measurements."""
    e2e = parts["e2e"]
    runs = [run["seconds"] for run in e2e["runs"] if not run["timed_out"]]
    found = {
        "runs": runs,
        "failed_runs": sum(run["exit_status"] != 0 for run in e2e["runs"]),
        "E": median(runs) if runs else None,
        "setup": e2e["machine"].get("seconds_since_job_start") or 0.0,
        "cmd": e2e["cmd_build"]["seconds"],
        "e2e_build": e2e["e2e_build"]["seconds"],
        "alone": parts.get("alone", {}).get("summary"),
    }
    found["q"] = found["alone"]["p90_seconds"] if found["alone"] else found["E"]
    rebuild = parts.get("rebuild", {})
    native = [step_seconds(rebuild, "mutated", "engine_native_build"), step_seconds(rebuild, "mutated", "engine_native_run")]
    found["engine_native_mutant"] = sum(native) if None not in native else None
    found["cmd_mutant"] = step_seconds(rebuild, "mutated", "cmd")
    found["cmd_clean"] = step_seconds(rebuild, "clean", "cmd")
    found["W"] = step_seconds(rebuild, "mutated", "engine_wasm_gc")
    coverage = parts.get("coverage")
    found["coverage"] = coverage
    return found


def estimate(found):
    """The recomputed estimate for one architecture, in seconds."""
    E, q = found["E"], found["q"]
    limit = 1.25 * E + 4
    mutant = E + KILLED * 2 * q + TIMED_OUT * 2 * limit
    overhead = found["setup"] + found["cmd"] + found["e2e_build"] + 2 * E
    result = {
        "mutant": mutant,
        "serial": POSITIONS * mutant,
        "operator": overhead + math.ceil(POSITIONS / JOBS) * mutant,
        "body": overhead + math.ceil(BODY_MUTANTS / JOBS) * mutant,
    }
    coverage = found["coverage"]
    if coverage:
        plain, instrumented = coverage["plain"], coverage["coverage"]
        plain_run = plain["native_only"]["run"]["seconds"]
        ratio = instrumented["native_only"]["run"]["seconds"] / plain_run if plain_run > 0 else 1.0
        report = instrumented["report"]["seconds"]
        result["e2e_coverage"] = found["setup"] + instrumented["binary"]["seconds"] + found["e2e_build"] + E * ratio + report
        result["coverage_job"] = found["setup"] + report + sum(
            instrumented[name][step]["seconds"] for name in ("native_only", "wasm_gc", "yaml_native") for step in ("build", "run")
        )
    if found["W"] is not None:
        scale = found["W"] / LOCAL_ENGINE_WASM_GC_MUTANT / WEEKLY_RUNNER_FACTOR
        result["weekly"] = tuple(hours * scale for hours in WEEKLY_HOURS)
    return result


def s(value, digits=1):
    return "not measured" if value is None else f"{value:.{digits}f} s"


def measured_table(names, all_found):
    lines = ["| | " + " | ".join(names) + " | Local arm64 machine (#275) |", "|---|" + "---:|" * (len(names) + 1)]

    def row(label, values, local):
        lines.append(f"| {label} | " + " | ".join(values) + f" | {local} |")

    counts = {len(found["runs"]) for found in all_found}
    count = counts.pop() if len(counts) == 1 else None
    runs = "one run" if count == 1 else f"median of {count} runs" if count else "median of the runs"
    row(f"Every e2e test in one process, {runs}",
        [f"{found['E']:.1f} s ({min(found['runs']):.1f} to {max(found['runs']):.1f})" for found in all_found], "34.7 s")
    row("Each e2e test alone: median, 90th percentile, slowest",
        [f"{a['median_seconds']:.2f}, {a['p90_seconds']:.2f}, {a['max_seconds']:.2f} s" if a else "not measured"
         for a in (found["alone"] for found in all_found)], "not measured")
    row("The checkout and the setup", [s(found["setup"]) for found in all_found], "not measured")
    row("cmd/smock, built from clean", [s(found["cmd"]) for found in all_found], "not measured")
    row("The e2e package, built after cmd/smock", [s(found["e2e_build"]) for found in all_found],
        "76.8 s, one build job, not from clean")
    row("engine's native tests after one mutant: rebuild and run",
        [s(found["engine_native_mutant"]) for found in all_found], "33.6 s")
    row("cmd/smock after one mutant in engine: rebuild", [s(found["cmd_mutant"]) for found in all_found],
        "31.6 s, after a server mutant")
    row("engine's wasm-gc tests after one mutant: rebuild and run", [s(found["W"]) for found in all_found], "3.0 s")

    def both(name, local, label):
        values = []
        for found in all_found:
            coverage = found["coverage"]
            if not coverage:
                values.append("not measured")
                continue
            pair = []
            for mode in ("plain", "coverage"):
                result = coverage[mode][name]
                pair.append(s(result["seconds"] if "seconds" in result else result["build"]["seconds"] + result["run"]["seconds"]))
            values.append(", ".join(pair))
        row(label, values, local)

    both("native_only", "not measured, 61.7 s", "The native-only packages' tests, built and run: plain, with coverage")
    both("wasm_gc", "5.0 s, 5.6 s, every pure package",
         "The pure packages' tests on wasm-gc but yaml's, built and run: plain, with coverage")
    both("yaml_native", "not measured", "yaml's tests natively, built and run: plain, with coverage")
    both("binary", "31.9 s, 40.1 s", "The binary, built from clean: plain, with coverage")

    def planned(kind):
        values = []
        for found in all_found:
            coverage = found["coverage"]
            if not coverage:
                values.append("not measured")
                continue
            values.append(" and ".join(
                ", ".join(str(coverage[mode]["plans"][name][kind]) for name in ("native_only", "binary"))
                for mode in ("plain", "coverage")))
        return values

    row("System C compiler commands planned, plain and with coverage: native-only packages' tests, binary",
        planned("system_cc"), "not measured")
    row("tcc commands planned, plain and with coverage: native-only packages' tests, binary", planned("tcc"), "not measured")
    works = []
    for found in all_found:
        coverage = found["coverage"]
        if not coverage:
            works.append("not measured")
            continue
        report = coverage["coverage"]["report"]
        works.append(f"{'yes' if coverage['coverage']['ok'] else 'no'}, {report['covered']} of {report['points']}")
    row("The coverage build works: its tests pass, and the points it covers", works, "yes")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--run-url", help="the link of the run the measurements come from")
    parser.add_argument("directories", nargs="+", help="one architecture's measurements each")
    args = parser.parse_args()
    all_parts = [read(directory) for directory in args.directories]
    names = [parts["name"] for parts in all_parts]
    all_found = [figures(parts) for parts in all_parts]
    estimates = [estimate(found) for found in all_found]

    lines = ["## Measured on CI's runners", ""]
    if args.run_url:
        lines += [f"Run: {args.run_url}", ""]
    lines += measured_table(names, all_found)
    notes = []
    for name, found in zip(names, all_found):
        if found["failed_runs"]:
            notes.append(f"On {name}, {found['failed_runs']} of {len(found['runs'])} runs of every e2e test in one "
                         "process had failing tests; their times count.")
        if not found["alone"]:
            notes.append(f"{name} has no time of each test alone, so a kill's confirmation is taken as two whole runs there.")
    if notes:
        lines += [""] + notes

    lines += ["", "## Recomputed estimate", "", "| | The spec's estimate | " + " | ".join(names) + " |",
              "|---|---|" + "---:|" * len(names)]

    def row(label, spec, values):
        lines.append(f"| {label} | {spec} | " + " | ".join(values) + " |")

    def each(key, show):
        return [show(result[key]) if key in result else "not measured" for result in estimates]

    row("A server mutant through e2e", "about 35 s locally", each("mutant", lambda v: f"{v:.1f} s"))
    row("The operator-level run, serially", "about 25 h", each("serial", lambda v: f"{v / 3600:.2f} h"))
    row(f"The operator-level run on {JOBS} jobs", "1.5 to 2.5 h", each("operator", lambda v: f"{v / 3600:.2f} h"))
    row(f"The BODY audit on {JOBS} jobs", "not estimated", each("body", lambda v: f"{v / 60:.1f} min"))
    row("The e2e coverage job", "not estimated", each("e2e_coverage", lambda v: f"{v / 60:.1f} min"))
    row("The coverage job on every push", "about 2 to 3 min", each("coverage_job", lambda v: f"{v / 60:.1f} min"))
    row(f"The weekly run on {JOBS} shards", "about 1 to 1.2 h", each("weekly", lambda v: f"{v[0]:.2f} to {v[1]:.2f} h"))

    # The coverage job's runner: the faster one, and whether the job fits
    # beside CI's longest job, which bounds CI's wall time.
    jobs = [(round(result["coverage_job"]), name) for result, name in zip(estimates, names) if "coverage_job" in result]
    if jobs:
        fastest, where = min(jobs)
        taken = " and ".join(f"{seconds} s on {name}" for seconds, name in jobs)
        longest = f"CI's longest job, the arm64 native tests ({CI_LONGEST_JOB[0]} and {CI_LONGEST_JOB[1]} s in #273's two runs)"
        if fastest <= CI_LONGEST_JOB[0]:
            fits = f"at {fastest} s the job fits beside {longest}."
        else:
            fits = f"at {fastest} s the job takes longer than {longest}, so CI's wall time would grow."
        faster = f"{where} is faster, and {fits}" if len(jobs) > 1 else fits[0].upper() + fits[1:]
        lines += ["", f"The coverage job on every push takes {taken}. {faster}"]

    lines += ["", "## Decision 6", "",
              f"The band of decision 6: a single-process e2e run of {BAND_E2E} s or less on amd64, and an operator-level "
              f"run of at most {BAND_OPERATOR_HOURS} hours on {JOBS} jobs.", ""]
    if "linux/amd64" in names:
        index = names.index("linux/amd64")
        e2e = all_found[index]["E"]
        operator = estimates[index]["operator"] / 3600
        inside = lambda ok: "within the band" if ok else "outside the band"  # noqa: E731
        lines.append(f"- The single-process e2e run on linux/amd64: {e2e:.1f} s, {inside(e2e <= BAND_E2E)} ({BAND_E2E} s or less).")
        lines.append(f"- The operator-level run on {JOBS} jobs on linux/amd64: {operator:.2f} h, "
                     f"{inside(round(operator, 2) <= BAND_OPERATOR_HOURS)} (at most {BAND_OPERATOR_HOURS} h).")
    else:
        lines.append("- linux/amd64 was not measured, so decision 6's band cannot be read.")
    lines += ["", "How each figure is computed: scripts/estimate-costs.py."]
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
