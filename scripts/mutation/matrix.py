#!/usr/bin/env python3
"""The kill matrix of the mutation runner: for each mutant, every test that
kills it (CONTRIBUTING.md, "Mutation runner", "The kill matrix").

In kill-matrix mode (`run.py --matrix`), each mutant of a package runs
against the tests of the package and of all its importers that build on
wasm-gc (importers.py) in one run, whichever would kill it first, with no
early stop: not the package's own tests first and its importers' tests
only for the survivors, as a run without the mode goes. Each kill is
confirmed test by test (confirm.py), so a test is credited with it only if
it fails again with the mutant on and passes with it off. Each record then
lists every test that kills its mutant, with the test's package and layer.
"""

import re
import subprocess

import compare

BACKEND = "wasm-gc"
# How long moon may take to list the tests it would run: it builds nothing,
# so this only stops one that hangs.
OUTLINE_LIMIT_S = 600
# One test in moon's outline: its number, its package, its file and line,
# its index in the file, and its name, if it has one, with each `\` and `"`
# escaped by a `\`.
OUTLINE = re.compile(r'^\s*\d+\. (\S+) (\S+):(\d+) index=(\d+)(?: name="(.*)")?$')
# The layers of tests, from the lowest: in-process tests of a package's
# public interface, and e2e tests, which run the binary over real sockets
# (CONTRIBUTING.md, "What makes a good test"). Removal rule (A) counts only
# the kills of tests in the same layer as the test removed or a lower one.
LAYERS = ("in-process", "e2e")
# The last part of the name of the package whose tests are e2e tests.
E2E = "e2e"


def layer(package):
    """The layer of a package's tests."""
    return "e2e" if package.rsplit("/", 1)[-1] == E2E else "in-process"


def unescaped(text):
    """A test's name as moon's outline prints it, without the outline's
    escapes: as moon's failures name the test, and as its file writes it
    between the quotes."""
    out, i = [], 0
    while i < len(text):
        if text[i] == "\\" and text[i + 1 : i + 2] in ("\\", '"'):
            out.append(text[i + 1])
            i += 2
        elif text[i] in '\\"':
            raise ValueError(f"an escape moon's outline does not write: {text}")
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def outline(worker, packages, error):
    """Every test that moon runs for packages in a worker's tree, in moon's
    order, each with its package, file, line, index, name and layer."""
    selected = [option for name in packages for option in ("-p", name)]
    command = [*worker.moon, "test", "--target", BACKEND, *selected, "--target-dir", str(worker.target),
               "--outline"]
    try:
        result = subprocess.run(command, cwd=worker.tree, capture_output=True, text=True, timeout=OUTLINE_LIMIT_S)
    except subprocess.TimeoutExpired as problem:
        raise error(f"moon took over {OUTLINE_LIMIT_S} s to list the tests of {', '.join(packages)}") from problem
    if result.returncode != 0:
        raise error(f"moon cannot list the tests of {', '.join(packages)}:\n{result.stdout}{result.stderr}")
    tests = []
    for line in result.stdout.splitlines():
        match = OUTLINE.match(line)
        if not match:
            continue
        package, file, number, index, name = match.groups()
        try:
            name = unescaped(name or "")
        except ValueError as problem:
            raise error(f"cannot read moon's outline of {package}: {problem}") from problem
        tests.append({"package": package, "file": file, "line": int(number), "index": int(index), "name": name,
                      "layer": layer(package)})
    return tests


def key(test):
    """A test as both moon's outline and its failures name it."""
    return test["package"], test["file"], test["index"], test["name"]


def run_package(workers, package, directory, found, native_only, sites, mutants, log, run_tests, counts, error):
    """Runs the chosen mutants of one package against the tests of the
    package and of its importers that build on wasm-gc (found) at once:
    its records, each listing every test that kills its mutant, and its
    summary's counts. run_tests, counts and error are the runner's."""
    everyone = [package, *found]
    tests = outline(workers[0], everyone, error)
    records, baseline, limit, self_test = run_tests(
        workers, f"the tests of {package} and its importers ({', '.join(found) or 'none'})", everyone, mutants, log,
        f"{package}: {len(sites)} sites, a kill matrix with the tests of {', '.join(everyone)}", own=directory,
        with_self_test=bool(mutants))
    if baseline["tests"] != len(tests):
        raise error(f"moon lists {len(tests)} tests of {', '.join(everyone)}, but ran {baseline['tests']}")
    place = {key(t): n for n, t in enumerate(tests)}
    for record in records:
        # The run tested every package's tests; the record is the package's.
        record["package"] = package
        tested = record["outcome"] in ("killed", "timed out", "survived", "unconfirmed")
        record["importers"] = list(found) if tested else []
        for test in record["killing_tests"]:
            if key(test) not in place:
                raise error(f"{record['id']}: {test} killed it, but moon does not list it")
            test["layer"] = layer(test["package"])
        record["killing_tests"].sort(key=lambda t: place[key(t)])
    summary = {
        "backend": BACKEND,
        "baseline": baseline,
        "limit_s": round(limit, 3),
        **counts(records),
        **compare.counts(records),
        "matrix": {"packages": everyone, "native_only": list(native_only), "tests": tests},
        **({"self_test": self_test} if self_test is not None else {}),
    }
    return records, summary
