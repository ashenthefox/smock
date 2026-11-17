#!/usr/bin/env python3
"""Derives the trace links of smock's tests, the third of the three sets
that the removal rule's (A) compares (#275, "The removal rule and its
proof"): from the commit that introduced each test block, following moves
and copies across files, to the ticket that commit's subject names, to
that issue's acceptance criteria. It writes them out per test, as JSON,
for the comparison before and after a removal and for the keep reasons of
rule (C).

usage: python3 scripts/trace-links.py [--repo <dir>] [--rev <rev>]
                                      [--issues <file>] [--jobs <n>]
                                      [<path>...]
       python3 scripts/trace-links.py [--repo <dir>] --dump-issues

<dir> is the checkout, this one unless given, and <rev> the commit whose
tests are read, HEAD unless given. The script reads the tests of the
workspace's modules at <rev> (the modules moon.work lists, or the module
at the root when there is none), or of their files under the paths
given: the test blocks of .mbt files and of the mbt blocks of .mbt.md
documents, and the doc tests in the mbt blocks of doc comments.

The commit that introduced a test block is the commit that git blame
gives for the block's header line (`test "..." {`), when it blames the
top-level item that holds it with -w -M -C -C -C: across whitespace
changes, and following lines moved or copied within a file, from other
files of the same commit, and from any file of any commit. A test moved
or copied to another file keeps the commit that first wrote it, and so
does a test that a later commit extends. git follows moved lines only
where they hold at least 40 letters and digits together (20 within one
file); a doc test is read with the whole item its doc comment belongs
to, and moves with it.

The header's commit must also have written another line of the block
that holds a letter or a digit. Where it wrote none, the header came
alone: from a commit that renamed the test, or from an older test of the
same name, which blame takes it to be a copy of. The block's commit is
then the one that wrote most of those other lines (the first of them on
a tie), so that a renamed test keeps the commit that introduced it.

The ticket is the issue number in the commit's subject: the one in a
trailing "(#N)", or else the only #N the subject names. A subject that
names none, or several and no trailing one, gives no ticket.

The issues come from gh: `gh api` on the checkout's repository, which
needs a token in GH_TOKEN on CI. --dump-issues prints them as gh gives
them, one JSON object a line, and --issues reads them from such a file
instead of asking gh, so that the links before and after a removal read
the same issues. An issue's acceptance criteria are the items of the
list under its heading "Acceptance criteria", or under a line that is
only that label in bold, as a bug's Agent Brief has: each item without
its check box, ticked or not, and with the lines indented under it.

<n> is how many files git blame reads at once, 4 unless given.

What it prints is one JSON object:

  rev     the commit read.
  tests   one record a test, in the order of their files and lines:
            package       its package, as moon names it: the module's
                          name and the directory within the module;
            file          its file, from the root;
            line          the line of its header;
            index         its index among the test blocks of its file,
                          from 0, as moon test --index takes it; doc
                          tests are numbered on their own;
            kind          test, or doc for a doc test;
            name          its name as moon test gives it, the text of its
                          literal with any escapes, or null;
            commit        the commit that introduced it;
            introduced_in the file that commit wrote it in;
            subject       that commit's subject;
            issue         the ticket the subject names, or null.
  issues  for each ticket that a test's issue names, by its number:
            title, state, labels, pull_request (whether it is a pull
            request), and criteria: its acceptance criteria, a list of
            texts, or null when its body has no such heading or label.
            A number that GitHub does not know has only "found": false.

It exits with 2 when git or gh cannot answer, such as when <rev> is not a
commit.
"""

import argparse
import json
import posixpath
import re
import subprocess
import sys
from collections import Counter
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
# A line of a doc comment, and its text after /// and one space.
DOC_LINE = re.compile(r"\s*/// ?(.*)$")


@dataclass
class Block:
    """A test block of a file: its kind (test, or doc for a doc test), its
    name or None, its index among the blocks of its kind in its file, the
    line of its header, and the first and last lines of the top-level item
    that holds it, all counted from 1."""

    kind: str
    name: str
    index: int
    header: int
    start: int
    end: int


def name_of(match):
    """The name of the test whose header matched, as moon test gives it:
    the text between the quotes of its literal, escapes and all; or None
    for a test without a name."""
    return match.group(1)[1:-1] if match.group(1) else None


def code_regions(path, lines):
    """The ranges of lines that hold code: the whole of a .mbt file, and
    the mbt blocks of a .mbt.md document."""
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


def test_blocks(path, lines):
    """The test blocks of a file's code, in the order moon test numbers
    them. moon fmt starts each top-level item with a line of ///|, and the
    item runs to its last line before the next one."""
    blocks = []
    for lo, hi in code_regions(path, lines):
        marks = [i for i in range(lo, hi) if lines[i].rstrip() == "///|"]
        for start, end in zip([lo] + [m + 1 for m in marks], marks + [hi]):
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
            blocks.append(
                Block("test", name_of(match), len(blocks), first + 1, start + 1, last + 1)
            )
    return blocks


def item_of(lines, i):
    """The first and the last lines, from 0, of the top-level item that
    holds line i: from the line after the last line of ///| before it, to
    the last line that is not blank before the next one."""
    start = next((j + 1 for j in range(i - 1, -1, -1) if lines[j].rstrip() == "///|"), 0)
    end = next((j for j in range(i + 1, len(lines)) if lines[j].rstrip() == "///|"), len(lines))
    while end - 1 > i and not lines[end - 1].strip():
        end -= 1
    return start, end - 1


def doc_test_blocks(lines):
    """The doc tests of a .mbt file: the test blocks in the mbt blocks of
    its doc comments, numbered on their own, as moon test numbers them.
    Blame reads each with the whole item that the doc comment belongs to:
    its own lines are often too few for git to find where they were moved
    from."""
    blocks = []
    fenced = False
    for i, line in enumerate(lines):
        doc = DOC_LINE.match(line)
        text = doc.group(1) if doc else ""
        if not doc or (fenced and text.strip().startswith("```")):
            fenced = False
        elif not fenced:
            fenced = text.strip().startswith("```mbt")
        elif match := TEST_HEADER.match(text):
            start, end = item_of(lines, i)
            blocks.append(Block("doc", name_of(match), len(blocks), i + 1, start + 1, end + 1))
    return blocks


def blocks_of(path, text):
    """The test blocks and doc tests of a file."""
    lines = text.split("\n")
    blocks = test_blocks(path, lines)
    if not path.endswith(".mbt.md"):
        blocks += doc_test_blocks(lines)
    return sorted(blocks, key=lambda b: b.header)


# --- Blame --------------------------------------------------------------------

BLAME_HEADER = re.compile(r"([0-9a-f]{40}) \d+ (\d+)(?: \d+)?$")


def blame(repo, rev, path, blocks):
    """For each line of the items that hold the blocks, what git blame
    says of it: the commit that introduced it, the file it was written in,
    and the commit's subject."""
    items = sorted({(b.start, b.end) for b in blocks})
    ranges = [arg for start, end in items for arg in ("-L", f"{start},{end}")]
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


# A letter or a digit.
ALNUM = re.compile(r"[^\W_]")


def introduction(block, blamed, lines):
    """What blame says of the line that tells which commit introduced a
    block: its header line, if the header's commit also wrote another line
    of the block that holds a letter or a digit. Otherwise the header came
    alone, from a commit that renamed the test or from an older test of
    the same name, and it is the first of the lines (with a letter or a
    digit) of the commit that wrote most of them."""
    header = blamed[block.header]
    others = [
        blamed[n] for n in range(block.header + 1, block.end + 1)
        if n in blamed and ALNUM.search(lines[n - 1])
    ]
    if not others or any(other["commit"] == header["commit"] for other in others):
        return header
    counts = Counter(other["commit"] for other in others)
    most = max(counts.values())
    return next(other for other in others if counts[other["commit"]] == most)


def links_of(repo, rev, path, package):
    """The records of the tests of a file at rev, of the package given."""
    text = git(repo, "show", f"{rev}:{path}")
    blocks = blocks_of(path, text)
    if not blocks:
        return []
    blamed = blame(repo, rev, path, blocks)
    lines = text.split("\n")
    records = []
    for block in blocks:
        line = introduction(block, blamed, lines)
        subject = line.get("summary", "")
        records.append({
            "package": package,
            "file": path,
            "line": block.header,
            "index": block.index,
            "kind": block.kind,
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
    as gh gives them: one JSON object a line."""
    return run(["gh", "api", "--paginate", "repos/{owner}/{repo}/issues?state=all&per_page=100",
                "--jq", ISSUE_FIELDS], cwd=repo)


def read_issues(text):
    """The issues of the lines that fetch_issues gives, by number."""
    issues = {}
    for line in text.splitlines():
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


MODULE_NAME = re.compile(r'^\s*name\s*=\s*"([^"]*)"', re.MULTILINE)
QUOTED = re.compile(r'"([^"]*)"')


def modules_of(repo, rev):
    """The modules at rev: each one's directory, from the root ("" for the
    root itself), its name, and whether it is a member of the workspace:
    one that moon.work lists, or the module at the root when there is no
    moon.work."""
    names = git(repo, "ls-tree", "-r", "--name-only", rev).splitlines()
    modules = {}
    for name in names:
        directory, base = posixpath.split(name)
        if base == "moon.mod":
            text = git(repo, "show", f"{rev}:{name}")
            match = MODULE_NAME.search(text)
            modules[directory] = match.group(1) if match else ""
        elif base == "moon.mod.json":
            modules[directory] = json.loads(git(repo, "show", f"{rev}:{name}")).get("name", "")
    if "moon.work" in names:
        work = git(repo, "show", f"{rev}:moon.work")
        listed = re.search(r"members\s*=\s*\[(.*?)\]", work, re.DOTALL)
        members = set()
        for member in QUOTED.findall(listed.group(1) if listed else ""):
            directory = posixpath.normpath(member)
            members.add("" if directory == "." else directory)
    else:
        members = {""}
    return {d: (n, d in members) for d, n in modules.items()}


def package_of(path, modules):
    """The package of a file, as moon names it: its module's name and the
    file's directory within the module. None when the module that holds
    the file is not a member of the workspace, or when no module does."""
    directory = posixpath.dirname(path)
    parts = directory.split("/") if directory else []
    for n in range(len(parts), -1, -1):
        module = "/".join(parts[:n])
        if module in modules:
            name, member = modules[module]
            return "/".join([name, *parts[n:]]) if member else None
    return None


def moonbit_files(repo, rev, paths, modules):
    """The MoonBit files at rev that members of the workspace hold, under
    the paths if any are given, with their packages."""
    names = git(repo, "ls-tree", "-r", "--name-only", rev, "--", *paths)
    files = []
    for name in names.splitlines():
        if name.endswith((".mbt", ".mbt.md")) and (package := package_of(name, modules)):
            files.append((name, package))
    return files


def issues_from(path):
    """The text of a file that --dump-issues wrote."""
    try:
        with open(path, encoding="utf-8") as file:
            return file.read()
    except OSError as error:
        raise Failure(f"{path}: {error.strerror}") from error


def main():
    """Prints the trace links, or the issues with --dump-issues."""
    parser = argparse.ArgumentParser(description="Derive the trace links of the tests.")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--rev", default="HEAD")
    parser.add_argument("--issues")
    parser.add_argument("--dump-issues", action="store_true")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    try:
        if args.dump_issues:
            sys.stdout.write(fetch_issues(args.repo))
            return 0
        rev = git(args.repo, "rev-parse", "--verify", "--quiet", f"{args.rev}^{{commit}}").strip()
        files = moonbit_files(args.repo, rev, args.paths, modules_of(args.repo, rev))
        with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            found = pool.map(lambda file: links_of(args.repo, rev, *file), files)
            tests = [record for records in found for record in records]
        numbers = sorted({t["issue"] for t in tests if t["issue"] is not None})
        if args.issues:
            known = read_issues(issues_from(args.issues))
        else:
            known = read_issues(fetch_issues(args.repo)) if numbers else {}
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
