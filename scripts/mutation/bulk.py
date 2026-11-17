#!/usr/bin/env python3
"""The steps of a bulk run of the mutation runner on GitHub Actions
(.github/workflows/mutation-runs.yml; CONTRIBUTING.md, "Mutation runner",
"Bulk runs on Actions"): the plan, which chooses the run's mutants and
cuts them into shards; a shard's run; and the finish, which merges the
shards' outputs into one report.

usage: python3 scripts/mutation/bulk.py plan --out <dir> [--root <dir>] [--mode <mode>]
           [--schedule <cron>] [--packages "<package directory>..."] [--set pinned|full]
           [--seed <s>] [--size <n>] [--list <file>] [--width <n>] [--workers <n>]
           [--seconds-per-mutant <s>] [--flakes <file>]
       python3 scripts/mutation/bulk.py shard --plan <plan.json> --name <shard> --out <dir>
           [--root <dir>] [--work <dir>] [--moon <moon>]
       python3 scripts/mutation/bulk.py finish --plan <plan.json> --out <dir> [--jobs <file>]
           [--run-url <url>] <shard's out>...
       python3 scripts/mutation/bulk.py stale --out <file> [--root <dir>] [--moonc <moonc>]
       python3 scripts/mutation/bulk.py seeds --out <dir> [--root <dir>] [--moon <moon>]
       python3 scripts/mutation/bulk.py triage --report <dir> --out <dir> [--max <n>]
           [--bodies <dir>] [--run-url <url>]

A mode is what the run runs (MODES); the packages are the pure packages
that have sites unless given (with a list, those of the listed files): a
pure package is one whose code builds on wasm-gc (changed.py), and one
with no site, such as testcerts, which is data, has nothing to mutate.
The weekly run is the pinned set over them, which L4 is defined over; the
monthly run, the full set, report-only. A scheduled run takes its mode
from its schedule (SCHEDULES), and an option given as empty, as GitHub
gives a scheduled run's inputs, takes its default.

plan   runs the runner with --sites-only on the mode's selection, which
       runs no mutant, and cuts the mutants into shards: as many as the
       width, or as many as it takes for each shard's mutants, at the
       planned time a mutant (--seconds-per-mutant), to take at most
       BUDGET_S of a job's six hours, and never more shards than mutants
       or than a matrix of jobs holds (MAX_JOBS). The mode timing has one
       shard, the whole selection, run three times, with 1, 2 and 4
       mutants built and tested at once. It writes plan.json, which the
       shards and the finish read, and plan.md, and prints the outputs
       that the workflow's matrix reads, as name=value lines for
       $GITHUB_OUTPUT: shards (a JSON list of each shard's name, index,
       count and mutants at once), width (how many run at once) and mode.
       A weekly run copies --flakes, the flake records of the latest weekly
       run, into the plan, for each shard to read; the first weekly run has
       none.

shard  runs one shard of the plan's run, named as the plan names it,
       with run.py, writing its output into <out>, and bulk.json beside
       it: the shard, its mutants at once, the runner's machine, how long
       run.py took and how it exited. It exits as run.py does.

finish merges the shards' outputs with merge.py into <out>, and starts
       the report with the run: its link, its selection, its shards, its
       times (from --jobs, the run's jobs as GitHub's API gives them, one
       JSON object per line: name, started_at, completed_at, conclusion)
       and a line per package. For the mode timing, it compares the three
       runs instead: their times per mutant, and whether each mutant had
       the same outcome in each. It prints the report, and exits with 1
       when a shard is missing or the shards do not merge. A job that did
       not succeed, such as the canary, a shard whose self-test failed or
       the properties with random seeds, makes the report a failed run's.

stale  lists the stale entries of the exclusion list (exclusions.py) into
       <out>, for their re-triage in a batch, and prints stale=<count>.

seeds  writes a random seed into each property's seed constant in the
       working copy at <root> (scripts/random-seeds.py), runs each test
       file that holds one, on wasm-gc in a pure package and natively in
       another, and writes report.md: each seed, and for each failure the
       test's output and how to run it again with that seed. It prints the
       report, and exits with 1 when a property failed.

triage cuts the unexplained survivors of a weekly run's merged output
       (stale-covered ones included) into triage tickets for each of stage
       1's closing tickets (STAGE_1) that has more than --max of them
       (about 40): at most --max each, a source file that holds fewer never
       split. It writes, into <out>, a body for each ticket, tickets.json
       and tickets.md; each body carries the closing ticket's triage
       criteria, from <bodies>/<number>.md when it is given.
"""

import argparse
import datetime
import json
import math
import platform
import posixpath
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import changed
import exclusions
import ratchet

HERE = Path(__file__).resolve().parent
RUN = HERE / "run.py"
MERGE = HERE / "merge.py"
RANDOM_SEEDS = HERE.parent / "random-seeds.py"

# What a run runs, by its mode, and how its report names it.
MODES = {
    "sample": "a seeded sample",
    "body": "a BODY pass",
    "packages": "chosen packages",
    "list": "a listed set",
    "matrix": "a kill matrix",
    "timing": "mutants side by side on one runner",
    "weekly": "the weekly run",
    "monthly": "the monthly run",
}
# The schedules of .github/workflows/mutation-runs.yml, and the run each
# starts: at a quiet hour, away from the weekly run with the latest MoonBit
# (Mondays, 03:17 UTC), and the monthly run hours after the weekly one when
# the 1st is a Friday.
SCHEDULES = {
    "23 20 * * 5": "weekly",
    "43 22 1 * *": "monthly",
}
# The packages that the monthly run takes besides the pure packages. Step
# 5 (#346) adds the small native-only ones here, defdir, watch, openssl and
# protobuf-conformance, which the runner runs wholly natively, and a job of
# its own for server and cmd/smock through e2e.
MONTHLY_NATIVE_ONLY = ()
# Stage 1's closing tickets, each with its packages (decision 1).
STAGE_1 = (
    (323, ("yaml",)),
    (324, ("http1",)),
    (325, ("xml",)),
    (326, ("re2",)),
    (327, ("grpc",)),
    (328, ("cookies", "metrics", "usage", "prng")),
    (329, ("settings",)),
)
# What every triage ticket waits for: this ticket (#314) and the held-out
# set's first measurement (#315); and settings', its in-process tests
# (#320).
BLOCKERS = (314, 315)
SETTINGS_BLOCKER = {329: 320}
# The criteria of a closing ticket that its triage tickets carry.
TRIAGE_CRITERIA = ("Triage", "Kills", "Exclusions", "Code", "No weakening")
# How many unexplained survivors a triage ticket holds at most (#275:
# "about 40").
TRIAGE_MAX = 40
# The account's concurrent jobs, which a run at full width holds.
MAX_WIDTH = 20
# The most jobs a matrix of GitHub Actions makes.
MAX_JOBS = 256
# How long a job may run on GitHub's runners is six hours; a shard's
# mutants take at most five of them, which leaves the rest for the
# checkout, the setup and the runs without a mutant.
BUDGET_S = 5 * 3600
# The planned time of a mutant on an amd64 runner, kill confirmation
# included: the costliest package's tests, engine's, took about 3 s a
# mutant on wasm-gc on a laptop (#275's cost model), a runner is about
# 1.7 times slower, and a kill is built and run three times; a mutant at
# an unchecked access also runs natively. Bulk runs set it from their
# times.
SECONDS_PER_MUTANT = 20
# The mutants at once that the mode timing compares.
TIMING_WORKERS = (1, 2, 4)
# The sample's default size: the baseline's.
SAMPLE_SIZE = 1000


class BulkError(Exception):
    """What stops a step: a selection the runner refuses, or shards that do
    not make a run."""


def width_spec(text):
    """The width, for argparse: how many shards run at once; all of them
    when it is given as empty."""
    if text == "":
        return MAX_WIDTH
    try:
        width = int(text)
    except ValueError:
        width = 0
    if not 1 <= width <= MAX_WIDTH:
        raise argparse.ArgumentTypeError(f"{text!r} is not a number from 1 to {MAX_WIDTH}")
    return width


def positive_or(default):
    """A whole number from 1, for argparse, or the default when it is given
    as empty."""
    return lambda text: default if text == "" else positive(text)


def or_default(default):
    """A text for argparse, or the default when it is given as empty."""
    return lambda text: text or default


def positive(text):
    """A whole number from 1, for argparse."""
    try:
        value = int(text)
    except ValueError:
        value = 0
    if value < 1:
        raise argparse.ArgumentTypeError(f"{text!r} is not a whole number from 1")
    return value


def pure_packages(root):
    """The packages of the workspace at root whose code builds on wasm-gc,
    sorted: those that have sites among them are the run's packages."""
    modules = changed.members(root)
    return [d for d in ratchet.packages(root) if changed.is_pure(root, d, modules)]


def selection_args(args, packages):
    """The runner's options that make the mode's selection of packages."""
    if args.mode == "weekly":
        return ["--set", "pinned", *packages]
    if args.mode == "monthly":
        return ["--set", "full", *packages]
    common = ["--set", args.set]
    if args.mode in ("sample", "timing"):
        return [*common, "--sample", str(args.size), "--seed", args.seed, *packages]
    if args.mode == "body":
        return [*common, "--operator", "BODY", *packages]
    if args.mode == "matrix":
        return ["--matrix", *common, *packages]
    if args.mode == "list":
        return ["--list", args.list, *packages]
    return [*common, *packages]


def sites_only(root, options, out):
    """Runs the runner with --sites-only: its summary and chosen mutants."""
    with tempfile.TemporaryDirectory(prefix="bulk-plan-") as work:
        result = subprocess.run([sys.executable, str(RUN), "--root", str(root), "--work", work, "--out", str(out),
                                 "--sites-only", *options], capture_output=True, text=True)
    if result.returncode != 0:
        raise BulkError(f"run.py --sites-only {shlex.join(options)} failed:\n{result.stderr.strip()}")
    summary = json.loads((out / "summary.json").read_text(encoding="utf-8"))
    chosen = [json.loads(line) for line in (out / "chosen.jsonl").read_text(encoding="utf-8").splitlines()
              if line.strip()]
    return summary, chosen


def shard_count(mutants, width, seconds_per_mutant):
    """How many shards a run of so many mutants takes: the width, or more
    when a shard would take longer than BUDGET_S, and never more than the
    mutants (one shard for none). More shards than the width run in waves,
    as jobs come free, so their count is a multiple of the width, which
    fills each wave: a last shard alone would double the run's time."""
    if seconds_per_mutant > BUDGET_S:
        raise BulkError(f"a mutant planned at {seconds_per_mutant} s does not fit in a shard's {BUDGET_S} s")
    per_shard = BUDGET_S // seconds_per_mutant
    count = max(min(width, mutants), math.ceil(mutants / per_shard), 1)
    if count > width:
        count = min(math.ceil(count / width) * width, mutants)
    if count > MAX_JOBS:
        raise BulkError(f"{mutants} mutants at {seconds_per_mutant} s each need {count} shards of at most"
                        f" {per_shard}, more than the {MAX_JOBS} jobs a matrix holds: choose fewer mutants")
    return count


def describe(plan):
    """What a run runs, in words."""
    count = len(plan["packages"])
    over = f"over {count} package{'s' if count != 1 else ''}"
    the_set = f"the {plan['set']} set"
    if plan["mode"] in ("sample", "timing"):
        return f"a seeded sample of {plan['size']} mutants (seed {plan['seed']}) of {the_set} {over}"
    if plan["mode"] == "body":
        return f"the BODY mutant of every function of {the_set} {over}"
    if plan["mode"] == "matrix":
        return f"a kill matrix of {the_set} {over}"
    if plan["mode"] == "list":
        return f"the mutants that {plan['list']} lists, {over}"
    return f"{the_set} {over}"


def describe_shards(plan):
    """How a run is cut into shards, in words."""
    if plan["mode"] == "timing":
        return ("in one shard, run three times, each on a runner of its own, with "
                + ", ".join(str(w) for w in TIMING_WORKERS[:-1]) + f" and {TIMING_WORKERS[-1]} mutants at a time")
    count, workers = len(plan["shards"]), plan["shards"][0]["workers"]
    return (f"in {count} shard{'s' if count != 1 else ''}, at most {plan['width']} at once, {workers}"
            f" mutant{'s' if workers != 1 else ''} at a time on each runner")


def plan_run(args):
    """Writes the plan into args.out; returns it."""
    root = Path(args.root).resolve()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.schedule:
        if args.schedule not in SCHEDULES:
            raise BulkError(f"no run is planned for the schedule {args.schedule}: the schedules are "
                            + ", ".join(f"{cron} ({mode})" for cron, mode in SCHEDULES.items()))
        args.mode = SCHEDULES[args.schedule]
    if args.mode == "list" and not args.list:
        raise BulkError("--mode list needs --list")
    if args.mode in ("weekly", "monthly"):
        args.set = "pinned" if args.mode == "weekly" else "full"
    given = args.packages.replace(",", " ").split()
    packages = given
    if not given and args.mode != "list":
        candidates = pure_packages(root)
        summary, _ = sites_only(root, ["--set", args.set, *candidates], out / "candidates")
        having = {p["directory"] for p in summary["packages"] if p["sets"]["full"]["sites"]}
        packages = [d for d in candidates if d in having]
        if args.mode == "monthly":
            packages += [d for d in MONTHLY_NATIVE_ONLY if d not in packages]
    options = selection_args(args, packages)
    summary, chosen = sites_only(root, options, out / "sites")
    mutants = len(chosen)
    if args.mode == "timing":
        shards = [{"name": f"workers-{w}", "index": 1, "count": 1, "workers": w} for w in TIMING_WORKERS]
        width = min(args.width, len(shards))
    else:
        count = shard_count(mutants, args.width, args.seconds_per_mutant)
        shards = [{"name": f"{k}-of-{count}", "index": k, "count": count, "workers": args.workers}
                  for k in range(1, count + 1)]
        width = min(args.width, count)
    # The packages the run is over: those given or found, or, for a list
    # alone, those of its mutants. A sample may leave some with none.
    directories = packages or [p["directory"] for p in summary["packages"]]
    per_package = {}
    for directory in directories:
        mine = [s for s in chosen if s.get("file", "").rsplit("/", 1)[0] == directory]
        per_package[directory] = {"mutants": len(mine),
                                  "unchecked_access": sum(1 for s in mine if s.get("unchecked_access"))}
    plan = {
        "mode": args.mode,
        "set": "listed" if args.mode == "list" else args.set,
        "size": args.size,
        "seed": args.seed,
        "list": args.list,
        "packages": directories,
        "args": options,
        "mutants": mutants,
        "per_package": per_package,
        "shards": shards,
        "width": width,
        "seconds_per_mutant": args.seconds_per_mutant,
        "budget_s": BUDGET_S,
        "flakes": None,
    }
    if args.mode == "weekly" and args.flakes and Path(args.flakes).is_file():
        shutil.copyfile(args.flakes, out / "flakes.json")
        plan["flakes"] = "flakes.json"
    (out / "plan.json").write_text(json.dumps(plan, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    lines = [f"# Plan: {MODES[args.mode]}", "",
             f"{describe(plan)[0].upper()}{describe(plan)[1:]}: {mutants} mutant{'s' if mutants != 1 else ''},"
             f" {describe_shards(plan)}.", "",
             f"run.py {shlex.join(options)}", "",
             "| package | mutants | at an unchecked access |", "|---|---:|---:|"]
    lines += [f"| {d} | {p['mutants']} | {p['unchecked_access']} |" for d, p in per_package.items()]
    if args.mode == "weekly":
        lines += ["", "Each shard reads the flake records of the latest weekly run." if plan["flakes"] else
                  "No flake records of an earlier weekly run: each shard starts with none."]
    (out / "plan.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"shards={json.dumps(shards, separators=(',', ':'))}")
    print(f"width={width}")
    print(f"mode={args.mode}")
    return plan


def run_shard(args):
    """Runs one shard of the plan; returns run.py's exit status."""
    plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
    shard = next((s for s in plan["shards"] if s["name"] == args.name), None)
    if shard is None:
        raise BulkError(f"the plan has no shard {args.name}: it has " + ", ".join(s["name"] for s in plan["shards"]))
    out = Path(args.out)
    command = [sys.executable, str(RUN), "--root", str(Path(args.root).resolve()), "--out", str(out),
               "--moon", args.moon, *plan["args"], "--shard", f"{shard['index']}/{shard['count']}",
               "--workers", str(shard["workers"])]
    if args.work:
        command += ["--work", str(Path(args.work).resolve())]
    if plan.get("flakes"):
        command += ["--flakes", str(Path(args.plan).resolve().parent / plan["flakes"])]
    started = time.monotonic()
    status = subprocess.run(command).returncode
    wall = time.monotonic() - started
    out.mkdir(parents=True, exist_ok=True)
    (out / "bulk.json").write_text(json.dumps(
        {"name": shard["name"], "index": shard["index"], "count": shard["count"], "workers": shard["workers"],
         "machine": platform.machine(), "wall_s": round(wall, 3), "status": status}, indent=2) + "\n",
        encoding="utf-8")
    return status


def duration(seconds):
    """A time in hours, minutes and seconds, those that are not 0."""
    seconds = round(seconds)
    parts = [(seconds // 3600, "h"), (seconds % 3600 // 60, "min"), (seconds % 60, "s")]
    shown = [f"{n} {unit}" for n, unit in parts if n]
    return " ".join(shown) if shown else "0 s"


def moment(text):
    """A time as GitHub's API writes it."""
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


def times_line(jobs):
    """The report's line of a run's wall and runner times, from its jobs
    that have ended."""
    ended = [j for j in jobs if j.get("started_at") and j.get("completed_at")]
    if not ended:
        return None
    starts = [moment(j["started_at"]) for j in ended]
    ends = [moment(j["completed_at"]) for j in ended]
    wall = (max(ends) - min(starts)).total_seconds()
    runner = sum((e - s).total_seconds() for s, e in zip(starts, ends))
    return (f"Wall time {duration(wall)}, from the first job's start to the last job's end; runner time"
            f" {duration(runner)}, the {len(ended)} jobs' times added up.")


def failed_line(jobs):
    """The report's line of the jobs that ended without success, or None."""
    failed = [j["name"] for j in jobs if j.get("completed_at") and j.get("conclusion") not in ("success", "skipped")]
    if not failed:
        return None
    return ("**The run failed.** These jobs did not succeed: " + ", ".join(failed) + ". A failed canary,"
            " self-test or property seed is a failure of the run.")


def rate(score):
    """A kill rate as the report writes it."""
    return "none" if score is None else f"{score:.1%}"


def package_rows(summary):
    """The report's line per package, and one for them all."""
    rows = []
    total = {k: 0 for k in ("mutants", "killed", "timed_out", "survived", "unexplained", "stale", "unviable",
                            "unconfirmed", "pseudo", "body", "skipped")}
    for package in summary["packages"]:
        if "mutants" not in package:
            continue
        # A stale-covered survivor counts as unexplained, as L4 counts it.
        found = package.get("exclusions", {})
        stale = found.get("stale_covered", 0)
        unexplained = found.get("unexplained", package["survived"] if not found else 0) + stale
        cells = {"mutants": package["mutants"], "killed": package["killed"], "timed_out": package["timed_out"],
                 "survived": package["survived"], "unexplained": unexplained, "stale": stale,
                 "unviable": package["unviable"], "unconfirmed": package["unconfirmed"],
                 "pseudo": len(package.get("pseudo_tested", [])), "body": package.get("body_mutants", 0),
                 "skipped": sum(package["skipped"].values())}
        for key, value in cells.items():
            total[key] += value
        rows.append((package["package"], cells, package["score"]))
    judged = total["killed"] + total["timed_out"] + total["survived"]
    rows.append(("all", total, round((total["killed"] + total["timed_out"]) / judged, 4) if judged else None))
    out = ["| package | mutants | killed | timed out | survived | unexplained | of them stale-covered | unviable"
           " | unconfirmed | kill rate | pseudo-tested | skipped sites |",
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for name, cells, score in rows:
        pseudo = f"{cells['pseudo']} of {cells['body']}" if cells["body"] else "none ran"
        out += [f"| {name} | {cells['mutants']} | {cells['killed']} | {cells['timed_out']} | {cells['survived']}"
                f" | {cells['unexplained']} | {cells['stale']} | {cells['unviable']} | {cells['unconfirmed']}"
                f" | {rate(score)} | {pseudo} | {cells['skipped']} |"]
    return out


def unexplained(record):
    """Whether a record is a survivor that counts as unexplained: one that
    no current entry other than DEFERRED covers, a stale-covered one
    included."""
    return record.get("outcome") == "survived" and record.get("exclusion", {}).get("status") != "accepted"


def read_records(path):
    """The records of a run's output."""
    path = Path(path)
    if not path.is_file():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def alternative_rows(summary, records):
    """The report's lines of a full set's unexplained survivors per
    package, at the pinned alternatives and at the others apart."""
    out = ["| package | unexplained at the pinned alternatives | at the other alternatives |", "|---|---:|---:|"]
    for package in summary["packages"]:
        mine = [r for r in records if r["package"] == package["package"] and unexplained(r)]
        out += [f"| {package['package']} | {sum(1 for r in mine if r.get('pinned'))}"
                f" | {sum(1 for r in mine if not r.get('pinned'))} |"]
    return out


def read_jobs(path):
    """The run's jobs, one JSON object per line."""
    if not path:
        return []
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def link(url):
    """The run's link, or words when there is none."""
    return f"[The run on GitHub Actions]({url})" if url else "The run"


def finish_run(args):
    """Merges the shards' outputs into args.out and writes the report;
    returns the report."""
    plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
    out = Path(args.out)
    if plan["mode"] == "timing":
        return finish_timing(plan, args, out)
    result = subprocess.run([sys.executable, str(MERGE), "--out", str(out), *args.shards], capture_output=True,
                            text=True)
    if result.returncode != 0:
        raise BulkError(result.stderr.strip().removeprefix("merge: "))
    summary = json.loads((out / "summary.json").read_text(encoding="utf-8"))
    merged = (out / "report.md").read_text(encoding="utf-8")
    walls = []
    for shard in args.shards:
        done = Path(shard) / "bulk.json"
        if done.is_file():
            walls.append(json.loads(done.read_text(encoding="utf-8")))
    jobs = read_jobs(args.jobs)
    lines = [f"# Mutation run: {MODES[plan['mode']]}", "",
             f"{link(args.run_url)}: {describe(plan)}, {describe_shards(plan)}.", ""]
    failed = failed_line(jobs)
    if failed:
        lines += [failed, ""]
    if plan["mode"] == "monthly":
        lines += ["This run is report-only: its survivors at the other alternatives stop no merge and no release,"
                  " and do not count towards L4 (decision 7).", ""]
    times = times_line(jobs)
    if times:
        lines += [times, ""]
    if walls:
        longest = max(walls, key=lambda w: w["wall_s"])
        lines += [f"The longest shard's run took {duration(longest['wall_s'])} (shard {longest['name']}), on"
                  f" {longest['machine']}.", ""]
    lines += package_rows(summary) + ["", "Stale-covered survivors, and those that a DEFERRED entry covers, count"
                                      " as unexplained, as L4 counts them. The kill rate is reported, never"
                                      " gated. Each package's section below gives the sites each rule skipped,"
                                      " its survivors, with the entry of each stale-covered one, and its"
                                      " pseudo-tested functions.", ""]
    if plan["set"] == "full":
        lines += alternative_rows(summary, read_records(out / "mutants.jsonl")) + [""]
    if plan["mode"] == "weekly" and "flakes" in summary:
        read = summary["flakes"].get("runs_read", 0)
        lines += [f"This run read the flake records of {read} earlier run{'s' if read != 1 else ''}." if read else
                  "This run read no flake records of an earlier run.", ""]
    report = "\n".join(lines) + "\n" + merged
    (out / "report.md").write_text(report, encoding="utf-8")
    return report


def finish_timing(plan, args, out):
    """Compares the timing's three runs: writes timing.json and the
    report; returns the report."""
    runs = []
    for shard in args.shards:
        done = json.loads((Path(shard) / "bulk.json").read_text(encoding="utf-8"))
        records = [json.loads(line) for line in (Path(shard) / "mutants.jsonl").read_text(encoding="utf-8")
                   .splitlines() if line.strip()]
        runs.append((done, {r["id"]: r["outcome"] for r in records}))
    runs.sort(key=lambda r: r[0]["workers"])
    if [r[0]["workers"] for r in runs] != list(TIMING_WORKERS):
        raise BulkError("the timing needs one run with each of " + ", ".join(map(str, TIMING_WORKERS))
                        + " mutants at once, and has " + ", ".join(str(r[0]["workers"]) for r in runs))
    first = runs[0][0]["wall_s"]
    rows = []
    for done, outcomes in runs:
        count = len(outcomes)
        rows.append({"workers": done["workers"], "mutants": count, "wall_s": done["wall_s"],
                     "per_mutant_s": round(done["wall_s"] / count, 3) if count else None,
                     "speed_up": round(first / done["wall_s"], 2) if done["wall_s"] else None,
                     "machine": done["machine"]})
    out.mkdir(parents=True, exist_ok=True)
    (out / "timing.json").write_text(json.dumps({"plan": plan, "runs": rows}, indent=2, ensure_ascii=False) + "\n",
                                     encoding="utf-8")
    differ = sorted({i for _, outcomes in runs for i in outcomes
                     if len({o.get(i) for _, o in runs}) > 1})
    lines = ["# Mutants side by side on one runner", "",
             f"{link(args.run_url)}: {describe(plan)}, {describe_shards(plan)}.", "",
             "| mutants at once | mutants | the shard's run | per mutant | against one at a time |",
             "|---:|---:|---:|---:|---:|"]
    for row in rows:
        lines += [f"| {row['workers']} | {row['mutants']} | {duration(row['wall_s'])} |"
                  f" {row['per_mutant_s']:.1f} s | {row['speed_up']:.2f} |"]
    lines += [""]
    if differ:
        lines += ["The runs gave these mutants different outcomes:", ""]
        lines += [f"- `{i}`: " + ", ".join(f"{d['workers']} at once {o.get(i, 'not run')}" for d, o in runs)
                  for i in differ]
    else:
        lines += ["The three runs gave each mutant the same outcome."]
    times = times_line(read_jobs(args.jobs))
    if times:
        lines += ["", times]
    report = "\n".join(lines) + "\n"
    (out / "report.md").write_text(report, encoding="utf-8")
    return report


def stale_run(args):
    """Writes the stale entries of the exclusion list into args.out;
    returns their count."""
    root = Path(args.root).resolve()
    entries, problems = exclusions.read_list(root)
    if problems and not entries:
        raise BulkError("; ".join(problems))
    files = {e.file for e in entries if isinstance(e.file, str)}
    found = exclusions.definitions(root, files, args.moonc)
    stale = [e for e in entries if exclusions.stale(e, found)]
    count = len(stale)
    lines = ["# Stale entries of the exclusion list", ""]
    if stale:
        lines += [f"{count} {'entry' if count == 1 else 'entries'} of the exclusion list {'is' if count == 1 else 'are'}"
                  " stale: the text of the definition named changed since the entry was made, or the definition"
                  " is gone. A survivor that only a stale entry covers counts as unexplained in the weekly run"
                  " and for L4 until its entry is triaged again, in a batch (CONTRIBUTING.md, \"Exclusions\").",
                  ""]
        lines += [f"- `{e.key}` ({e.category})" for e in stale]
    else:
        lines += ["No entry of the exclusion list is stale."]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"stale={count}")
    return count


SEED_LINE = re.compile(r"^(?P<file>.+):(?P<line>\d+): (?P<name>[A-Z][A-Z0-9_]*_SEED) = (?P<seed>\d+)$")


def seeds_run(args):
    """Runs the properties with random seeds; returns the report and
    whether every property passed."""
    root = Path(args.root).resolve()
    moon = shlex.split(args.moon)
    written = subprocess.run([sys.executable, str(RANDOM_SEEDS)], cwd=root, capture_output=True, text=True)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    lines = ["# Properties with random seeds", ""]
    if written.returncode == 1:
        lines += ["No property has a seed constant, so none ran."]
        report = "\n".join(lines) + "\n"
        (out / "report.md").write_text(report, encoding="utf-8")
        return report, True
    if written.returncode != 0:
        raise BulkError(f"random-seeds.py failed:\n{written.stdout}{written.stderr}".strip())
    seeds = [m.groupdict() for m in map(SEED_LINE.match, written.stdout.splitlines()) if m]
    modules = changed.members(root)
    results = {}
    for file in dict.fromkeys(s["file"] for s in seeds):
        target = "wasm-gc" if changed.is_pure(root, posixpath.dirname(file), modules) else "native"
        run = subprocess.run([*moon, "test", "--target", target, file], cwd=root, capture_output=True, text=True)
        results[file] = (target, run)
    passed = all(run.returncode == 0 for _, run in results.values())
    lines += ["Each property ran with the random seed written into its seed constant in this run's working copy"
              " (CONTRIBUTING.md, \"Seeds\").", ""]
    for seed in seeds:
        target, run = results[seed["file"]]
        where = f"- {seed['file']}:{seed['line']}: `{seed['name']}` = {seed['seed']}"
        if run.returncode == 0:
            lines += [f"{where}: passed."]
        else:
            lines += [f"{where}: failed. To run it again, set `{seed['name']}` to {seed['seed']} and run"
                      f" `moon test --target {target} {seed['file']}`."]
    for file, (target, run) in results.items():
        if run.returncode != 0:
            lines += ["", f"## {file}", "", "```", (run.stdout + run.stderr).strip(), "```"]
    report = "\n".join(lines) + "\n"
    (out / "report.md").write_text(report, encoding="utf-8")
    return report, passed


def closing_criteria(bodies, number):
    """The triage criteria of a closing ticket, from its body when bodies
    holds it: the lines of its acceptance criteria that TRIAGE_CRITERIA
    name; None without it."""
    if not bodies or not (Path(bodies) / f"{number}.md").is_file():
        return None
    text = (Path(bodies) / f"{number}.md").read_text(encoding="utf-8")
    found = []
    for line in text.splitlines():
        for label in TRIAGE_CRITERIA:
            if re.match(rf"- \[ \] \*\*{re.escape(label)}[.*]", line):
                found.append(line)
    return found


def cut(survivors, most):
    """The survivors of one closing ticket, in order, cut into tickets of
    at most most survivors, by source file: a file that holds at most most
    is never split, and one that holds more is cut into equal parts."""
    files = {}
    for record in survivors:
        files.setdefault(record["file"], []).append(record)
    tickets, current = [], []
    for file, mine in files.items():
        if len(mine) > most:
            if current:
                tickets.append(current)
                current = []
            parts = math.ceil(len(mine) / most)
            size = math.ceil(len(mine) / parts)
            tickets += [mine[i:i + size] for i in range(0, len(mine), size)]
            continue
        if len(current) + len(mine) > most:
            tickets.append(current)
            current = []
        current += mine
    if current:
        tickets.append(current)
    return tickets


def triage_body(number, packages, ticket, part, criteria, run_url, blocked_by):
    """The body of a triage ticket."""
    files = list(dict.fromkeys(r["file"] for r in ticket))
    count = len(ticket)
    run = f"[the weekly run]({run_url})" if run_url else "the weekly run"
    lines = ["## Parent", "", f"#{number}", "", "## What to build", "",
             f"Part {part} of the triage of {' and '.join(packages)}'s survivors for #{number}, in stage 1 of #275:"
             f" the {count} unexplained survivor{'s' if count != 1 else ''} of {run} in {', '.join(files)}."
             " Stale-covered survivors, and those that a DEFERRED entry covers, count as unexplained.", "",
             "## Survivors", ""]
    lines += [f"- `{r['id']}`" for r in ticket]
    lines += ["", "## Acceptance criteria", "", f"For the {count} survivor{'s' if count != 1 else ''} above only.", ""]
    if criteria is None:
        lines += [f"- [ ] #{number}'s criteria Triage, Kills, Exclusions, Code and No weakening, as #{number}"
                  " states them."]
    else:
        lines += criteria
    lines += ["- [ ] The agent time spent is recorded on this ticket when it closes.", "", "## Blocked by", ""]
    lines += [f"- #{n}" for n in blocked_by]
    lines += ["", "## Blocks", "", f"- #{number}"]
    return "\n".join(lines) + "\n"


def triage_run(args):
    """Writes stage 1's triage tickets; returns the summary."""
    records = read_records(Path(args.report) / "mutants.jsonl")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    tickets, rows = [], []
    for number, packages in STAGE_1:
        survivors = sorted((r for r in records if unexplained(r) and posixpath.dirname(r["file"]) in packages),
                           key=lambda r: (packages.index(posixpath.dirname(r["file"])), r["file"],
                                          r.get("line", 0), r["id"]))
        if len(survivors) <= args.max:
            rows.append(f"| #{number} | {', '.join(packages)} | {len(survivors)} | none: triaged in #{number} |")
            continue
        cuts = cut(survivors, args.max)
        rows.append(f"| #{number} | {', '.join(packages)} | {len(survivors)} | {len(cuts)} |")
        criteria = closing_criteria(args.bodies, number)
        blocked_by = [*BLOCKERS, *([SETTINGS_BLOCKER[number]] if number in SETTINGS_BLOCKER else [])]
        for part, ticket in enumerate(cuts, 1):
            files = list(dict.fromkeys(r["file"] for r in ticket))
            mine = list(dict.fromkeys(posixpath.dirname(f) for f in files))
            name = f"{number}-{part}.md"
            (out / name).write_text(triage_body(number, mine, ticket, f"{part} of {len(cuts)}", criteria,
                                                args.run_url, blocked_by), encoding="utf-8")
            tickets.append({"closing": number, "packages": mine, "files": files,
                            "survivors": [r["id"] for r in ticket],
                            "title": f"Triage the survivors of {' and '.join(mine)} in {', '.join(files)}"
                                     f" ({part} of {len(cuts)})",
                            "labels": ["ready-for-agent"], "blocked_by": blocked_by, "blocks": number,
                            "body": name})
    (out / "tickets.json").write_text(json.dumps(tickets, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    summary = "\n".join(["# Stage 1's triage tickets", "",
                         f"At most {args.max} unexplained survivors a ticket, a source file that holds fewer never"
                         " split.", "", "| closing ticket | packages | unexplained survivors | triage tickets |",
                         "|---|---|---:|---|", *rows]) + "\n"
    (out / "tickets.md").write_text(summary, encoding="utf-8")
    return summary


def main():
    parser = argparse.ArgumentParser(description="Plan, run and finish a bulk run of the mutation runner.")
    steps = parser.add_subparsers(dest="step", required=True)
    planning = steps.add_parser("plan", help="choose the run's mutants and cut them into shards")
    planning.add_argument("--out", required=True, help="where plan.json and plan.md go")
    planning.add_argument("--root", default=".", help="the workspace")
    planning.add_argument("--mode", default="packages", type=or_default("packages"), choices=sorted(MODES),
                          help="what the run runs")
    planning.add_argument("--schedule", default="", help="the schedule that started the run, which gives its mode")
    planning.add_argument("--packages", default="", help="package directories, by spaces or commas; the pure"
                                                         " packages that have sites unless given")
    planning.add_argument("--set", default="pinned", type=or_default("pinned"), choices=("pinned", "full"),
                          help="the pinned or the full set")
    planning.add_argument("--seed", default="0", type=or_default("0"), help="the seed of a sample")
    planning.add_argument("--size", type=positive_or(SAMPLE_SIZE), default=SAMPLE_SIZE, help="the sample's size")
    planning.add_argument("--list", help="with --mode list, the list of mutants")
    planning.add_argument("--width", type=width_spec, default=MAX_WIDTH,
                          help=f"how many shards run at once, from 1 to {MAX_WIDTH}")
    planning.add_argument("--workers", type=positive_or(1), default=1,
                          help="how many mutants each shard builds and tests at once")
    planning.add_argument("--seconds-per-mutant", type=positive, default=SECONDS_PER_MUTANT,
                          help="the planned time of a mutant, which sizes the shards")
    planning.add_argument("--flakes", help="the flake records of the latest weekly run, which a weekly run reads")
    sharding = steps.add_parser("shard", help="run one shard of a plan")
    sharding.add_argument("--plan", required=True, help="the plan's plan.json")
    sharding.add_argument("--name", required=True, help="the shard, as the plan names it")
    sharding.add_argument("--out", required=True, help="where the shard's output goes")
    sharding.add_argument("--root", default=".", help="the workspace")
    sharding.add_argument("--work", help="the runner's own directory")
    sharding.add_argument("--moon", default="moon", help="the moon command")
    finishing = steps.add_parser("finish", help="merge the shards' outputs into one report")
    finishing.add_argument("--plan", required=True, help="the plan's plan.json")
    finishing.add_argument("--out", required=True, help="where the merged output and the report go")
    finishing.add_argument("--jobs", help="the run's jobs, as GitHub's API gives them, one JSON object per line")
    finishing.add_argument("--run-url", help="the run's link")
    finishing.add_argument("shards", nargs="+", help="the directories the shards wrote")
    staling = steps.add_parser("stale", help="list the stale entries of the exclusion list")
    staling.add_argument("--out", required=True, help="the file the list goes into")
    staling.add_argument("--root", default=".", help="the workspace")
    staling.add_argument("--moonc", default="moonc", help="the compiler, whose parse tree gives the definitions")
    seeding = steps.add_parser("seeds", help="run the properties with random seeds")
    seeding.add_argument("--out", required=True, help="where the report goes")
    seeding.add_argument("--root", default=".", help="the working copy, whose seed constants change")
    seeding.add_argument("--moon", default="moon", help="the moon command")
    triaging = steps.add_parser("triage", help="cut a weekly run's survivors into stage 1's triage tickets")
    triaging.add_argument("--report", required=True, help="the weekly run's merged output")
    triaging.add_argument("--out", required=True, help="where the tickets go")
    triaging.add_argument("--max", type=positive, default=TRIAGE_MAX, help="the most survivors a ticket holds")
    triaging.add_argument("--bodies", help="the closing tickets' bodies, as <number>.md")
    triaging.add_argument("--run-url", help="the weekly run's link")
    args = parser.parse_args()
    if args.step == "plan" and args.mode == "list" and not args.list and not args.schedule:
        parser.error("--mode list needs --list")
    try:
        if args.step == "plan":
            plan_run(args)
        elif args.step == "shard":
            sys.exit(run_shard(args))
        elif args.step == "stale":
            stale_run(args)
        elif args.step == "seeds":
            report, passed = seeds_run(args)
            print(report)
            sys.exit(0 if passed else 1)
        elif args.step == "triage":
            print(triage_run(args))
        else:
            print(finish_run(args))
    except BulkError as error:
        print(f"bulk: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
