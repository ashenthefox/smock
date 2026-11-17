#!/usr/bin/env python3
"""Lists what a branch weakens, against its merge base with main, for the
maintainer to read before merging it (CONTRIBUTING.md, "The weakening
report"). It only reports: it exits with 0 whatever it finds.

usage: python3 scripts/weakening-report.py [--repo <dir>] [--base <ref>]
                                           [--head <ref>]

<dir> is the checkout, this one unless given. The report compares <head>
(HEAD unless given) with its merge base with <base> (origin/main unless
given), and prints itself as Markdown. It reads the MoonBit packages
that the branch changes, test code only: the test files (_test.mbt,
_wbtest.mbt and the mbt blocks of .mbt.md), and the test blocks of other
files. moon fmt starts each top-level item with a line of ///|, and the
report reads the items so, and their statements by moon fmt's layout.

What it lists, each under a heading, or "Nothing to report.":

  Tests deleted
      each test block of the base that its package no longer has. A test
      whose name is gone is matched with the new test of its package
      that holds most of its body, or whose name is much like its own,
      and is then a test that stays.
  Assertions removed or changed in tests that stay
      in each test, and each other item of a test file, that the head
      still has, the lines it removes or changes that assert something:
      a call of inspect, debug_inspect, json_inspect, an assert_
      function, fail, abort or panic; a guard; an if whose block fails;
      and a line that compares two values (==, !=, <, <=, > or >=).
      Lines are compared without their indentation. Lines added inside
      an assertion are not listed, as extending a test adds them.
  Snapshot lines changed
      the lines a test removes from, changes in or adds to a snapshot:
      the content= of a call of inspect, debug_inspect or json_inspect,
      or a constant or a variable that a content= names; and each file
      in a __snapshot__ directory that the head changes or deletes.
  Skip attributes and target settings added
      each #skip or #cfg attribute that a test gains, a package whose
      supported targets no longer let its tests run on wasm-gc, and a
      test file that its package's targets no longer build for wasm-gc.
  Files that decide a verdict changed
      each changed file that scripts/verdict-files.txt names, in the base
      or in the head, with its diff, and each change to that list.

It exits with 2 when git cannot answer, such as when <base> or <head> is
not a commit.
"""

import argparse
import difflib
import json
import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass


class GitError(Exception):
    """A git command that failed."""


def git(repo, *args):
    """The output of a git command in repo."""
    result = subprocess.run(
        ["git", "-C", repo, *args], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise GitError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def show(repo, rev, path):
    """The text of path at rev."""
    return git(repo, "show", f"{rev}:{path}")


def diff_of(repo, base, head, path):
    """The hunks of git's diff of path from base to head."""
    diff = git(repo, "diff", base, head, "--", path).splitlines()
    start = next((i for i, line in enumerate(diff) if line.startswith("@@")), len(diff))
    return diff[start:]


def fenced(lines, info=""):
    """Lines in a fenced code block of Markdown, whose fence is longer than
    any run of backticks in them."""
    longest = max((len(run) for line in lines for run in re.findall("`+", line)), default=0)
    fence = "`" * max(3, longest + 1)
    return [fence + info, *lines, fence]


def exists(repo, rev, path):
    """Whether path is a file at rev."""
    return bool(git(repo, "ls-tree", "--name-only", rev, "--", path).strip())


def files_in(repo, rev, directory):
    """The files directly in directory at rev, as paths from the root."""
    prefix = f"{directory}/" if directory else ""
    names = git(repo, "ls-tree", "--name-only", rev, "--", prefix or ".")
    return [
        name
        for name in names.splitlines()
        if name and posixpath.dirname(name) == directory
    ]


# --- MoonBit test code ---------------------------------------------------------

TEST_HEADER = re.compile(r'(?:async\s+)?test\b(?:\s*("(?:[^"\\]|\\.)*"))?')
FN_HEADER = re.compile(
    r"(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn(?:\[[^\]]*\])?\s+"
    r"([A-Za-z_]\w*(?:::[A-Za-z_]\w*)?)"
)
LET_HEADER = re.compile(r"(?:pub(?:\([^)]*\))?\s+)?(let|const)\s+([A-Za-z_]\w*)")


def is_moonbit(path):
    """Whether path is MoonBit source: a .mbt file or a .mbt.md document."""
    return path.endswith((".mbt", ".mbt.md"))


def is_test_file(path):
    """Whether every item of path is test code."""
    return path.endswith(("_test.mbt", "_wbtest.mbt", ".mbt.md"))


@dataclass
class Item:
    """A top-level item of MoonBit test code: a test block, or a function,
    a constant or a type of a test file."""

    path: str
    kind: str
    name: str
    # The item's lines from its header to its end, and the line number of
    # the header in its file.
    lines: list
    line: int
    # The attributes written before the header, such as #skip.
    attributes: list

    def title(self):
        """How the report names the item."""
        if self.kind == "test":
            return f"test {self.name}" if self.name else "test (no name)"
        return f"{self.kind} {self.name}"


def code_regions(path, lines):
    """The ranges of lines that hold code: the whole of a .mbt file, and
    the fenced mbt blocks of a .mbt.md document."""
    if not path.endswith(".mbt.md"):
        return [(0, len(lines))]
    regions = []
    start = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if start is None and stripped.startswith("```mbt"):
            start = i + 1
        elif start is not None and stripped.startswith("```"):
            regions.append((start, i))
            start = None
    return regions


def header(segment):
    """The index in segment of the item's header: its first line that is
    not blank, a comment or an attribute."""
    for i, line in enumerate(segment):
        stripped = line.strip()
        if stripped and not stripped.startswith(("//", "#")):
            return i
    return None


def items_of(path, text):
    """The items of test code in a file: every item of a test file, and the
    test blocks of any other. moon fmt starts each top-level item with a
    line of ///|."""
    lines = text.split("\n")
    items = []
    for lo, hi in code_regions(path, lines):
        marks = [i for i in range(lo, hi) if lines[i].rstrip() == "///|"]
        bounds = [lo] + [m + 1 for m in marks]
        ends = marks + [hi]
        for start, end in zip(bounds, ends):
            segment = lines[start:end]
            first = header(segment)
            if first is None:
                continue
            while segment and not segment[-1].strip():
                segment.pop()
            text_of_header = segment[first].strip()
            if match := TEST_HEADER.match(text_of_header):
                kind, name = "test", match.group(1)
            elif not is_test_file(path):
                continue
            elif match := FN_HEADER.match(text_of_header):
                kind, name = "fn", match.group(1)
            elif match := LET_HEADER.match(text_of_header):
                kind, name = match.group(1), match.group(2)
            else:
                kind, name = "item", " ".join(text_of_header.split())
            attributes = [
                line.strip() for line in segment[:first] if line.strip().startswith("#")
            ]
            items.append(
                Item(path, kind, name, segment[first:], start + first + 1, attributes)
            )
    return items


CHAR = re.compile(r"'(?:\\[^']*|[^'\\])'")


def code_of(line):
    """The code of a line: without its comment and the text of its string
    and character literals, but with the code interpolated into a string.
    A line of a multi-line string (#| or $|) holds no code but what $|
    interpolates."""
    stripped = line.strip()
    if stripped.startswith("#|"):
        return ""
    if stripped.startswith("$|"):
        line = '"' + stripped[2:].replace('"', '\\"') + '"'
    out = []
    i = 0
    while i < len(line):
        c = line[i]
        if line.startswith("//", i):
            break
        if c == "'" and (char := CHAR.match(line, i)):
            out.append("' '")
            i = char.end()
        elif c == '"':
            i += 1
            while i < len(line) and line[i] != '"':
                if line.startswith("\\{", i):
                    depth, j = 1, i + 2
                    while j < len(line) and depth:
                        depth += {"{": 1, "}": -1}.get(line[j], 0)
                        j += 1
                    out.append(" " + line[i + 2 : j - 1] + " ")
                    i = j
                elif line[i] == "\\":
                    i += 2
                else:
                    i += 1
            out.append('""')
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def indent(line):
    """The width of a line's indentation."""
    return len(line) - len(line.lstrip())


def statement_end(lines, i):
    """The index of the last line of the statement that starts on line i,
    by moon fmt's layout: the lines indented deeper than it, and a line
    as deep as it that closes a bracket."""
    depth = indent(lines[i])
    end = i
    for j in range(i + 1, len(lines)):
        line = lines[j]
        if not line.strip():
            continue
        if indent(line) > depth or line.strip()[0] in ")]}":
            if indent(line) < depth:
                break
            end = j
        else:
            break
    return end


ASSERTION = re.compile(
    r"(?<![\w.])(?:@\w+\.)?"
    r"(?:inspect|debug_inspect|json_inspect|assert_\w+|fail|abort|panic)\s*\("
)
FAILURE = re.compile(r"(?<![\w.])(?:fail|abort|panic)\s*\(")
GUARD = re.compile(r"\s*guard\b")
IF = re.compile(r"\s*(?:\}\s*else\s+)?if\b")
COMPARISON = re.compile(r"\s(?:==|!=|<=|>=|<|>)\s")


def assertion_spans(lines):
    """The ranges of lines, first and last, that assert something: a call
    of inspect, debug_inspect, json_inspect, an assert_ function, fail,
    abort or panic; a guard statement; the line of an if whose block
    fails; and a line that compares two values."""
    code = [code_of(line) for line in lines]
    spans = []
    for i, text in enumerate(code):
        if ASSERTION.search(text) or GUARD.match(text):
            spans.append((i, statement_end(lines, i)))
        elif COMPARISON.search(text):
            spans.append((i, i))
        elif IF.match(text):
            end = statement_end(lines, i)
            if any(FAILURE.search(code[j]) for j in range(i + 1, end + 1)):
                spans.append((i, i))
    return spans


def inside(spans, first, last):
    """Whether one span holds every line from first to last."""
    return any(start <= first and last <= end for start, end in spans)


def touches(spans, first, last):
    """Whether a span holds any line from first to last."""
    return any(start <= last and first <= end for start, end in spans)


@dataclass
class Hunk:
    """Lines of an item that the head removed, changed or added: the base's
    and the head's, each with the line number of its first line."""

    base_line: int
    base: list
    head_line: int
    head: list

    def render(self):
        """The hunk as a unified diff."""
        out = [f"@@ -{self.base_line},{len(self.base)} +{self.head_line},{len(self.head)} @@"]
        out += [f"-{line}" for line in self.base]
        out += [f"+{line}" for line in self.head]
        return out


SNAPSHOT = re.compile(r"(?<![\w.])(?:@\w+\.)?(?:inspect|debug_inspect|json_inspect)\s*\(")
CONTENT_NAME = re.compile(r"\bcontent=\s*([a-z_]\w*)")
LOCAL_LET = re.compile(r"\s*let\s+([a-z_]\w*)\b")


def snapshot_names(items):
    """The names that a content= of these items gives a snapshot by: of
    a constant or a variable that holds it."""
    return {
        name
        for item in items
        for line in item.lines
        for name in CONTENT_NAME.findall(code_of(line))
    }


def snapshot_spans(item, names):
    """The ranges of lines, first and last, of an item that hold a
    snapshot: the content= of a call of inspect, debug_inspect or
    json_inspect, and the value of a constant or a variable that a
    content= names."""
    if item.kind == "let" and item.name in names:
        return [(0, len(item.lines) - 1)]
    code = [code_of(line) for line in item.lines]
    spans = []
    for i, text in enumerate(code):
        if SNAPSHOT.search(text):
            for j in range(i, statement_end(item.lines, i) + 1):
                if "content=" in code[j]:
                    spans.append((j, statement_end(item.lines, j)))
        elif (local := LOCAL_LET.match(text)) and local.group(1) in names:
            spans.append((i, statement_end(item.lines, i)))
    return spans


def weakened(before, after, names):
    """The hunks in which after removes or changes a snapshot or an
    assertion of before, or adds lines inside a snapshot: those of
    snapshots, and those of other assertions. Lines added inside another
    assertion, such as a case added to the value an inspect shows, are not
    listed: they change its snapshot when they change what it shows. Lines
    are compared without their indentation, so that a block moved deeper
    changes nothing."""
    snapshots = snapshot_spans(before, names)
    assertions = assertion_spans(before.lines)
    matcher = difflib.SequenceMatcher(
        None,
        [line.strip() for line in before.lines],
        [line.strip() for line in after.lines],
        autojunk=False,
    )
    found = {"snapshot": [], "assertion": []}
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        hunk = Hunk(before.line + i1, before.lines[i1:i2], after.line + j1, after.lines[j1:j2])
        if i1 == i2:
            if i1 > 0 and inside(snapshots, i1 - 1, i1):
                found["snapshot"].append(hunk)
        elif touches(snapshots, i1, i2 - 1):
            found["snapshot"].append(hunk)
        elif touches(assertions, i1, i2 - 1):
            found["assertion"].append(hunk)
    return found["snapshot"], found["assertion"]


def package_items(repo, rev, package):
    """The items of test code in a package at rev."""
    items = []
    for path in files_in(repo, rev, package):
        if is_moonbit(path):
            items.extend(items_of(path, show(repo, rev, path)))
    return items


def key(item):
    """What an item is known by in its package. A test without a name is
    known by its file as well."""
    if item.kind == "test" and item.name is None:
        return (item.kind, None, item.path)
    return (item.kind, item.name)


def body(item):
    """The lines of an item that say what it does: without its header,
    blank lines and lines that only close brackets."""
    lines = (line.strip() for line in item.lines[1:])
    return [line for line in lines if line.strip(")]},;")]


def overlap(before, after):
    """The share of before's body that after's body holds."""
    lines = body(before)
    if not lines:
        return 0.0
    left = list(body(after))
    held = 0
    for line in lines:
        if line in left:
            left.remove(line)
            held += 1
    return held / len(lines)


def likeness(before, after):
    """How much two tests' names are alike, from 0 to 1."""
    return difflib.SequenceMatcher(None, before.name or "", after.name or "").ratio()


def pair(base_items, head_items):
    """The items of the base that the head still has, each with its head
    item; those it does not; and the head's new items. An item keeps its
    key; one of several of the same key is matched in its file first. A
    test whose name is gone is the new test of its package that holds most
    of its body, or whose name is much like its own: renamed, as when a
    test is extended."""
    free = list(head_items)
    pairs, gone = [], []
    for item in base_items:
        candidates = [other for other in free if key(other) == key(item)]
        if not candidates:
            gone.append(item)
            continue
        same_file = [other for other in candidates if other.path == item.path]
        chosen = (same_file or candidates)[0]
        free.remove(chosen)
        pairs.append((item, chosen))
    for item in [item for item in gone if item.kind == "test"]:
        scored = [
            (overlap(item, other) + likeness(item, other), other.path == item.path, -n, other)
            for n, other in enumerate(free)
            if other.kind == "test"
            and (overlap(item, other) >= 0.6 or likeness(item, other) >= 0.75)
        ]
        if scored:
            chosen = max(scored, key=lambda score: score[:3])[3]
            free.remove(chosen)
            gone.remove(item)
            pairs.append((item, chosen))
    return pairs, gone, free


# --- Where tests run -------------------------------------------------------------

SKIP = re.compile(r"#(?:skip|cfg)\b")
TARGETS = {"wasm", "wasm-gc", "js", "native", "llvm"}
TARGET = re.compile(r"([+-]?)\s*(all|wasm-gc|wasm|js|native|llvm)\b")
SUPPORTED = re.compile(
    r'(?:^[ \t]*supported_targets[ \t]*=|"supported-targets"[ \t]*:)[ \t]*'
    r'("(?:[^"\\]|\\.)*"|\[[^\]]*\])',
    re.MULTILINE,
)
FILE_TARGETS = re.compile(r'"?\btargets"?\s*:\s*\{')


def skips_added(before, after):
    """The attributes of a test that skip it, or compile it for some
    targets alone, that after has and before had not."""
    if after.kind != "test":
        return []
    had = before.attributes if before else []
    return [text for text in after.attributes if SKIP.match(text) and text not in had]


def loads(text):
    """A JSON value written in a package's settings, which may end a list
    or an object with a comma."""
    return json.loads(re.sub(r",(\s*[\]}])", r"\1", text))


def targets(value):
    """The set of targets a supported-targets value names: a list, or an
    expression such as "native", "native+wasm" or "-all+native". None
    when it cannot be read."""
    if isinstance(value, list):
        return set(value)
    tokens = TARGET.findall(value) if isinstance(value, str) else []
    if not tokens:
        return None
    result = set(TARGETS) if tokens[0][0] == "-" else set()
    for sign, name in tokens:
        names = TARGETS if name == "all" else {name}
        result = result - names if sign == "-" else result | names
    return result


def allows_wasm_gc(condition):
    """Whether a file's condition in a package's targets lets it build for
    wasm-gc: a target, a list of them, or ["and" | "or" | "not", ...]. A
    condition on debug or release builds alone allows it."""

    def value(cond):
        # True or False, or None for a condition that does not name targets.
        if isinstance(cond, str):
            if cond in ("debug", "release"):
                return None
            named = targets(cond)
            return None if named is None else "wasm-gc" in named
        if isinstance(cond, list) and cond and cond[0] in ("and", "or", "not"):
            values = [value(c) for c in cond[1:]]
            if cond[0] == "not":
                return None if not values or values[0] is None else not values[0]
            if cond[0] == "and":
                return not any(v is False for v in values)
            return any(v is not False for v in values)
        if isinstance(cond, list):
            return any(value(c) is not False for c in cond)
        return None

    return value(condition) is not False


def balanced(text, start):
    """The index just past the bracket that closes the one at start,
    outside string literals."""
    depth, i = 0, start
    while i < len(text):
        c = text[i]
        if c == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif c in "[{(":
            depth += 1
        elif c in "]})":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(text)


ENTRY = re.compile(r'\s*,?\s*"([^"]+)"\s*:\s*')
UNREADABLE = "unreadable"


def settings(text):
    """What a package's settings say of where its tests run: its supported
    targets, as written and as a set of targets (None when it names none);
    and the condition of each file in its targets, with the entry as
    written. A value that cannot be read is UNREADABLE."""
    supported = SUPPORTED.search(text or "")
    package = (None, None)
    if supported:
        try:
            named = targets(loads(supported.group(1)))
        except ValueError:
            named = None
        package = (supported.group(0).strip(), UNREADABLE if named is None else named)
    files = {}
    if found := FILE_TARGETS.search(text or ""):
        body = text[found.end() - 1 : balanced(text, found.end() - 1)]
        i = 1
        while (entry := ENTRY.match(body, i)) and entry.end() < len(body):
            j = entry.end()
            end = balanced(body, j) if body[j] in "[{" else body.index('"', j + 1) + 1
            written = " ".join(body[entry.start() : end].split()).lstrip(", ")
            try:
                files[entry.group(1)] = (written, loads(body[j:end]))
            except ValueError:
                files[entry.group(1)] = (written, UNREADABLE)
            i = end
    return package, files


def runs_on_wasm_gc(named):
    """Whether a package whose supported targets are named runs its tests
    on wasm-gc: True, False, or None when the report cannot tell."""
    if named == UNREADABLE:
        return None
    return named is None or "wasm-gc" in named


def kept_off_wasm_gc(repo, base, head, path):
    """What a change to a package's settings keeps off wasm-gc, as lines
    of the report: the package's tests, or a test file."""
    package = posixpath.dirname(path)
    shown = f"`{package}`" if package else "the root package"

    def read(rev):
        return show(repo, rev, path) if exists(repo, rev, path) else None

    (_, base_named), base_files = settings(read(base))
    (written, head_named), head_files = settings(read(head))
    tests = [
        item
        for rev in (base, head)
        for item in package_items(repo, rev, package)
        if item.kind == "test"
    ]
    out = []
    if tests and runs_on_wasm_gc(base_named) is not False:
        if runs_on_wasm_gc(head_named) is None:
            out.append(
                f"- `{path}`: the report cannot tell whether the tests of {shown} "
                f"still run on wasm-gc: `{written}`"
            )
        elif not runs_on_wasm_gc(head_named):
            out.append(f"- `{path}`: the tests of {shown} no longer run on wasm-gc: `{written}`")
    tested = {item.path for item in tests}
    for name in sorted(head_files):
        file = posixpath.join(package, name)
        if not (is_test_file(file) or file in tested):
            continue
        if name in base_files:
            before = base_files[name][1]
            if before != UNREADABLE and not allows_wasm_gc(before):
                continue
        written, condition = head_files[name]
        if condition == UNREADABLE:
            out.append(
                f"- `{path}`: the report cannot tell whether `{file}` still runs on "
                f"wasm-gc: `{written}`"
            )
        elif not allows_wasm_gc(condition):
            out.append(f"- `{path}`: `{file}` no longer runs on wasm-gc: `{written}`")
    return out


# --- Files that decide a verdict --------------------------------------------------

LIST = "scripts/verdict-files.txt"
LIST_ENTRY = (LIST, "the list of the files that decide a verdict")
STATUS = {"A": "added", "M": "changed", "D": "deleted", "T": "changed in type"}
DIFF_LINES = 400


def watched(text):
    """The entries of a list of the files that decide a verdict: each a
    pattern and what it names. A line is a pattern, spaces and words; one
    that starts with # is a comment."""
    entries = []
    for line in (text or "").splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            pattern, *description = line.split(None, 1)
            entries.append((pattern, " ".join(description).strip()))
    return entries


def matches(pattern, path):
    """Whether path is a file that pattern names: the path itself; with
    a final /, every file under that directory; and with *, any text
    without a / in its place."""
    if pattern.endswith("/"):
        return path.startswith(pattern)
    return re.fullmatch(re.escape(pattern).replace(r"\*", "[^/]*"), path) is not None


def verdict_files(repo, base, head, changed):
    """The changed files that decide a verdict, as Markdown lines: those
    that the list names in the base or in the head, and the list itself."""
    entries = [LIST_ENTRY]
    for rev in (head, base):
        if exists(repo, rev, LIST):
            entries += [e for e in watched(show(repo, rev, LIST)) if e[0] not in dict(entries)]
    out = []
    for status, path in changed:
        entry = next((e for e in entries if matches(e[0], path)), None)
        if entry is None:
            continue
        pattern, description = entry
        hunks = diff_of(repo, base, head, path)
        added = sum(1 for line in hunks if line.startswith("+"))
        removed = sum(1 for line in hunks if line.startswith("-"))
        shown = hunks[:DIFF_LINES]
        if len(hunks) > DIFF_LINES:
            shown.append(f"... {len(hunks) - DIFF_LINES} more lines: git diff {base[:12]} {head[:12]} -- {path}")
        out += [
            f"### `{path}` ({STATUS.get(status[0], status)})",
            "",
            f"{description[:1].upper()}{description[1:]} (listed as `{pattern}`).",
            "",
            f"<details><summary>{added} lines added, {removed} removed</summary>",
            "",
            *fenced(shown, "diff"),
            "",
            "</details>",
            "",
        ]
    return out


# --- The report ----------------------------------------------------------------


def report(repo, base_ref, head_ref):
    """The report as Markdown lines."""
    head = git(repo, "rev-parse", "--verify", f"{head_ref}^{{commit}}").strip()
    git(repo, "rev-parse", "--verify", f"{base_ref}^{{commit}}")
    base = git(repo, "merge-base", base_ref, head).strip()
    changed = [
        line.split("\t", 1)
        for line in git(repo, "diff", "--name-status", "--no-renames", base, head).splitlines()
    ]

    deleted, assertions, snapshots, skips = [], [], [], []
    packages = sorted({posixpath.dirname(path) for _, path in changed if is_moonbit(path)})
    for package in packages:
        base_items = package_items(repo, base, package)
        head_items = package_items(repo, head, package)
        names = snapshot_names(base_items + head_items)
        pairs, gone, new = pair(base_items, head_items)
        deleted.extend(item for item in gone if item.kind == "test")
        for before, after in pairs + [(None, item) for item in new]:
            skips.extend(
                f"- `{after.path}:{after.line}`: {after.title()}: `{text}`"
                for text in skips_added(before, after)
            )
            if before is None:
                continue
            in_snapshots, in_assertions = weakened(before, after, names)
            if in_snapshots:
                snapshots.append(changed_item(before, after, in_snapshots))
            if in_assertions:
                assertions.append(changed_item(before, after, in_assertions))
    for status, path in changed:
        if "__snapshot__" in path.split("/") and status in ("M", "D"):
            snapshots.append(changed_file(repo, base, head, path))
        if posixpath.basename(path) in ("moon.pkg", "moon.pkg.json"):
            skips.extend(kept_off_wasm_gc(repo, base, head, path))

    def short(rev):
        return git(repo, "rev-parse", "--short", rev).strip()

    out = [
        "# Weakening report",
        "",
        (
            f"Branch head `{short(head)}`, against `{short(base)}`, "
            f"its merge base with `{base_ref}`."
        ),
        "",
    ]
    if deleted:
        out += ["## Tests deleted", ""]
        out += [f"- `{item.path}:{item.line}`: {item.title()}" for item in deleted]
        out.append("")
    for title, entries in (
        ("Assertions removed or changed in tests that stay", assertions),
        ("Snapshot lines changed", snapshots),
    ):
        if entries:
            out += [f"## {title}", ""]
            for entry in entries:
                out += entry
    if skips:
        out += ["## Skip attributes and target settings added", "", *skips, ""]
    verdicts = verdict_files(repo, base, head, changed)
    if verdicts:
        out += ["## Files that decide a verdict changed", "", *verdicts]
    if not (deleted or assertions or snapshots or skips or verdicts):
        out += ["Nothing to report.", ""]
    return out


def changed_file(repo, base, head, path):
    """A file and its diff, as Markdown lines."""
    return [f"### `{path}`", "", *fenced(diff_of(repo, base, head, path), "diff"), ""]


def changed_item(before, after, hunks):
    """An item of the base and its hunks, as Markdown lines."""
    out = [f"### `{before.path}:{before.line}`: {before.title()}", ""]
    if (after.path, after.title()) != (before.path, before.title()):
        out += [f"Now `{after.path}:{after.line}`: {after.title()}.", ""]
    out += fenced([line for hunk in hunks for line in hunk.render()], "diff")
    out.append("")
    return out


def main():
    """Prints the report."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args()
    try:
        lines = report(args.repo, args.base, args.head)
    except GitError as error:
        print(f"weakening-report: {error}", file=sys.stderr)
        return 2
    sys.stdout.write("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
