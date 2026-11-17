"""The forced-fail self-test of the mutation runner (CONTRIBUTING.md,
"Mutation runner", "The self-test"). Before any mutant of a package, the
runner (run.py) switches on a mutant that the package's tests must see,
and the run fails if that mutant survives, times out or does not build: a
runner that applies no mutant, builds in the wrong place, runs a stale
binary, ignores a failed test or breaks every build would otherwise
report its mutants as survived or unviable, and so reach a "zero" that
says nothing.

The mutant is chosen by a rule, from the package's source alone, never
from a run's outcome: `abort("mutation self-test")` is put at the start of
the body of every top-level function and method of the package's non-test
source whose body is MoonBit, so that any test that calls one of them
fails. Foreign functions (whose body is not MoonBit), init and main
blocks, test blocks, test files and generated files are left as they are.
The functions are found in the parse tree that the site finder reads
(sites.py), so the rule holds whatever the finder prints.
"""

import tempfile
from pathlib import Path

import sites

# What the mutant puts at the start of each body.
STATEMENT = 'abort("mutation self-test")'


def body_starts(source, tree_text):
    """The functions and methods of one file that the self-test changes, as
    (offset just after the opening brace of the body, definition's name),
    in the order of the file."""
    starts = []
    for entry in sites.parse_tree(tree_text):
        if not (isinstance(entry, list) and len(entry) == 3 and entry[0] == "base_pos"):
            raise sites.FinderError(f"{source.path}: unexpected entry in the parse tree: {str(entry)[:80]}")
        item = sites.Item(source, entry[1], entry[2])
        if item.is_test():
            continue
        parts = item.function()
        if parts is None or sites.head_of(parts[0]) != "Decl_body":
            continue
        # The body's brace is the first one after the last position of the
        # elements before the body, as for BODY's sites.
        header = parts[2]
        ends = [item.loc(a)[1] for n in sites.walk(header) for a in n if item.loc(a)]
        brace = source.offset(*max(ends))
        while brace < len(source.text) and source.text[brace] in " \t\r\n":
            brace += 1
        if source.text[brace : brace + 1] != "{":
            raise sites.FinderError(f"{source.path}: cannot find the body of {item.name()}")
        starts.append((brace + 1, item.name()))
    return starts


def mutant(tree, directory, moonc="moonc", target="wasm-gc"):
    """The self-test's mutant of the package in tree/directory: a list of
    (file relative to tree, its text, its mutated text), one for each file
    it changes, and the definitions it changes, as "<file>,<name>"."""
    tree = Path(tree)
    changes, definitions = [], []
    texts = {}
    for path in sites.source_files(tree, [directory]):
        text = (tree / path).read_text(encoding="utf-8")
        if not sites.is_generated(text):
            texts[path] = text
    with tempfile.TemporaryDirectory(prefix="smock-selftest-") as tmp:
        for index, (path, text) in enumerate(texts.items()):
            tree_text = sites.dump(moonc, target, Path(tmp), index, path, text)
            starts = body_starts(sites.SourceFile(path, text), tree_text)
            if not starts:
                continue
            mutated = text
            for offset, _ in reversed(starts):
                mutated = mutated[:offset] + f"\n  {STATEMENT}\n" + mutated[offset:]
            changes.append((path.as_posix(), text, mutated))
            definitions += [f"{path.as_posix()},{name}" for _, name in starts]
    return changes, definitions


def run(worker, package, directory, limit, failures):
    """Switches the self-test's mutant on in the worker's tree, builds and
    runs the package's tests there, and switches it off again: its
    record, with the outcome as a mutant's (killed, timed out, unviable or
    survived), or "no function" when the package has none to change.
    failures reads the failed tests from the run's output."""
    changes, definitions = mutant(worker.tree, directory)
    record = {"definitions": definitions, "files": [path for path, _, _ in changes]}
    if not changes:
        record.update(outcome="no function")
        return record
    try:
        for path, _, mutated in changes:
            (worker.tree / path).write_text(mutated, encoding="utf-8")
        status, output, build_s = worker.build(package)
        timings = {"build_s": round(build_s, 3), "run_s": 0.0, "limit_s": round(limit, 3)}
        if status != 0:
            record.update(outcome="unviable", timings=timings, message=output[-2000:])
        else:
            status, output, run_s, timed_out = worker.moon_test(package, limit, build_only=False)
            timings["run_s"] = round(run_s, 3)
            if timed_out:
                record.update(outcome="timed out", timings=timings)
            elif status == 0:
                record.update(outcome="survived", timings=timings)
            else:
                record.update(outcome="killed", failed_tests=len(failures(output)), timings=timings)
    finally:
        for path, text, _ in changes:
            (worker.tree / path).write_text(text, encoding="utf-8")
    return record


def failure(package, record):
    """Why a self-test's record fails the run, or None when it passes: only
    a mutant that a test killed passes."""
    outcome = record["outcome"]
    if outcome == "killed":
        return None
    what = f"the self-test of {package} {outcome}"
    if outcome == "no function":
        what = f"the self-test of {package} found no function to put {STATEMENT} in"
    elif outcome == "survived":
        what += (f": no test saw {STATEMENT} at the start of {len(record['definitions'])} functions,"
                 " so the run could not see any mutant")
    elif outcome == "unviable":
        what = (f"the self-test of {package} does not build, so no mutant could:\n{record.get('message', '')}")
    elif outcome == "timed out":
        what += f": its tests ran past {record['timings']['limit_s']:.2f} s"
    return what


def report_line(record):
    """The report's line on a self-test that passed. Natively, the abort
    stops the test program, so moon names no failed test."""
    killed = (f"killed by {record['failed_tests']} tests" if record["failed_tests"] else
              "killed: the test program stopped before it named a failed test, as an abort stops it natively")
    return f"Self-test: `{STATEMENT}` at the start of {len(record['definitions'])} functions, {killed}."
