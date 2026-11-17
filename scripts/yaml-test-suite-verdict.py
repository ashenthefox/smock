#!/usr/bin/env python3
"""Judges smock's YAML parser in one of its modes against yaml-test-suite,
from the testee's answers and the list of cases that do not pass in that
mode.

usage: python3 scripts/yaml-test-suite-verdict.py <list> <suite> <answers>

<list> is yaml-test-suite/<mode>.txt, where <mode> is safe (the safe subset,
which Definition files use) or openapi (the mode for OpenAPI documents); its
name, without .txt, names the mode. <suite> is the directory of
yaml-test-suite's data release, one directory for each case, which
scripts/fetch-yaml-test-suite.sh unpacks. <answers> is what the testee,
yaml-test-suite/, printed for every case: one line of JSON each.

A case passes when smock reads it as the suite does:

- When the suite marks the input an error, smock refuses it.
- Otherwise, when the suite gives the JSON it reads as, smock reads that
  JSON: the same values, and the members of each object in the same order.
- Otherwise, the suite gives no JSON, and smock reads the input.

Each line of the list names a case, why it is listed, and the reason in
words, separated by spaces; a line that starts with # is a comment. Why is
one of

  differs   a known difference: smock reads the case otherwise on purpose.
  skipped   the testee skips the case.
  #<issue>  a bug: the case fails until that issue is done.

It prints how many cases passed, every listed case with its outcome and
reason, and every case that failed or was skipped without being listed
with that outcome, with what the suite and smock read. It exits with 1
when a case failed or was skipped without being listed with that outcome,
when a listed case passed, which must then come off the list, when a
listed case is not in the suite, or when a case has no answer; on GitHub
Actions, a listed case that passed is also an error on its line of the
list. It exits with 2 when it cannot read the list, the suite or the
answers.
"""

import json
import os
import re
import sys
from pathlib import Path

MODES = ("safe", "openapi")


class ListError(Exception):
    """A line of the list that cannot be read."""


class Object(list):
    """A JSON object, as the pairs of its members in order, so that the
    order of members counts when two objects are compared."""


def load(text):
    """Every JSON value in text, one after the other, with objects as
    Object."""
    decoder = json.JSONDecoder(object_pairs_hook=Object)
    values = []
    position = 0
    while True:
        while position < len(text) and text[position].isspace():
            position += 1
        if position == len(text):
            return values
        value, position = decoder.raw_decode(text, position)
        values.append(value)


def same(a, b):
    """Whether two JSON values are the same: booleans are not numbers, and
    numbers are the same when their values are."""
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, Object) and isinstance(b, Object):
        return len(a) == len(b) and all(ka == kb and same(va, vb) for (ka, va), (kb, vb) in zip(a, b))
    if isinstance(a, list) and isinstance(b, list) and not isinstance(a, Object) and not isinstance(b, Object):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def plain(value):
    """value with each Object as a dict, to print it."""
    if isinstance(value, Object):
        return {key: plain(member) for key, member in value}
    if isinstance(value, list):
        return [plain(item) for item in value]
    return value


def shown(value):
    """value as JSON on one line."""
    return json.dumps(plain(value), ensure_ascii=False)


class Entry:
    """A case on the list: why it is listed, the reason, and its line."""

    def __init__(self, why, reason, line):
        self.why = why
        self.reason = reason
        self.line = line

    def allows(self, outcome):
        """Whether the case may have this outcome, other than passing."""
        return outcome == ("skipped" if self.why == "skipped" else "failed")

    def how(self):
        """How the case is listed, in words."""
        if self.why == "skipped":
            return "as skipped"
        if self.why == "differs":
            return "as a known difference"
        return f"until {self.why}"


def read_list(path):
    """The entries of a list, by case."""
    entries = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split(None, 2)
        if len(fields) < 3:
            raise ListError(f"{path.name}:{number}: give the case, why it is listed, and the reason")
        case, why, reason = fields
        if why not in ("differs", "skipped") and not re.fullmatch(r"#[0-9]+", why):
            raise ListError(f"{path.name}:{number}: {case} is listed as {why!r}, "
                            "not as differs, skipped or #<issue>")
        if case in entries:
            raise ListError(f"{path.name}:{number}: {case} is listed twice")
        entries[case] = Entry(why, reason.strip(), number)
    return entries


class Case:
    """A case of the suite, as its directory holds it."""

    def __init__(self, directory, name):
        self.id = name
        self.name = (directory / "===").read_text(encoding="utf-8").strip()
        self.error = (directory / "error").exists()
        json_file = directory / "in.json"
        self.json = load(json_file.read_text(encoding="utf-8")) if json_file.exists() else None


def read_suite(root):
    """The cases of the suite, in order of their IDs. A case is a directory
    that holds in.yaml; the data release's directories name/ and tags/ hold
    only links to them, which are not followed."""
    found = []
    for directory in sorted(root.rglob("in.yaml")):
        relative = directory.parent.relative_to(root)
        if relative.parts and relative.parts[0] in ("name", "tags"):
            continue
        found.append(Case(directory.parent, relative.as_posix()))
    return found


def read_answers(path):
    """The testee's answers, by case."""
    answers = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            answer = load(line)[0]
            answers[dict(answer)["case"]] = dict(answer)
    return answers


def reading_lines(reading):
    """What smock read, as lines of the detail."""
    reading = dict(reading)
    if "value" in reading:
        return [f"    smock reads: {shown(reading['value'])}"]
    error = dict(reading["error"])
    where = f"{error['pointer']}: " if error["pointer"] else ""
    return [f"    smock refuses it: {where}{error['message']}"]


def judge(case, reading):
    """The outcome of a case in one mode, from what smock read: passed,
    failed or skipped, and the lines that say why it did not pass."""
    reading = dict(reading)
    if "skipped" in reading:
        return "skipped", [f"    the testee skips it: {reading['skipped']}"]
    if case.error:
        if "error" in reading:
            return "passed", []
        return "failed", ["    the suite marks the input an error"] + reading_lines(reading)
    if case.json is not None and len(case.json) == 1:
        if "value" in reading and same(case.json[0], reading["value"]):
            return "passed", []
        return "failed", [f"    the suite reads: {shown(case.json[0])}"] + reading_lines(reading)
    if "value" in reading:
        return "passed", []
    return "failed", ["    the suite gives no JSON for it, so smock should read it"] + reading_lines(reading)


def plural(count, one, more):
    """<count> <one>, or <count> <more> when count is not 1."""
    return f"{count} {one if count == 1 else more}"


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = Path(argv[1])
    mode = path.stem
    if mode not in MODES:
        print(f"yaml-test-suite: {path.name} names no mode: its name is safe.txt or openapi.txt", file=sys.stderr)
        return 2
    label = f"yaml-test-suite {mode}"
    try:
        listed = read_list(path)
    except (OSError, UnicodeDecodeError, ListError) as error:
        print(f"{label}: {error}", file=sys.stderr)
        return 2
    try:
        suite = read_suite(Path(argv[2]))
    except (OSError, UnicodeDecodeError, ValueError) as error:
        print(f"{label}: cannot read the suite {argv[2]}: {error}", file=sys.stderr)
        return 2
    if not suite:
        print(f"{label}: the suite {argv[2]} holds no case", file=sys.stderr)
        return 2
    try:
        answers = read_answers(Path(argv[3]))
    except (OSError, UnicodeDecodeError, ValueError, KeyError, IndexError, TypeError) as error:
        print(f"{label}: cannot read the answers {argv[3]}: {error}", file=sys.stderr)
        return 2

    run = []
    unanswered = []
    for case in suite:
        answer = answers.get(case.id)
        if answer is None or mode not in answer:
            unanswered.append(case)
            continue
        outcome, detail = judge(case, answer[mode])
        run.append((case, outcome, detail))
    counts = {outcome: sum(1 for _, o, _ in run if o == outcome) for outcome in ("passed", "skipped", "failed")}
    print(f"{label}: {plural(len(suite), 'case', 'cases')}, {counts['passed']} passed, "
          f"{counts['skipped']} skipped, {counts['failed']} failed")

    # Every listed case, with its outcome and reason.
    if listed:
        print(f"{label}: listed in {path.name}, with the reason:")
    passing = []
    for case, outcome, _ in run:
        entry = listed.get(case.id)
        if entry is None:
            continue
        print(f"  {case.id} {outcome}, listed {entry.how()}: {entry.reason}")
        if outcome == "passed":
            passing.append((case.id, entry))
    if passing:
        print(f"{label}: {plural(len(passing), 'listed case', 'listed cases')} passed, "
              f"so {'it' if len(passing) == 1 else 'they'} must come off {path.name}: "
              + " ".join(case for case, _ in passing))
        if os.environ.get("GITHUB_ACTIONS") == "true":
            for case, entry in passing:
                print(f"::error file={path},line={entry.line},title={label}::"
                      f"{case} passes now, so it must come off the list")

    # The cases that failed or were skipped without being listed so.
    wrong = 0
    for case, outcome, detail in run:
        entry = listed.get(case.id)
        if outcome == "passed" or (entry is not None and entry.allows(outcome)):
            continue
        wrong += 1
        if entry is None:
            print(f"{label}: {case.id} {outcome}, and is not listed: {case.name}")
        else:
            print(f"{label}: {case.id} {outcome}, but is listed {entry.how()}: {case.name}")
        for line in detail:
            print(line)
    for case in unanswered:
        print(f"{label}: {case.id} has no answer from the testee: {case.name}")
    ids = {case.id for case in suite}
    stale = 0
    for case in listed:
        if case not in ids:
            stale += 1
            print(f"{label}: {case} is listed in {path.name}, but the suite has no such case")
    if wrong:
        print(f"{label}: {plural(wrong, 'case', 'cases')} failed or "
              f"{'was' if wrong == 1 else 'were'} skipped, and {path.name} does not list "
              f"{'it' if wrong == 1 else 'them'} with that outcome")
    if unanswered:
        print(f"{label}: {plural(len(unanswered), 'case has', 'cases have')} no answer, so the testee did not run "
              f"{'it' if len(unanswered) == 1 else 'them'}")
    if stale:
        print(f"{label}: {plural(stale, 'listed case is', 'listed cases are')} not in the suite, "
              f"so {path.name} is out of date")
    if wrong or passing or unanswered or stale:
        return 1
    print(f"{label}: every case passed or is listed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
