#!/usr/bin/env python3
"""Checks the use-case and boundary ledgers, docs/ledgers/use-cases.md and
docs/ledgers/boundaries.md (CONTRIBUTING.md, "How tests are judged"). Each
test and check a row names must be there, so that a test renamed, moved to
another file or removed fails the check until the ledger follows it, and
each row must say where its feature, limit or message comes from and how
far it is checked.

usage: python3 scripts/check-ledgers.py [<tree>]

<tree> is the checkout to check: this one, unless it is given.

A ledger is Markdown. Its rows are those of the tables whose header's
first cell is ID, and the header gives the table's kind by its columns:

  | ID | Feature | Source | Status | Checked by |
      a documented feature; its id is F and two digits, and its status
      tested, partly, manual or open;
  | ID | Message | Source | Seen by | Status | Checked by |
      a message smock gives; its id is M and two digits, its status
      asserted, open, deleted or manual, and seen by user, when a user of
      smock can see it, package, when only a package's interface shows it,
      or nobody, when no input reaches it;
  | ID | Limit | Source | Package | Status | At the limit | Just past it |
      a limit; its id is L, two digits and maybe a lower-case letter, its
      status tested, partly or open, and its package one or more package
      directories, each in backquotes and separated by ", ", that hold it.

Another table whose header starts with ID is a problem. Each row has a
cell for each column. Its id is unique across the two ledgers. Its source
holds a Markdown link or names an issue (#<number>).

The cells that name what checks a row (Checked by, At the limit and Just
past it) hold entries separated by <br>, each one of these, and maybe text
after it:

  `<path>` "<name>"
      a test: <path> is a test file, a path from <tree> that ends in
      _test.mbt, _wbtest.mbt or .mbt.md, and <name> the test's name as the
      file writes it between the quotes, escapes included, as moon's test
      metadata and the keep list name it. The file must hold exactly one
      test block of that name: a line that starts with `test "<name>"` or
      `async test "<name>"`, as moon fmt writes test blocks. A name in a
      comment or in a string, or the start of a longer name, is not a test;
  `<path>`
      a check that CI runs, such as a script: <path> is a file or a
      directory of <tree> that is not a test file;
  #<number>
      a ticket or an issue that adds what is missing, or that deleted a
      message;
  Manual: <reason>
      a manual check, with why it is not automated.

The status agrees with the entries:

  tested, asserted
      tests and checks alone; for a limit, on each side;
  partly
      tests, checks and tickets alone, with at least one ticket and one
      test or check;
  manual
      at least one manual check;
  open
      tickets alone;
  deleted
      tickets alone: the one that deleted the message.

It prints each problem as <ledger>:<line>: <id>: <what is wrong>, and then
a count. It exits with 1 when it found a problem, and with 2 when a ledger
or a test file cannot be read.

CI runs it on every push (ci.yml). scripts/test-check-ledgers.sh tests it.
It needs Python 3.9 or later.
"""
import os
import re
import sys

LEDGERS = ["docs/ledgers/use-cases.md", "docs/ledgers/boundaries.md"]
KINDS = {
    ("ID", "Feature", "Source", "Status", "Checked by"): "feature",
    ("ID", "Message", "Source", "Seen by", "Status", "Checked by"): "message",
    ("ID", "Limit", "Source", "Package", "Status", "At the limit", "Just past it"): "limit",
}
TEST_COLUMNS = {"feature": ["Checked by"], "message": ["Checked by"], "limit": ["At the limit", "Just past it"]}
TEST_FILE = re.compile(r".*(?:_test\.mbt|_wbtest\.mbt|\.mbt\.md)")
TEST_HEAD = re.compile(r'(?:async )?test "((?:[^"\\]|\\.)*)"')
TEST_ENTRY = re.compile(r'`([^`]+)` "((?:[^"\\]|\\.)*)"')
CHECK_ENTRY = re.compile(r"`([^`]+)`(?:\s|$)")
TICKET_ENTRY = re.compile(r"#[0-9]+\b")
MANUAL_ENTRY = re.compile(r"Manual: \S")
ID = {
    "feature": re.compile(r"F[0-9]{2}"),
    "message": re.compile(r"M[0-9]{2}"),
    "limit": re.compile(r"L[0-9]{2}[a-z]?"),
}
ID_SHAPES = {
    "feature": "F and two digits",
    "message": "M and two digits",
    "limit": "L, two digits and maybe a lower-case letter",
}
STATUSES = {
    "feature": ["tested", "partly", "manual", "open"],
    "message": ["asserted", "open", "deleted", "manual"],
    "limit": ["tested", "partly", "open"],
}
LINK = re.compile(r"\]\([^)]+\)")
TICKET = re.compile(r"#[0-9]+\b")
PACKAGE = re.compile(r"`([^`]+)`")
PACKAGES = re.compile(r"`[^`]+`(?:, `[^`]+`)*")


def plural(count, word):
    return f"{count} {word}" if count == 1 else f"{count} {word}s"


def cells(line):
    """The cells of the table row `line`, trimmed."""
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


class Tree:
    """The test files of a tree, read once each."""

    def __init__(self, root):
        self.root = root
        self.names = {}

    def tests(self, path):
        """The names of the test blocks of `path`, or None when there is no
        such file."""
        if path not in self.names:
            full = os.path.join(self.root, path)
            if not self.exists(path) or not os.path.isfile(full):
                self.names[path] = None
            else:
                with open(full, encoding="utf-8") as f:
                    self.names[path] = [m.group(1) for m in map(TEST_HEAD.match, f) if m]
        return self.names[path]

    def exists(self, path):
        """Whether `path`, a path from the tree's root, is a file or a
        directory of the tree."""
        parts = path.split("/")
        if path.startswith("/") or ".." in parts:
            return False
        return os.path.exists(os.path.join(self.root, path))


def entry_kind(entry):
    """What the entry `entry` of a cell that names what checks a row is: a
    test, a check, a ticket or a manual check, or None."""
    test = TEST_ENTRY.match(entry)
    if test and TEST_FILE.fullmatch(test.group(1)):
        return "test"
    check = CHECK_ENTRY.match(entry)
    if check and not TEST_FILE.fullmatch(check.group(1)):
        return "check"
    if TICKET_ENTRY.match(entry):
        return "ticket"
    if MANUAL_ENTRY.match(entry):
        return "manual"
    return None


def entry_problems(entry, column, tree):
    """The problems of `entry`, an entry of the cell of `column` that names
    what checks a row."""
    if not entry:
        return [f"an entry of {column} is empty"]
    kind = entry_kind(entry)
    if kind is None:
        return [f'"{entry}" is not a test, a check, a ticket or a manual check']
    if kind == "test":
        path, name = TEST_ENTRY.match(entry).groups()
        names = tree.tests(path)
        if names is None:
            return [f"{path}: no such file"]
        count = names.count(name)
        if count == 0:
            return [f'{path}: no test named "{name}"']
        if count > 1:
            return [f'{path}: {count} tests are named "{name}"']
    if kind == "check":
        path = CHECK_ENTRY.match(entry).group(1)
        if not tree.exists(path):
            return [f"{path}: no such file or directory"]
    return []


def status_problem(kind, status, sides):
    """What is wrong with the status `status` of a row of `kind`, whose
    cells that name what checks it hold the entries of the kinds `sides`,
    one set for each cell, or None."""
    if status not in STATUSES[kind]:
        listed = STATUSES[kind]
        return f"the status is not {', '.join(listed[:-1])} or {listed[-1]}"
    found = set().union(*sides)
    tested = bool(found & {"test", "check"})
    if status in ("tested", "asserted"):
        if not all(side and side <= {"test", "check"} for side in sides):
            what = "an asserted row" if status == "asserted" else "a tested row"
            return f"{what} names tests and checks alone"
    elif status == "partly":
        if not (found <= {"test", "check", "ticket"} and tested and "ticket" in found):
            return (
                "a partly tested row names tests, checks and tickets alone,"
                " with at least one ticket and one test or check"
            )
    elif status == "manual":
        if "manual" not in found:
            return "a manual row names a manual check with its reason"
    elif status == "open":
        if found != {"ticket"}:
            return "an open row names tickets alone"
    elif status == "deleted":
        if found != {"ticket"}:
            return "a deleted row names tickets alone: the one that deleted it"
    return None


def package_problems(cell, tree):
    """The problems of `cell`, a limit's cell that names the packages that
    hold it."""
    if not PACKAGES.fullmatch(cell):
        return ["the package is not one or more package directories, each in backquotes"]
    problems = []
    for package in PACKAGE.findall(cell):
        if not tree.exists(f"{package}/moon.pkg"):
            problems.append(f"{package} is not a package: it has no moon.pkg")
    return problems


def row_problems(kind, values, tree):
    """The problems of a row of `kind`, whose cells are `values` by their
    column."""
    problems = []
    row_id = values["ID"]
    if not ID[kind].fullmatch(row_id):
        problems.append(f"the id is not {ID_SHAPES[kind]}")
    if not (LINK.search(values["Source"]) or TICKET.search(values["Source"])):
        problems.append("the source has no link and names no issue")
    if kind == "message" and values["Seen by"] not in ("user", "package", "nobody"):
        problems.append("seen by is not user, package or nobody")
    if kind == "limit":
        problems += package_problems(values["Package"], tree)
    sides = []
    for column in TEST_COLUMNS[kind]:
        side = set()
        for entry in values[column].split("<br>"):
            entry = entry.strip()
            problems += entry_problems(entry, column, tree)
            if entry and entry_kind(entry):
                side.add(entry_kind(entry))
        sides.append(side)
    problem = status_problem(kind, values["Status"], sides)
    if problem is not None:
        problems.append(problem)
    return problems


def ledger_problems(path, text, tree, counts, ids):
    """The problems of the ledger `path`, whose text is `text`, each as
    (line, id, text). `ids` maps each id seen in the ledgers so far to where
    its row is."""
    problems = []
    kind = None
    columns = []
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.startswith("|"):
            kind = None
            continue
        row = cells(line)
        if kind is None:
            if row and row[0] == "ID":
                kind = KINDS.get(tuple(row), "unknown")
                columns = row
                if kind == "unknown":
                    problems.append(
                        (number, None, "the table's columns are not those of the features, the messages or the limits")
                    )
            continue
        if kind == "unknown" or all(set(cell) <= set("-: ") for cell in row):
            continue
        counts[kind] += 1
        values = dict(zip(columns, row))
        row_id = values["ID"]
        if len(row) != len(columns):
            problems.append((number, row_id, f"the row has {len(row)} cells, not {len(columns)}"))
            continue
        found = row_problems(kind, values, tree)
        if row_id in ids:
            found.append(f"{ids[row_id]} has the id {row_id} too")
        else:
            ids[row_id] = f"{path}:{number}"
        problems += [(number, row_id, problem) for problem in found]
    return problems


def main(argv):
    if len(argv) > 2 or any(arg.startswith("-") for arg in argv[1:]):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    root = argv[1] if len(argv) > 1 else here
    tree = Tree(root)
    counts = {"feature": 0, "message": 0, "limit": 0}
    problems = []
    ids = {}
    try:
        for ledger in LEDGERS:
            try:
                with open(os.path.join(root, ledger), encoding="utf-8") as f:
                    text = f.read()
            except (OSError, UnicodeDecodeError) as error:
                why = error.strerror if isinstance(error, OSError) else "it is not UTF-8"
                print(f"check-ledgers: cannot read {ledger}: {why}", file=sys.stderr)
                return 2
            problems += [(ledger,) + problem for problem in ledger_problems(ledger, text, tree, counts, ids)]
    except (OSError, UnicodeDecodeError) as error:
        print(f"check-ledgers: cannot read a test file: {error}", file=sys.stderr)
        return 2
    for ledger, line, row, text in problems:
        print(f"{ledger}:{line}: {text}" if row is None else f"{ledger}:{line}: {row}: {text}")
    counted = (
        f"{plural(counts['feature'], 'feature')}, {plural(counts['message'], 'message')}"
        f" and {plural(counts['limit'], 'limit')}"
    )
    if problems:
        print(f"check-ledgers: {counted}, {plural(len(problems), 'problem')}")
        return 1
    print(f"check-ledgers: {counted}, each test and check found")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
