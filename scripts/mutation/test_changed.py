"""Tests of the mutation runner's diff mode (--changed), which runs every
mutant of the pinned set on the non-test lines that a branch changes in
the pure packages, against its merge base with main (#304), through the
command line of scripts/mutation/run.py, on a small git history of the
fixture module scripts/mutation/fixture.

The outcomes of the mutants on the changed lines are worked out from the
fixture's tests (calc_test.mbt), as the comments of calc.mbt work out
those of its own mutants; the rules this ticket decided where it was
silent are in CONTRIBUTING.md, "Mutation runner", which the tests cite.

They need python3, git, moon and moonc (the toolchain of
.moonbit-version).

usage: python3 -m unittest discover -s scripts/mutation -v
"""

import json
import re
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


def git(repo, *args):
    """Runs git in repo, as an author of its own, and gives its output."""
    author = ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"]
    result = subprocess.run(["git", "-C", str(repo), *author, *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"git {' '.join(args)} failed:\n{result.stderr}")
    return result.stdout


def edit(path, old, new):
    """Replaces the one place of old in a file with new."""
    text = path.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise AssertionError(f"{path} holds {old!r} {text.count(old)} times")
    path.write_text(text.replace(old, new), encoding="utf-8")


def history(directory):
    """A git repository at directory, from the fixture module:

      main   the fixture, then a change to log/lines.mbt, made after
             topic left it;
      topic  from the fixture: "odd" changes is_odd's body (calc.mbt's
             line 75) and, besides, a test file, the generated limits.mbt
             and a new package that builds natively only; then "range"
             changes in_range's body (line 17).

    It gives the commits by name, with topic checked out."""
    shutil.copytree(FIXTURE, directory, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
    git(directory, "init", "-q", "-b", "main")
    git(directory, "add", "-A")
    git(directory, "commit", "-q", "-m", "the fixture")
    commits = {"fixture": git(directory, "rev-parse", "HEAD").strip()}
    git(directory, "checkout", "-q", "-b", "topic")
    calc = directory / "calc"
    edit(calc / "calc.mbt", "  !(n % 2 == 0)\n", "  n % 2 != 0\n")
    edit(calc / "calc_test.mbt", 'test "3 is odd" {\n', 'test "3 is odd" {\n  assert_true(@calc.is_odd(5))\n')
    edit(calc / "limits.mbt", "if 3 > 2 { 3 } else { 2 }", "if 3 >= 2 { 3 } else { 2 }")
    (directory / "native").mkdir()
    (directory / "native" / "moon.pkg").write_text('supported_targets = "native"\n')
    (directory / "native" / "native.mbt").write_text(
        "///|\n/// Twice `n`, on the native backend only.\npub fn twice(n : Int) -> Int {\n  n * 2\n}\n")
    git(directory, "add", "-A")
    git(directory, "commit", "-q", "-m", "odd")
    commits["odd"] = git(directory, "rev-parse", "HEAD").strip()
    edit(calc / "calc.mbt", "  low <= n && n <= high\n", "  n >= low && n <= high\n")
    git(directory, "commit", "-q", "-am", "range")
    commits["range"] = git(directory, "rev-parse", "HEAD").strip()
    git(directory, "checkout", "-q", "main")
    edit(directory / "log" / "lines.mbt", '  "info: " + message\n', '  "info: " + message + ""\n')
    git(directory, "commit", "-q", "-am", "main moves on")
    git(directory, "checkout", "-q", "topic")
    return commits


def read_lines(path):
    """The JSON objects of a file of JSON lines."""
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


class ChangedLinesTest(unittest.TestCase):
    """The diff mode on topic, against main and against another base."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-changed-"))
        cls.root = cls.tmp / "root"
        cls.commits = history(cls.root)
        cls.out = cls.tmp / "main"
        cls.result = cls.run_runner(cls.out, "--changed")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def run_runner(cls, out, *args, moon="moon"):
        return subprocess.run([sys.executable, str(RUN), "--root", str(cls.root), "--work", str(cls.tmp / "work"),
                               "--out", str(out), "--moon", moon, *args], capture_output=True, text=True)

    def test_the_mutants_of_the_pinned_set_on_the_changed_lines_run_against_the_merge_base_with_main(self):
        # #304: "By default the base is the merge base with main ... The
        # runner finds the non-test source lines the branch adds or
        # changes in the pure packages, and runs every mutant of the
        # pinned set on them." main's own later change to log is not the
        # branch's; nor are the test file, the generated file and the
        # package that builds natively only (#275, Terms and Scope).
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        records = read_lines(self.out / "mutants.jsonl")
        self.assertEqual([(r["id"], r["outcome"]) for r in records], [
            # in_range's body holds line 17 (CONTRIBUTING, "Mutation
            # runner": a site is on the changed lines when any line of its
            # text is). The tests check 1 in the range from 1 to 3, and 0.
            ("calc/calc.mbt,in_range,BODY,{…},{ false },0", "killed"),
            ("calc/calc.mbt,in_range,ROR,>=,>,0", "killed"),  # 1 is then below the range
            ("calc/calc.mbt,in_range,LCR,&&,||,0", "killed"),  # 0 is then in it
            ("calc/calc.mbt,in_range,ROR,<=,<,0", "survived"),  # no test has a number at the high end
            # is_odd's line 75, `n % 2 != 0`: the tests check 3 and 5.
            ("calc/calc.mbt,is_odd,BODY,{…},{ false },0", "killed"),
            ("calc/calc.mbt,is_odd,INT,2,3,0", "killed"),  # 3 % 3 is 0
            ("calc/calc.mbt,is_odd,INT,2,1,0", "killed"),  # n % 1 is 0
            ("calc/calc.mbt,is_odd,INT,0,1,0", "killed"),  # 3 % 2 is 1
            ("calc/calc.mbt,is_odd,INT,0,-1,0", "survived"),  # no test has an even number
        ])
        self.assertEqual({r["set"] for r in records}, {"pinned"})

    def test_the_report_names_its_base_says_how_many_mutants_ran_and_shows_the_survivors(self):
        # #304: "The report lists the survivors on changed lines with their
        # diffs, names its base, and says how many mutants it ran."
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        report = (self.out / "report.md").read_text()
        base = self.commits["fixture"][:12]
        self.assertTrue(report.startswith(
            "# Mutants on changed lines\n\n"
            f"Against `main`, merge base `{base}`: 2 changed non-test lines in the pure packages (calc)."
            " The run ran the 9 mutants of the pinned set on them.\n\n# Mutation report\n"), report[:400])
        self.assertIn("-  n >= low && n <= high\n+  n >= low && n < high\n", report)
        self.assertIn("-  n % 2 != 0\n+  n % 2 != -1\n", report)
        self.assertNotIn("is_odd,INT,0,1,0", report)
        summary = json.loads((self.out / "summary.json").read_text())
        self.assertEqual(summary["changed"], {"base": "main", "merge_base": self.commits["fixture"],
                                              "lines": {"calc/calc.mbt": [17, 75]}, "mutants": 9})

    def test_another_base_can_be_given(self):
        # #304: "another base can be given as an option": the merge base
        # with "odd" is odd itself, so only "range" is the branch's.
        out = self.tmp / "odd"
        result = self.run_runner(out, "--changed", "--base", self.commits["odd"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["id"] for r in read_lines(out / "mutants.jsonl")], [
            "calc/calc.mbt,in_range,BODY,{…},{ false },0", "calc/calc.mbt,in_range,ROR,>=,>,0",
            "calc/calc.mbt,in_range,LCR,&&,||,0", "calc/calc.mbt,in_range,ROR,<=,<,0"])
        self.assertIn(f"Against `{self.commits['odd']}`, merge base `{self.commits['odd'][:12]}`: 1 changed"
                      " non-test line in the pure packages (calc).", (out / "report.md").read_text())

    def test_sites_only_counts_the_mutants_on_the_changed_lines_and_runs_none(self):
        # #275: a diff too large for the changed-lines job is "reported as
        # not covered", so the job needs the count before it runs.
        out = self.tmp / "count"
        result = self.run_runner(out, "--changed", "--sites-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 changed non-test lines in the pure packages (calc). 9 mutants of the pinned set are on"
                      " them.\n", (out / "report.md").read_text())
        self.assertEqual(len(read_lines(out / "chosen.jsonl")), 9)
        self.assertEqual(json.loads((out / "summary.json").read_text())["changed"]["mutants"], 9)

    def test_the_shards_of_a_run_on_changed_lines_merge_into_its_report(self):
        # #275: the changed-lines job runs "on at most about 3 shards"; the
        # merge gives the report of the run without them (#305).
        shards = [self.tmp / f"shard-{k}" for k in (1, 2, 3)]
        for k, shard in enumerate(shards, 1):
            result = self.run_runner(shard, "--changed", "--shard", f"{k}/3")
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("This shard ran 3 of the 9 mutants of the pinned set on them.",
                      (shards[1] / "report.md").read_text())
        merged = self.tmp / "merged"
        result = subprocess.run([sys.executable, str(HERE / "merge.py"), "--out", str(merged), *map(str, shards)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

        def without_timings(text):
            return re.sub(r"\d+\.\d+ s\b", "N s", text)

        self.assertEqual(without_timings((merged / "report.md").read_text()),
                         without_timings((self.out / "report.md").read_text()))

    def test_a_change_with_no_non_test_source_line_runs_nothing_and_says_so(self):
        # #304: "A change with no non-test source line runs nothing and
        # says so." Against topic itself, and against the commit before
        # the test file's change, there is none; a moon that fails when it
        # runs shows that nothing ran.
        never = self.tmp / "never"
        never.write_text("#!/bin/sh\necho moon ran >&2\nexit 9\n")
        never.chmod(never.stat().st_mode | stat.S_IXUSR)

        def nothing(name, *args):
            out = self.tmp / f"nothing-{name}"
            result = self.run_runner(out, "--changed", *args, moon=str(never))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("moon ran", result.stderr)
            self.assertEqual(read_lines(out / "mutants.jsonl"), [])
            self.assertIn("no non-test line of a pure package changed, so no mutant ran.\n",
                          (out / "report.md").read_text())
            self.assertIn("no mutant ran", result.stdout)

        nothing("topic", "--base", "topic")
        git(self.root, "checkout", "-q", "-b", "tests-only", self.commits["fixture"])
        try:
            edit(self.root / "calc" / "calc_test.mbt", 'test "3 is odd" {\n',
                 'test "3 is odd" {\n  assert_true(@calc.is_odd(7))\n')
            git(self.root, "commit", "-q", "-am", "a test")
            nothing("tests-only")
        finally:
            git(self.root, "checkout", "-q", "-f", "topic")

if __name__ == "__main__":
    unittest.main()
