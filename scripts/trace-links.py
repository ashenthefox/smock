#!/usr/bin/env python3
"""Derives the trace links of smock's tests, the third of the three sets
that the removal rule's (A) compares (#275, "The removal rule and its
proof"): from the commit that introduced each test block, following moves
and copies across files, to the ticket that commit's subject names, to
that issue's acceptance criteria. It writes them out per test, as JSON,
for the comparison before and after a removal and for the keep reasons of
rule (C).

usage: python3 scripts/trace-links.py [--repo <dir>] [--rev <rev>]
                                      [--jobs <n>] [<path>...]

<dir> is the checkout, this one unless given, and <rev> the commit whose
tests are read, HEAD unless given. The script reads the tests of every
MoonBit file at <rev> (.mbt, and the mbt blocks of .mbt.md), or of the
files under the paths given.

The commit that introduced a test block is the commit that git blame
gives for the block's header line (`test "..." {`), when it blames the
block with -w -M -C -C -C: across whitespace changes, and following lines
moved or copied within a file, from other files of the same commit, and
from any file of any commit. A test moved to another file keeps the
commit that wrote it there first.

The ticket is the issue number in the commit's subject: the one in a
trailing "(#N)", or else the only #N the subject names. A subject that
names none, or several and no trailing one, gives no ticket.

The issues come from gh (`gh api` on the checkout's repository). An
issue's acceptance criteria are the items of the list under its heading
"Acceptance criteria", without their check boxes, each with the lines
indented under it.

What it prints is one JSON object:

  rev     the commit read.
  tests   one record a test, in the order of their files and lines:
            file          the file, from the root;
            line          the line of its header;
            name          its name, as moon test gives it;
            commit        the commit that introduced it;
            introduced_in the file that commit wrote it in;
            subject       that commit's subject;
            issue         the ticket the subject names, or null.
  issues  for each ticket that a test's issue names, by its number:
            title, state, labels, pull_request (whether it is a pull
            request), and criteria: its acceptance criteria, a list of
            texts, or null when its body has no such heading.

It exits with 2 when git or gh cannot answer, such as when <rev> is not a
commit.
"""

import argparse
import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass


class Failure(Exception):
    """A command that failed, with what it said."""


def run(command, cwd=None):
    """The standard output of a command, which must succeed."""
    try:
        result = subprocess.run(
            command, cwd=cwd, capture_output=True, text=True, encoding="utf-8",
            errors="replace", check=False,
        )
    except OSError as error:
        raise Failure(f"{command[0]}: {error}") from error
    if result.returncode != 0:
        raise Failure(f"{' '.join(command[:3])}: {result.stderr.strip()}")
    return result.stdout


def git(repo, *args):
    """The output of a git command in repo."""
    return run(["git", "-C", repo, *args])


# --- Tests --------------------------------------------------------------------

TEST_HEADER = re.compile(r'(?:async\s+)?test(?:\s+("(?:[^"\\]|\\.)*"))?\s*[({]')


@dataclass
class Block:
    """A test block of a file: its name, and the lines of its header and of
    its end, counted from 1."""

    name: str
    header: int
    end: int


def unquote(literal):
    """The text of a MoonBit string literal."""
    return literal[1:-1].replace('\\"', '"').replace("\\\\", "\\")


def blocks_of(text):
    """The test blocks of a file. moon fmt starts each top-level item with
    a line of ///|; a test block runs from its header to its last line
    before the next item."""
    lines = text.split("\n")
    marks = [i for i, line in enumerate(lines) if line.rstrip() == "///|"]
    blocks = []
    for start, end in zip([0] + [m + 1 for m in marks], marks + [len(lines)]):
        first = next(
            (i for i in range(start, end)
             if lines[i].strip() and not lines[i].lstrip().startswith(("//", "#"))),
            None,
        )
        if first is None or not (match := TEST_HEADER.match(lines[first])):
            continue
        last = end - 1
        while last > first and not lines[last].strip():
            last -= 1
        blocks.append(Block(unquote(match.group(1)), first + 1, last + 1))
    return blocks


# --- Blame --------------------------------------------------------------------

BLAME_HEADER = re.compile(r"([0-9a-f]{40}) \d+ (\d+)(?: \d+)?$")


def blame(repo, rev, path, blocks):
    """For each line of the blocks, what git blame says of it: the commit
    that introduced it, the file it was written in, and the commit's
    subject."""
    ranges = [arg for b in blocks for arg in ("-L", f"{b.header},{b.end}")]
    out = git(repo, "blame", "--line-porcelain", "-w", "-M", "-C", "-C", "-C",
              *ranges, rev, "--", path)
    lines = {}
    current = None
    for line in out.split("\n"):
        if current is None:
            if match := BLAME_HEADER.match(line):
                current = {"commit": match.group(1), "line": int(match.group(2))}
        elif line.startswith("\t"):
            lines[current["line"]] = current
            current = None
        elif line.startswith("filename "):
            current["filename"] = line[len("filename "):]
        elif line.startswith("summary "):
            current["summary"] = line[len("summary "):]
    return lines


TRAILING_ISSUE = re.compile(r"\(#(\d+)\)\s*$")
ANY_ISSUE = re.compile(r"(?<![\w/#])#(\d+)\b")


def issue_of(subject):
    """The ticket a commit's subject names: the number of a trailing
    "(#N)", or else the only #N in it, or None."""
    if match := TRAILING_ISSUE.search(subject):
        return int(match.group(1))
    numbers = set(ANY_ISSUE.findall(subject))
    return int(numbers.pop()) if len(numbers) == 1 else None


def links_of(repo, rev, path):
    """The records of the tests of a file at rev."""
    blocks = blocks_of(git(repo, "show", f"{rev}:{path}"))
    if not blocks:
        return []
    blamed = blame(repo, rev, path, blocks)
    records = []
    for block in blocks:
        line = blamed[block.header]
        subject = line.get("summary", "")
        records.append({
            "file": path,
            "line": block.header,
            "name": block.name,
            "commit": line["commit"],
            "introduced_in": line.get("filename", path),
            "subject": subject,
            "issue": issue_of(subject),
        })
    return records


# --- Issues -------------------------------------------------------------------

ISSUE_FIELDS = (
    ".[] | {number, title, state, labels: [.labels[].name],"
    " pull_request: (.pull_request != null), body}"
)


def fetch_issues(repo):
    """Every issue and pull request of the checkout's repository on GitHub,
    by number."""
    out = run(["gh", "api", "--paginate", "repos/{owner}/{repo}/issues?state=all&per_page=100",
               "--jq", ISSUE_FIELDS], cwd=repo)
    issues = {}
    for line in out.splitlines():
        if line.strip():
            issue = json.loads(line)
            issues[int(issue["number"])] = issue
    return issues


HEADING = re.compile(r"(#{1,6})\s+(.*?)\s*#*\s*$")
# A line that is only a bold label, such as **Acceptance criteria:**, as
# the Agent Brief of a bug report has.
LABEL = re.compile(r"\*\*([^*]+)\*\*\s*:?\s*$")
ITEM = re.compile(r"(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.*)$")


def is_criteria_title(text):
    """Whether a heading's or a label's text is "Acceptance criteria"."""
    return text.strip().rstrip(":").strip().lower() == "acceptance criteria"


def criteria_of(body):
    """The acceptance criteria of an issue's body, or None when it has no
    heading or label for them. A heading's section ends at the next
    heading of its level or above; a label's at the next heading or line
    of text that is not indented, such as the next label."""
    lines = (body or "").split("\n")
    start = level = label = None
    for i, line in enumerate(lines):
        if (match := HEADING.match(line)) and is_criteria_title(match.group(2)):
            start, level, label = i + 1, len(match.group(1)), False
            break
        if (match := LABEL.match(line)) and is_criteria_title(match.group(1)):
            # Any heading ends a label's section.
            start, level, label = i + 1, 6, True
            break
    if start is None:
        return None
    items = []
    current = None
    for line in lines[start:]:
        if (match := HEADING.match(line)) and len(match.group(1)) <= level:
            break
        if match := ITEM.match(line):
            current = [match.group(1).rstrip()]
            items.append(current)
        elif line.strip() and line[0].isspace():
            if current is not None:
                current.append(line.rstrip())
        elif line.strip():
            if label:
                break
            current = None
    return ["\n".join(item) for item in items]


def issue_record(issue):
    """What the output says of an issue."""
    return {
        "title": issue.get("title"),
        "state": issue.get("state"),
        "labels": issue.get("labels", []),
        "pull_request": bool(issue.get("pull_request")),
        "criteria": criteria_of(issue.get("body")),
    }


# --- The whole --------------------------------------------------------------------


def moonbit_files(repo, rev, paths):
    """The MoonBit files at rev, under the paths if any are given."""
    names = git(repo, "ls-tree", "-r", "--name-only", rev, "--", *paths)
    return [n for n in names.splitlines() if n.endswith((".mbt", ".mbt.md"))]


def main():
    """Prints the trace links."""
    parser = argparse.ArgumentParser(description="Derive the trace links of the tests.")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--rev", default="HEAD")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    try:
        rev = git(args.repo, "rev-parse", "--verify", "--quiet", f"{args.rev}^{{commit}}").strip()
        files = moonbit_files(args.repo, rev, args.paths)
        with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            tests = [t for records in pool.map(lambda f: links_of(args.repo, rev, f), files)
                     for t in records]
        numbers = sorted({t["issue"] for t in tests if t["issue"] is not None})
        known = fetch_issues(args.repo) if numbers else {}
    except Failure as error:
        print(f"trace-links: {error}", file=sys.stderr)
        return 2
    issues = {str(n): issue_record(known[n]) if n in known else {"found": False} for n in numbers}
    json.dump({"rev": rev, "tests": tests, "issues": issues}, sys.stdout, indent=1,
              ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
