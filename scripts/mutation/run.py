#!/usr/bin/env python3
"""Runs the mutants of MoonBit packages on wasm-gc with each package's own
tests, and writes one record per mutant, a summary per package and a
report (CONTRIBUTING.md, "Mutation runner").

usage: python3 scripts/mutation/run.py [--root <dir>] [--work <dir>] [--out <dir>]
           [--set pinned|full] [--mutant <id>]... [--sites-only] [--workers <n>]
           [--list <file> [--totals-only]] [--sample <n> [--seed <s>]] [--shard <k>/<n>]
           [--moon <moon>] [--finder <command>] [<package directory>...]

<package directory> is relative to <root>, the workspace or module to
mutate: the current directory unless it is given. The site finder
(scripts/mutation/sites.py, or --finder) gives the sites of the full set,
one per line, each with whether the pinned set takes it, and the sites
that a rule of the operator set skipped. --set pinned, the default, makes
one mutant of each site of the pinned set: one per position, two for INT
in a comparison or an index, the alternative chosen by the rule of
operator set v1. --set full makes one of each site of the full set: every
alternative of every operator at every position. --mutant runs only the
mutant with that id, which must be in the set, and may be given more than
once; a package given that holds none of the ids is not run.
--sites-only runs no mutant: it writes the counts of sites, positions and
skipped sites of each package, in both sets, and the mutants a run would
make, in chosen.jsonl.

Three more options choose the mutants, for bulk runs (choice.py says how):

  --list <file>    runs the mutants a file lists, in its order, in place
                   of a set: by offset on a commit, or by key on any
                   later commit. A mutant that no site of operator set v1
                   makes is outside v1, and its record says so
                   (in_operator_set). The packages are those of the
                   listed files, unless given. A key that no longer
                   finds its text is written, with why, to
                   unapplied.jsonl, and the report counts it. With
                   --totals-only, the run writes only per-package and
                   total counts into summary.json and report.md; it
                   removes from <out> the files of an earlier run that
                   name mutants and from <work> the workers' builds, and
                   prints no mutant's id, no output of a build or a test,
                   and not the reason it stops, which may name a mutant.
  --sample <n>     runs a sample of n of the set's mutants, stratified by
                   package, which --seed (0 unless given) fixes.
  --shard <k>/<n>  runs the k-th of n parts of the mutants, in the run's
                   order, whose sizes differ by one at most;
                   scripts/mutation/merge.py merges the outputs of a
                   run's shards into the output of the run without them.

Without --mutant, --list or --sample, every package given runs, one that
has no mutant at all in the first shard; with one of them, only the
packages that hold one of the shard's mutants run.

For each worker, the runner copies <root> into <work>/tree-<n>, the files
that git tracks and the untracked ones it does not ignore, and builds
there into <work>/target-<n>: a build directory at a stable path, in a
target directory of the runner's own, so that a plain build and a mutant
build never rebuild each other, and each mutant is built where the last
one was. <work> is <root>/_build/mutation unless it is given. For each
package, the runner first builds and runs the tests without a mutant, and
stops if they fail. Then, for each mutant, it writes the mutated file into
the tree, builds the package's tests (moon test --build-only), and runs
them. It checks the build's exit status, so that a failed build never
runs the binary of an earlier one, and it never passes -u. The outcome is

  killed      a test failed;
  timed out   the run took longer than 1.25 times the baseline run plus
              4 s, and was stopped; listed apart, since a time-out is not
              yet confirmed as a kill;
  unviable    the mutant does not build; outside the counts of killed and
              survived;
  survived    every test passed.

It writes into <out> (<work>/out unless it is given):

  mutants.jsonl  one record per mutant: the site's fields (its operator
                 set's version and whether the pinned set takes it
                 included), the package, the set that ran, the outcome,
                 the tests that killed it, the backend, the timings
                 (build_s, run_s and the run's limit_s), the compiler's
                 message for an unviable one, and a survivor's diff;
  summary.json   the operator set's version, the set that ran (listed for
                 --list), what chose the mutants (selection), and per
                 package: the baseline, the counts of sites and positions
                 in the set that ran and in both sets, the sites each rule
                 skipped, the counts of mutants and each outcome, and the
                 score: killed / (killed + survived), which leaves
                 time-outs out until they are confirmed; for the full set,
                 the same counts at the pinned alternatives and at the
                 other alternatives apart;
  report.md      the operator set's version and the set, the summaries,
                 the sites each rule skipped, the time-outs, and each
                 survivor's diff with its whole enclosing definition (for
                 the full set, the survivors at the pinned alternatives and
                 those at the other alternatives apart), which it also
                 prints; for a listed set, then, per package, the
                 mutants listed, run, no longer applying and outside v1,
                 each listed mutant with its outcome, and each key that
                 no longer applies, with why.

A position is the place of one or more sites: their file, operator, line
and column.

It exits with 0 when every mutant has an outcome, survivors or not, and
with 1 when it cannot run them.
"""

import argparse
import difflib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import choice

HERE = Path(__file__).resolve().parent
BACKEND = "wasm-gc"
# The build of the package without a mutant, and its tests, may take this
# long: they have no baseline to scale from.
FIRST_RUN_LIMIT_S = 1800
# Directories of a tree that are never copied nor removed: build output,
# downloaded modules and git's own.
SKIPPED = {"_build", "target", ".mooncakes", ".git"}
# The file in a tree that lists what the runner copied there.
MANIFEST = ".mutation-files"
NAME = re.compile(r'^\s*"?name"?\s*[=:]\s*"([^"]+)"', re.MULTILINE)
TOTAL = re.compile(r"Total tests: (\d+), passed: (\d+), failed: (\d+)")


class RunnerError(Exception):
    """What stops the run: a package that fails without a mutant, or a site
    that does not match the source."""


def package_name(root, directory):
    """The moon package of a directory: its module's name, from the nearest
    moon.mod or moon.mod.json at or above it within root, and its path
    within the module."""
    root = root.resolve()
    current = (root / directory).resolve()
    if not current.is_dir():
        raise RunnerError(f"{directory} is not a directory of {root}")
    module = current
    while True:
        for file in ("moon.mod", "moon.mod.json"):
            if (module / file).is_file():
                match = NAME.search((module / file).read_text(encoding="utf-8"))
                if not match:
                    raise RunnerError(f"{module / file} names no module")
                rel = current.relative_to(module).as_posix()
                return match.group(1) if rel == "." else f"{match.group(1)}/{rel}"
        if module == root:
            raise RunnerError(f"no module holds {directory}")
        module = module.parent


def listed_files(root):
    """The files of root to copy, relative to it: those git tracks, and the
    untracked ones it does not ignore; every file outside the skipped
    directories when root is not in a git work tree."""
    result = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                            capture_output=True)
    if result.returncode == 0:
        names = [n for n in result.stdout.decode("utf-8").split("\0") if n]
        return sorted(n for n in names if (root / n).is_file())
    files = []
    for directory, subdirectories, names in os.walk(root):
        subdirectories[:] = [d for d in subdirectories if d not in SKIPPED]
        for name in names:
            files.append((Path(directory) / name).relative_to(root).as_posix())
    return sorted(files)


def sync(root, tree, files):
    """Makes tree a copy of root's files: copies each one that differs, and
    removes what an earlier copy left that root no longer has. Files the
    build writes in the tree stay."""
    tree.mkdir(parents=True, exist_ok=True)
    manifest = tree / MANIFEST
    wanted = set(files)
    if manifest.is_file():
        for old in manifest.read_text(encoding="utf-8").splitlines():
            if old and old not in wanted and (tree / old).is_file():
                (tree / old).unlink()
    for name in files:
        source, target = root / name, tree / name
        data = source.read_bytes()
        if not target.is_file() or target.read_bytes() != data:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        shutil.copymode(source, target)
    manifest.write_text("".join(f"{n}\n" for n in files), encoding="utf-8")


def run(command, cwd, limit):
    """Runs a command in its own process group, and stops the group after
    limit seconds: (exit status, output, seconds, whether it timed out)."""
    start = time.monotonic()
    process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=limit)
        timed_out = False
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        timed_out = True
    elapsed = time.monotonic() - start
    return process.returncode, output.decode("utf-8", errors="replace"), elapsed, timed_out


def diagnostics(output, tree):
    """The error messages of moon's JSON diagnostics in an output, with
    paths relative to the tree."""
    prefix = f"{tree}/"
    messages = []
    for line in output.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict) and item.get("$message_type") == "diagnostic" and item.get("level") == "error":
            path = str(item.get("path", "")).removeprefix(prefix)
            messages.append(f"{path}:{item.get('loc', '')}: {item.get('message', '')}")
    return messages


def failed_tests(output):
    """The tests that failed, from moon test --test-failure-json."""
    tests = []
    for line in output.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict) and "test_name" in item:
            tests.append({"package": item.get("package"), "file": item.get("filename"),
                          "index": int(item.get("index", -1)), "name": item.get("test_name")})
    return tests


class Worker:
    """A tree and a target directory, where mutants are built one at a
    time."""

    def __init__(self, number, work, moon):
        self.number = number
        self.tree = work / f"tree-{number}"
        self.target = work / f"target-{number}"
        self.moon = moon

    def moon_test(self, package, limit, build_only):
        """Builds the package's tests, or runs them, in the worker's tree."""
        command = [*self.moon, "test", "--target", BACKEND, "-p", package, "--target-dir", str(self.target)]
        command += ["--build-only", "--output-json"] if build_only else ["--test-failure-json"]
        return run(command, self.tree, limit)

    def build(self, package, limit=FIRST_RUN_LIMIT_S):
        """Builds the package's tests: (exit status, output, seconds)."""
        status, output, seconds, timed_out = self.moon_test(package, limit, build_only=True)
        if timed_out:
            raise RunnerError(f"the build of {package} in {self.tree} took over {limit} s")
        return status, output, seconds


def apply(text, site):
    """The text with the site's change, after checking that the site's
    original text is where the site says."""
    starts = [0]
    for line in text.split("\n"):
        starts.append(starts[-1] + len(line) + 1)
    line, column = site["line"], site["column"]
    if not 1 <= line < len(starts):
        raise RunnerError(f"{site['id']}: {site['file']} has no line {line}")
    offset = starts[line - 1] + column - 1
    end = offset + len(site["original"])
    if text[offset:end] != site["original"]:
        raise RunnerError(f"{site['id']}: {site['file']}:{line}:{column} holds {text[offset:end]!r},"
                          f" not {site['original']!r}")
    return text[:offset] + site["replacement"] + text[end:]


def definition_diff(site, text, mutated):
    """The mutant's diff, with its whole enclosing definition as context."""
    first, last = site["definition_lines"]
    before = text.split("\n")
    after = mutated.split("\n")
    delta = len(after) - len(before)
    old = before[first - 1 : last]
    new = after[first - 1 : last + delta]
    lines = list(difflib.unified_diff(old, new, lineterm="", n=len(old) + len(new)))
    hunk = [f"@@ -{first},{len(old)} +{first},{len(new)} @@ {site['definition']}"]
    return "\n".join([f"--- a/{site['file']}", f"+++ b/{site['file']}"] + hunk + lines[3:]) + "\n"


def find_sites(finder, root, directory):
    """The sites of the full set that the finder prints for a package's
    directory, and the sites that a rule skipped. Every line names the
    same operator set."""
    command = [*finder, "--root", str(root), "--set", "full", directory]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RunnerError(f"the site finder failed on {directory}:\n{result.stderr}")
    lines = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    versions = {line.get("operator_set") for line in lines}
    if None in versions or len(versions) > 1:
        raise RunnerError(f"the site finder's lines for {directory} do not name one operator set:"
                          f" {sorted(map(str, versions))}")
    return [s for s in lines if "skipped" not in s], [s for s in lines if "skipped" in s]


def in_set(site, chosen):
    """Whether a site is in the chosen set, pinned or full."""
    return chosen == "full" or site["pinned"]


def position(site):
    """The place of a site, which it shares with the other alternatives of
    its operator there."""
    return site["file"], site["operator"], site["line"], site["column"]


def set_counts(sites, skipped):
    """The counts of sites and positions, and of the sites that each rule
    skipped, in the pinned set and in the full set."""
    counts = {}
    for chosen in ("pinned", "full"):
        mine = [s for s in sites if in_set(s, chosen)]
        rules = {}
        for site in skipped:
            if in_set(site, chosen):
                rule = f"{site['operator']} {site['skipped']}"
                rules[rule] = rules.get(rule, 0) + 1
        counts[chosen] = {"sites": len(mine), "positions": len({position(s) for s in mine}),
                          "skipped": dict(sorted(rules.items()))}
    return counts


def outcome_counts(records):
    """The count of each outcome among records, and the score."""
    counts = {o: sum(1 for r in records if r["outcome"] == o) for o in ("killed", "timed out", "survived", "unviable")}
    judged = counts["killed"] + counts["survived"]
    return {
        "mutants": len(records),
        "killed": counts["killed"],
        "timed_out": counts["timed out"],
        "survived": counts["survived"],
        "unviable": counts["unviable"],
        # Time-outs are left out until they are confirmed as kills.
        "score": round(counts["killed"] / judged, 4) if judged else None,
    }


def choose(found, chosen_set, ids, directories):
    """The sites of the chosen set in each package, and the mutants to run
    of them: all of them, or, with ids, those the ids name, which must all
    be sites of the set."""
    sites = {d: [s for s in found[d][0] if in_set(s, chosen_set)] for d in directories}
    if not ids:
        return sites, {d: list(mine) for d, mine in sites.items()}
    known = {s["id"] for mine in sites.values() for s in mine}
    unknown = [i for i in ids if i not in known]
    if unknown:
        where = ", ".join(directories)
        raise RunnerError("".join(f"no site of {where} in the {chosen_set} set has the id {i}\n"
                                  for i in unknown).rstrip())
    return sites, {d: [s for s in mine if s["id"] in ids] for d, mine in sites.items()}


def alternative_counts(records):
    """A full set's counts at the pinned alternatives and at the others,
    apart: L4 reads only the former."""
    return {"pinned": outcome_counts([r for r in records if r["pinned"]]),
            "other": outcome_counts([r for r in records if not r["pinned"]])}


def package_summary(root, directory, sites, skipped, chosen, operator_set):
    """What a package's summary says without a run: its sites, positions
    and skipped sites in the set that ran and in both sets."""
    counts = set_counts(sites, skipped)
    return {
        "package": package_name(root, directory),
        "directory": directory,
        "operator_set": operator_set,
        "set": chosen,
        "sites": counts[chosen]["sites"],
        "positions": counts[chosen]["positions"],
        "skipped": counts[chosen]["skipped"],
        "sets": counts,
    }


def run_package(root, directory, sites, mutants, workers, log):
    """Runs the chosen mutants of one package, whose sites are given: its
    records, and its summary's counts of the run."""
    package = package_name(root, directory)
    first = workers[0]
    status, output, _ = first.build(package)
    if status != 0:
        raise RunnerError(f"{package} does not build without a mutant:\n{output}")
    status, output, baseline_s, timed_out = first.moon_test(package, FIRST_RUN_LIMIT_S, build_only=False)
    totals = TOTAL.findall(output)
    if status != 0 or timed_out:
        raise RunnerError(f"the tests of {package} fail without a mutant:\n{output}")
    tests = sum(int(t[0]) for t in totals)
    limit = 1.25 * baseline_s + 4
    log(f"{package}: {len(sites)} sites, {len(mutants)} mutants, {tests} tests,"
        f" baseline run {baseline_s:.2f} s, limit {limit:.2f} s")
    for worker in workers[1:]:
        status, output, _ = worker.build(package)
        if status != 0:
            raise RunnerError(f"{package} does not build without a mutant in {worker.tree}:\n{output}")

    records = [None] * len(mutants)
    queue = list(enumerate(mutants))
    lock = threading.Lock()

    def work(worker):
        while True:
            with lock:
                if not queue:
                    return
                index, site = queue.pop(0)
            records[index] = run_mutant(worker, package, site, limit)
            record = records[index]
            log(f"  {record['outcome']:9} {site['id']}  (build {record['timings']['build_s']:.2f} s,"
                f" run {record['timings']['run_s']:.2f} s)")

    with ThreadPoolExecutor(max_workers=len(workers)) as pool:
        for future in [pool.submit(work, w) for w in workers]:
            future.result()

    summary = {
        "backend": BACKEND,
        "baseline": {"run_s": round(baseline_s, 3), "tests": tests},
        "limit_s": round(limit, 3),
        **outcome_counts(records),
    }
    return records, summary


def run_mutant(worker, package, site, limit):
    """Builds and tests one mutant in a worker's tree: its record."""
    path = worker.tree / site["file"]
    text = path.read_text(encoding="utf-8")
    mutated = apply(text, site)
    record = dict(site, package=package, backend=BACKEND)
    try:
        path.write_text(mutated, encoding="utf-8")
        status, output, build_s = worker.build(package)
        timings = {"build_s": round(build_s, 3), "run_s": 0.0, "limit_s": round(limit, 3)}
        if status != 0:
            messages = diagnostics(output, worker.tree)
            record.update(outcome="unviable", killing_tests=[], timings=timings,
                          message="\n".join(messages) if messages else output[-2000:])
        else:
            status, output, run_s, timed_out = worker.moon_test(package, limit, build_only=False)
            timings["run_s"] = round(run_s, 3)
            if timed_out:
                record.update(outcome="timed out", killing_tests=[], timings=timings)
            elif status == 0:
                record.update(outcome="survived", killing_tests=[], timings=timings)
            else:
                record.update(outcome="killed", killing_tests=failed_tests(output), timings=timings)
                if not record["killing_tests"]:
                    record["message"] = output[-2000:]
    finally:
        path.write_text(text, encoding="utf-8")
    if record["outcome"] == "survived":
        record["diff"] = definition_diff(site, text, mutated)
    return record


def report(operator_set, chosen, summaries, records):
    """The report: the operator set and the set, the summary of each
    package, the sites each rule skipped, its time-outs, and its survivors
    with their diffs, those at the other alternatives of the full set
    apart."""
    which = {"pinned": "the pinned set", "full": "the full set"}.get(chosen, f"a {chosen} set")
    out = ["# Mutation report", "", f"Operator set {operator_set}, {which}.", ""]
    for summary in summaries:
        package = summary["package"]
        mine = [r for r in records if r["package"] == package]
        out += [f"## {package}", ""]
        if "backend" in summary:
            out += [f"Backend {summary['backend']}, {summary['baseline']['tests']} tests, baseline run"
                    f" {summary['baseline']['run_s']:.2f} s, time limit {summary['limit_s']:.2f} s.", ""]
        out += site_table(summary)
        if "backend" not in summary:
            continue
        rows = [("", summary)]
        if chosen == "full":
            rows = [("all", summary), ("at the pinned alternatives", summary["pinned"]),
                    ("at the other alternatives", summary["other"])]
        out += ["| mutants | killed | timed out | survived | unviable | score |" if chosen == "pinned" else
                "| alternatives | mutants | killed | timed out | survived | unviable | score |"]
        out += ["|---:|---:|---:|---:|---:|---:|" if chosen == "pinned" else "|---|---:|---:|---:|---:|---:|---:|"]
        for label, counts in rows:
            score = "none" if counts["score"] is None else f"{counts['score']:.1%}"
            cells = [counts["mutants"], counts["killed"], counts["timed_out"], counts["survived"],
                     counts["unviable"], score]
            out += ["| " + " | ".join(([label] if chosen == "full" else []) + [str(c) for c in cells]) + " |"]
        out += [""]
        timed_out = [r for r in mine if r["outcome"] == "timed out"]
        if timed_out:
            out += ["### Timed out, not yet confirmed", ""]
            out += [f"- `{r['id']}` (run stopped after {r['timings']['run_s']:.2f} s)" for r in timed_out]
            out += [""]
        survivors = [r for r in mine if r["outcome"] == "survived"]
        groups = [("Survivors", survivors)]
        if chosen == "full":
            groups = [("Survivors at the pinned alternatives", [r for r in survivors if r["pinned"]]),
                      ("Survivors at the other alternatives", [r for r in survivors if not r["pinned"]])]
        for title, group in groups:
            out += [f"### {title} ({len(group)})", ""]
            for record in group:
                out += [f"#### `{record['id']}`", "", f"In `{record['definition']}`, {record['file']}"
                        f" lines {record['definition_lines'][0]} to {record['definition_lines'][1]}:", "",
                        "```diff", record["diff"].rstrip("\n"), "```", ""]
    return "\n".join(out)


def site_table(summary):
    """The lines of the report that count a package's sites, positions and
    skipped sites, in both sets."""
    sets = summary["sets"]
    out = ["| set | sites | positions |", "|---|---:|---:|"]
    for chosen in ("pinned", "full"):
        out += [f"| {chosen} | {sets[chosen]['sites']} | {sets[chosen]['positions']} |"]
    out += [""]
    skipped = summary["skipped"]
    if skipped:
        out += ["Sites skipped in this set: " + ", ".join(f"{rule} {n}" for rule, n in skipped.items()) + ".", ""]
    else:
        out += ["Sites skipped in this set: none.", ""]
    return out


def main():
    parser = argparse.ArgumentParser(description="Run the mutants of MoonBit packages and report the survivors.")
    parser.add_argument("--root", default=".", help="the workspace or module to mutate")
    parser.add_argument("--work", help="the runner's own directory (default <root>/_build/mutation)")
    parser.add_argument("--out", help="where the records and the report go (default <work>/out)")
    parser.add_argument("--set", default="pinned", choices=("pinned", "full"),
                        help="the pinned set (the default) or the full set")
    parser.add_argument("--mutant", action="append", help="run only the mutant with this id")
    parser.add_argument("--sites-only", action="store_true",
                        help="count the sites of each package in both sets, and run no mutant")
    parser.add_argument("--list", metavar="FILE",
                        help="run the mutants that FILE lists, by offset on a commit or by key")
    parser.add_argument("--totals-only", action="store_true",
                        help="with --list, write only per-package and total counts, naming no mutant")
    parser.add_argument("--sample", type=int, metavar="N",
                        help="run a sample of N of the mutants, stratified by package")
    parser.add_argument("--seed", default="0", help="the seed of --sample (0 unless given)")
    parser.add_argument("--shard", type=choice.shard_spec, metavar="K/N",
                        help="run only shard K of N of the mutants (K from 1)")
    parser.add_argument("--workers", type=int, default=1, help="how many mutants build and run at once")
    parser.add_argument("--moon", default="moon", help="the moon command")
    parser.add_argument("--finder", help="the site finder's command (default: sites.py beside this script)")
    parser.add_argument("packages", nargs="*",
                        help="package directories, relative to <root> (with --list, those of its files"
                             " unless given)")
    args = parser.parse_args()
    if args.workers < 1:
        parser.error("--workers must be at least 1")
    if args.sample is not None and (args.sample < 1 or args.mutant or args.list):
        parser.error("--sample takes a number from 1, and no --mutant or --list")
    if args.list and args.mutant:
        parser.error("--list and --mutant choose the mutants each: give one of them")
    if not args.packages and not args.list:
        parser.error("give at least one package directory")
    if args.totals_only and (not args.list or args.sites_only or args.shard):
        parser.error("--totals-only takes --list, and neither --sites-only nor --shard")
    root = Path(args.root).resolve()
    work = Path(args.work).resolve() if args.work else root / "_build" / "mutation"
    out = Path(args.out).resolve() if args.out else work / "out"
    finder = shlex.split(args.finder) if args.finder else [sys.executable, str(HERE / "sites.py")]

    def log(message):
        if not args.totals_only:
            print(message, file=sys.stderr, flush=True)

    try:
        entries = choice.read_list(args.list) if args.list else None
        if entries is not None and not args.packages:
            args.packages = choice.list_directories(entries)
        found = {directory: find_sites(finder, root, directory) for directory in args.packages
                 if entries is None or (root / directory).is_dir()}
        found.update({directory: ([], []) for directory in args.packages if directory not in found})
        versions = {s["operator_set"] for sites, skipped in found.values() for s in sites + skipped}
        if len(versions) > 1:
            raise RunnerError(f"the packages' sites name several operator sets: {sorted(versions)}")
        operator_set = versions.pop() if versions else None
        sites, chosen = choose(found, args.set, args.mutant, args.packages)
        unapplied = {directory: [] for directory in args.packages}
        if entries is not None:
            chosen, unapplied = choice.resolve(root, args.list, entries, found, args.packages)
            if args.shard and args.shard[0] != 1:
                # The first shard counts the keys that no longer apply.
                unapplied = {directory: [] for directory in args.packages}
        if args.sample is not None:
            chosen = choice.sample(chosen, args.packages, args.sample, args.seed)
        # The run's mutants, and the shard's.
        whole, chosen = chosen, choice.shard(chosen, args.packages, *args.shard) if args.shard else chosen
        selected = bool(args.mutant) or args.sample is not None or entries is not None
        run_set = "listed" if entries is not None else args.set
        runs = choice.running(args.packages, whole, chosen, selected, args.shard and args.shard[0])
        records, summaries = [], []
        if not args.sites_only:
            files = listed_files(root)
            workers = [Worker(n, work, shlex.split(args.moon)) for n in range(args.workers)]
            for worker in workers:
                sync(root, worker.tree, files)
        for directory in args.packages:
            if directory not in runs:
                continue
            summary = package_summary(root, directory, found[directory][0], found[directory][1], args.set,
                                      operator_set)
            summary["set"] = run_set
            if not args.sites_only:
                package_records, counts = run_package(root, directory, sites[directory], chosen[directory],
                                                      workers, log)
                for record in package_records:
                    record.update(set=run_set)
                summary.update(counts)
                if run_set == "full":
                    summary.update(alternative_counts(package_records))
                records += package_records
            summaries.append(summary)
    except (RunnerError, choice.ChoiceError) as error:
        print(choice.HIDDEN if args.totals_only else f"run: {error}", file=sys.stderr)
        sys.exit(1)
    except Exception:
        if not args.totals_only:
            raise
        print(choice.HIDDEN, file=sys.stderr)
        sys.exit(1)
    finally:
        if args.totals_only:
            choice.drop_builds(work)
    if args.totals_only:
        print(choice.write_totals(out, operator_set, choice.selection(args), args.packages, summaries, records,
                                  unapplied, outcome_counts))
        return
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "mutants.jsonl", "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    if entries is not None:
        with open(out / "unapplied.jsonl", "w", encoding="utf-8") as f:
            for directory in args.packages:
                for entry, why in unapplied[directory]:
                    line = {"directory": directory, "listed": entry, "why": why}
                    f.write(json.dumps(line, ensure_ascii=False) + "\n")
    if args.sites_only:
        with open(out / "chosen.jsonl", "w", encoding="utf-8") as f:
            for directory in args.packages:
                for site in chosen[directory] if directory in runs else []:
                    f.write(json.dumps(site, ensure_ascii=False) + "\n")
    (out / "summary.json").write_text(
        json.dumps({"operator_set": operator_set, "set": run_set, "selection": choice.selection(args),
                    "packages": summaries},
                   indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    text = report(operator_set, run_set, summaries, records)
    if entries is not None and not args.sites_only:
        text += "\n".join(["", *choice.listed_report(args.packages, records, unapplied)])
    (out / "report.md").write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
