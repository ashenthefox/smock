"""Chooses which mutants a run of the mutation runner makes, beyond its set
and the ids of --mutant (CONTRIBUTING.md, "Mutation runner"): a listed set
of mutants, a seeded sample of them, stratified by package, and shard k of
n of them. scripts/mutation/run.py calls it; it runs nothing but git and
the compiler's parser.

The run's order is the order of the packages given, then the finder's
order within each package, or the list's. A choice keeps that order, so
that the shards of a run, read in shard order, hold its mutants in its own
order.

A list of mutants has one JSON object per line, each a mutant by offset or
by key:

  by offset  "file", "offset" (in characters, from 0), "original" (the
             text there, which the mutant replaces), "replacement" and
             "commit" (on which the offset holds), and "operator" if it
             names one;
  by key     "file", "definition", "operator", "original", "replacement"
             and "ordinal": the fields of a mutant's id, which an
             exclusion names it by, with the texts whole.

A mutant that a site of operator set v1 makes is that site, with its id.
Any other is outside v1, and is named as a site would be: its file, its
enclosing definition, its operator (OTHER when an entry by offset names
none), its texts and an ordinal, which counts the places in its
definition where the same original text starts before it, outside
comments. A key whose operator is one of v1's names a site of v1 by its
id; a key with any other operator names the place its ordinal counts to.
A key that finds neither no longer applies.
"""

import argparse
import hashlib
import json
import posixpath
import re
import subprocess
import tempfile
from pathlib import Path

import operators as ops
import sites as finder

SHARD = re.compile(r"^(\d+)/(\d+)$")
# The operator of a listed mutant by offset that names none.
OTHER = "OTHER"
BY_OFFSET = {"file": str, "offset": int, "original": str, "replacement": str, "commit": str}
BY_KEY = {"file": str, "definition": str, "operator": str, "original": str, "replacement": str, "ordinal": int}


class ChoiceError(Exception):
    """What stops a choice: an input that names no mutant it can make."""


def shard_spec(text):
    """The k and n of a shard written "k/n", for argparse."""
    match = SHARD.match(text)
    if not match:
        raise argparse.ArgumentTypeError(f"{text!r} is not k/n, such as 2/3")
    index, count = int(match.group(1)), int(match.group(2))
    if count < 1 or not 1 <= index <= count:
        raise argparse.ArgumentTypeError(f"{text!r}: k must be from 1 to n, and n at least 1")
    return index, count


def shard(chosen, directories, index, count):
    """Shard index of count of the chosen mutants of each package: the
    index-th of count runs of the run's order, whose lengths differ by one
    at most. Each mutant is in exactly one shard, and the same mutants give
    the same shards."""
    order = [(d, s) for d in directories for s in chosen[d]]
    start, end = (index - 1) * len(order) // count, index * len(order) // count
    mine = {d: [] for d in directories}
    for directory, site in order[start:end]:
        mine[directory].append(site)
    return mine


def sample(chosen, directories, size, seed):
    """A sample of size of the chosen mutants, stratified by package: each
    package's share of it is its share of the mutants, rounded down, and
    the mutants left over go to the packages whose shares lost the most in
    rounding (the first package given wins a tie). Within a package, the
    mutants taken are those whose ids, with the seed, have the smallest
    SHA-256 hashes, so that the same seed and the same mutants give the
    same sample, whatever the version of Python."""
    total = sum(len(chosen[d]) for d in directories)
    if size >= total:
        return {d: list(chosen[d]) for d in directories}
    quotas = {d: size * len(chosen[d]) // total for d in directories}
    lost = sorted(directories, key=lambda d: (-(size * len(chosen[d]) % total), directories.index(d)))
    for directory in lost[: size - sum(quotas.values())]:
        quotas[directory] += 1
    taken = {}
    for directory in directories:
        ranked = sorted(range(len(chosen[directory])),
                        key=lambda i: (hashlib.sha256(f"{seed}\n{chosen[directory][i]['id']}".encode()).hexdigest(), i))
        keep = set(ranked[: quotas[directory]])
        taken[directory] = [s for i, s in enumerate(chosen[directory]) if i in keep]
    return taken


def running(directories, chosen, mine, selected, shard_index):
    """The packages a run builds and tests, given the chosen mutants of
    each package and the shard's own (the same without shards). Without a
    selection that can leave a package with no mutant (ids, a list, a
    sample, changed lines), every package runs, as it always has: one that
    has no mutant at all runs in the first shard. Otherwise only the
    packages that hold one of the shard's mutants run."""
    first = shard_index is None or shard_index == 1
    return {d for d in directories if mine[d] or (not selected and first and not chosen[d])}


def selection(args):
    """What chose a run's mutants, as its summary gives it: the set, the
    packages given, the ids, the list (by its digest), the sample and the
    shard. Shards whose
    selections differ only in their shard are of one run."""
    return {
        "set": args.set,
        "packages": list(args.packages),
        "mutants": list(args.mutant or []),
        "list": list_digest(args.list) if args.list else None,
        "sample": None if args.sample is None else {"size": args.sample, "seed": args.seed},
        "shard": None if args.shard is None else {"index": args.shard[0], "count": args.shard[1]},
    }


def read_list(path):
    """The entries of a list of mutants, each with the number of its line."""
    entries = []
    for number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            entry = None
        if not isinstance(entry, dict):
            raise ChoiceError(f"{path}:{number}: a line of the list is a JSON object")
        kind, fields = ("offset", BY_OFFSET) if "offset" in entry else ("key", BY_KEY)
        for field, kind_of in fields.items():
            value = entry.get(field)
            if not isinstance(value, kind_of) or isinstance(value, bool) or (kind_of is int and value < 0):
                what = "a number from 0" if kind_of is int else "a string"
                raise ChoiceError(f"{path}:{number}: a mutant by {kind} has a \"{field}\", {what}")
        if "operator" in entry and not isinstance(entry["operator"], str):
            raise ChoiceError(f"{path}:{number}: a mutant's \"operator\" is a string")
        entries.append((number, entry))
    return entries


def list_directories(entries):
    """The package directories of the listed files, in the list's order."""
    directories = []
    for _, entry in entries:
        directory = posixpath.dirname(entry["file"])
        if directory not in directories:
            directories.append(directory)
    return directories


def list_digest(path):
    """What names a list in a summary without naming its mutants: the
    SHA-256 of its bytes."""
    return "sha256:" + hashlib.sha256(Path(path).read_bytes()).hexdigest()


def comment_start(line):
    """Where the comment of a line of MoonBit starts, outside its string and
    character literals, or None."""
    if line.lstrip().startswith(("#|", "$|")):
        return None
    i = 0
    while i < len(line):
        c = line[i]
        if c == '"':
            i += 1
            while i < len(line) and line[i] != '"':
                i += 2 if line[i] == "\\" else 1
        elif c == "'":
            close = line.find("'", i + (3 if line[i + 1 : i + 2] == "\\" else 2))
            i = close if close > i else i
        elif line.startswith("//", i):
            return i
        i += 1
    return None


def places(source, lines, original):
    """Where original starts in the definition on lines (its first and its
    last), outside comments, as offsets in the file."""
    found = []
    for number in range(lines[0], lines[1] + 1):
        start, end = source.starts[number - 1], source.starts[number] - 1
        line = source.text[start:end]
        cut = comment_start(line)
        limit = start + (len(line) if cut is None else cut)
        at = source.text.find(original, start)
        while at != -1 and at < limit:
            found.append(at)
            at = source.text.find(original, at + 1)
    return found


class Files:
    """The files of a root that the list names, read once, with their
    definitions from the compiler's parse tree."""

    def __init__(self, root, moonc):
        self.root = root
        self.moonc = moonc
        self.read = {}

    def source(self, file):
        """The file's text as a finder.SourceFile, or None when it is gone."""
        if file not in self.read:
            path = self.root / file
            self.read[file] = finder.SourceFile(Path(file), path.read_text(encoding="utf-8")) if path.is_file() else None
        return self.read[file]

    def definitions(self, file):
        """The file's top-level definitions but its tests: (name, [first
        line, last line])."""
        source = self.source(file)
        with tempfile.TemporaryDirectory(prefix="smock-choice-") as tmp:
            try:
                tree = finder.dump(self.moonc, "wasm-gc", Path(tmp), 0, Path(file), source.text)
            except finder.FinderError as error:
                raise ChoiceError(str(error)) from None
        items = [finder.Item(source, entry[1], entry[2]) for entry in finder.parse_tree(tree)]
        return [(item.name(), item.lines()) for item in items if not item.is_test()]


def outside(source, file, definition, lines, operator, original, replacement, offset):
    """A listed mutant outside operator set v1, named as a site is."""
    ordinal = places(source, lines, original).index(offset)
    line, column = source.position(offset)
    fields = [file, definition, operator, finder.shorten(original), finder.shorten(replacement)]
    return {"id": ",".join(finder.escape(f) for f in fields + [str(ordinal)]), "file": file,
            "definition": definition, "operator": operator, "original": original, "replacement": replacement,
            "ordinal": ordinal, "line": line, "column": column, "definition_lines": lines, "pinned": False,
            "operator_set": ops.VERSION, "in_operator_set": False}


def at_commit(root, file, commit):
    """The text of a file on a commit, as git gives it."""
    result = subprocess.run(["git", "-C", str(root), "show", f"{commit}:./{file}"], capture_output=True)
    if result.returncode != 0:
        raise ChoiceError(f"git cannot give {file} on {commit}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout.decode("utf-8", errors="replace")


def by_offset(files, where, entry, sites):
    """The mutant an entry by offset names, after checking that its file
    holds the commit's text and its original text at its offset."""
    file, offset, original = entry["file"], entry["offset"], entry["original"]
    source = files.source(file)
    if source is None:
        raise ChoiceError(f"{where}: {file} is not a file of {files.root}")
    if source.text != at_commit(files.root, file, entry["commit"]):
        raise ChoiceError(f"{where}: {file} differs from its text at {entry['commit']}")
    if source.text[offset : offset + len(original)] != original:
        raise ChoiceError(f"{where}: {file} does not hold {json.dumps(original)} at offset {offset}")
    line, column = source.position(offset)
    for site in sites:
        if ((site["file"], site["line"], site["column"], site["original"], site["replacement"])
                == (file, line, column, original, entry["replacement"])):
            return dict(site, in_operator_set=True)
    end = source.position(offset + len(original))[0]
    for name, lines in files.definitions(file):
        if lines[0] <= line and end <= lines[1]:
            if offset not in places(source, lines, original):
                raise ChoiceError(f"{where}: offset {offset} of {file} is in a comment")
            return outside(source, file, name, lines, entry.get("operator", OTHER), original,
                           entry["replacement"], offset)
    raise ChoiceError(f"{where}: offset {offset} of {file} is in no definition but a test")


def by_key(files, entry, sites):
    """The mutant an entry by key names, or None and why it no longer
    applies."""
    file = entry["file"]
    source = files.source(file)
    if source is None:
        return None, "its file is gone"
    if entry["operator"] in ops.OPERATORS:
        name = key_name(entry)
        for site in sites:
            if site["id"] == name:
                return dict(site, in_operator_set=True), None
        return None, "no site of operator set v1 has its id"
    mine = [lines for name, lines in files.definitions(file) if name == entry["definition"]]
    if not mine:
        return None, "its definition is gone"
    found = [(lines, at) for lines in mine for at in places(source, lines, entry["original"])]
    if entry["ordinal"] >= len(found):
        return None, "its text is gone"
    lines, at = found[entry["ordinal"]]
    return outside(source, file, entry["definition"], lines, entry["operator"], entry["original"],
                   entry["replacement"], at), None


def resolve(root, path, entries, found, directories, moonc="moonc"):
    """The listed mutants of each package given, in the list's order, and
    the keys that no longer apply there, each with why."""
    files = Files(root, moonc)
    chosen = {d: [] for d in directories}
    unapplied = {d: [] for d in directories}
    for number, entry in entries:
        directory = posixpath.dirname(entry["file"])
        if directory not in chosen:
            continue
        if "offset" in entry:
            mutant, why = by_offset(files, f"{path}:{number}", entry, found[directory][0]), None
        else:
            mutant, why = by_key(files, entry, found[directory][0])
        if mutant is None:
            unapplied[directory].append((entry, why))
        else:
            chosen[directory].append(dict(mutant, listed=entry))
    return chosen, unapplied


def key_name(entry):
    """A listed key, written as an id."""
    fields = [entry["file"], entry["definition"], entry["operator"], finder.shorten(entry["original"]),
              finder.shorten(entry["replacement"])]
    return ",".join(finder.escape(f) for f in fields + [str(entry["ordinal"])])


def listed_report(directories, records, unapplied):
    """The report's lines on a listed set: per package, how many mutants it
    lists, how many ran, how many no longer apply and how many are
    outside operator set v1; each mutant that ran, with its outcome; and
    each key that no longer applies, with why."""
    out = ["## Listed mutants", "",
           "| package | listed | run | no longer apply | outside operator set v1 |", "|---|---:|---:|---:|---:|"]
    for directory in directories:
        mine = [r for r in records if posixpath.dirname(r["file"]) == directory]
        gone = unapplied.get(directory, [])
        if mine or gone:
            outside_set = sum(1 for r in mine if not r["in_operator_set"])
            out += [f"| {directory} | {len(mine) + len(gone)} | {len(mine)} | {len(gone)} | {outside_set} |"]
    out += ["", "| mutant | operator set v1 | outcome |", "|---|---|---|"]
    out += [f"| `{r['id']}` | {'in it' if r['in_operator_set'] else 'outside it'} | {r['outcome']} |"
            for r in records]
    out += [""]
    gone = [(d, entry, why) for d in directories for entry, why in unapplied.get(d, [])]
    if gone:
        out += [f"### No longer apply ({len(gone)})", ""]
        out += [f"- `{key_name(entry)}`: {why}" for _, entry, why in gone]
        out += [""]
    return out
