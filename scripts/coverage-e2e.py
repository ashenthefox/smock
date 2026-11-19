#!/usr/bin/env python3
"""Coverage from the e2e tests, merged with the in-process tests' (#342;
CONTRIBUTING.md, "Coverage from the e2e tests"): which points of each
package the in-process tests reach, which the e2e tests reach in the
binary, and which no test reaches. scripts/coverage-e2e.sh runs both
suites and then this report.

usage: python3 scripts/coverage-e2e.py report --in-process <report> --e2e <report> --out <dir>
           [--root <dir>]

report  reads two bisect reports of moon_cove, the toolchain's coverage
        reader, made of the same trace sources (scripts/coverage-report.py
        reads the format): the in-process tests' (scripts/coverage.sh) and
        the e2e tests', of the counters that the smock processes of the
        e2e tests dumped. A point is reached when its count is above 0 in
        either. Their paths are relative to <root>, the current directory
        unless given. It writes into <out> report.md, and prints it: per
        package, the points reached in-process, by e2e and by either, and
        those that no test reaches.

It exits with 2, saying why, when it cannot read a report, or when the two
reports do not hold the same points: they were made of other trace
sources.
"""

import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name, path):
    """A script beside this one, as a module."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coverage_report = load("coverage_report", HERE / "coverage-report.py")
ReportError = coverage_report.ReportError


def same_points(in_process, e2e):
    """Checks that two bisect reports hold the same points: the same files,
    each with the same offsets."""
    mine = {name: sorted(offset for offset, _ in points) for name, points in in_process}
    theirs = {name: sorted(offset for offset, _ in points) for name, points in e2e}
    for name in sorted(set(mine) | set(theirs)):
        if name not in mine or name not in theirs:
            raise ReportError(f"the two reports do not hold the same points: {name} is in one only")
        if mine[name] != theirs[name]:
            raise ReportError(f"the two reports do not hold the same points: {name} differs")


def counts(report):
    """Each point's count in a report, by file and offset."""
    found = {}
    for name, points in report:
        mine = found.setdefault(name, {})
        for offset, count in points:
            mine[offset] = mine.get(offset, 0) + count
    return found


def write_bisect(path, files):
    """Writes a bisect report of format 4: for each file, its path, the
    offsets of its points and their counts."""
    words = ["BISECT-COVERAGE-4", str(len(files))]
    for name, points in files:
        words += [str(len(name.encode("utf-8"))), name, str(len(points))]
        words += [str(offset) for offset, _ in points]
        words += [str(len(points))] + [str(count) for _, count in points]
    Path(path).write_text(" ".join(words) + "\n", encoding="utf-8")


def percent(part, whole):
    """part of whole, as a percentage with one decimal."""
    return f"{100 * part / whole:.1f}%" if whole else "-"


def package_of(name):
    """The package of a file: its directory."""
    return str(Path(name).parent)


def table(in_process, e2e, either):
    """The table of the packages: their points, those reached in-process, by
    e2e and by either, and those no test reaches, after the exclusion
    list."""
    rows = {}
    for name, points in in_process.items():
        row = rows.setdefault(package_of(name), {"points": 0, "in-process": 0, "e2e": 0, "either": 0})
        for offset, count in points.items():
            other = e2e[name][offset]
            row["points"] += 1
            row["in-process"] += count > 0
            row["e2e"] += other > 0
            row["either"] += count > 0 or other > 0
    lines = ["| package | points | in-process | e2e | either | unreached |", "|---|---:|---:|---:|---:|---:|"]
    total = {"points": 0, "in-process": 0, "e2e": 0, "either": 0, "unreached": 0}
    for package in sorted(rows):
        row = rows[package]
        row["unreached"] = len(either[package].uncovered)
        for key in total:
            total[key] += row[key]
    for package, row in sorted(rows.items()) + [("all", total)]:
        cells = [f"{row[key]} ({percent(row[key], row['points'])})" for key in ("in-process", "e2e", "either")]
        lines.append(f"| {package} | {row['points']} | {' | '.join(cells)} | {row['unreached']} |")
    return lines


def read(path):
    """The files of a bisect report, or the error naming the report."""
    try:
        return coverage_report.read_report(path)
    except ReportError as error:
        raise ReportError(f"{path}: {error}") from None


def report(args):
    """Writes the report into args.out; returns it."""
    root = Path(args.root)
    in_process, e2e = read(args.in_process), read(args.e2e)
    same_points(in_process, e2e)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    in_counts, e2e_counts = counts(in_process), counts(e2e)
    merged = [(name, [(offset, count + e2e_counts[name][offset]) for offset, count in points])
              for name, points in in_process]
    write_bisect(out / "either.bisect", merged)
    exclusions = coverage_report.read_exclusions(root)
    either = coverage_report.read_packages(out / "either.bisect", root, exclusions)
    lines = ["# Coverage from the e2e tests", "", *table(in_counts, e2e_counts, either), ""]
    text = "\n".join(lines)
    (out / "report.md").write_text(text, encoding="utf-8")
    return text


def main():
    parser = argparse.ArgumentParser(description="Report coverage from the e2e tests beside the in-process tests'.")
    steps = parser.add_subparsers(dest="step", required=True)
    reporting = steps.add_parser("report", help="report the points reached in-process, by e2e and by either")
    reporting.add_argument("--in-process", required=True, help="the in-process tests' bisect report")
    reporting.add_argument("--e2e", required=True, help="the e2e tests' bisect report")
    reporting.add_argument("--out", required=True, help="where the report goes")
    reporting.add_argument("--root", default=".", help="the directory the reports' paths are relative to")
    reporting.add_argument("--trees", help="the compiler's parse trees of the sources, as <path>.ast")
    args = parser.parse_args()
    try:
        print(report(args))
    except ReportError as error:
        print(f"coverage-e2e: {error}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
