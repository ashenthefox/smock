#!/usr/bin/env python3
"""Checks the keep list, mutation/kept-tests.toml: the tests that removal
rule (C) keeps for a reason the kill matrix cannot see (CONTRIBUTING.md,
"How tests are judged"). Each test the list names must still be there, so
that a listed test cannot vanish unnoticed: a test renamed, moved to
another file or removed fails the check until the list follows it.

usage: python3 scripts/check-kept-tests.py [<list> [<tree>]]

<list> is the keep list, mutation/kept-tests.toml of the checkout unless
it is given; <tree> is the directory its paths start from, the checkout
unless it is given.

The list is TOML, with nothing at its top but these:

  [derived]
      reasons    the keep reasons of rule (C) that are derived per batch,
                 from the ledgers and the trace links, and so not listed:
                 a list of strings, not empty.
  [[reason]]
      id         lower-case words joined by hyphens, unique in the list;
      rule       which reason of rule (C) it is: spec constant, backend
                 agreement, dependency or deliberate overlap;
      title      what the reason keeps;
      source     where the reason comes from;
      search     the searches over test names, files and comments that
                 found its tests: a list of strings, not empty;
      found      what the searches found, and how their hits were judged,
                 or that they found no test;
      [[reason.test]], one for each test kept for the reason, if any:
        file     the test's file, a path from <tree> that ends in
                 _test.mbt, _wbtest.mbt or .mbt.md;
        name     the test's name, as its file writes it between the
                 quotes, escapes included, which is how moon's test
                 metadata names it;
        source   what the test checks, and where its expected value
                 comes from.

Every key is a string unless it says otherwise, and none is empty. A test
may be kept for several reasons, but listed once under each.

A test is there when its file holds exactly one test block of that name: a
line that starts with `test "<name>"` or `async test "<name>"`, as moon fmt
writes test blocks, in a .mbt.md file inside its code. A name in a comment
or in a string, or the start of a longer name, is not a test.

It prints each problem as <list>: <reason>: <what is wrong>, and then a
count. It exits with 1 when it found a problem, and with 2 when the list
cannot be read or is not TOML.

CI runs it on every push (ci.yml). scripts/test-check-kept-tests.sh tests
it. It needs Python 3.11 or later, for tomllib.
"""
import os
import re
import sys
import tomllib

RULES = ["spec constant", "backend agreement", "dependency", "deliberate overlap"]
REASON_KEYS = ["id", "rule", "title", "source", "search", "found", "test"]
TEST_KEYS = ["file", "name", "source"]
ID = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
TEST_FILE = re.compile(r".*(?:_test\.mbt|_wbtest\.mbt|\.mbt\.md)")
TEST_HEAD = re.compile(r'(?:async )?test "((?:[^"\\]|\\.)*)"')


def plural(count, word):
    return f"{count} {word}" if count == 1 else f"{count} {word}s"


def text_problem(table, key):
    """What is wrong with `table[key]` as a string that is not empty, or
    None."""
    if key not in table:
        return f"no {key}"
    if not isinstance(table[key], str):
        return f"the {key} is not a string"
    if not table[key]:
        return f"the {key} is empty"
    return None


def texts_problem(table, key):
    """What is wrong with `table[key]` as a list, not empty, of strings
    that are not empty, or None."""
    if key not in table:
        return f"no {key}"
    value = table[key]
    if not isinstance(value, list):
        return f"the {key} is not a list"
    if not value:
        return f"the {key} is empty"
    if not all(isinstance(item, str) and item for item in value):
        return f"the {key} holds something that is not a string, or an empty one"
    return None


def path_problem(path):
    """What is wrong with `path` as a test file's path from the tree, or
    None."""
    parts = path.split("/")
    if path.startswith("/") or ".." in parts or "" in parts or "." in parts:
        return f"{path} is not a path inside the tree"
    if not TEST_FILE.fullmatch(path):
        return f"{path} is not a test file: its name ends in _test.mbt, _wbtest.mbt or .mbt.md"
    return None


class Tree:
    """The test files of a tree, read once each."""

    def __init__(self, root):
        self.root = root
        self.names = {}

    def tests(self, path):
        """The names of the test blocks of `path`, in order, or None when
        there is no such file."""
        if path not in self.names:
            full = os.path.join(self.root, path)
            if not os.path.isfile(full):
                self.names[path] = None
            else:
                with open(full, encoding="utf-8") as f:
                    names = []
                    for line in f:
                        head = TEST_HEAD.match(line)
                        if head:
                            names.append(head.group(1))
                self.names[path] = names
        return self.names[path]


def reason_problems(reason, number, ids, tree):
    """The problems of `reason`, the list's `number`th, each as (label,
    text), and how many tests it lists."""
    if not isinstance(reason, dict):
        return [(f"reason {number}", "is not a table")], 0
    label = reason["id"] if isinstance(reason.get("id"), str) and reason["id"] else f"reason {number}"
    problems = []
    fault = text_problem(reason, "id")
    if fault is None and not ID.fullmatch(reason["id"]):
        label = f"reason {number}"
        fault = "the id is not lower-case words joined by hyphens"
    elif fault is None and reason["id"] in ids:
        fault = f"another reason has the id {reason['id']}"
    if fault is None:
        ids.add(reason["id"])
    else:
        problems.append((label, fault))
    for key in sorted(set(reason) - set(REASON_KEYS)):
        problems.append((label, f"{key} is not a key of a reason"))
    for key in ["rule", "title", "source", "found"]:
        fault = text_problem(reason, key)
        if fault is None and key == "rule" and reason["rule"] not in RULES:
            fault = f"the rule is not one of {', '.join(RULES[:-1])} and {RULES[-1]}"
        if fault is not None:
            problems.append((label, fault))
    fault = texts_problem(reason, "search")
    if fault is not None:
        problems.append((label, fault))
    tests = reason.get("test", [])
    if not isinstance(tests, list):
        problems.append((label, "the test is not a list of tables"))
        return problems, 0
    seen = set()
    for n, test in enumerate(tests, start=1):
        problems += [(label, text) for text in test_problems(test, n, seen, tree)]
    return problems, len(tests)


def test_problems(test, number, seen, tree):
    """The problems of `test`, the `number`th of its reason, given the
    tests listed before it under that reason, `seen`."""
    where = f"test {number}"
    if not isinstance(test, dict):
        return [f"{where}: is not a table"]
    problems = [f"{where}: {key} is not a key of a test" for key in sorted(set(test) - set(TEST_KEYS))]
    for key in TEST_KEYS:
        fault = text_problem(test, key)
        if fault is None and key == "file":
            fault = path_problem(test["file"])
        if fault is not None:
            problems.append(f"{where}: {fault}")
    if problems:
        return problems
    path, name = test["file"], test["name"]
    if (path, name) in seen:
        return [f'{path}: "{name}" is listed twice']
    seen.add((path, name))
    names = tree.tests(path)
    if names is None:
        return [f"{path}: no such file"]
    count = names.count(name)
    if count == 0:
        return [f'{path}: no test named "{name}"']
    if count > 1:
        return [f'{path}: {count} tests are named "{name}"']
    return []


def list_problems(kept, tree):
    """The problems of the keep list `kept`, each as (label, text) with
    None for the list as a whole, and the counts of its reasons and its
    tests."""
    problems = []
    for key in sorted(set(kept) - {"derived", "reason"}):
        problems.append((None, f"{key} is not a key of the list"))
    derived = kept.get("derived")
    if derived is None:
        problems.append((None, "no derived: the list says which keep reasons are derived per batch"))
    elif not isinstance(derived, dict):
        problems.append((None, "derived is not a table"))
    else:
        fault = texts_problem(derived, "reasons")
        if fault == "the reasons is empty":
            fault = "no reasons"
        if fault is not None:
            problems.append(("derived", fault))
        for key in sorted(set(derived) - {"reasons"}):
            problems.append(("derived", f"{key} is not a key of derived"))
    reasons = kept.get("reason", [])
    if not isinstance(reasons, list):
        problems.append((None, "reason is not a list of tables"))
        return problems, 0, 0
    if not reasons:
        problems.append((None, "no reason"))
    ids = set()
    tests = 0
    for number, reason in enumerate(reasons, start=1):
        found, count = reason_problems(reason, number, ids, tree)
        problems += found
        tests += count
    return problems, len(reasons), tests


def main(argv):
    if len(argv) > 3 or any(arg.startswith("-") for arg in argv[1:]):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = argv[1] if len(argv) > 1 else os.path.join(here, "mutation", "kept-tests.toml")
    root = argv[2] if len(argv) > 2 else here
    try:
        with open(path, "rb") as f:
            kept = tomllib.load(f)
    except OSError as error:
        print(f"check-kept-tests: cannot read {path}: {error.strerror}", file=sys.stderr)
        return 2
    except tomllib.TOMLDecodeError as error:
        print(f"check-kept-tests: {path} is not TOML: {error}", file=sys.stderr)
        return 2
    shown = path if len(argv) > 1 else os.path.relpath(path, here)
    try:
        problems, reasons, tests = list_problems(kept, Tree(root))
    except (OSError, UnicodeDecodeError) as error:
        print(f"check-kept-tests: cannot read a test file: {error}", file=sys.stderr)
        return 2
    for label, text in problems:
        print(f"{shown}: {text}" if label is None else f"{shown}: {label}: {text}")
    counted = f"{plural(tests, 'test')} under {plural(reasons, 'reason')}"
    if problems:
        print(f"check-kept-tests: {counted}, {plural(len(problems), 'problem')}")
        return 1
    print(f"check-kept-tests: {counted}, each found")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
