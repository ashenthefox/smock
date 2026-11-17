"""Compares the compiler's output for each mutant of a package with the
output without a mutant, and with the other mutants' outputs, before any
test runs (CONTRIBUTING.md, "Mutation runner", "The compiler's output").

The output is the package linked as a program on wasm-gc, the backend of
the verdicts, by the pinned compiler with its optimisations on: `moonc
link-core` of the package's core IR, which `moon test --build-only` builds
for the package's tests, with the core IR of its dependencies, the
package's public functions and methods as the program's exports, and WAT,
the text form of WebAssembly, as the output. Identical output marks the
mutant equivalent, and output identical to an earlier mutant's marks it a
duplicate of that one: neither runs tests.

The output's code holds no source position, but its names do. The
compiler numbers its locals, labels and closures in the order it makes
them, and a closure's name holds the line of its definition. So every name
in the output is replaced, before the comparison, by a number in the order
of its first use: two outputs that then match differ in their names alone,
which makes the same program. Text that the program itself holds stays,
such as the file, line and column of a call to `fail`, which its message
gives. Mutants keep the lines of the source, so that such text changes
only on the mutant's own line.

The linker leaves out what the exports do not reach, inlines small
functions into their callers, and compiles a generic function once for
each type it is used with. So a mutant is compared only where both the
output without it and its own output hold a function of its own, by its
name, for the definition that holds the site: compiled once for every
caller, so that the same output means the same function for any argument.
A definition that the exports do not reach, such as an implementation of
a trait that no function of the package uses, would otherwise look
equivalent, and a function inlined into each of its callers could hide a
mutant behind the callers' arguments. Such a mutant, one in a generic
function, and one in a constant or another value, is not compared, and
runs its tests.
"""

import hashlib
import os
import re
import shlex
import subprocess
import threading
import time
from pathlib import Path

BACKEND = "wasm-gc"
# How long moon's plan and the link may take: a package's link takes a
# fraction of a second, so this only stops one that hangs.
LINK_LIMIT_S = 600
# A public function or method at the start of a line, where moon fmt puts
# each top-level definition: its name.
PUBLIC = re.compile(r"^pub(?:\([a-z]+\))? fn(?:\[[^\]\n]*\])? (?:[A-Za-z_][A-Za-z0-9_]*::)?([A-Za-z_][A-Za-z0-9_]*)",
                    re.MULTILINE)
# A string of WAT, which stays as it is, or a name, which is replaced.
TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|\$[0-9A-Za-z!#$%&\'*+\-./:<=>?@\\^_`|~]+')
FUNCTION = re.compile(r"^\(func (\$\S+)", re.MULTILINE)
IDENT = r"[A-Za-z_][A-Za-z0-9_]*"


def with_line_breaks(original, replacement):
    """The replacement, with as many line breaks as the original text it
    replaces: a deletion keeps the lines empty, a block keeps them before
    its closing brace, and any other expression keeps them inside
    parentheses."""
    missing = original.count("\n") - replacement.count("\n")
    if missing <= 0:
        return replacement
    if not replacement:
        return "\n" * missing
    if replacement.startswith("{") and replacement.endswith("}"):
        return replacement[:-1] + "\n" * missing + "}"
    return "(" + replacement + "\n" * missing + ")"


def mangled(name):
    """A name as the compiler's output spells it: its length, then the
    name with each `_` doubled and each character that is neither a letter
    nor a digit written as `_` and its code in hexadecimal."""
    text = "".join(c if c.isascii() and c.isalnum() else "__" if c == "_" else f"_{ord(c):x}" for c in name)
    return f"{len(text)}{text}"


def own_function(package, definition):
    """The pattern of the name of a definition's own function in the output,
    or None for a definition that has none: a constant, a value, an
    initialisation block, or an implementation for a type of another
    package. The output names a function by its package and its name, a
    method by its type too, and an implementation by its type, its trait
    and its method. A generic function's own functions are its instances,
    which no pattern here matches."""
    path = package.split("/")
    prefix = f"P{len(path)}" + "".join(mangled(p) for p in path)
    if re.fullmatch(IDENT, definition) and definition not in ("init", "main"):
        return re.escape(f"_M0F{prefix}{mangled(definition)}")
    if match := re.fullmatch(rf"({IDENT})::({IDENT})", definition):
        return re.escape(f"_M0M{prefix}{mangled(match[1])}{mangled(match[2])}")
    if match := re.fullmatch(rf"impl (?:@{IDENT}\.)?({IDENT})(?: for ({IDENT})(?:\[.*\])?)? with ({IDENT})", definition):
        trait, owner, method = match[1], match[2] or match[1], match[3]
        return (re.escape(f"_M0I{prefix}{mangled(owner)}") + "P[0-9A-Za-z_]*"
                + re.escape(f"{mangled(trait)}{mangled(method)}"))
    return None


def canonical(wat):
    """The output with each name replaced by its number, in the order of
    the names' first use."""
    names = {}

    def rename(match):
        token = match.group(0)
        if token.startswith('"'):
            return token
        return names.setdefault(token, f"${len(names)}")

    return TOKEN.sub(rename, wat)


class Comparison:
    """The compiler's output for one package without a mutant, and for each
    mutant compared so far, which the workers share."""

    def __init__(self, package, directory, workers, log):
        """Links the package without a mutant in each worker, whose tree and
        target directory hold the package's tests as the runner built them
        without a mutant."""
        self.package = package
        self.lock = threading.Lock()
        self.first = {}
        self.links = {}
        self.baseline = None
        self.functions = set()
        self.unavailable = None
        start = time.monotonic()
        try:
            exports = public_names(workers[0].tree / directory)
            for worker in workers:
                self.links[worker.number] = self.link_command(worker, exports)
            wat = self.link(workers[0])
        except ComparisonError as error:
            self.unavailable = str(error)
            log(f"  the compiler's output is not compared: {error}")
            return
        self.baseline = digest(wat)
        self.functions = set(FUNCTION.findall(wat))
        log(f"  the compiler's output without a mutant: {len(self.functions)} functions,"
            f" {len(exports)} exported names, {time.monotonic() - start:.2f} s")

    def link_command(self, worker, exports):
        """The command that links the package in a worker's tree: moon's own
        link of the package's internal tests, given the package's core IR
        in place of its tests', its public names as exports, and the
        compiler's optimisations."""
        command = [*worker.moon, "test", "--target", BACKEND, "-p", self.package, "--target-dir", str(worker.target),
                   "--build-only", "--dry-run"]
        plan = run(command, worker.tree)
        home = os.environ.get("MOON_HOME") or str(Path.home() / ".moon")
        name = self.package.rsplit("/", 1)[-1]
        for line in plan.stdout.splitlines():
            if not line.startswith("moonc link-core "):
                continue
            words = [w.replace("$MOON_HOME", home) for w in shlex.split(line)]
            inputs = words[2:words.index("-main")] if "-main" in words else []
            if not inputs or not inputs[-1].endswith(f"/{name}.internal_test.core"):
                continue
            inputs[-1] = inputs[-1].removesuffix(".internal_test.core") + ".core"
            sources = [w for before, w in zip(words, words[1:]) if before == "-pkg-sources"]
            output = worker.target / "compiler-output.wat"
            return (["moonc", "link-core", *inputs, "-main", self.package, "-exported_functions", ",".join(exports),
                     *[a for s in sources for a in ("-pkg-sources", s)], "-target", BACKEND, "-o", str(output)],
                    output)
        raise ComparisonError(f"moon's plan for the tests of {self.package} has no link of its internal tests")

    def link(self, worker):
        """The package's output in a worker's tree, as it is now."""
        command, output = self.links[worker.number]
        if output.exists():
            output.unlink()
        result = run(command, worker.tree)
        if result.returncode != 0 or not output.is_file():
            message = (result.stderr or result.stdout).strip().splitlines()
            raise ComparisonError(f"the link failed: {message[0] if message else result.returncode}")
        return output.read_text(encoding="utf-8")

    def judge(self, worker, site, record, timings):
        """Compares the output of the mutant that a worker built with the
        output without a mutant and with the earlier mutants' outputs. It
        records the result and its time, and, for an equivalent mutant or a
        duplicate, the outcome: then it returns True, and the mutant runs no
        tests."""
        start = time.monotonic()
        result = self.result(worker, site)
        timings["compare_s"] = round(time.monotonic() - start, 3)
        record["compiler_output"] = result
        if result["result"] == "identical":
            record["outcome"] = "equivalent"
        elif result["result"] == "duplicate":
            record.update(outcome="duplicate", duplicate_of=result.pop("first"))
        else:
            return False
        return True

    def result(self, worker, site):
        """What the comparison finds for a mutant."""
        if self.unavailable:
            return {"result": "not compared", "reason": self.unavailable}
        pattern = own_function(self.package, site["definition"])
        if pattern is None or not any(re.fullmatch(pattern, f[1:]) for f in self.functions):
            return {"result": "not compared",
                    "reason": f"the output has no function of its own for {site['definition']}"}
        try:
            wat = self.link(worker)
        except ComparisonError as error:
            return {"result": "not compared", "reason": str(error)}
        if not any(re.fullmatch(pattern, f[1:]) for f in FUNCTION.findall(wat)):
            return {"result": "not compared",
                    "reason": f"the mutant's output has no function of its own for {site['definition']}"}
        mine = digest(wat)
        with self.lock:
            if mine == self.baseline:
                return {"result": "identical", "digest": mine}
            if mine in self.first:
                return {"result": "duplicate", "digest": mine, "first": self.first[mine]}
            self.first[mine] = site["id"]
        return {"result": "differs", "digest": mine}


class ComparisonError(Exception):
    """What keeps the compiler's output from being compared."""


def run(command, cwd):
    """Runs a command of moon's or moonc's, and stops it after LINK_LIMIT_S."""
    try:
        return subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=LINK_LIMIT_S)
    except subprocess.TimeoutExpired as error:
        raise ComparisonError(f"{command[0]} took over {LINK_LIMIT_S} s") from error


def digest(wat):
    """The digest of an output, after its names are replaced."""
    return "sha256:" + hashlib.sha256(canonical(wat).encode("utf-8")).hexdigest()


def public_names(directory):
    """The names of the public functions and methods in a package's
    directory, outside its tests."""
    names = set()
    for path in sorted(directory.glob("*.mbt")):
        if not path.name.endswith(("_test.mbt", "_wbtest.mbt")):
            names.update(PUBLIC.findall(path.read_text(encoding="utf-8")))
    if not names:
        raise ComparisonError(f"{directory.name} has no public function")
    return sorted(names)


def counts(records):
    """The counts of a package's equivalent mutants, its duplicates, and the
    mutants that compiled but were not compared."""
    found = [r.get("compiler_output", {}).get("result") for r in records]
    return {"equivalent": found.count("identical"), "duplicate": found.count("duplicate"),
            "not_compared": found.count("not compared")}


def report(records):
    """The lines of the report that count a package's equivalent mutants
    and duplicates, and list them."""
    found = counts(records)
    compared = sum(1 for r in records if r.get("compiler_output", {}).get("result") not in (None, "not compared"))
    duplicates = "duplicate" if found["duplicate"] == 1 else "duplicates"
    mutants = "mutant" if compared == 1 else "mutants"
    out = [f"By the compiler's output: {found['equivalent']} equivalent and {found['duplicate']} {duplicates},"
           f" which ran no tests; {compared} {mutants} compared, {found['not_compared']} not compared.", ""]
    equivalent = [r for r in records if r["outcome"] == "equivalent"]
    if equivalent:
        out += [f"### Equivalent by the compiler's output ({len(equivalent)})", ""]
        out += [f"- `{r['id']}`" for r in equivalent] + [""]
    duplicate = [r for r in records if r["outcome"] == "duplicate"]
    if duplicate:
        outcomes = {r["id"]: r["outcome"] for r in records}
        out += [f"### Duplicates by the compiler's output ({len(duplicate)})", ""]
        out += [f"- `{r['id']}`, as `{r['duplicate_of']}` ({outcomes.get(r['duplicate_of'], 'not run')})"
                for r in duplicate] + [""]
    return out
