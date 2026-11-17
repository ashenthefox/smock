#!/usr/bin/env python3
"""Reports point coverage per package from a bisect report of moon_cove,
the MoonBit toolchain's coverage reader (scripts/coverage.sh makes one).

usage: python3 scripts/coverage-report.py [--root <dir>] <report>

<report> is in the format moon_cove writes with -f bisect: BISECT-COVERAGE-4,
the number of files, then for each file its path, the byte offsets of its
points and their counts. A path is relative to <root>, the directory
moon_cove ran in (the current directory unless given), and a file's package
is its directory. Each uncovered point is named by its file, line and
column, the column in characters, and by the top-level definition that
holds it.

A point is covered when its count is above 0. For each package it prints
the points covered of all, with line figures beside them: the lines that
hold a point, and those of them whose every point is covered, so that a
partly covered line never counts as covered. A summary gives the totals
of the packages other than server and cmd/smock, of those two, and of all.

It exits with 2, saying why, when it cannot read the report, or when a
file of the report is not in <root> or is shorter than its points: the
report was then made of other sources than those in <root>.
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


class ReportError(Exception):
    """A bisect report that cannot be read."""


class Reader:
    """Reads the words of a bisect report in turn: numbers, and strings
    that their length in bytes starts."""

    def __init__(self, data):
        self.data = data
        self.at = 0

    def skip_spaces(self):
        """Moves past the white space at the reading position."""
        while self.at < len(self.data) and self.data[self.at : self.at + 1].isspace():
            self.at += 1

    def word(self):
        """The next word, up to white space."""
        self.skip_spaces()
        start = self.at
        while self.at < len(self.data) and not self.data[self.at : self.at + 1].isspace():
            self.at += 1
        if start == self.at:
            raise EOFError
        return self.data[start : self.at].decode("utf-8", "replace")

    def number(self):
        """The next word, which is a number."""
        word = self.word()
        if not word.isdigit():
            raise ReportError(f"{word} is not a number")
        return int(word)

    def string(self):
        """The next string: its length, a space, and that many bytes."""
        length = self.number()
        start = self.at + 1
        self.at = start + length
        after = self.data[self.at : self.at + 1]
        if self.at > len(self.data) or (after and not after.isspace()):
            raise ReportError("a file name is not as long as its length says")
        return self.data[start : self.at].decode("utf-8")

    def numbers(self):
        """The next array of numbers: its length, then each of them."""
        return [self.number() for _ in range(self.number())]

    def at_end(self):
        """Whether only white space is left."""
        self.skip_spaces()
        return self.at == len(self.data)


def read_report(path):
    """The files of a bisect report: (path, [(offset, count)]) in order."""
    reader = Reader(Path(path).read_bytes())
    try:
        if reader.word() != "BISECT-COVERAGE-4":
            raise EOFError
    except EOFError:
        raise ReportError("not a bisect report of format 4 (BISECT-COVERAGE-4)") from None
    files = []
    try:
        expected = reader.number()
        for _ in range(expected):
            name = reader.string()
            offsets = reader.numbers()
            counts = reader.numbers()
            if len(offsets) != len(counts):
                raise ReportError(
                    f"{name} has {len(offsets)} points but {len(counts)} counts"
                )
            files.append((name, list(zip(offsets, counts))))
    except EOFError:
        raise ReportError(f"the report ends before its {expected} files do") from None
    if not reader.at_end():
        raise ReportError("the report goes on after its last file")
    if not files:
        raise ReportError("the report holds no file")
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


# The packages that only the binary runs, and that the e2e tests reach from
# outside: the summary gives their totals apart from the others'.
BINARY_ONLY = ("server", "cmd/smock")


def summary(title, packages):
    """One line of totals over some packages."""
    points = sum(package.points for package in packages)
    covered = sum(package.covered for package in packages)
    lines = sum(len(package.lines) for package in packages)
    lines_covered = sum(package.lines_covered() for package in packages)
    return (
        f"{title}: {covered} of {points} points covered ({percent(covered, points)}), "
        f"{points - covered} uncovered; lines {lines_covered} of {lines}"
    )


def definitions_of(lines):
    """For each line, the name of the top-level definition that holds it."""
    current = "(none)"
    names = []
    for line in lines:
        current = definition_name(line) or current
        names.append(current)
    return names


def read_packages(report, root):
    """The packages of a bisect report, by name, with their points; the
    report's paths are relative to root."""
    packages = {}
    for name, points in read_report(report):
        try:
            data = (root / name).read_bytes()
        except FileNotFoundError:
            raise ReportError(f"{name} is not in {root}") from None
        starts = [0] + [at + 1 for at, byte in enumerate(data) if byte == 10]
        definitions = definitions_of(data.decode("utf-8").split("\n"))
        package_name = str(Path(name).parent)
        package = packages.setdefault(package_name, Package(package_name))
        for offset, count in sorted(points):
            if offset >= len(data):
                raise ReportError(f"{name} has a point at byte {offset}, past its end")
            line = line_of(starts, offset)
            column = len(data[starts[line - 1] : offset].decode("utf-8")) + 1
            package.add(name, line, column, definitions[line - 1], count)
    return packages


def print_report(packages):
    """Prints the uncovered points of each package, a table of the
    packages, and the totals."""
    for name in sorted(packages):
        package = packages[name]
        if package.uncovered:
            print(f"{name}: {len(package.uncovered)} of {package.points} points uncovered")
            for file, line, column, definition in package.uncovered:
                print(f"  {file}:{line}:{column}  {definition}")
    rows = [("package", "points covered", "", "uncovered", "lines covered")]
    for name in sorted(packages):
        package = packages[name]
        rows.append(
            (
                name,
                f"{package.covered} of {package.points}",
                percent(package.covered, package.points),
                str(package.points - package.covered),
                f"{package.lines_covered()} of {len(package.lines)}",
            )
        )
    widths = [max(len(row[column]) for row in rows) for column in range(5)]
    print()
    for row in rows:
        print(
            f"{row[0]:<{widths[0]}}  {row[1]:>{widths[1]}} {row[2]:>{widths[2]}}"
            f"  {row[3]:>{widths[3]}}  {row[4]:>{widths[4]}}"
        )
    print()
    inside = [packages[name] for name in sorted(packages) if name in BINARY_ONLY]
    outside = [packages[name] for name in sorted(packages) if name not in BINARY_ONLY]
    print(summary("Outside server and cmd/smock", outside))
    print(summary("server and cmd/smock", inside))
    print(summary("All packages", outside + inside))


def main(args):
    root = Path(".")
    if args[:1] == ["--root"] and len(args) >= 2:
        root = Path(args[1])
        args = args[2:]
    if len(args) != 1 or args[0].startswith("-"):
        print("usage: python3 scripts/coverage-report.py [--root <dir>] <report>", file=sys.stderr)
        return 2
    report = args[0]
    try:
        packages = read_packages(report, root)
    except ReportError as error:
        print(f"coverage-report: {report}: {error}", file=sys.stderr)
        return 2
    print_report(packages)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
