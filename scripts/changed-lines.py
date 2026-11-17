#!/usr/bin/env python3
"""The changed-lines job of the branch checks (CONTRIBUTING.md, "The
changed-lines job"): every mutant of the pinned set on the non-test lines
that a branch changes in the pure packages, against its merge base with
main, run on a few shards by the mutation runner (scripts/mutation/run.py,
--changed), and the report of their survivors. It only reports: the
merge check reads the report (#312).

usage: python3 scripts/changed-lines.py plan [--root <dir>] [--runner <command>]
           [--by-hand <shards>] --out <dir>
       python3 scripts/changed-lines.py shard [--root <dir>] [--runner <command>]
           --plan <dir> --shard <k> --out <dir>
       python3 scripts/changed-lines.py report --plan <dir> [--shards <dir>] --out <dir>

<root> is the checkout, the current directory unless given, and <command>
the runner, scripts/mutation/run.py beside this script unless given. The
workflow runs the three steps in three jobs:

plan    counts the mutants on the changed lines against the merge base of
        HEAD with origin/main (the runner's --changed --sites-only, into
        <dir>/sites), and plans the shards that run them. On a push, a
        shard runs for each 50 mutants, and at most 3 shards run: a diff
        with more than 600 mutants is not covered, and none of them runs.
        A run started by hand (--by-hand <shards>, from 1 to 20; empty
        for a push) runs them all on that many shards, or on one for each
        mutant when there are fewer. It writes the plan into
        <dir>/plan.json and prints the step's output for the workflow,
        shards=<the shards' numbers, as a JSON list>, on standard output.
shard   runs the k-th of the plan's shards (the runner's --changed
        --shard k/n, against the plan's merge base, so that every shard
        runs on the same lines), into <dir>.
report  reads the plan and the outputs of its shards, each a directory
        under <dir> of --shards, and writes into <dir> of --out:
        report.md, the report, which the job summary shows; report.json,
        what the merge check reads; plan.json; and each shard's output,
        as shard-<k>.

The report names the head, the base and the merge base, whether the run
was on a push or started by hand, and whether it covered the whole diff.
Per package, it counts the mutants and their outcomes, and the survivors
that the exclusion list leaves unexplained, finds stale-covered and
accepts. It lists each unexplained survivor, DEFERRED ones included, with
its package, its enclosing definition and its diff, and each
stale-covered one with the id of its stale entry. report.json gives the
same, and each survivor with its id, package directory, file,
definition, status after the exclusion list, and entry.

It exits with 0 when it wrote what it writes, survivors or not, and with
1 when it cannot: the runner failed, or the shards' outputs are not those
of the plan.
"""

import argparse
import json
import math
import posixpath
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Where a push's run takes its merge base: CI's checkout has no main
# branch of its own.
BASE = "origin/main"
# On a push, a shard runs for each PER_SHARD mutants, and at most
# MOST_SHARDS run, so that the job leaves room among the account's 20
# concurrent jobs; a diff with more mutants than they hold is not
# covered (CONTRIBUTING.md, "The changed-lines job").
PER_SHARD = 50
MOST_SHARDS = 3
BUDGET = 600
# A run started by hand runs on at most this many shards, the account's
# concurrent jobs.
MOST_BY_HAND = 20
OUTCOMES = ("killed", "timed out", "survived", "unviable", "unconfirmed", "equivalent", "duplicate")
STATUSES = ("unexplained", "stale-covered", "accepted")


class JobError(Exception):
    """What stops the job: a runner that failed, or shards that are not
    the plan's."""


def git(root, *args):
    """Runs git in root, and gives its output."""
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise JobError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def run_runner(runner, root, out, *args):
    """Runs the runner on root with its output into out, its own output to
    standard error, and gives its summary."""
    command = [*runner, "--root", str(root), "--out", str(out), *args]
    if subprocess.run(command, stdout=sys.stderr).returncode != 0:
        raise JobError(f"the runner failed: {shlex.join(command)}")
    return json.loads((out / "summary.json").read_text(encoding="utf-8"))


def by_hand(value):
    """The shards of a run started by hand, from --by-hand: None for a
    push, whose value is empty."""
    if value == "":
        return None
    if not value.isdigit() or not 1 <= int(value) <= MOST_BY_HAND:
        raise argparse.ArgumentTypeError(f"a run started by hand takes from 1 to {MOST_BY_HAND} shards, not {value!r}")
    return int(value)


def shard_count(mutants, width):
    """How many shards run for a count of mutants: on a push (width None),
    one for each PER_SHARD mutants and at most MOST_SHARDS, or none when
    they are more than the budget; in a run started by hand, width, or one
    for each mutant when there are fewer."""
    if width is not None:
        return min(width, mutants)
    if mutants > BUDGET:
        return 0
    return min(MOST_SHARDS, math.ceil(mutants / PER_SHARD))


def plan(root, runner, width, out):
    """Counts the mutants on the changed lines and plans the shards for a
    push, or for a run started by hand on width shards: the plan, which it
    also writes into out."""
    out.mkdir(parents=True, exist_ok=True)
    changed = run_runner(runner, root, out / "sites", "--changed", "--base", BASE, "--sites-only")["changed"]
    mutants = changed["mutants"]
    found = {
        "head": git(root, "rev-parse", "HEAD"),
        "base": BASE,
        "merge_base": changed["merge_base"],
        "event": "push" if width is None else "workflow_dispatch",
        "lines": sum(len(n) for n in changed["lines"].values()),
        "packages": sorted({posixpath.dirname(f) for f in changed["lines"]}),
        "mutants": mutants,
        "covered": width is not None or mutants <= BUDGET,
        "shards": shard_count(mutants, width),
    }
    (out / "plan.json").write_text(json.dumps(found, indent=2) + "\n", encoding="utf-8")
    return found


def read_plan(directory):
    """The plan that a plan step wrote into directory."""
    path = Path(directory) / "plan.json"
    if not path.is_file():
        raise JobError(f"{directory} holds no plan.json")
    return json.loads(path.read_text(encoding="utf-8"))


def shard(root, runner, planned, k, out):
    """Runs the k-th of the plan's shards into out."""
    count = planned["shards"]
    if not 1 <= k <= count:
        raise JobError(f"the plan has {count} shards, and no shard {k}")
    run_runner(runner, root, out, "--changed", "--base", planned["merge_base"], "--shard", f"{k}/{count}")


def read_shards(planned, directory):
    """The output directory of each of the plan's shards under directory,
    by number, after checking that they are every shard of the plan, each
    given once, run on its lines."""
    count = planned["shards"]
    found = {}
    for summary_path in sorted(Path(directory).rglob("summary.json")) if directory else []:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        selection = (summary.get("selection") or {}).get("shard") or {}
        k = selection.get("index")
        if selection.get("count") != count or k is None:
            raise JobError(f"{summary_path.parent} is not a shard of the plan's {count}")
        if k in found:
            raise JobError(f"shard {k}/{count} is given twice")
        changed = summary.get("changed") or {}
        if changed.get("merge_base") != planned["merge_base"] or changed.get("mutants") != planned["mutants"]:
            raise JobError(f"shard {k}/{count} ran on other lines than the plan's: its merge base is"
                           f" {changed.get('merge_base')} and it found {changed.get('mutants')} mutants")
        found[k] = summary_path.parent
    missing = [k for k in range(1, count + 1) if k not in found]
    if missing:
        raise JobError("the output of shard " + ", ".join(f"{k}/{count}" for k in missing) + " is missing")
    return found


def records_of(directory):
    """The records of a shard's mutants."""
    path = directory / "mutants.jsonl"
    if not path.is_file():
        raise JobError(f"{directory} holds no mutants.jsonl")
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def status_of(record):
    """A survivor's status after the exclusion list."""
    return (record.get("exclusion") or {}).get("status", "unexplained")


def report(planned, shards):
    """The report's JSON and Markdown, from the plan and its shards'
    output directories."""
    records = [r for k in sorted(shards) for r in records_of(shards[k])]
    if planned["shards"] and len(records) != planned["mutants"]:
        raise JobError(f"the shards ran {len(records)} mutants, and the plan has {planned['mutants']}")
    counts = {}
    for record in records:
        package = counts.setdefault(posixpath.dirname(record["file"]),
                                    {"mutants": 0, **{o: 0 for o in OUTCOMES}, **{s: 0 for s in STATUSES}})
        package["mutants"] += 1
        package[record["outcome"]] = package.get(record["outcome"], 0) + 1
        if record["outcome"] == "survived":
            package[status_of(record)] += 1
    survivors = []
    for record in records:
        if record["outcome"] != "survived":
            continue
        exclusion = record.get("exclusion") or {}
        survivors.append({"id": record["id"], "package": record.get("package"),
                          "directory": posixpath.dirname(record["file"]), "file": record["file"],
                          "definition": record["definition"], "status": status_of(record),
                          "entry": exclusion.get("entry"),
                          **({"issue": exclusion["issue"]} if "issue" in exclusion else {})})
    found = dict(planned, ran=len(records), counts=dict(sorted(counts.items())), survivors=survivors)
    return found, markdown(found, records)


def markdown(found, records):
    """The report as the job summary shows it."""
    out = ["# Mutants on changed lines", "",
           f"Head `{found['head'][:12]}`, against `{found['base']}`, merge base `{found['merge_base'][:12]}`,"
           f" {'on a push' if found['event'] == 'push' else 'in a run started by hand'}.", ""]
    lines = found["lines"]
    if not lines:
        return "\n".join(out + ["No non-test line of a pure package changed, so no mutant ran: the whole diff is"
                                " covered.", ""])
    if not found["mutants"]:
        return "\n".join(out + [
            f"**The whole diff is covered**: {lines} changed non-test {'line' if lines == 1 else 'lines'} in the pure"
            f" packages ({', '.join(found['packages'])}), with no mutant of the pinned set on"
            f" {'it' if lines == 1 else 'them'}, so none ran.", ""])
    on_lines = (f"{lines} changed non-test {'line' if lines == 1 else 'lines'} in the pure packages"
                f" ({', '.join(found['packages'])}), with {found['mutants']} mutants of the pinned set on them")
    if not found["covered"]:
        return "\n".join(out + [
            f"**The diff is not covered**: {on_lines}, more than the {BUDGET} that the {MOST_SHARDS} shards of a"
            " push run, so none ran. To run them all, start the branch checks by hand on this branch, which runs"
            f" them on {MOST_BY_HAND} shards unless you give another number from 1 to {MOST_BY_HAND}"
            " (CONTRIBUTING.md, \"The changed-lines job\"):", "", "```sh",
            "gh workflow run branch-checks.yml --ref <branch>",
            "gh workflow run branch-checks.yml --ref <branch> -f shards=<n>", "```", ""])
    out += [f"**The whole diff is covered**: {on_lines}, all run on {found['shards']}"
            f" {'shard' if found['shards'] == 1 else 'shards'}.", ""]
    columns = ("mutants", *OUTCOMES, *STATUSES)
    out += ["| package | " + " | ".join(columns) + " |", "|---|" + "---:|" * len(columns)]
    for package, counts in found["counts"].items():
        out += [f"| {package} | " + " | ".join(str(counts[c]) for c in columns) + " |"]
    out += [""]
    for status, title in (("unexplained", "Unexplained survivors"), ("stale-covered", "Stale-covered survivors")):
        group = [r for r in records if r["outcome"] == "survived" and status_of(r) == status]
        if not group:
            continue
        out += [f"## {title} ({len(group)})", ""]
        for record in group:
            exclusion = record.get("exclusion") or {}
            if status == "stale-covered":
                line = f"Stale-covered: its only entry, `{exclusion.get('entry')}`, is stale."
            elif "issue" in exclusion:
                line = f"Unexplained: DEFERRED to #{exclusion['issue']}."
            else:
                line = "Unexplained."
            first, last = record["definition_lines"]
            out += [f"### `{record['id']}`", "", line, "",
                    f"In package `{posixpath.dirname(record['file'])}`, `{record['definition']}`, {record['file']}"
                    f" lines {first} to {last}:", "", "```diff", record.get("diff", "").rstrip("\n"), "```", ""]
    return "\n".join(out)


def write_report(plan_directory, shards_directory, out):
    """Writes the report, the plan and each shard's output into out."""
    planned = read_plan(plan_directory)
    shards = read_shards(planned, shards_directory)
    found, text = report(planned, shards)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    shutil.copy(Path(plan_directory) / "plan.json", out / "plan.json")
    for k, directory in shards.items():
        shutil.copytree(directory, out / f"shard-{k}")
    (out / "report.json").write_text(json.dumps(found, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (out / "report.md").write_text(text, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    steps = parser.add_subparsers(dest="step", required=True)
    for name in ("plan", "shard"):
        step = steps.add_parser(name)
        step.add_argument("--root", default=".", help="the checkout")
        step.add_argument("--runner", help="the mutation runner's command (default: scripts/mutation/run.py)")
        step.add_argument("--out", required=True, help="where the step writes")
    steps.choices["plan"].add_argument("--by-hand", type=by_hand, default=None,
                                       help="the shards of a run started by hand, from 1 to 20 (empty for a push)")
    steps.choices["shard"].add_argument("--plan", required=True, help="the plan step's directory")
    steps.choices["shard"].add_argument("--shard", type=int, required=True, help="the shard's number, from 1")
    reporting = steps.add_parser("report")
    reporting.add_argument("--plan", required=True, help="the plan step's directory")
    reporting.add_argument("--shards", help="the directory that holds the shards' outputs")
    reporting.add_argument("--out", required=True, help="where the report goes")
    args = parser.parse_args()
    try:
        if args.step == "report":
            write_report(args.plan, args.shards, Path(args.out))
            return 0
        runner = shlex.split(args.runner) if args.runner else [sys.executable, str(HERE / "mutation" / "run.py")]
        root = Path(args.root)
        if args.step == "plan":
            found = plan(root, runner, args.by_hand, Path(args.out))
            print("shards=" + json.dumps(list(range(1, found["shards"] + 1)), separators=(",", ":")))
        else:
            shard(root, runner, read_plan(args.plan), args.shard, Path(args.out))
    except JobError as error:
        print(f"changed-lines: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
