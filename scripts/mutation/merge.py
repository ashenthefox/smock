#!/usr/bin/env python3
"""Merges the outputs of the shards of one run of the mutation runner into
the output of the run without shards: its records, its summary and its
report (CONTRIBUTING.md, "Mutation runner").

usage: python3 scripts/mutation/merge.py --out <dir> <shard's out>...

Each <shard's out> is the directory a run of scripts/mutation/run.py with
--shard k/n wrote. Every shard of the run must be given once, and their
selections (the set, the packages, the ids, the sample) must be the same.
The records are those of the shards, in shard order, which is the order
of the run without shards. Each package's summary is its shards'
summary, with the counts of the outcomes taken again from all its
records, and with "shards": what each shard that ran the package gave of
its run (the mutants it ran, the run without a mutant and the time
limit), since each shard ran the package's tests without a mutant on its
own. The report is the one run.py writes from them, which it also prints; for a
listed set, the keys that no longer apply are those the first shard gives;
for a run on changed lines, the report starts with its base and lines.

It exits with 0 when it merged them, and with 1 when it cannot.
"""

import argparse
import json
import sys
from pathlib import Path

import changed
import choice
import run

# What a shard's summary of a package gives of its own run, beside the
# counts of the outcomes, which the merge takes again from the records.
OWN_RUN = ("mutants", "baseline", "limit_s")


class MergeError(Exception):
    """What stops the merge: shards that are not all of one run."""


def read(directory):
    """A shard's summary, and its records, chosen mutants and keys that no
    longer apply (None for a file the shard did not write)."""
    summary_path = directory / "summary.json"
    if not summary_path.is_file():
        raise MergeError(f"{directory} holds no summary.json")
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    lines = {}
    for name in ("mutants.jsonl", "chosen.jsonl", "unapplied.jsonl"):
        path = directory / name
        lines[name] = ([json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
                       if path.is_file() else None)
    return summary, lines["mutants.jsonl"], lines["chosen.jsonl"], lines["unapplied.jsonl"]


def ordered(directories):
    """The shards, read and sorted by their index, after checking that
    they are every shard of one run, each given once."""
    shards = []
    for directory in directories:
        summary, records, chosen, unapplied = read(directory)
        selection = summary.get("selection") or {}
        shard = selection.get("shard")
        if not shard:
            raise MergeError(f"{directory} is not a shard: its run had no --shard")
        shards.append((shard["index"], shard["count"], directory, summary, records, chosen, unapplied))
    count = shards[0][1]
    if any(s[1] != count for s in shards):
        raise MergeError("the shards are of runs in different numbers of shards: "
                         + ", ".join(f"{s[0]}/{s[1]}" for s in shards))
    shards.sort(key=lambda s: s[0])
    indices = [s[0] for s in shards]
    for index in range(1, count + 1):
        if indices.count(index) > 1:
            raise MergeError(f"shard {index}/{count} is given twice")
        if index not in indices:
            raise MergeError(f"shard {index}/{count} is missing")

    def of_run(summary):
        selection = dict(summary["selection"], shard=None)
        return summary.get("operator_set"), summary.get("set"), selection, summary.get("changed")

    first = of_run(shards[0][3])
    for index, _, directory, summary, *_ in shards[1:]:
        if of_run(summary) != first:
            raise MergeError(f"shard {index}/{count} ({directory}) is of another run than shard 1/{count}:"
                             " its operator set, set, selection or changed lines differ")
    return shards


def merge(directories):
    """The merged summary, records, chosen mutants and keys that no longer
    apply (each None unless every shard wrote it)."""
    shards = ordered(directories)
    count = shards[0][1]
    records = [r for s in shards for r in (s[4] or [])]
    chosen = None if any(s[5] is None for s in shards) else [c for s in shards for c in s[5]]
    unapplied = None if any(s[6] is None for s in shards) else [u for s in shards for u in s[6]]
    first = shards[0][3]
    chosen_set = first["set"]
    summaries = []
    for directory in first["selection"]["packages"]:
        mine = [(s[0], p) for s in shards for p in s[3]["packages"] if p["directory"] == directory]
        if not mine:
            continue
        summary = dict(mine[0][1])
        if any(p["sets"] != summary["sets"] for _, p in mine):
            raise MergeError(f"the shards count the sites of {directory} differently")
        if "mutants" in summary:
            package = [r for r in records if r["package"] == summary["package"]]
            summary.update(run.outcome_counts(package))
            if chosen_set == "full":
                summary.update(run.alternative_counts(package))
            summary["shards"] = [{"shard": f"{index}/{count}", **{k: p[k] for k in OWN_RUN if k in p}}
                                 for index, p in mine]
        summaries.append(summary)
    merged = {key: value for key, value in first.items() if key != "packages"}
    merged["selection"] = dict(first["selection"], shard=None)
    merged["packages"] = summaries
    return merged, records, chosen, unapplied


def main():
    parser = argparse.ArgumentParser(description="Merge the outputs of the shards of one mutation run.")
    parser.add_argument("--out", required=True, help="where the merged records, summary and report go")
    parser.add_argument("shards", nargs="+", help="the directories the shards' runs wrote")
    args = parser.parse_args()
    try:
        summary, records, chosen, unapplied = merge([Path(d) for d in args.shards])
    except MergeError as error:
        print(f"merge: {error}", file=sys.stderr)
        sys.exit(1)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "mutants.jsonl", "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    for name, lines in (("chosen.jsonl", chosen), ("unapplied.jsonl", unapplied)):
        if lines is not None:
            with open(out / name, "w", encoding="utf-8") as f:
                for line in lines:
                    f.write(json.dumps(line, ensure_ascii=False) + "\n")
    (out / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    text = run.report(summary["operator_set"], summary["set"], summary["packages"], records)
    if unapplied is not None and chosen is None:
        gone = {}
        for line in unapplied:
            gone.setdefault(line["directory"], []).append((line["listed"], line["why"]))
        text += "\n".join(["", *choice.listed_report(summary["selection"]["packages"], records, gone)])
    if "changed" in summary:
        text = "\n".join(changed.header(summary["changed"], summary["selection"]["set"], len(records))
                         + ([text] if summary["packages"] else []))
    (out / "report.md").write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
