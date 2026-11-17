"""Tests of the mutation runner's kill-matrix mode (run.py --matrix) and of
the tool that reads the matrix (scripts/mutation/matrix.py), through their
command lines, on the fixture module scripts/mutation/fixture (#306).

In kill-matrix mode, each mutant runs against its own package's tests and
all its importers' tests at once, whatever kills it first, with no early
stop, and its record lists every test that kills it, with its package and
layer (#306, first criterion; #275, "Kill credit, pure packages": "Only
kill-matrix mode ... runs every covering test for every mutant"). Kill
confirmation applies to each test in the matrix: a test credited with a
kill fails with the mutant on and passes with it off (#306, second
criterion; #275, "Kill confirmation"). The tool answers which tests alone
kill some mutant, and which mutants a given set of tests kills (#306, third
criterion); with one test left out of a run, the mutants only it killed
are survivors (#306, fourth criterion).

The fixture's package units has the importers meter, and dial through
meter, whose tests build on wasm-gc, and probe, which builds only natively
(its comments, and test_mutation.py's ImportersTest). The matrix below is
worked out by hand from what each test checks and what each mutant of
units.mbt changes, as the comments beside units.mbt's sites give it.

They need python3, git, moon and moonc (the toolchain of
.moonbit-version).

usage: python3 -m unittest discover -s scripts/mutation -v
"""

import json
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "fixture"
RUN = HERE / "run.py"

# The tests of units and of its importers that build on wasm-gc, as moon
# names them: package, file, index in the file, name.
DIAL_HIGH = ("mutation/fixture/dial", "dial_test.mbt", 0, "a reading at the high end of a scale from 0 to 10 is on it")
METER_LOW = ("mutation/fixture/meter", "meter_test.mbt", 0, "a reading at the low end of the scale is on it")
INSIDE = ("mutation/fixture/units", "units_test.mbt", 0, "a number inside the range is in it")
BELOW = ("mutation/fixture/units", "units_test.mbt", 1, "a number below the range is not in it")
PAST = ("mutation/fixture/units", "units_test.mbt", 2, "a number beyond the end of a range is past it")

# units' kill matrix: each mutant of the pinned set, its outcome, and every
# test that kills it.
# - within's BODY `{ false }` fails every test that needs a number in a
#   range: 2 in 1 to 3 (units), 1 on a scale from 1 to 3 (meter), and 10 on
#   a scale from 0 to 10 (dial); 0 below 1 to 3 still is not in it.
# - `low < n` fails only meter's 1 on a scale from 1.
# - `||` fails only units' 0 below the range, which `0 <= 3` lets in.
# - `n < high` fails only dial's 10 on a scale to 10.
# - past's BODY `{ false }` fails only units' 5 past 3.
# - `n >= high` survives: only probe's test has a number at the end, and
#   probe builds only natively.
MATRIX = [
    ("units/units.mbt,within,BODY,{…},{ false },0", "killed", [DIAL_HIGH, METER_LOW, INSIDE]),
    ("units/units.mbt,within,ROR,<=,<,0", "killed", [METER_LOW]),
    ("units/units.mbt,within,LCR,&&,||,0", "killed", [BELOW]),
    ("units/units.mbt,within,ROR,<=,<,1", "killed", [DIAL_HIGH]),
    ("units/units.mbt,past,BODY,{…},{ false },0", "killed", [PAST]),
    ("units/units.mbt,past,ROR,>,>=,0", "survived", []),
]


def logging_moon(directory):
    """A moon that logs each of its command lines and runs the real one."""
    moon = shutil.which("moon")
    if moon is None:
        raise unittest.SkipTest("moon is not on PATH")
    script = directory / "moon"
    log = directory / "moon.log"
    script.write_text(f'#!/bin/sh\necho "$*" >>"{log}"\nexec "{moon}" "$@"\n')
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script, log


def run_runner(root, work, out, moon, *args):
    """Runs run.py on root, writing into out."""
    return subprocess.run([sys.executable, str(RUN), "--root", str(root), "--work", str(work), "--out", str(out),
                           "--moon", str(moon), *args], capture_output=True, text=True)


def read_lines(path):
    """The JSON objects of a file of JSON lines."""
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def fields(test):
    """A test's fields, as a record gives them, from the tuples above."""
    package, file, index, name = test
    return {"package": package, "file": file, "index": index, "name": name}


class KillMatrixTest(unittest.TestCase):
    """One kill-matrix run of units' pinned set, which the tests read."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-matrix-"))
        cls.moon, cls.log = logging_moon(cls.tmp)
        cls.out = cls.tmp / "out"
        cls.result = run_runner(FIXTURE, cls.tmp / "work", cls.out, cls.moon, "--matrix", "units")
        if cls.result.returncode != 0:
            raise AssertionError(f"run.py failed ({cls.result.returncode}):\n{cls.result.stderr}")
        cls.records = read_lines(cls.out / "mutants.jsonl")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_each_record_lists_every_test_that_kills_its_mutant_with_its_package_and_layer(self):
        self.assertEqual(
            [(r["id"], r["outcome"], r["killing_tests"]) for r in self.records],
            [(i, outcome, [dict(fields(t), layer="in-process") for t in tests]) for i, outcome, tests in MATRIX])
        # Each record is units' own, whichever package's test killed it.
        self.assertEqual({r["package"] for r in self.records}, {"mutation/fixture/units"})


if __name__ == "__main__":
    unittest.main()
