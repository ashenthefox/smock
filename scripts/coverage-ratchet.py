#!/usr/bin/env python3
"""The coverage ratchet (CONTRIBUTING.md, "The coverage floors"): each
package's committed floor, the most uncovered points it may have, and the
check that a change never raises a package's uncovered points above it.

usage: python3 scripts/coverage-ratchet.py [--root <dir>] check
           [--base <ref>] [--summary <file>] <report>
       python3 scripts/coverage-ratchet.py [--root <dir>] write <report>

<report> is a bisect report that scripts/coverage.sh made
(<target directory>/coverage.bisect), read as scripts/coverage-report.py
reads it, over the tree at <root>, the current directory unless given.
The floors are in <root>/coverage/floors.txt, a line for each package:

  <package> <uncovered points>

check  fails, with 1, when a package's uncovered points are above its
       floor, naming the package and its new uncovered points, and passes
       when they are at or below it.
"""

import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FLOORS = Path("coverage") / "floors.txt"


def load_report_module():
    """scripts/coverage-report.py, whose reader of bisect reports the
    ratchet shares."""
    spec = importlib.util.spec_from_file_location("coverage_report", HERE / "coverage-report.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


report_module = load_report_module()


def points(count):
    """A number of uncovered points, in words."""
    return f"{count} uncovered point{'' if count == 1 else 's'}"


def read_floors(text, problems):
    """The floors of a file of floors, by package; a malformed line is a
    problem."""
    floors = {}
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 2 or not fields[1].isdigit():
            problems.append(f"{FLOORS.as_posix()}:{number}: should be <package> <uncovered points>, not: {line}")
            continue
        floors[fields[0]] = int(fields[1])
    return floors


def check(root, report):
    """Checks the uncovered points of each package against its floor:
    whether it passed."""
    packages = report_module.read_packages(report, root)
    problems, notes = [], []
    path = root / FLOORS
    floors = read_floors(path.read_text(encoding="utf-8") if path.is_file() else "", problems)
    for name in sorted(packages):
        package = packages[name]
        count = len(package.uncovered)
        floor = floors.get(name)
        if floor is None:
            continue
        if count > floor:
            listed = "".join(f"\n  {file}:{line}:{column}  {definition}"
                             for file, line, column, definition in package.uncovered)
            problems.append(f"{name}: {points(count)}, above its floor of {floor}. Its uncovered points:{listed}")
        elif count == floor:
            notes.append(f"{name}: {points(count)}, at its floor of {floor}")
    for note in notes:
        print(f"coverage-ratchet: {note}")
    for problem in problems:
        print(f"coverage-ratchet: {problem}", file=sys.stderr)
    return not problems


def main():
    parser = argparse.ArgumentParser(description="Check or write each package's floor of uncovered points.")
    parser.add_argument("--root", default=".", help="the checkout the report's paths are relative to")
    commands = parser.add_subparsers(dest="command", required=True)
    checking = commands.add_parser("check", help="check the uncovered points against the floors")
    checking.add_argument("--base", default="origin/main", help="compare the floors with the merge base of HEAD and this")
    checking.add_argument("report", help="the bisect report")
    args = parser.parse_args()
    root = Path(args.root)
    try:
        passed = check(root, args.report)
    except report_module.ReportError as error:
        print(f"coverage-ratchet: {args.report}: {error}", file=sys.stderr)
        sys.exit(2)
    if not passed:
        sys.exit(1)


if __name__ == "__main__":
    main()
