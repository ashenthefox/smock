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

    def test_a_runner_that_tests_another_tree_fails_its_self_test(self):
        # A moon that builds and runs the fixture's own source, not the
        # worker's tree, where the runner writes each mutant.
        pristine = self.tmp / "pristine"
        shutil.copytree(FIXTURE, pristine, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
        moon, log = moon_script(self.tmp, "elsewhere", f'cd "{pristine}" && exec "$moon" "$@"')
        result = self.run_runner("elsewhere", moon, "--mutant", SURVIVOR, "calc")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("the self-test of mutation/fixture/calc survived", result.stderr)
        self.assertEqual(len(builds(log)), 2)

    def test_a_runner_whose_mutants_never_build_fails_its_self_test(self):
        # A moon that builds once, the baseline, and fails every later
        # build: every mutant would be unviable, outside both counts.
        count = self.tmp / "builds"
        moon, log = moon_script(self.tmp, "once", (
            'case " $* " in *" --build-only "*)\n'
            f'  echo x >>"{count}"\n'
            f'  if [ "$(wc -l <"{count}")" -gt 1 ]; then echo "no build" >&2; exit 1; fi ;;\n'
            'esac\nexec "$moon" "$@"'))
        result = self.run_runner("once", moon, "--mutant", SURVIVOR, "calc")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("the self-test of mutation/fixture/calc does not build, so no mutant could", result.stderr)
        self.assertEqual(len(builds(log)), 2)

    def test_a_run_records_its_self_test_and_switches_it_off_before_the_mutants(self):
        moon, log = moon_script(self.tmp, "real", 'exec "$moon" "$@"')
        result = self.run_runner("real", moon, "--mutant", SURVIVOR, "calc")
        self.assertEqual(result.returncode, 0, result.stderr)
        package = json.loads((self.tmp / "out-real" / "summary.json").read_text())["packages"][0]
        self_test = package["self_test"]
        self.assertEqual((self_test["outcome"], self_test["failed_tests"]), ("killed", 5))
        self.assertEqual(self_test["definitions"], ["calc/calc.mbt,in_range", "calc/calc.mbt,halve_until",
                                                    "calc/calc.mbt,is_blank", "calc/calc.mbt,is_odd"])
        self.assertEqual(self_test["files"], ["calc/calc.mbt"])
        # The survivor still survives: the self-test's abort is gone when
        # the mutant runs, and the tree is the fixture's again.
        records = [json.loads(line) for line in (self.tmp / "out-real" / "mutants.jsonl").read_text().splitlines()]
        self.assertEqual([(r["id"], r["outcome"]) for r in records], [(SURVIVOR, "survived")])
        self.assertEqual((self.tmp / "work-real" / "tree-0" / "calc" / "calc.mbt").read_text(),
                         (FIXTURE / "calc" / "calc.mbt").read_text())
        # The baseline, then the self-test, then the mutant.
        self.assertEqual(len(builds(log)), 3)
        report = (self.tmp / "out-real" / "report.md").read_text()
        self.assertIn('Self-test: `abort("mutation self-test")` at the start of 4 functions, killed by 5 tests.',
                      report)

    def test_the_self_test_alone_runs_no_mutant(self):
        moon, log = moon_script(self.tmp, "alone", 'exec "$moon" "$@"')
        result = self.run_runner("alone", moon, "--self-test-only", "calc", "log")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.tmp / "out-alone" / "mutants.jsonl").read_text(), "")
        summary = json.loads((self.tmp / "out-alone" / "summary.json").read_text())
        self.assertEqual(
            [(p["package"], p["mutants"], p["self_test"]["outcome"], p["self_test"]["failed_tests"],
              len(p["self_test"]["definitions"])) for p in summary["packages"]],
            [("mutation/fixture/calc", 0, "killed", 5, 4), ("mutation/fixture/log", 0, "killed", 3, 3)])
        # Each package's baseline and its self-test.
        self.assertEqual(len(builds(log)), 4)

    def test_a_package_whose_tests_call_none_of_its_functions_fails_its_self_test(self):
        # shapes has functions and no test.
        moon, _ = moon_script(self.tmp, "untested", 'exec "$moon" "$@"')
        result = self.run_runner("untested", moon, "--self-test-only", "shapes")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("the self-test of mutation/fixture/shapes survived", result.stderr)

    def test_the_self_test_cannot_be_given_with_mutants_or_counts_alone(self):
        for other in (["--mutant", SURVIVOR], ["--sites-only"]):
            result = subprocess.run([sys.executable, str(RUN), "--root", str(FIXTURE), "--self-test-only",
                                     *other, "calc"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("--self-test-only", result.stderr)


if __name__ == "__main__":
    unittest.main()
