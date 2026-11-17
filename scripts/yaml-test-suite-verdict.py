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
- Otherwise, when the input has a construct that the documents say the
  mode refuses, smock refuses it with the message the documents give for
  that construct: one that names it, or "quote this value" or "quote this
  key" for a plain scalar that YAML 1.1 or 1.2 types otherwise. A refusal
  for another reason does not count. The constructs and where the
  documents say so are under CONSTRUCTS below.
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

# How the documents name what a mode refuses, and where they say so. smock's
# YAML parser documents both modes in yaml/yaml.mbt (`parse`), and
# docs/definition-files.md repeats the safe subset's rules. In the safe
# subset, "Rejected, each with a message naming it: anchors, aliases, tags,
# merge keys (`<<`), duplicate keys, multiple documents, directives,
# explicit keys (`?`), block scalar indentation indicators, empty values";
# a plain scalar that YAML 1.1 or 1.2 would type "is rejected with 'quote
# this value'", and a plain key that is not a string in every YAML version
# "with 'quote this key'". The mode for OpenAPI documents differs from the
# safe subset "in these ways, and in no other": it reads plain scalars by
# the YAML 1.2 core schema, empty values included, but refuses the numbers
# JSON cannot hold, reads every key as a string, and takes indentation
# indicators.
#
# Each construct is (what it is, in words; the pattern its message must
# match; the words of that rule), by its kind.
NAMES_IT = "a message that names it"
CONSTRUCTS = {
    "anchor": ("an anchor", r"\banchors?\b", NAMES_IT),
    "alias": ("an alias", r"\balias(es)?\b", NAMES_IT),
    "tag": ("a tag", r"\btags?\b", NAMES_IT),
    "merge key": ("a merge key", r"\bmerge keys?\b", NAMES_IT),
    "duplicate key": ("a duplicate key", r"\bduplicate keys?\b", NAMES_IT),
    "documents": ("several documents", r"\bmultiple documents\b", NAMES_IT),
    "directive": ("a directive", r"\bdirectives?\b", NAMES_IT),
    "explicit key": ("an explicit key", r"\bexplicit keys?\b", NAMES_IT),
    "indentation indicator": ("an indentation indicator", r"\bindentation indicators?\b", NAMES_IT),
    "empty value": ("an empty value", r"\bempty\b", NAMES_IT),
    "empty key": ("an empty key", r"\bempty\b", NAMES_IT),
    "typed value": ("the plain value {}, which YAML 1.1 or 1.2 types otherwise", r"quote this value",
                    '"quote this value"'),
    "typed key": ("the plain key {}, which YAML 1.1 or 1.2 does not read as a string", r"quote this key",
                  '"quote this key"'),
    "no JSON number": ("the plain value {}, which JSON cannot hold", r"quote this value", '"quote this value"'),
}

# The kinds of construct each mode refuses.
REFUSED = {
    "safe": set(CONSTRUCTS) - {"no JSON number"},
    "openapi": set(CONSTRUCTS) - {"indentation indicator", "empty value", "typed value", "typed key"},
}

MODE_NAMES = {"safe": "the safe subset", "openapi": "the mode for OpenAPI documents"}

# The types of YAML 1.1 (https://yaml.org/type/, the regular expressions of
# its bool, int, float, null, timestamp, merge and value pages), which a
# plain scalar that matches has instead of a string. The timestamp page's
# expression takes blanks only before Z, but its examples give
# "2001-12-14 21:59:43.10 -5" as a timestamp, "space separated", so the
# blanks come before any time zone here.
YAML_1_1 = re.compile("|".join([
    r"y|Y|yes|Yes|YES|n|N|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF",
    r"[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(:[0-5]?[0-9])+",
    r"[-+]?([0-9][0-9_]*)?\.[0-9.]*([eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+\.[0-9_]*"
    r"|[-+]?\.(inf|Inf|INF)|\.(nan|NaN|NAN)",
    r"~|null|Null|NULL",
    r"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"
    r"|[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?([Tt]|[ \t]+)[0-9][0-9]?:[0-9][0-9]:[0-9][0-9]"
    r"(\.[0-9]*)?([ \t]*(Z|[-+][0-9][0-9]?(:[0-9][0-9])?))?",
    r"<<",
    r"=",
]))

# The types of the YAML 1.2 core schema (YAML 1.2.2, section 10.3.2, Tag
# Resolution), but for the empty scalar.
CORE_INFINITE = re.compile(r"[-+]?(\.inf|\.Inf|\.INF)|\.nan|\.NaN|\.NAN")
CORE_RADIX = re.compile(r"0o[0-7]+|0x[0-9a-fA-F]+")
YAML_1_2 = re.compile("|".join([
    r"null|Null|NULL|~",
    r"true|True|TRUE|false|False|FALSE",
    r"[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+",
    r"[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?",
    CORE_INFINITE.pattern,
]))

# What the safe subset types: "plain true, false, null and numbers in JSON
# syntax are typed as JSON types them" (yaml/yaml.mbt); a number in JSON
# syntax is RFC 8259's, section 6.
JSON_TYPED = re.compile(r"true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?")

# The largest integer a JSON number holds exactly, 2^53 - 1, above which
# the mode for OpenAPI documents refuses a hexadecimal or octal integer.
MAX_SAFE_INTEGER = 2**53 - 1


class Event:
    """An event of a case's test.event: its kind, such as +MAP or =VAL; its
    anchor and tag, or None; and for a scalar its style, one of : ' " | >,
    and its text."""

    def __init__(self, kind, anchor=None, tag=None, style=None, text=None):
        self.kind = kind
        self.anchor = anchor
        self.tag = tag
        self.style = style
        self.text = text


ESCAPES = {"\\\\": "\\", "\\n": "\n", "\\t": "\t", "\\r": "\r", "\\b": "\b", "\\0": "\0"}


def parse_event(line):
    """An Event of a line of test.event, as yaml-test-suite writes it, such as
    `=VAL &a <tag:yaml.org,2002:str> :text` or `+MAP {}`."""
    kind, _, rest = line.partition(" ")
    if kind == "=ALI":
        return Event(kind)
    anchor = tag = None
    while True:
        if rest.startswith("&"):
            anchor, _, rest = rest[1:].partition(" ")
        elif rest.startswith("<"):
            tag, _, rest = rest[1:].partition("> ")
            if not rest and tag.endswith(">"):
                tag = tag[:-1]
        else:
            break
    if kind != "=VAL":
        return Event(kind, anchor, tag)
    text = re.sub(r"\\[\\ntrb0]", lambda m: ESCAPES[m.group()], rest[1:])
    return Event(kind, anchor, tag, rest[:1], text)


def from_events(events):
    """The constructs that the events of a case show: (kind, value) pairs,
    where the value is the plain scalar's text for the typed kinds."""
    found = set()
    # One entry for each open collection: for a mapping, how many nodes it
    # holds so far and the texts of its scalar keys; for a sequence, None.
    stack = []
    for event in events:
        if event.kind == "+DOC":
            if any(e.kind == "+DOC" for e in events[:events.index(event)]):
                found.add(("documents", None))
        if event.anchor is not None:
            found.add(("anchor", None))
        if event.tag is not None:
            found.add(("tag", None))
        if event.kind == "=ALI":
            found.add(("alias", None))
        if event.kind in ("=VAL", "=ALI", "+MAP", "+SEQ"):
            position = "value"
            if stack and stack[-1] is not None:
                mapping = stack[-1]
                position = "key" if mapping["nodes"] % 2 == 0 else "value"
                mapping["nodes"] += 1
                if position == "key" and event.kind == "=VAL":
                    if event.text in mapping["keys"]:
                        found.add(("duplicate key", None))
                    mapping["keys"].add(event.text)
            if event.kind == "=VAL" and event.style == ":":
                found |= plain_constructs(event.text, position)
        if event.kind == "+MAP":
            stack.append({"nodes": 0, "keys": set()})
        elif event.kind == "+SEQ":
            stack.append(None)
        elif event.kind in ("-MAP", "-SEQ"):
            stack.pop()
    return found


def plain_constructs(text, position):
    """The constructs that a plain scalar with this text is, at a key or a
    value."""
    if text == "":
        return {("empty key", None)} if position == "key" else {("empty value", None)}
    found = set()
    typed = YAML_1_1.fullmatch(text) or YAML_1_2.fullmatch(text)
    if position == "key":
        if text == "<<":
            found.add(("merge key", None))
        if typed:
            found.add(("typed key", text))
    else:
        if typed and not JSON_TYPED.fullmatch(text):
            found.add(("typed value", text))
        if CORE_INFINITE.fullmatch(text) or (CORE_RADIX.fullmatch(text) and int(text, 0) > MAX_SAFE_INTEGER):
            found.add(("no JSON number", text))
    return found


def has_directive(text):
    """Whether the input has a directive: a line that starts with %, where a
    document may start. That is at the start of the stream, or after a
    document's end marker, ..., with only comments, blank lines and other
    directives between (YAML 1.2.2, chapter 9, l-yaml-stream). Elsewhere,
    such a line is part of a scalar."""
    may_start = True
    for line in text.splitlines():
        if line.startswith("%"):
            if may_start:
                return True
        elif not line.strip() or line.lstrip().startswith("#"):
            continue
        else:
            may_start = re.match(r"\.\.\.([ \t]|$)", line) is not None
            continue
        may_start = False
    return False


# The ? of an explicit key: where a node may start, at the start of a line,
# after a block indicator (-, ? or :) and blanks, or after [, { or ,; and
# before a blank or the end of the line (YAML 1.2.2, 8.2.2, and 7.4).
EXPLICIT_KEY = re.compile(r"(^[ \t]*|[-?:][ \t]+|[\[{,][ \t]*)\?([ \t]|$)")

# A block scalar header with an indentation indicator, a digit from 1 to 9,
# before or after its chomping indicator (YAML 1.2.2, 8.1.1.1).
INDENTATION_INDICATOR = re.compile(r"(^|[ \t])[|>]([1-9][-+]?|[-+][1-9])([ \t]|$)")


def constructs(case, mode):
    """The constructs of a valid case that the documents say the mode
    refuses: (kind, value) pairs."""
    found = from_events(case.events)
    if has_directive(case.input):
        found.add(("directive", None))
    lines = case.input.splitlines()
    if any(EXPLICIT_KEY.search(line) for line in lines):
        found.add(("explicit key", None))
    if any(e.style in ("|", ">") for e in case.events) and any(INDENTATION_INDICATOR.search(l) for l in lines):
        found.add(("indentation indicator", None))
    return sorted(c for c in found if c[0] in REFUSED[mode])


def described(construct):
    """A construct in words, and the words of the rule for its message."""
    kind, value = construct
    words, _, rule = CONSTRUCTS[kind]
    return words.format(json.dumps(value, ensure_ascii=False)), rule


def refused_for(construct, message):
    """Whether a message is the one the documents give for a construct."""
    return re.search(CONSTRUCTS[construct[0]][1], message, re.IGNORECASE) is not None


class Case:
    """A case of the suite, as its directory holds it."""

    def __init__(self, directory, name):
        self.id = name
        self.name = (directory / "===").read_text(encoding="utf-8").strip()
        self.error = (directory / "error").exists()
        json_file = directory / "in.json"
        self.json = load(json_file.read_text(encoding="utf-8")) if json_file.exists() else None
        self.input = (directory / "in.yaml").read_bytes().decode("utf-8", errors="replace")
        self.events = [parse_event(line)
                       for line in (directory / "test.event").read_text(encoding="utf-8").splitlines()
                       if line.strip()]


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


def judge(case, mode, reading):
    """The outcome of a case in one mode, from what smock read: passed,
    failed or skipped, and the lines that say why it did not pass."""
    reading = dict(reading)
    if "skipped" in reading:
        return "skipped", [f"    the testee skips it: {reading['skipped']}"]
    if case.error:
        if "error" in reading:
            return "passed", []
        return "failed", ["    the suite marks the input an error"] + reading_lines(reading)
    refused = constructs(case, mode)
    if refused:
        if "error" in reading and any(refused_for(c, dict(reading["error"])["message"]) for c in refused):
            return "passed", []
        lines = []
        for construct in refused:
            words, rule = described(construct)
            lines.append(f"    the documents say {MODE_NAMES[mode]} refuses {words}, with {rule}")
        return "failed", lines + reading_lines(reading)
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
        outcome, detail = judge(case, mode, answer[mode])
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
