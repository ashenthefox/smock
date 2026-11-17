#!/usr/bin/env python3
"""Lists what a branch weakens, against its merge base with main, for the
maintainer to read before merging it (CONTRIBUTING.md, "The weakening
report"). It only reports: it exits with 0 whatever it finds.

usage: python3 scripts/weakening-report.py [--repo <dir>] [--base <ref>]
                                           [--head <ref>] [--json <file>]

<dir> is the checkout, this one unless given. The report compares <head>
(HEAD unless given) with its merge base with <base> (origin/main unless
given), and prints itself as Markdown.

What it lists:

  Tests deleted
      a test block of the base that the head no longer has in its package.

It exits with 2 when git cannot answer, such as when <base> or <head> is
not a commit.
"""

import argparse
import difflib
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
            items.append(Item(path, kind, name, segment[first:], start + first + 1))
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
    assertion of before, or adds lines inside one: those of snapshots, and
    those of other assertions. Lines are compared without their
    indentation, so that a block moved deeper changes nothing."""
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
        for kind, spans in (("snapshot", snapshots), ("assertion", assertions)):
            if (i1 < i2 and touches(spans, i1, i2 - 1)) or (
                i1 == i2 and i1 > 0 and inside(spans, i1 - 1, i1)
            ):
                hunk = Hunk(
                    before.line + i1,
                    before.lines[i1:i2],
                    after.line + j1,
                    after.lines[j1:j2],
                )
                found[kind].append(hunk)
                break
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


def pair(base_items, head_items):
    """The items of the base that the head still has, each with its head
    item, and those it does not. An item keeps its key; one of several of
    the same key is matched in its file first."""
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
    return pairs, gone


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

    deleted, assertions, snapshots = [], [], []
    packages = sorted({posixpath.dirname(path) for _, path in changed if is_moonbit(path)})
    for package in packages:
        base_items = package_items(repo, base, package)
        head_items = package_items(repo, head, package)
        names = snapshot_names(base_items + head_items)
        pairs, gone = pair(base_items, head_items)
        deleted.extend(item for item in gone if item.kind == "test")
        for before, after in pairs:
            in_snapshots, in_assertions = weakened(before, after, names)
            if in_snapshots:
                snapshots.append(changed_item(before, after, in_snapshots))
            if in_assertions:
                assertions.append(changed_item(before, after, in_assertions))
    for status, path in changed:
        if "__snapshot__" in path.split("/") and status in ("M", "D"):
            snapshots.append(changed_file(repo, base, head, path))

    short = lambda rev: git(repo, "rev-parse", "--short", rev).strip()
    out = [
        "# Weakening report",
        "",
        f"Branch head `{short(head)}`, against `{short(base)}`, "
        f"its merge base with `{base_ref}`.",
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
    if not (deleted or assertions or snapshots):
        out += ["Nothing to report.", ""]
    return out


def changed_file(repo, base, head, path):
    """A file and its diff, as Markdown lines."""
    diff = git(repo, "diff", base, head, "--", path).splitlines()
    hunks = diff[next((i for i, line in enumerate(diff) if line.startswith("@@")), len(diff)) :]
    return [f"### `{path}`", "", "```diff", *hunks, "```", ""]


def changed_item(before, after, hunks):
    """An item of the base and its hunks, as Markdown lines."""
    out = [f"### `{before.path}:{before.line}`: {before.title()}", ""]
    if (after.path, after.title()) != (before.path, before.title()):
        out += [f"Now `{after.path}:{after.line}`: {after.title()}.", ""]
    out.append("```diff")
    for hunk in hunks:
        out += hunk.render()
    out += ["```", ""]
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
