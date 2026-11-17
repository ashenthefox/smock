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
    changed = git(repo, "diff", "--name-only", "--no-renames", base, head).splitlines()

    deleted = []
    packages = sorted({posixpath.dirname(path) for path in changed if is_moonbit(path)})
    for package in packages:
        _, gone = pair(package_items(repo, base, package), package_items(repo, head, package))
        deleted.extend(item for item in gone if item.kind == "test")

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
    else:
        out += ["Nothing to report.", ""]
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
