"""Tests of the mutation runner's forced-fail self-test
(scripts/mutation/selftest.py, run by scripts/mutation/run.py), through
the runner's command line, on the fixture module scripts/mutation/fixture.

#309 asks for it: each run first switches on a mutant whose effect a test
must see, and fails if that mutant survives or does not build. The rule
that chooses the mutant is CONTRIBUTING.md's ("Mutation runner", "The
self-test"): `abort("mutation self-test")` at the start of the body of
every top-level function and method of the package's non-test source
whose body is MoonBit. The runs below break the runner on purpose through
--moon, as a weakened runner would be broken, and the self-test must then
stop the run before any mutant runs.

The expected values come from the fixture: calc.mbt has four functions
(in_range, halve_until, is_blank and is_odd), and of calc's seven tests
the five of calc_test.mbt call one of them, while the white-box test and
the test block of calc.mbt call none; log's lines.mbt has three, each
called by one of log's three tests, and log/target.mbt has only a let.

They need python3, git, moon and moonc (the toolchain of
.moonbit-version), as test_mutation.py does.

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

# A mutant of calc that survives (test_mutation.py's CALC): no test has a
# number at the high end of the range. The runs below run it alone, so a
# run that the self-test does not stop runs one mutant only.
SURVIVOR = "calc/calc.mbt,in_range,ROR,<=,<,1"


def moon_script(directory, name, body):
    """A moon command, a shell script in directory that logs each of its
    command lines into <name>.log and then does what body says; $moon is
    the real moon."""
    moon = shutil.which("moon")
    if moon is None:
        raise unittest.SkipTest("moon is not on PATH")
    script = directory / name
    log = directory / f"{name}.log"
    script.write_text(f'#!/bin/sh\nmoon="{moon}"\necho "$*" >>"{log}"\n{body}\n')
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script, log


def builds(log):
    """The command lines of a moon log that build without running."""
    return [line for line in log.read_text().splitlines() if "--build-only" in line.split()]


class SelfTestTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-selftest-"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_runner(self, name, moon, *args):
        """Runs the runner on the fixture with a moon command, in a work
        directory of the run's own."""
        return subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(self.tmp / f"work-{name}"),
             "--out", str(self.tmp / f"out-{name}"), "--moon", str(moon), *args],
            capture_output=True, text=True)

    def test_a_runner_that_never_sees_a_test_fail_fails_its_self_test(self):
        # A moon whose test runs always pass: every mutant would survive.
        moon, log = moon_script(self.tmp, "passes", '"$moon" "$@"\nstatus=$?\n'
                                'case " $* " in *" --build-only "*) exit $status ;; esac\nexit 0')
        result = self.run_runner("passes", moon, "--mutant", SURVIVOR, "calc")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("the self-test of mutation/fixture/calc survived", result.stderr)
        # The mutant never built: the baseline's build and the self-test's
        # are the only ones.
        self.assertEqual(len(builds(log)), 2)
        self.assertFalse((self.tmp / "out-passes" / "mutants.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
