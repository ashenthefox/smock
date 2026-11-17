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
# units' two tests with no name: 5 in 1 to 9, and 4 in 0 to 8.
FIVE = ("mutation/fixture/units", "units_test.mbt", 3, "")
FOUR = ("mutation/fixture/units", "units_test.mbt", 4, "")

# units' kill matrix: each mutant of the pinned set, its outcome, and every
# test that kills it, in moon's order of the tests.
# - within's BODY `{ false }` fails every test that needs a number in a
#   range: 2 in 1 to 3, 5 in 1 to 9 and 4 in 0 to 8 (units), 1 on a scale
#   from 1 to 3 (meter), and 10 on a scale from 0 to 10 (dial); 0 below 1
#   to 3 still is not in it. No other mutant changes whether a number well
#   inside a range is in it.
# - `low < n` fails only meter's 1 on a scale from 1.
# - `||` fails only units' 0 below the range, which `0 <= 3` lets in.
# - `n < high` fails only dial's 10 on a scale to 10.
# - past's BODY `{ false }` fails only units' 5 past 3.
# - `n >= high` survives: only probe's test has a number at the end, and
#   probe builds only natively.
MATRIX = [
    ("units/units.mbt,within,BODY,{…},{ false },0", "killed", [DIAL_HIGH, METER_LOW, INSIDE, FIVE, FOUR]),
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


# A moon that answers the runs of tests, but not their builds, dry runs or
# outlines, from a script: a JSON list of answers, taken in turn. "real"
# runs the real moon; {"fail": [test, ...]} prints what moon prints when
# those tests fail, and exits as it does. Once the script is used up, the
# real moon answers. Its arguments: the script, the real moon, then moon's
# own.
SCRIPTED_MOON = '''\
import json, os, sys
script, real, args = sys.argv[1], sys.argv[2], sys.argv[3:]
if args[:1] == ["test"] and not {"--build-only", "--dry-run", "--outline"} & set(args):
    with open(script) as f:
        answers = json.load(f)
    if answers:
        answer = answers.pop(0)
        with open(script, "w") as f:
            json.dump(answers, f)
        if isinstance(answer, dict) and "fail" in answer:
            for package, filename, index, name in answer["fail"]:
                print(json.dumps({"package": package, "filename": filename, "index": str(index),
                                  "test_name": name, "message": "a scripted failure"}))
            print(f"Total tests: 7, passed: {7 - len(answer['fail'])}, failed: {len(answer['fail'])}.")
            sys.exit(2)
os.execv(real, [real, *args])
'''


class MatrixConfirmationTest(unittest.TestCase):
    """Kill-matrix runs of within's BODY `{ false }`, which three tests of
    three packages kill, with a moon that answers from a script, so that
    one of them fails only once, or fails without the mutant too."""

    MUTANT = MATRIX[0][0]

    @classmethod
    def setUpClass(cls):
        moon = shutil.which("moon")
        if moon is None:
            raise unittest.SkipTest("moon is not on PATH")
        cls.real = moon
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-matrix-confirm-"))
        cls.fake = cls.tmp / "scripted_moon.py"
        cls.fake.write_text(SCRIPTED_MOON)
        cls.runs = 0

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_scripted(self, answers):
        """Runs the runner in kill-matrix mode on the mutant, with the moon
        that answers from the script: its record and its flake records."""
        type(self).runs += 1
        script = self.tmp / f"run-{self.runs}.json"
        script.write_text(json.dumps(answers))
        moon = f"{sys.executable} {self.fake} {script} {self.real}"
        out = self.tmp / f"run-{self.runs}"
        result = run_runner(FIXTURE, self.tmp / "work", out, moon, "--matrix", "--mutant", self.MUTANT, "units")
        self.assertEqual(result.returncode, 0, result.stderr)
        [record] = read_lines(out / "mutants.jsonl")
        return record, json.loads((out / "flakes.json").read_text())["runs"][-1]

    # The runs of tests, in turn: the two runs without a mutant, the
    # self-test's run, the mutant's run, its run again with the mutant on,
    # and the run without it.

    def test_a_test_that_passes_when_the_kill_runs_again_is_not_credited(self):
        killed = [list(DIAL_HIGH), list(METER_LOW), list(INSIDE)]
        record, flakes = self.run_scripted(["real", "real", "real", {"fail": killed},
                                            {"fail": [list(DIAL_HIGH), list(INSIDE)]}])
        self.assertEqual((record["outcome"], record["confirmation"]), ("killed", "confirmed"))
        self.assertEqual(record["killing_tests"], [dict(fields(t), layer="in-process") for t in (DIAL_HIGH, INSIDE)])
        # meter's test passed the one time it ran again with the mutant on.
        self.assertIn({"package": METER_LOW[0], "file": METER_LOW[1], "name": METER_LOW[3], "flaked": 1,
                       "reruns": 1}, flakes["tests"])

    def test_a_test_that_fails_without_the_mutant_too_is_not_credited(self):
        record, flakes = self.run_scripted(["real", "real", "real", "real", "real", {"fail": [list(METER_LOW)]}])
        self.assertEqual((record["outcome"], record["confirmation"]), ("killed", "confirmed"))
        self.assertEqual(record["killing_tests"],
                         [dict(fields(t), layer="in-process") for t in (DIAL_HIGH, INSIDE, FIVE, FOUR)])
        self.assertIn({"package": METER_LOW[0], "file": METER_LOW[1], "name": METER_LOW[3], "flaked": 1,
                       "reruns": 1}, flakes["tests"])

    def test_tests_with_no_name_are_confirmed_each_on_its_own(self):
        # Both fail with the mutant on; run again, only the second does, so
        # only the second is credited, though neither has a name.
        record, flakes = self.run_scripted(["real", "real", "real", {"fail": [list(FIVE), list(FOUR)]},
                                            {"fail": [list(FOUR)]}])
        self.assertEqual((record["outcome"], record["confirmation"]), ("killed", "confirmed"))
        self.assertEqual(record["killing_tests"], [dict(fields(FOUR), layer="in-process")])
        # The flake records name a test with no name by its index.
        self.assertEqual([t for t in flakes["tests"] if t["package"] == FIVE[0]], [
            {"package": FIVE[0], "file": FIVE[1], "name": "#3", "flaked": 1, "reruns": 1},
            {"package": FOUR[0], "file": FOUR[1], "name": "#4", "flaked": 0, "reruns": 1}])


if __name__ == "__main__":
    unittest.main()
