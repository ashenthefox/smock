#!/usr/bin/env python3
"""Checks that no e2e test file uses what another test file defines, so
that removing a test file breaks no other (CONTRIBUTING.md, "Build and
test"). What several files share lives in the harness files, the files of
the package whose names end in harness_test.mbt.

usage: python3 scripts/check-e2e-helpers.py [<package>]

Run it from the module's root. <package> is the package's directory, e2e
unless it is given.

The compiler decides, not the text. The check runs `moon check` on the
package, which must pass, and takes from `moon check --dry-run` the moonc
command that checks the package's black-box test files. It then runs that
command, with its output in a temporary directory, on the harness files
alone, and on the harness files with each test file in turn. A use of
what another test file defines is then an error, at the line that uses it.

For each such error it prints <file>:<line>: uses <name>, which <file>
defines, once for each name a file uses, at its first use. The name is a
function, a value, a constant, a type, an enum's constructor, an error
type, a method (Type::method), a trait's implementation (impl Trait for
Type), or a struct that a record literal builds. It finds the file that
defines it by moon fmt's layout: a top-level item starts at column 0.
Any other error, such as one that follows from an unknown name, is
printed with the compiler's message. Then it prints a count. It exits
with 1 when a file uses what a test file defines, and with 2 when the
package does not check as a whole, has no harness file or no test file,
or the command cannot be taken from moon's dry run.

It needs python3, and moon and moonc on PATH. The moonc command names the
toolchain's libraries by $MOON_HOME, which is ~/.moon unless MOON_HOME is
set. scripts/test-check-e2e-helpers.sh tests it.
"""
import os
import re
import shlex
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ME = "check-e2e-helpers"

# A top-level item, as moon fmt writes it, and what it defines.
VISIBILITY = r"(?:pub(?:\([a-z]+\))? |priv )?"
TYPE_PARAMS = r"(?:\[[^\]]*\])?"
METHOD = re.compile(
    rf"^{VISIBILITY}(?:async )?fn{TYPE_PARAMS} ([A-Z]\w*)::([a-z_]\w*)"
)
FUNCTION = re.compile(rf"^{VISIBILITY}(?:async )?fn{TYPE_PARAMS} ([a-z_]\w*)")
VALUE = re.compile(rf"^{VISIBILITY}(?:let|const) ([A-Za-z_]\w*)")
TYPE = re.compile(
    rf"^{VISIBILITY}(struct|enum|type|suberror|trait|typealias) ([A-Z]\w*)"
)
IMPL = re.compile(
    rf"^impl{TYPE_PARAMS} ([A-Z]\w*)(?:\[[^\]]*\])? for ([A-Z]\w*)"
    r"(?:\[[^\]]*\])?(?: with ([a-z_]\w*))?"
)
CONSTRUCTOR = re.compile(r"^  ([A-Z]\w*)\b")
FIELD = re.compile(r"^  (?:mut )?([a-z_]\w*) ?:")

# The compiler's messages that name what a file uses.
DIAGNOSTIC = re.compile(r"^(\S+?):(\d+):\d+-\S+ \[(E\d+)\] (.*)$")
UNBOUND = re.compile(r"^The value identifier (\w+) is unbound")
NO_TYPE = re.compile(r"^The type(?:/trait)? (\w+) is (?:undefined|not found)")
NO_METHOD = re.compile(r"^Type (\w+) has no method (\w+)")
NO_IMPL = re.compile(r"^Type (\w+) does not implement trait (\w+)")
NO_RECORD = re.compile(r"^There is no record definition with the fields: (.*)\.$")


def stop(message):
    print(f"{ME}: {message}")
    sys.exit(2)


def plural(count, one, many):
    return one if count == 1 else many


class Definitions:
    """What the test files define at the top level, by kind."""

    def __init__(self):
        self.values = {}
        self.types = {}
        self.methods = {}
        self.impls = {}
        self.structs = []

    def read(self, path):
        kind = None
        for line in open(path, encoding="utf-8").read().split("\n"):
            if line and not line[0].isspace() and not line.startswith(("//", "#")):
                kind = None
                m = METHOD.match(line)
                if m:
                    self.methods.setdefault((m.group(1), m.group(2)), path)
                    continue
                m = FUNCTION.match(line) or VALUE.match(line)
                if m:
                    self.values.setdefault(m.group(1), path)
                    continue
                m = TYPE.match(line)
                if m:
                    kind = m.group(1)
                    self.types.setdefault(m.group(2), path)
                    if kind == "suberror":
                        self.values.setdefault(m.group(2), path)
                    elif kind == "struct":
                        self.structs.append((m.group(2), set(), path))
                    continue
                m = IMPL.match(line)
                if m:
                    self.impls.setdefault((m.group(1), m.group(2)), path)
                    if m.group(3):
                        self.methods.setdefault((m.group(2), m.group(3)), path)
                continue
            if kind == "enum":
                m = CONSTRUCTOR.match(line)
                if m:
                    self.values.setdefault(m.group(1), path)
            elif kind == "struct":
                m = FIELD.match(line)
                if m:
                    self.structs[-1][1].add(m.group(1))

    def definer(self, message):
        """The name that a compiler's message says is unknown, and the file
        that defines it, or None."""
        m = UNBOUND.match(message)
        if m and m.group(1) in self.values:
            return m.group(1), self.values[m.group(1)]
        m = NO_TYPE.match(message)
        if m and m.group(1) in self.types:
            return m.group(1), self.types[m.group(1)]
        m = NO_METHOD.match(message)
        if m and (m.group(1), m.group(2)) in self.methods:
            name = f"{m.group(1)}::{m.group(2)}"
            return name, self.methods[(m.group(1), m.group(2))]
        m = NO_IMPL.match(message)
        if m and (m.group(2), m.group(1)) in self.impls:
            name = f"impl {m.group(2)} for {m.group(1)}"
            return name, self.impls[(m.group(2), m.group(1))]
        m = NO_RECORD.match(message)
        if m:
            wanted = {f.strip() for f in m.group(1).split(",")}
            for name, fields, path in self.structs:
                if wanted <= fields:
                    return name, path
        return None


def run(command):
    return subprocess.run(command, capture_output=True, text=True)


def moonc_command(package):
    """The moonc command that checks the package's black-box test files,
    from moon's dry run, without its files, and the files it names."""
    dry = run(["moon", "check", "--target", "native", "--no-mbti", "--dry-run", package])
    if dry.returncode != 0:
        print(dry.stdout + dry.stderr, end="")
        stop("moon check --dry-run failed")
    home = os.environ.get("MOON_HOME") or os.path.expanduser("~/.moon")
    found = []
    for line in dry.stdout.split("\n"):
        words = shlex.split(line) if line.startswith("moonc check ") else []
        if "-blackbox-test" in words and "-pkg-sources" in words:
            sources = words[words.index("-pkg-sources") + 1]
            if sources.endswith(f":./{package}"):
                found.append([w.replace("$MOON_HOME", home) for w in words])
    if len(found) != 1:
        stop(f"moon's dry run gives {len(found)} commands that check the "
             f"black-box tests of {package}, not one")
    words = found[0]
    if "-o" not in words:
        stop("the command that moon's dry run gives writes no output")
    files = [w for w in words if w.endswith(".mbt")]
    command = [w for w in words if not w.endswith(".mbt")]
    return command, files


def errors(output):
    """The errors of a moonc run, as (file, line, message), warnings left
    out."""
    out = []
    for line in output.split("\n"):
        m = DIAGNOSTIC.match(line)
        if m and not m.group(4).startswith("Warning"):
            out.append((os.path.normpath(m.group(1)), int(m.group(2)), m.group(4)))
    return out


def main():
    if len(sys.argv) > 2:
        stop("usage: python3 scripts/check-e2e-helpers.py [<package>]")
    package = os.path.normpath(sys.argv[1] if len(sys.argv) > 1 else "e2e")
    if not os.path.isdir(package):
        stop(f"{package} is not a directory")
    names = sorted(n for n in os.listdir(package) if n.endswith("_test.mbt"))
    harness = [f"{package}/{n}" for n in names if n.endswith("harness_test.mbt")]
    tests = [f"{package}/{n}" for n in names if not n.endswith("harness_test.mbt")]
    if not harness:
        stop(f"{package} has no harness file (a name that ends in harness_test.mbt)")
    if not tests:
        stop(f"{package} has no test file besides the harness files")

    whole = run(["moon", "check", "--target", "native", "--no-mbti", package])
    if whole.returncode != 0:
        print(whole.stdout + whole.stderr, end="")
        stop(f"{package} does not check as a whole")
    command, listed = moonc_command(package)
    if sorted(os.path.normpath(f) for f in listed) != sorted(harness + tests):
        stop("the command that moon's dry run gives does not name the "
             f"test files of {package}")

    with tempfile.TemporaryDirectory() as scratch:

        def check(job):
            n, files = job
            argv = list(command)
            argv[argv.index("-o") + 1] = os.path.join(scratch, f"{n}.mi")
            argv[2:2] = [f"./{f}" for f in files]
            done = run(argv)
            return done.returncode, errors(done.stdout + done.stderr)

        jobs = [(0, harness + tests), (1, harness)]
        jobs += [(n + 2, harness + [t]) for n, t in enumerate(tests)]
        with ThreadPoolExecutor(max(1, min(8, os.cpu_count() or 1))) as pool:
            results = list(pool.map(check, jobs))

    status, problems = results[0]
    if status != 0:
        for path, line, message in problems:
            print(f"{path}:{line}: {message}")
        stop("the command that moon's dry run gives does not check "
             f"{package} as a whole")

    definitions = Definitions()
    for test in tests:
        definitions.read(test)
    harness_status, harness_errors = results[1]
    harness_failed = harness_status != 0

    def report(own):
        seen = set()
        for path, line, message in sorted(own, key=lambda e: (e[0], e[1])):
            found = definitions.definer(message)
            if found:
                if found[0] in seen:
                    continue
                seen.add(found[0])
                print(f"{path}:{line}: uses {found[0]}, which {found[1]} defines")
            else:
                print(f"{path}:{line}: {message}")

    if harness_failed:
        report(harness_errors)
    failing = 0
    for test, (status, problems) in zip(tests, results[2:]):
        own = [e for e in problems if e[0] == test]
        if status != 0 and own:
            failing += 1
            report(own)

    if harness_failed:
        print(f"{ME}: {package}: the {len(harness)} "
              f"{plural(len(harness), 'harness file uses', 'harness files use')} "
              "what a test file defines")
    if failing:
        print(f"{ME}: {package}: {failing} of {len(tests)} test files "
              f"{plural(failing, 'uses', 'use')} what another test file defines")
    if harness_failed or failing:
        sys.exit(1)
    print(f"{ME}: {package}: each of the {len(tests)} test files checks with "
          f"the {len(harness)} {plural(len(harness), 'harness file', 'harness files')} alone")


if __name__ == "__main__":
    main()
