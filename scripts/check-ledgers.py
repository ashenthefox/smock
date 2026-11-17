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


def entry_problems(entry, tree):
    """The problems of one entry of a cell that names what checks a row."""
    test = TEST_ENTRY.match(entry)
    if test and TEST_FILE.fullmatch(test.group(1)):
        path, name = test.groups()
        names = tree.tests(path)
        if names is None:
            return [f"{path}: no such file"]
        if names.count(name) == 0:
            return [f'{path}: no test named "{name}"']
    return []


def ledger_problems(path, text, tree, counts):
    """The problems of the ledger `path`, whose text is `text`, each as
    (line, id, text)."""
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
        values = dict(zip(columns, row))
        for column in TEST_COLUMNS[kind]:
            for entry in values.get(column, "").split("<br>"):
                for problem in entry_problems(entry.strip(), tree):
                    problems.append((number, values["ID"], problem))
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
    for ledger in LEDGERS:
        with open(os.path.join(root, ledger), encoding="utf-8") as f:
            text = f.read()
        problems += [(ledger,) + problem for problem in ledger_problems(ledger, text, tree, counts)]
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
