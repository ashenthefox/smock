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

import json
import re
import shutil
import subprocess

import compare

BACKEND = "wasm-gc"
# The version of the format of a matrix's file.
VERSION = 1
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


def test_id(test):
    """A test's name in the matrix: its package, `/`, its file, then `:`
    and its name, or, for a test that has none, `#` and its index in the
    file. A name stays when other tests of its file come or go; an index
    may not, but moon tells a test with no name apart by nothing else."""
    where = f"{test['package']}/{test['file']}"
    return f"{where}:{test['name']}" if test["name"] else f"{where}#{test['index']}"


def entries(records):
    """The mutants of a package's matrix, from its records: each one's id,
    outcome and killing tests, and the mutant it compiles as, for a
    duplicate."""
    found = []
    for record in records:
        entry = {"id": record["id"], "outcome": record["outcome"],
                 "killing_tests": [test_id(t) for t in record["killing_tests"]]}
        if record["outcome"] == "duplicate":
            entry["duplicate_of"] = record["duplicate_of"]
        found.append(entry)
    return found


def alone(mutants):
    """The tests that alone kill some of a matrix's mutants, each with
    those mutants' ids, in the order of the mutants. A duplicate counts as
    the mutant it compiles as."""
    found = {}
    for mutant in resolved(mutants):
        if mutant["outcome"] == "killed" and len(mutant["killing_tests"]) == 1:
            found.setdefault(mutant["killing_tests"][0], []).append(mutant["id"])
    return found


def resolved(mutants):
    """A matrix's mutants, each duplicate with the outcome and the killing
    tests of the mutant it compiles as, when the matrix holds that one."""
    by_id = {m["id"]: m for m in mutants}
    out = []
    for mutant in mutants:
        first = by_id.get(mutant.get("duplicate_of"))
        out.append(dict(mutant, outcome=first["outcome"], killing_tests=first["killing_tests"]) if first else mutant)
    return out


def counts(found, records):
    """What a package's summary says of its matrix: the packages whose
    tests ran and those that build only natively, every test that ran, and
    how many of them kill some mutant, how many alone kill one, and how
    many mutants each package's tests kill."""
    mutants = entries(records)
    killed = [r for r in records if r["outcome"] == "killed"]
    by = {}
    for record in killed:
        for package in {t["package"] for t in record["killing_tests"]}:
            by[package] = by.get(package, 0) + 1
    return {
        "packages": list(found["packages"]),
        "native_only": list(found["native_only"]),
        "tests": list(found["tests"]),
        "killing": len({t for m in mutants if m["outcome"] == "killed" for t in m["killing_tests"]}),
        "alone": len(alone(mutants)),
        "killed_by": dict(sorted(by.items())),
    }


def report_lines(summary):
    """The lines of the report that give a package's kill matrix: the tests
    that ran, how many of them kill some mutant and alone kill one, and
    how many mutants each package's tests kill."""
    found = summary.get("matrix")
    if found is None:
        return []
    packages = found["packages"]
    listed = packages[0] if len(packages) == 1 else ", ".join(packages[:-1]) + f" and {packages[-1]}"
    out = [f"Kill matrix: each mutant ran against the {len(found['tests'])} tests of {listed} at once, with no early"
           " stop.",
           f"- {found['killing']} of these tests kill some mutant, and {found['alone']} of them alone kill some"
           " mutant."]
    if found["killed_by"]:
        out += ["- Mutants killed by the tests of each package: "
                + ", ".join(f"{name} {n}" for name, n in found["killed_by"].items()) + "."]
    if found["native_only"]:
        out += ["- Importers that build only natively, whose tests did not run: "
                + ", ".join(found["native_only"]) + "."]
    return out + [""]


def write(out, operator_set, chosen, summaries, records):
    """Writes the kill matrix of each package that ran in kill-matrix mode
    into out/matrix/<package directory>.json, after removing what an
    earlier run wrote there."""
    folder = out / "matrix"
    shutil.rmtree(folder, ignore_errors=True)
    for summary in summaries:
        found = summary.get("matrix")
        if found is None:
            continue
        matrix = {
            "version": VERSION,
            "package": summary["package"],
            "directory": summary["directory"],
            "operator_set": operator_set,
            "set": chosen,
            "backend": summary["backend"],
            "packages": found["packages"],
            "native_only": found["native_only"],
            "tests": [dict(test=test_id(t), **t) for t in found["tests"]],
            "mutants": entries([r for r in records if r["package"] == summary["package"]]),
        }
        path = folder / f"{summary['directory']}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(dumps(matrix), encoding="utf-8")


def dumps(matrix):
    """A matrix as JSON, with one test and one mutant on each line."""
    lines = []
    for name, value in matrix.items():
        if name in ("tests", "mutants") and value:
            items = ",\n".join(f"    {json.dumps(v, ensure_ascii=False)}" for v in value)
            lines.append(f"  {json.dumps(name)}: [\n{items}\n  ]")
        else:
            lines.append(f"  {json.dumps(name)}: {json.dumps(value, ensure_ascii=False)}")
    return "{\n" + ",\n".join(lines) + "\n}\n"


def run_package(workers, package, directory, found, native_only, sites, mutants, log, run_tests, outcome_counts,
                error):
    """Runs the chosen mutants of one package against the tests of the
    package and of its importers that build on wasm-gc (found) at once:
    its records, each listing every test that kills its mutant, and its
    summary's counts. run_tests, outcome_counts and error are the
    runner's."""
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
        **outcome_counts(records),
        **compare.counts(records),
        "matrix": counts({"packages": everyone, "native_only": native_only, "tests": tests}, records),
        **({"self_test": self_test} if self_test is not None else {}),
    }
    return records, summary
