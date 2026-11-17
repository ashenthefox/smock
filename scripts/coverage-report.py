#!/usr/bin/env python3
"""Reports point coverage per package from a bisect report of moon_cove,
the MoonBit toolchain's coverage reader (scripts/coverage.sh makes one).

usage: python3 scripts/coverage-report.py [--root <dir>] <report>

<report> is in the format moon_cove writes with -f bisect: BISECT-COVERAGE-4,
the number of files, then for each file its path, the byte offsets of its
points and their counts. A path is relative to <root>, the directory
moon_cove ran in (the current directory unless given), and a file's package
is its directory.

A point is covered when its count is above 0. For each package it prints
the points covered of all, with line figures beside them: the lines that
hold a point, and those of them whose every point is covered, so that a
partly covered line never counts as covered.
"""

import re
import sys
from pathlib import Path

# The first line of a top-level definition: moon fmt starts each at the
# first column, and nothing else that holds a point starts there.
DEFINITION = re.compile(
    r"(?:pub(?:\([a-z]+\))? |priv )?(?:async )?"
    r"(fn|impl|let|const|test|struct|enum|type|suberror|trait|extern)\b ?(.*)"
)


def read_report(path):
    """The files of a bisect report: (path, [(offset, count)]) in order."""
    tokens = Path(path).read_text().split()
    files = []
    at = 2
    for _ in range(int(tokens[1])):
        name = tokens[at + 1]
        points = int(tokens[at + 2])
        offsets = [int(t) for t in tokens[at + 3 : at + 3 + points]]
        at += 3 + points
        counts = [int(t) for t in tokens[at + 1 : at + 1 + points]]
        at += 1 + points
        files.append((name, list(zip(offsets, counts))))
    return files


def skip_type_parameters(text):
    """text without the type parameters it starts with, such as [S : Show]."""
    if not text.startswith("["):
        return text
    depth = 0
    for at, char in enumerate(text):
        depth += {"[": 1, "]": -1}.get(char, 0)
        if depth == 0:
            return text[at + 1 :].lstrip()
    return text


def definition_name(line):
    """The name of the top-level definition that starts on a line, or None
    when none starts there: Type::method or name for a function,
    "impl Trait for Type with method" for a method of a trait, and the
    keyword and the name for anything else, such as "let name"."""
    match = DEFINITION.match(line)
    if match is None:
        return None
    keyword, rest = match.group(1), match.group(2)
    if keyword == "fn":
        name = re.match(r"[\w@.:]+", skip_type_parameters(rest))
        return name.group(0) if name else "fn"
    if keyword == "impl":
        head, _, method = skip_type_parameters(rest).partition(" with ")
        method = re.match(r"(?:fn )?(\w+)", method)
        return f"impl {head.strip()}" + (f" with {method.group(1)}" if method else "")
    name = re.match(r'"[^"]*"|[\w@.:]+', rest)
    return f"{keyword} {name.group(0)}" if name else keyword


def line_of(starts, offset):
    """The line, from 1, that holds a byte offset, given each line's start."""
    low, high = 0, len(starts) - 1
    while low < high:
        middle = (low + high + 1) // 2
        if starts[middle] <= offset:
            low = middle
        else:
            high = middle - 1
    return low + 1


class Package:
    """The points and lines of one package."""

    def __init__(self, name):
        self.name = name
        self.points = 0
        self.covered = 0
        self.lines = {}
        self.uncovered = []

    def add(self, file, line, column, definition, count):
        """Adds a point of a file, at a line and column, in a definition,
        with its count."""
        self.points += 1
        if count > 0:
            self.covered += 1
        else:
            self.uncovered.append((file, line, column, definition))
        key = (file, line)
        self.lines[key] = self.lines.get(key, True) and count > 0

    def lines_covered(self):
        """The lines whose every point is covered."""
        return sum(1 for covered in self.lines.values() if covered)


def percent(part, whole):
    """part of whole, as a percentage with one decimal."""
    return f"{100 * part / whole:.1f}%" if whole else "-"


def main(args):
    root = Path(".")
    if args[:1] == ["--root"]:
        root = Path(args[1])
        args = args[2:]
    report = args[0]
    packages = {}
    for name, points in read_report(report):
        data = (root / name).read_bytes()
        starts = [0] + [at + 1 for at, byte in enumerate(data) if byte == 10]
        lines = data.decode("utf-8").split("\n")
        package = packages.setdefault(name.rsplit("/", 1)[0], Package(name.rsplit("/", 1)[0]))
        for offset, count in sorted(points):
            line = line_of(starts, offset)
            column = len(data[starts[line - 1] : offset].decode("utf-8")) + 1
            definition = next(
                (d for d in map(definition_name, reversed(lines[:line])) if d), "(none)"
            )
            package.add(name, line, column, definition, count)
    for name in sorted(packages):
        package = packages[name]
        if package.uncovered:
            print(f"{name}: {len(package.uncovered)} of {package.points} points uncovered")
            for file, line, column, definition in package.uncovered:
                print(f"  {file}:{line}:{column}  {definition}")
    width = max(len(name) for name in packages)
    for name in sorted(packages):
        package = packages[name]
        print(
            f"{name:<{width}}  {package.covered} of {package.points}  "
            f"{percent(package.covered, package.points)}  "
            f"{package.points - package.covered}  "
            f"{package.lines_covered()} of {len(package.lines)}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
