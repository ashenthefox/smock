"""Tests of the mutation runner, scripts/mutation/run.py, and of its site
finder, scripts/mutation/sites.py, through their command lines, on the
fixture module scripts/mutation/fixture. In the fixture's package calc,
each site's mutant has a known outcome, which a comment beside the site
gives with its reason; the package shapes holds one site in each kind of
definition, and look-alikes that are not sites.

The operators and their alternatives are those of #298's acceptance
criteria and of operator set v1 (#275, CONTRIBUTING.md): ROR swaps < and <=,
and > and >=; BOOL swaps true and false; NOT removes a prefix !. The time
limit, 1.25 times the baseline run plus 4 s, is #298's too.

They need python3, git, moon and moonc (the toolchain of .moonbit-version),
and take about half a minute: one mutant of the fixture times out.

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
REPO = HERE.parent.parent
FIXTURE = HERE / "fixture"
SITES = HERE / "sites.py"
RUN = HERE / "run.py"

# The sites of calc, from calc/calc.mbt: each one's id, line and column,
# and the outcome that the comment beside it gives.
CALC = [
    ("calc/calc.mbt,in_range,ROR,<=,<,0", 13, 7, "killed"),
    ("calc/calc.mbt,in_range,ROR,<=,<,1", 13, 17, "survived"),
    ("calc/calc.mbt,halve_until,ROR,>,>=,0", 22, 11, "timed out"),
    ("calc/calc.mbt,is_blank,BOOL,true,false,0", 31, 49, "survived"),
    ("calc/calc.mbt,is_blank,NOT,!,,0", 35, 6, "survived"),
    ("calc/calc.mbt,is_blank,BOOL,false,true,0", 41, 14, "killed"),
    ("calc/calc.mbt,is_blank,BOOL,true,false,1", 45, 3, "killed"),
    ("calc/calc.mbt,is_odd,NOT,!,,0", 52, 3, "killed"),
]


def find_sites(root, *paths):
    """What the site finder prints for the paths, as a list of objects."""
    result = subprocess.run([sys.executable, str(SITES), "--root", str(root), *paths],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"sites.py failed ({result.returncode}):\n{result.stderr}")
    return [json.loads(line) for line in result.stdout.splitlines()]


class SitesTest(unittest.TestCase):
    def test_each_site_of_calc_with_its_position(self):
        sites = find_sites(FIXTURE, "calc")
        self.assertEqual([(s["id"], s["line"], s["column"]) for s in sites],
                         [(i, line, column) for i, line, column, _ in CALC])

    def test_a_site_has_the_fields_of_its_id(self):
        site = find_sites(FIXTURE, "calc")[1]
        self.assertEqual(site, {
            "id": "calc/calc.mbt,in_range,ROR,<=,<,1",
            "file": "calc/calc.mbt",
            "definition": "in_range",
            "operator": "ROR",
            "original": "<=",
            "replacement": "<",
            "ordinal": 1,
            "line": 13,
            "column": 17,
            "definition_lines": [8, 14],
        })

    def test_each_kind_of_definition_names_its_sites(self):
        sites = find_sites(FIXTURE, "shapes")
        self.assertEqual([(s["id"], s["line"], s["column"]) for s in sites], [
            ("shapes/shapes.mbt,Span::is_empty,ROR,>,>=,0", 15, 12),
            ("shapes/shapes.mbt,impl Show for Span with output,ROR,<=,<,0", 20, 35),
            ("shapes/shapes.mbt,impl Round with is_round,BOOL,false,true,0", 31, 3),
            ("shapes/shapes.mbt,threshold,NOT,!,,0", 35, 24),
            ("shapes/shapes.mbt,threshold,ROR,>=,>,0", 35, 28),
            ("shapes/shapes.mbt,init,ROR,<,<=,0", 58, 25),
        ])

    def test_tests_generated_files_and_the_test_certificates_have_no_sites(self):
        # In the fixture: calc_test.mbt, calc_wbtest.mbt, the test block of
        # calc.mbt and the generated limits.mbt each hold a comparison.
        self.assertEqual(
            {s["file"] for s in find_sites(FIXTURE, "calc", "calc/calc_test.mbt", "calc/limits.mbt")},
            {"calc/calc.mbt"})
        # In the workspace (#275, Scope): the Unicode data table, the build
        # information, which a build writes, and the test certificates.
        files = {s["file"] for s in find_sites(REPO, "unicode", "buildinfo", "testcerts")}
        self.assertEqual(files - {"unicode/unicode.mbt", "buildinfo/buildinfo.mbt"}, set())
        self.assertIn("unicode/unicode.mbt", files)

    def test_a_file_that_does_not_parse_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "broken.mbt").write_text("///|\nfn broken( -> Int {\n  1 < 2\n}\n")
            result = subprocess.run([sys.executable, str(SITES), "--root", tmp, "broken.mbt"],
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("broken.mbt: moonc cannot parse it", result.stderr)
        self.assertEqual(result.stdout, "")


def logging_moon(directory, fail_build_when=None):
    """A moon that logs each of its command lines and runs the real one."""
    moon = shutil.which("moon")
    if moon is None:
        raise unittest.SkipTest("moon is not on PATH")
    script = directory / "moon"
    log = directory / "moon.log"
    script.write_text(f'#!/bin/sh\necho "$*" >>"{log}"\nexec "{moon}" "$@"\n')
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script, log


class RunnerTest(unittest.TestCase):
    """One run of every mutant of calc, which the tests read, and runs of
    one mutant alone, in the same work directory."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-mutation-"))
        cls.moon, cls.log = logging_moon(cls.tmp)
        cls.work = cls.tmp / "work"
        cls.out = cls.tmp / "all"
        cls.result = cls.run_runner(cls.out, "calc")
        if cls.result.returncode != 0:
            raise AssertionError(f"run.py failed ({cls.result.returncode}):\n{cls.result.stderr}")
        cls.records = [json.loads(line) for line in (cls.out / "mutants.jsonl").read_text().splitlines()]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def run_runner(cls, out, *args):
        return subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(cls.work), "--out", str(out),
             "--moon", str(cls.moon), *args],
            capture_output=True, text=True)

    def test_each_mutant_has_its_known_outcome(self):
        self.assertEqual([(r["id"], r["outcome"]) for r in self.records],
                         [(i, outcome) for i, _, _, outcome in CALC])

    def test_a_record_names_the_tests_that_killed_its_mutant(self):
        killed = {r["id"]: [t["name"] for t in r["killing_tests"]] for r in self.records}
        self.assertEqual(killed["calc/calc.mbt,in_range,ROR,<=,<,0"], ["a number at the low end is in range"])
        self.assertEqual(killed["calc/calc.mbt,is_odd,NOT,!,,0"], ["3 is odd"])
        self.assertEqual(killed["calc/calc.mbt,in_range,ROR,<=,<,1"], [])

    def test_a_record_gives_the_backend_and_the_timings(self):
        for record in self.records:
            self.assertEqual(record["backend"], "wasm-gc")
            self.assertEqual(record["package"], "mutation/fixture/calc")
            timings = record["timings"]
            self.assertGreater(timings["build_s"], 0)
            self.assertGreater(timings["run_s"], 0)
        summary = json.loads((self.out / "summary.json").read_text())["packages"][0]
        limit = 1.25 * summary["baseline"]["run_s"] + 4
        timed_out = next(r for r in self.records if r["outcome"] == "timed out")
        self.assertAlmostEqual(timed_out["timings"]["limit_s"], limit, places=2)
        self.assertGreaterEqual(timed_out["timings"]["run_s"], limit)

    def test_the_summary_counts_each_outcome_of_the_package(self):
        summary = json.loads((self.out / "summary.json").read_text())
        self.assertEqual(len(summary["packages"]), 1)
        package = summary["packages"][0]
        self.assertEqual(package["package"], "mutation/fixture/calc")
        self.assertEqual(package["backend"], "wasm-gc")
        self.assertEqual(
            {k: package[k] for k in ("sites", "mutants", "killed", "timed_out", "survived", "unviable")},
            {"sites": 8, "mutants": 8, "killed": 4, "timed_out": 1, "survived": 3, "unviable": 0})
        self.assertEqual(package["baseline"]["tests"], 7)

    def test_the_report_shows_each_survivor_with_its_definition(self):
        report = (self.out / "report.md").read_text()
        self.assertIn("calc/calc.mbt,is_blank,NOT,!,,0", report)
        self.assertIn("calc/calc.mbt,is_blank,BOOL,true,false,0", report)
        self.assertIn(
            "@@ -8,7 +8,7 @@ in_range\n"
            " pub fn in_range(n : Int, low : Int, high : Int) -> Bool {\n",
            report)
        self.assertIn("-  low <= n && n <= high\n+  low <= n && n < high\n }\n", report)
        # The time-out is listed apart, and no killed mutant is shown.
        self.assertIn("calc/calc.mbt,halve_until,ROR,>,>=,0", report)
        self.assertNotIn("calc/calc.mbt,is_odd,NOT,!,,0", report)
        # The run prints the report.
        self.assertIn("-  low <= n && n <= high\n+  low <= n && n < high\n", self.result.stdout)

    def test_the_runner_never_passes_u(self):
        # in_range's first mutant is killed by a snapshot alone, which -u
        # would rewrite: it would then survive.
        lines = self.log.read_text().splitlines()
        self.assertTrue(lines)
        for line in lines:
            self.assertNotIn("--update", line.split())
            self.assertNotIn("-u", line.split())
        self.assertEqual((self.work / "tree-0" / "calc" / "calc_test.mbt").read_text(),
                         (FIXTURE / "calc" / "calc_test.mbt").read_text())

    def test_one_mutant_runs_alone_by_its_id(self):
        out = self.tmp / "one"
        result = self.run_runner(out, "--mutant", "calc/calc.mbt,is_odd,NOT,!,,0", "calc")
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in (out / "mutants.jsonl").read_text().splitlines()]
        self.assertEqual([(r["id"], r["outcome"]) for r in records], [("calc/calc.mbt,is_odd,NOT,!,,0", "killed")])

    def test_an_unknown_id_fails(self):
        result = self.run_runner(self.tmp / "unknown", "--mutant", "calc/calc.mbt,is_odd,NOT,!,,9", "calc")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no site of calc has the id calc/calc.mbt,is_odd,NOT,!,,9", result.stderr)

    def test_a_mutant_that_does_not_build_is_unviable_and_never_runs(self):
        # A finder that gives one site whose replacement does not parse.
        # Were the build's exit status not checked, the tests would run the
        # binary of the last build, the baseline's, and pass.
        site = {"id": "calc/calc.mbt,in_range,ROR,<=,<=<,0", "file": "calc/calc.mbt", "definition": "in_range",
                "operator": "ROR", "original": "<=", "replacement": "<=<", "ordinal": 0,
                "line": 13, "column": 17, "definition_lines": [8, 14]}
        finder = self.tmp / "finder"
        finder.write_text(f"#!/bin/sh\necho '{json.dumps(site)}'\n")
        finder.chmod(finder.stat().st_mode | stat.S_IXUSR)
        out = self.tmp / "unviable"
        before = len(self.log.read_text().splitlines())
        result = self.run_runner(out, "--finder", str(finder), "calc")
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in (out / "mutants.jsonl").read_text().splitlines()]
        self.assertEqual([(r["id"], r["outcome"]) for r in records], [(site["id"], "unviable")])
        self.assertIn("Parse error", records[0]["message"])
        summary = json.loads((out / "summary.json").read_text())["packages"][0]
        self.assertEqual((summary["unviable"], summary["killed"], summary["survived"]), (1, 0, 0))
        # The last thing the run did was the failed build.
        self.assertIn("--build-only", self.log.read_text().splitlines()[-1].split())
        self.assertGreater(len(self.log.read_text().splitlines()), before)


if __name__ == "__main__":
    unittest.main()
