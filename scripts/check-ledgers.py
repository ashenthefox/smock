#!/usr/bin/env python3
"""Checks the use-case and boundary ledgers, docs/ledgers/use-cases.md and
docs/ledgers/boundaries.md.

usage: python3 scripts/check-ledgers.py [<tree>]

<tree> is the checkout to check: this one, unless it is given.
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
            if not os.path.isfile(full):
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


def row_problems(kind, values, tree):
    """The problems of a row of `kind`, whose cells are `values` by their
    column."""
    problems = []
    row_id = values["ID"]
    if not ID[kind].fullmatch(row_id):
        problems.append(f"the id is not {ID_SHAPES[kind]}")
    if not (LINK.search(values["Source"]) or TICKET.search(values["Source"])):
        problems.append("the source has no link and names no issue")
    if kind == "message" and values["Seen by"] not in ("user", "package"):
        problems.append("seen by is not user or package")
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
                kind = KINDS.get(tuple(row))
                columns = row
            continue
        if all(set(cell) <= set("-: ") for cell in row):
            continue
        counts[kind] += 1
        values = dict(zip(columns, row + [""] * (len(columns) - len(row))))
        row_id = values["ID"]
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
    for ledger in LEDGERS:
        with open(os.path.join(root, ledger), encoding="utf-8") as f:
            text = f.read()
        problems += [(ledger,) + problem for problem in ledger_problems(ledger, text, tree, counts, ids)]
    for ledger, line, row, text in problems:
        print(f"{ledger}:{line}: {row}: {text}")
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
