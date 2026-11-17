"""Finds the lines a branch changes, for the mutation runner's diff mode
(--changed; CONTRIBUTING.md, "Mutation runner"): the non-test lines of the
pure packages that the working tree adds or changes against the merge
base of HEAD with a base, main unless another is given. Its runs nothing
but git.

A changed line is a line of the working tree's file that git's diff with
the merge base gives as added, without following renames, so a file that
moved counts as changed whole; a file that git does not track but does
not ignore counts as changed whole too, since the runner copies it. Only
.mbt files count, and not test files (*_test.mbt, *_wbtest.mbt) nor
generated ones (the finder's rule). A pure package is a directory with a
moon.pkg (or moon.pkg.json), in a module that the workspace's moon.work
lists (the root's own module when there is no moon.work), whose
supported targets, if it names any, hold wasm-gc. A site is on the
changed lines when any line of its original text is one.
"""

import json
import posixpath
import re
import subprocess
from pathlib import Path

import sites as finder

# The base of the merge base, unless another is given, and the one to fall
# back to where the checkout has no main branch of its own, as CI's has
# not.
DEFAULT_BASES = ("main", "origin/main")
HUNK = re.compile(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@")
MEMBERS = re.compile(r"\bmembers\s*=\s*\[([^\]]*)\]")
SUPPORTED = re.compile(r'(?:^[ \t]*supported_targets[ \t]*=|"supported-targets"[ \t]*:)[ \t]*'
                       r'("(?:[^"\\]|\\.)*"|\[[^\]]*\])', re.MULTILINE)
TARGET = re.compile(r"([+-]?)\s*(all|wasm-gc|wasm|js|native|llvm)\b")
TARGETS = {"wasm", "wasm-gc", "js", "native", "llvm"}


class ChangedError(Exception):
    """What stops the diff mode: a base git cannot find."""


def git(root, *args):
    """Runs git in root, and gives its output."""
    result = subprocess.run(["git", "-C", str(root), "-c", "core.quotepath=off", *args], capture_output=True,
                            text=True)
    if result.returncode != 0:
        raise ChangedError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def merge_base(root, base):
    """The base as named (the default's first that git knows when none is
    given), and the full id of its merge base with HEAD."""
    for name in (base,) if base else DEFAULT_BASES:
        if subprocess.run(["git", "-C", str(root), "rev-parse", "--verify", "--quiet", f"{name}^{{commit}}"],
                          capture_output=True).returncode == 0:
            return name, git(root, "merge-base", name, "HEAD").strip()
    raise ChangedError(f"git knows no {base or ' or '.join(DEFAULT_BASES)} to take the merge base with")


def changed_lines(root, commit):
    """The lines of each .mbt file that the working tree adds or changes
    against a commit, from 1, and those of the files git does not track
    but does not ignore."""
    lines, file = {}, None
    for line in git(root, "diff", "--no-renames", "--relative", "--no-color", "-U0", commit, "--", "*.mbt").splitlines():
        if line.startswith("+++ "):
            file = None if line[4:] == "/dev/null" else line[6:]
        elif line.startswith("@@") and file is not None:
            match = HUNK.match(line)
            start, count = int(match.group(1)), int(match.group(2) or 1)
            lines.setdefault(file, set()).update(range(start, start + count))
    for file in git(root, "ls-files", "--others", "--exclude-standard", "--", "*.mbt").splitlines():
        count = len((root / file).read_text(encoding="utf-8").split("\n"))
        lines[file] = set(range(1, count + 1))
    return {f: sorted(n) for f, n in sorted(lines.items()) if n}


def members(root):
    """The directories of the workspace's modules."""
    work = root / "moon.work"
    if not work.is_file():
        return {root.resolve()}
    listed = MEMBERS.search(work.read_text(encoding="utf-8"))
    return {(root / m).resolve() for m in re.findall(r'"([^"]+)"', listed.group(1) if listed else "")}


def targets(value):
    """The targets a supported-targets value names: a list, or an
    expression such as "native" or "-all+native"."""
    if value.startswith("["):
        return set(json.loads(re.sub(r",(\s*\])", r"\1", value)))
    tokens = TARGET.findall(value)
    result = set(TARGETS) if tokens and tokens[0][0] == "-" else set()
    for sign, name in tokens:
        names = TARGETS if name == "all" else {name}
        result = result - names if sign == "-" else result | names
    return result


def is_pure(root, directory, modules):
    """Whether a directory of root is a pure package: its tests build on
    wasm-gc, in a module of the workspace."""
    path = (root / directory).resolve()
    settings = [path / name for name in ("moon.pkg", "moon.pkg.json") if (path / name).is_file()]
    if not settings:
        return False
    module = path
    while not any((module / name).is_file() for name in ("moon.mod", "moon.mod.json")):
        if module == root.resolve() or module == module.parent:
            return False
        module = module.parent
    if module not in modules:
        return False
    supported = SUPPORTED.search(settings[0].read_text(encoding="utf-8"))
    if supported is None:
        return True
    value = supported.group(1)
    return "wasm-gc" in targets(json.loads(value) if value.startswith('"') else value)


def source_lines(root, lines):
    """The changed lines that count: those of the non-test .mbt files of
    the pure packages that a generator did not write."""
    modules = members(root)
    kept = {}
    for file, numbers in lines.items():
        path = root / file
        directory = posixpath.dirname(file)
        if finder.is_test_file(Path(file)) or not path.is_file() or not is_pure(root, directory, modules):
            continue
        if finder.is_generated(path.read_text(encoding="utf-8")):
            continue
        kept[file] = numbers
    return kept


def find(root, base, given):
    """What the diff mode runs on: the base as named, the merge base, and
    the changed lines that count, of the packages given or of all."""
    name, commit = merge_base(root, base)
    lines = source_lines(root, changed_lines(root, commit))
    if given:
        lines = {f: n for f, n in lines.items() if posixpath.dirname(f) in given}
    return {"base": name, "merge_base": commit, "lines": lines}


def on_lines(chosen, directories, lines):
    """The chosen mutants of each package whose original text holds a
    changed line."""

    def holds(site):
        first = site["line"]
        last = first + site["original"].count("\n")
        return any(first <= n <= last for n in lines.get(site["file"], ()))

    return {d: [s for s in chosen[d] if holds(s)] for d in directories}


def directories(lines):
    """The package directories of the changed files, sorted."""
    return sorted({posixpath.dirname(f) for f in lines})


def header(info, chosen_set, ran, sharded=False):
    """The diff mode's lines at the top of the report: the base, the lines
    and how many mutants ran of those on them, in the run or, sharded, in
    the shard (None for a run that runs none, as --sites-only)."""
    out = ["# Mutants on changed lines", ""]
    where = f"Against `{info['base']}`, merge base `{info['merge_base'][:12]}`"
    count = sum(len(n) for n in info["lines"].values())
    if not count:
        return out + [f"{where}: no non-test line of a pure package changed, so no mutant ran.", ""]
    packages = ", ".join(directories(info["lines"]))
    noun = "line" if count == 1 else "lines"
    total = info["mutants"]
    if not total:
        ran_text = f"No mutant of the {chosen_set} set is on them, so none ran."
    elif ran is None:
        ran_text = f"{total} mutants of the {chosen_set} set are on them."
    elif ran == total:
        ran_text = f"The run ran the {total} mutants of the {chosen_set} set on them." if total > 1 else \
            f"The run ran the one mutant of the {chosen_set} set on them."
    else:
        ran_text = f"{'This shard' if sharded else 'The run'} ran {ran} of the {total} mutants of the" \
            f" {chosen_set} set on them."
    return out + [f"{where}: {count} changed non-test {noun} in the pure packages ({packages}). {ran_text}", ""]
