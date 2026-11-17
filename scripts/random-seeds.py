#!/usr/bin/env python3
"""Writes a random seed into each property's seed constant, in the working
copy it runs in, and prints each seed (CONTRIBUTING.md, "Seeds").

usage: python3 scripts/random-seeds.py [<path>...]

Each property runs with a fixed seed, committed beside it as a constant of
its test file. The weekly run of the properties with random seeds runs this
script in a working copy that it then throws away, and runs the tests:
a failure there is rerun by setting the constant to the seed printed for it.
Run it only in such a copy: it rewrites the files in place.

<path> is a test file or a directory: the current directory unless one is
given. In a directory, it reads every test file (a name that ends in
_test.mbt or _wbtest.mbt), outside the directories named _build, target,
.mooncakes and .git, in the order of their paths.

A seed constant is a line of the form

    const <NAME>_SEED : UInt64 = <digits>

at the start of a line of a test file, with nothing after the digits. As
the mutation runner applies a mutant, the script finds each constant's value
where that form puts it, replaces those digits with a random seed from 0 to
2^64 - 1, and leaves every other character of the file as it was. It prints
one line for each constant, in the order of their files and lines:

    <file>:<line>: <NAME>_SEED = <seed>

It exits with 0 when it wrote a seed, with 1 when it found no seed constant,
and with 2, writing nothing, when a path does not exist or a line of a test
file declares a constant or a let whose name ends in _SEED in another form,
or with a value larger than a UInt64 holds: that property would otherwise
keep its fixed seed in the weekly run, unnoticed.
"""

import os
import re
import secrets
import sys

# A seed constant, as the properties write it.
SEED = re.compile(r"const ([A-Z][A-Z0-9_]*_SEED) : UInt64 = ([0-9]+)")

# Any line that declares a constant or a let whose name ends in _SEED.
DECLARES = re.compile(r"\s*(?:pub(?:\([a-z]+\))?\s+|priv\s+)?(?:const|let)\s+[A-Za-z0-9_]*_SEED\b")

# The directories that hold no source.
SKIPPED = {"_build", "target", ".mooncakes", ".git"}

UINT64_MAX = 2**64 - 1


class SeedError(Exception):
    """A path or a line that the script cannot handle."""


def is_test_file(name):
    """Whether the file named so holds tests."""
    return name.endswith("_test.mbt") or name.endswith("_wbtest.mbt")


def test_files(path):
    """The test files of a path: the file itself, or those of a directory."""
    if os.path.isfile(path):
        return [path]
    if not os.path.isdir(path):
        raise SeedError(f"{path} does not exist")
    found = []
    for directory, subdirectories, names in os.walk(path):
        subdirectories[:] = [d for d in subdirectories if d not in SKIPPED]
        found += [os.path.normpath(os.path.join(directory, n)) for n in names if is_test_file(n)]
    return sorted(found)


def seed_lines(name, text):
    """The (index, name of the constant, start and end of its value) of each
    seed constant among the lines of a file's text."""
    found = []
    for index, line in enumerate(text.split("\n")):
        content = line[:-1] if line.endswith("\r") else line
        if not DECLARES.match(content):
            continue
        match = SEED.fullmatch(content)
        if not match:
            raise SeedError(f"{name}:{index + 1}: a seed constant is written"
                            f" 'const <NAME>_SEED : UInt64 = <digits>', alone on its line: {content}")
        if int(match.group(2)) > UINT64_MAX:
            raise SeedError(f"{name}:{index + 1}: {match.group(1)}'s value is larger than a UInt64 holds")
        found.append((index, match.group(1), match.start(2), match.end(2)))
    return found


def main(arguments):
    paths = arguments or ["."]
    try:
        files = [f for p in paths for f in test_files(p)]
        plans = []
        for name in files:
            with open(name, encoding="utf-8", newline="") as file:
                text = file.read()
            constants = seed_lines(name, text)
            if constants:
                plans.append((name, text, constants))
    except SeedError as error:
        print(f"random-seeds: {error}", file=sys.stderr)
        return 2
    if not plans:
        print(f"random-seeds: no seed constant in {' '.join(paths)}", file=sys.stderr)
        return 1
    for name, text, constants in plans:
        lines = text.split("\n")
        for index, constant, start, end in constants:
            seed = secrets.randbits(64)
            line = lines[index]
            lines[index] = line[:start] + str(seed) + line[end:]
            print(f"{name}:{index + 1}: {constant} = {seed}")
        with open(name, "w", encoding="utf-8", newline="") as file:
            file.write("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
