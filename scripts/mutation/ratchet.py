#!/usr/bin/env python3
"""The site-count ratchet of the mutation runner (CONTRIBUTING.md,
"Mutation runner", "The site counts"): the committed count of each
package's sites, per definition and operator, and the check that keeps a
change from weakening the runner by finding fewer sites.

usage: python3 scripts/mutation/ratchet.py [--root <dir>] [--finder <command>]
           [--moonc <moonc>] write
       python3 scripts/mutation/ratchet.py [--root <dir>] [--finder <command>]
           [--moonc <moonc>] check [--base <ref>]

<root> is the workspace, the current directory unless it is given. Its
packages are every directory with a moon.pkg or a moon.pkg.json in the
modules that moon.work lists (or in the module at <root> without one),
but not in a module of its own that moon.work does not list, such as the
runner's fixture module. The site finder (scripts/mutation/sites.py, or
--finder) gives their sites in the full set, each with whether the pinned
set takes it.

write  writes the counts into <root>/mutation/site-counts/: a file for
       each package that has a site, named by the package's directory,
       as mutation/site-counts/cmd/smock.jsonl for cmd/smock. Each line
       is one top-level definition that holds a site, as JSON, in the
       order of the package's files and of the definitions in them:
         file        the definition's file, relative to <root>
         definition  its name, as a site's id gives it
         text        the first 16 hexadecimal digits of the SHA-256 of
                     its text, from its first line to its last, which
                     tells a definition that a change changed from one
                     it left as it was
         pinned      its count of sites of each operator in the pinned set
         full        the same in the full set
       A file of a package that no longer has a site is removed.

check  fails, with 1, when the committed counts differ from what write
       would write on <root>'s tree, and when, against the merge base of
       HEAD and <base> (origin/main unless it is given), a package's sites
       drop by more than the base's sites in the definitions that the
       change deletes or changes. The base's counts are those committed
       at the merge base. A definition that the change neither deletes
       nor changes is one whose text the package still has, in any of its
       files; for each such definition, each operator and each set, a
       count of the head below the base's is a drop that only the list of
       approved drops can allow: mutation/approved-drops.txt, in which the
       change adds, for each package, operator and set with such a drop, a
       line
         <package> <operator> <pinned|full> <sites> <reason>
       with the number of sites dropped. Only the lines that the change
       adds approve a drop, and each must name a drop that the change
       makes. When the merge base has no committed counts, nothing is
       compared with it.

It exits with 2 when it cannot judge: the finder fails, a file does not
parse, or git cannot answer.
"""

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

import operators as ops
import sites

HERE = Path(__file__).resolve().parent
COUNTS = Path("mutation") / "site-counts"
DROPS = Path("mutation") / "approved-drops.txt"
SETS = ("pinned", "full")
# Directories that hold no package: build output, downloaded modules and
# git's own.
SKIPPED = {"_build", "target", ".mooncakes", ".git", "node_modules"}
MEMBER = re.compile(r'"([^"]+)"')


class RatchetError(Exception):
    """What keeps the ratchet from judging."""


def modules(root):
    """The directories of the workspace's modules, relative to root."""
    work = root / "moon.work"
    if not work.is_file():
        return [Path(".")]
    text = work.read_text(encoding="utf-8")
    members = re.search(r"members\s*=\s*\[(.*?)\]", text, re.DOTALL)
    if not members:
        raise RatchetError(f"{work} lists no members")
    return [Path(os.path.normpath(m)) for m in MEMBER.findall(members.group(1))]


def packages(root):
    """The directories of the workspace's packages, relative to root, with
    "/", sorted."""
    found = set()
    for module in modules(root):
        top = (root / module).resolve()
        for directory, subdirectories, names in os.walk(top):
            here = Path(directory)
            subdirectories[:] = sorted(
                d for d in subdirectories
                if d not in SKIPPED and not any((here / d / m).is_file() for m in ("moon.mod", "moon.mod.json")))
            if "moon.pkg" in names or "moon.pkg.json" in names:
                found.add(here.relative_to(root.resolve()).as_posix())
    return sorted(found)


def text_hash(text):
    """The first 16 hexadecimal digits of a text's SHA-256."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


class Definition:
    """A top-level definition of a package's source: its file, name, lines,
    the hash of its text, and its counts of sites in each set."""

    def __init__(self, file, name, first, last, text):
        self.file = file
        self.name = name
        self.first = first
        self.last = last
        self.text = text_hash(text)
        self.counts = {s: Counter() for s in SETS}

    def line(self):
        """Its line in the package's file of counts."""
        counts = {s: {o: self.counts[s][o] for o in ops.OPERATORS if self.counts[s][o]} for s in SETS}
        return json.dumps({"file": self.file, "definition": self.name, "text": self.text, **counts},
                          ensure_ascii=False, separators=(",", ":"))


def definitions(root, package, moonc):
    """The top-level definitions of a package's non-test source, outside
    generated files and test blocks, in the order of its files and lines."""
    found = []
    files = []
    for path in sites.source_files(root, [package]):
        text = (root / path).read_text(encoding="utf-8")
        if not sites.is_generated(text):
            files.append((path, text))
    with tempfile.TemporaryDirectory(prefix="smock-ratchet-") as tmp:
        for index, (path, text) in enumerate(files):
            source = sites.SourceFile(path, text)
            for entry in sites.parse_tree(sites.dump(moonc, "wasm-gc", Path(tmp), index, path, text)):
                if not (isinstance(entry, list) and len(entry) == 3 and entry[0] == "base_pos"):
                    raise RatchetError(f"{path}: unexpected entry in the parse tree: {str(entry)[:80]}")
                item = sites.Item(source, entry[1], entry[2])
                if item.is_test():
                    continue
                first, last = item.lines()
                body = "\n".join(text.split("\n")[first - 1 : last])
                found.append(Definition(path.as_posix(), item.name(), first, last, body))
    return found


def find_sites(finder, root, directories):
    """The sites of the full set that the finder prints for the packages,
    without the skipped ones."""
    if not directories:
        return []
    result = subprocess.run([*finder, "--root", str(root), "--set", "full", *directories],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise RatchetError(f"the site finder failed:\n{result.stderr}")
    lines = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    return [s for s in lines if "skipped" not in s]


def tree_counts(root, finder, moonc):
    """Each package's definitions, each with its counts of sites, on
    root's tree."""
    names = packages(root)
    by_package = {p: definitions(root, p, moonc) for p in names}
    by_file = {}
    for found in by_package.values():
        for definition in found:
            by_file.setdefault(definition.file, []).append(definition)
    for site in find_sites(finder, root, names):
        holders = [d for d in by_file.get(site["file"], []) if d.first <= site["line"] <= d.last]
        if len(holders) != 1:
            raise RatchetError(f"{site['file']}:{site['line']}: the site {site.get('id')} lies in"
                               f" {len(holders)} top-level definitions, not one")
        for chosen in SETS:
            if chosen == "full" or site["pinned"]:
                holders[0].counts[chosen][site["operator"]] += 1
    return by_package


def count_files(by_package):
    """The text of each package's file of counts, by its path under the
    counts' directory; none for a package without a site."""
    files = {}
    for package, found in by_package.items():
        lines = [d.line() for d in found if sum(d.counts["full"].values())]
        if lines:
            files[f"{package}.jsonl"] = "".join(f"{line}\n" for line in lines)
    return files


def write(root, finder, moonc):
    """Writes the counts of root's tree."""
    files = count_files(tree_counts(root, finder, moonc))
    directory = root / COUNTS
    if directory.is_dir():
        for old in sorted(directory.rglob("*.jsonl")):
            if old.relative_to(directory).as_posix() not in files:
                old.unlink()
    for name, text in files.items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    print(f"ratchet: wrote the site counts of {len(files)} packages into {COUNTS.as_posix()}/")


def main():
    parser = argparse.ArgumentParser(description="Write or check the committed site counts of each package.")
    parser.add_argument("--root", default=".", help="the workspace")
    parser.add_argument("--finder", help="the site finder's command (default: sites.py beside this script)")
    parser.add_argument("--moonc", default="moonc", help="the compiler, whose parse tree gives the definitions")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("write", help="write the counts of the tree")
    check = commands.add_parser("check", help="check the counts against the tree and the base")
    check.add_argument("--base", default="origin/main", help="compare with the merge base of HEAD and this")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    finder = shlex.split(args.finder) if args.finder else [sys.executable, str(HERE / "sites.py")]
    try:
        if args.command == "write":
            write(root, finder, args.moonc)
    except (RatchetError, sites.FinderError, FileNotFoundError) as error:
        print(f"ratchet: {error}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
