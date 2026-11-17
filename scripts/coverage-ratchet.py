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
       when they are at or below it. Below it, it says that the floor can
       be lowered, as the change that lowers the count does. The new
       points are those on the lines that the tree adds or changes against
       the merge base below; where none is, it names every uncovered point
       of the package, since a test may no longer reach them. A package of
       the report without a floor, a floor of a package that the report
       does not hold, and a malformed line fail it too. --summary appends
       a table of the packages, with their points and floors, and what the
       check found, in Markdown, to a file, such as CI's job summary.

       Against the merge base of HEAD and <base> (origin/main unless it is
       given), a floor above the base's, or a first floor above 0 for a
       package that had none there, is a raise. A raise fails the check
       unless the change records it in coverage/approved-raises.txt, with
       a line for each package whose floor it raises:

         <package> <points> <reason>

       Only the lines that the change adds record a raise, and those of a
       package must add up to at least its raise. When the merge base has
       no committed floors, nothing is compared with it.

write  writes each package's uncovered points as its floor, keeping the
       comments at the start of the file.

It exits with 2 when it cannot judge: the report cannot be read, or git
cannot answer.
"""

import argparse
import importlib.util
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import NamedTuple

HERE = Path(__file__).resolve().parent
FLOORS = Path("coverage") / "floors.txt"
RAISES = Path("coverage") / "approved-raises.txt"
# A hunk's header in git's diff, with the first line and the count of the
# lines that the newer side has.
HUNK = re.compile(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@")
# How many uncovered points a failure names at most.
LISTED = 50


class GitError(Exception):
    """A git command that failed."""


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


class Raise(NamedTuple):
    """A line of the list of approved raises."""

    package: str
    points: int
    reason: str


def read_raises(text, problems):
    """The lines of a list of approved raises; a malformed line is a
    problem."""
    raises = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split(None, 2)
        if len(fields) != 3 or not fields[1].isdigit() or int(fields[1]) < 1:
            problems.append(f"{RAISES.as_posix()}:{number}: should be <package> <points> <reason>, with a"
                            f" number of points from 1, not: {line}")
            continue
        raises.append(Raise(fields[0], int(fields[1]), fields[2].strip()))
    return raises


def git(root, *args):
    """The output of a git command in root."""
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise GitError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def at_base(root, revision, path):
    """The text of a file at a revision, or None when it has no such file."""
    if not git(root, "ls-tree", "--name-only", revision, "--", path.as_posix()).strip():
        return None
    return git(root, "show", f"{revision}:{path.as_posix()}")


def read_file(root, path):
    """The text of a file of the tree, or the empty text when it has none."""
    return (root / path).read_text(encoding="utf-8") if (root / path).is_file() else ""


def compare_with_base(root, base, merge_base, floors, problems, notes):
    """Compares the floors with those at the merge base: a problem for each
    raise that the lines the change adds to the list of approved raises do
    not cover."""
    base_text = at_base(root, merge_base, FLOORS)
    if base_text is None:
        notes.append(f"the merge base with {base}, {merge_base[:12]}, has no committed floors: nothing to compare"
                     " with")
        return
    base_floors = read_floors(base_text, [])
    earlier = Counter(read_raises(at_base(root, merge_base, RAISES) or "", []))
    recorded = {}
    for line in read_raises(read_file(root, RAISES), problems):
        if earlier[line]:
            earlier[line] -= 1
        else:
            recorded.setdefault(line.package, []).append(line)
    for name in sorted(set(floors) | set(recorded)):
        before, after = base_floors.get(name), floors.get(name, 0)
        rise = after - (before or 0)
        lines = recorded.get(name, [])
        covered = sum(line.points for line in lines)
        reasons = "; ".join(line.reason for line in lines)
        if rise <= 0:
            if lines:
                notes.append(f"{name}: {RAISES.as_posix()} records a raise of {covered}, but its floor did not rise:"
                             f" {reasons}")
        elif covered >= rise:
            notes.append(f"{name}: its floor rose by {rise}, as {RAISES.as_posix()} records: {reasons}")
        else:
            had = "none" if before is None else before
            recorded_part = f"; {RAISES.as_posix()} records {covered} point{'' if covered == 1 else 's'} of it" \
                if covered else ""
            problems.append(f"{name}: its floor rose from {had} to {after} against the merge base with {base},"
                            f" {merge_base[:12]}{recorded_part}. A floor rises only with the maintainer's"
                            f" approval: add \"{name} {rise - covered} <reason>\" to {RAISES.as_posix()} in the same"
                            " change.")


def changed_lines(root, merge_base, files):
    """The lines of each file that the tree adds or changes against the
    merge base: every line of a file that the merge base does not have."""
    changed = {}
    for file in sorted(files):
        if not at_base(root, merge_base, Path(file)):
            changed[file] = None
            continue
        lines = set()
        for line in git(root, "diff", "--unified=0", "--no-color", "--no-ext-diff", merge_base, "--", file).splitlines():
            match = HUNK.match(line)
            if match:
                first, count = int(match.group(1)), int(match.group(2) or 1)
                lines.update(range(first, first + count))
        changed[file] = lines
    return changed


def listed(uncovered, limit=LISTED):
    """Uncovered points, one an indented line, at most limit of them."""
    shown = "".join(f"\n  {file}:{line}:{column}  {definition}" for file, line, column, definition in uncovered[:limit])
    more = len(uncovered) - limit
    return shown + (f"\n  ... and {more} more: see the coverage report" if more > 0 else "")


def above(root, merge_base, name, package, floor):
    """The problem of a package above its floor, naming its new uncovered
    points: those on the lines that the change adds or changes, or all of
    them when none is on such a line."""
    count = len(package.uncovered)
    changed = changed_lines(root, merge_base, {point[0] for point in package.uncovered})
    new = [point for point in package.uncovered
           if changed[point[0]] is None or point[1] in changed[point[0]]]
    head = f"{name}: {points(count)}, above its floor of {floor}."
    if new:
        return f"{head} Its new uncovered points, on the lines that the change adds or changes:{listed(new)}"
    return (f"{head} None is on a line that the change adds or changes, so a test may no longer reach them; its"
            f" uncovered points:{listed(package.uncovered)}")


def summary(packages, floors, problems, notes):
    """The job summary, in Markdown: a table of the packages, with their
    points and floors, then what the check found."""
    lines = ["## Coverage floors", "", "| Package | Points | Covered | Uncovered | Floor |",
             "|---|---:|---:|---:|---:|"]
    for name in sorted(packages):
        package = packages[name]
        floor = floors.get(name)
        lines.append(f"| {name} | {package.points} | {package.covered} | {len(package.uncovered)} |"
                     f" {'none' if floor is None else floor} |")
    for title, found in (("Failed", problems), ("Notes", notes)):
        if found:
            lines += ["", f"### {title}", ""]
            lines += fenced([line for item in found for line in item.splitlines()])
    return lines


def fenced(lines):
    """Lines in a fenced block of Markdown."""
    return ["```text", *lines, "```"]


def check(root, report, base, summary_file=None):
    """Checks the uncovered points of each package against its floor, and
    the floors against the base: whether it passed."""
    packages = report_module.read_packages(report, root)
    merge_base = git(root, "merge-base", "HEAD", base).strip()
    problems, notes = [], []
    floors = read_floors(read_file(root, FLOORS), problems)
    for name in sorted(set(floors) - set(packages)):
        problems.append(f"{name}: a floor of {floors[name]}, but the report has no such package: remove its line"
                        f" from {FLOORS.as_posix()}")
    for name in sorted(packages):
        package = packages[name]
        count = len(package.uncovered)
        floor = floors.get(name)
        if floor is None:
            problems.append(f"{name}: {points(count)}, and no floor: add \"{name} {count}\" to {FLOORS.as_posix()}")
        elif count > floor:
            problems.append(above(root, merge_base, name, package, floor))
        elif count == floor:
            notes.append(f"{name}: {points(count)}, at its floor of {floor}")
        else:
            notes.append(f"{name}: {points(count)}, below its floor of {floor}: lower it to {count} in this"
                         f" change (python3 scripts/coverage-ratchet.py write {report})")
    compare_with_base(root, base, merge_base, floors, problems, notes)
    for note in notes:
        print(f"coverage-ratchet: {note}")
    for problem in problems:
        print(f"coverage-ratchet: {problem}", file=sys.stderr)
    if summary_file:
        with open(summary_file, "a", encoding="utf-8") as out:
            out.write("".join(f"{line}\n" for line in summary(packages, floors, problems, notes)))
    return not problems


def write(root, report):
    """Writes each package's uncovered points as its floor."""
    packages = report_module.read_packages(report, root)
    path = root / FLOORS
    text = path.read_text(encoding="utf-8") if path.is_file() else ""
    header = []
    for line in text.splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            break
        header.append(line)
    while header and not header[-1].strip():
        header.pop()
    lines = header + ([""] if header else [])
    lines += [f"{name} {len(packages[name].uncovered)}" for name in sorted(packages)]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")
    print(f"coverage-ratchet: wrote the floors of {len(packages)} packages into {FLOORS.as_posix()}")


def main():
    parser = argparse.ArgumentParser(description="Check or write each package's floor of uncovered points.")
    parser.add_argument("--root", default=".", help="the checkout the report's paths are relative to")
    commands = parser.add_subparsers(dest="command", required=True)
    checking = commands.add_parser("check", help="check the uncovered points against the floors")
    checking.add_argument("--base", default="origin/main", help="compare the floors with the merge base of HEAD and this")
    checking.add_argument("--summary", help="append a table of the packages, in Markdown, to this file")
    checking.add_argument("report", help="the bisect report")
    writing = commands.add_parser("write", help="write each package's uncovered points as its floor")
    writing.add_argument("report", help="the bisect report")
    args = parser.parse_args()
    root = Path(args.root)
    try:
        if args.command == "write":
            write(root, args.report)
            return
        passed = check(root, args.report, args.base, args.summary)
    except report_module.ReportError as error:
        print(f"coverage-ratchet: {args.report}: {error}", file=sys.stderr)
        sys.exit(2)
    except GitError as error:
        print(f"coverage-ratchet: {error}", file=sys.stderr)
        sys.exit(2)
    if not passed:
        sys.exit(1)


if __name__ == "__main__":
    main()
