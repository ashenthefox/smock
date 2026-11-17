"""Tests of the mutation runner's modes for bulk runs, through the command
lines of scripts/mutation/run.py and scripts/mutation/merge.py, on the
fixture module scripts/mutation/fixture: shards whose reports merge into
one, seeded samples stratified by package, chosen packages, and listed
sets of mutants, by offset on a commit or by key on any later commit,
with a run that writes totals only (#305).

The modes come from #305's acceptance criteria and from #275 (Step 2's
runner: "modes for ... a shard, a seeded sample, ... chosen packages and
a listed set (applied to later commits by key, with totals only for the
held-out set)"); the rules this ticket decided where they were silent are
in CONTRIBUTING.md, "Mutation runner", which the tests cite. The outcomes
of the fixture's mutants are those its comments give, as in
test_mutation.py.

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
MERGE = HERE / "merge.py"
PACKAGES = ("calc", "forms", "log", "shapes")


def git(repo, *args):
    """Runs git in repo, as an author of its own, and gives its output."""
    result = subprocess.run(["git", "-C", str(repo), "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                             "-c", "commit.gpgsign=false", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"git {' '.join(args)} failed:\n{result.stderr}")
    return result.stdout


def fixture_history(directory):
    """A git repository at directory that holds a copy of the fixture
    module in one commit, on main: the commit's id."""
    shutil.copytree(FIXTURE, directory, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
    git(directory, "init", "-q", "-b", "main")
    git(directory, "add", "-A")
    git(directory, "commit", "-q", "-m", "the fixture")
    return git(directory, "rev-parse", "HEAD").strip()


def run_runner(root, out, *args, work=None, moon="moon"):
    """Runs run.py on root, writing into out."""
    work = work or out.parent / "work"
    return subprocess.run([sys.executable, str(RUN), "--root", str(root), "--work", str(work), "--out", str(out),
                           "--moon", str(moon), *args], capture_output=True, text=True)


def read_lines(path):
    """The JSON objects of a file of JSON lines."""
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


class ShardTest(unittest.TestCase):
    """Shards, chosen without a run (--sites-only)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-choice-shards-"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def chosen(self, name, *args):
        out = self.tmp / name
        result = run_runner(FIXTURE, out, "--sites-only", "--set", "full", *args, *PACKAGES)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [s["id"] for s in read_lines(out / "chosen.jsonl")]

    def test_each_mutant_is_in_exactly_one_shard_and_the_same_input_gives_the_same_shards(self):
        # #305: "every mutant is in exactly one shard, and the same input
        # gives the same shards".
        whole = self.chosen("whole")
        self.assertEqual(len(set(whole)), len(whole))
        self.assertGreater(len(whole), 100)
        parts = [self.chosen(f"shard-{k}", "--shard", f"{k}/3") for k in (1, 2, 3)]
        # In shard order, the shards hold the run's mutants in its own order.
        self.assertEqual([i for part in parts for i in part], whole)
        self.assertEqual(self.chosen("again", "--shard", "2/3"), parts[1])
        # CONTRIBUTING, "Mutation runner": the shards' sizes differ by one
        # at most.
        self.assertLessEqual(max(map(len, parts)) - min(map(len, parts)), 1)

    def test_a_shard_must_be_one_of_n(self):
        for shard in ("0/3", "4/3", "3", "a/b", "1/0"):
            result = run_runner(FIXTURE, self.tmp / "bad", "--sites-only", "--shard", shard, "calc")
            self.assertEqual(result.returncode, 2, shard)
            self.assertIn("argument --shard: ", result.stderr)


def without_timings(text):
    """A report with each time in seconds written as N."""
    return re.sub(r"\d+\.\d+ s\b", "N s", text)


class MergeTest(unittest.TestCase):
    """One run of log's full set and of a package without a site, and the
    same run in three shards, whose reports merge."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-choice-merge-"))
        cls.root = cls.tmp / "root"
        shutil.copytree(FIXTURE, cls.root, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
        (cls.root / "empty").mkdir()
        (cls.root / "empty" / "moon.pkg").write_text("")
        (cls.root / "empty" / "empty.mbt").write_text(
            '///|\n/// A text, which is no site: STR\'s scope does not hold this package.\npub let text : String = "a"\n')
        cls.packages = ("--set", "full", "log", "empty")
        cls.whole = cls.run_once(cls.tmp / "whole")
        cls.shards = [cls.run_once(cls.tmp / f"shard-{k}", "--shard", f"{k}/3") for k in (1, 2, 3)]
        cls.merged = cls.tmp / "merged"
        cls.result = subprocess.run([sys.executable, str(MERGE), "--out", str(cls.merged), *map(str, cls.shards)],
                                    capture_output=True, text=True)

    @classmethod
    def run_once(cls, out, *args):
        result = run_runner(cls.root, out, *args, *cls.packages, work=cls.tmp / "work")
        if result.returncode != 0:
            raise AssertionError(f"run.py failed ({result.returncode}):\n{result.stderr}")
        return out

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_the_shards_reports_merge_into_the_report_of_the_run_without_shards(self):
        # #305: "Shard reports merge into one report equal to a run without
        # shards in every mutant's outcome and killing tests, timings
        # aside."
        self.assertEqual(self.result.returncode, 0, self.result.stderr)

        def records(out):
            return [{k: v for k, v in r.items() if k != "timings"} for r in read_lines(out / "mutants.jsonl")]

        self.assertEqual(records(self.merged), records(self.whole))
        self.assertEqual(len(records(self.merged)), 8)
        # Each shard ran a part of them.
        self.assertEqual([len(read_lines(s / "mutants.jsonl")) for s in self.shards], [2, 3, 3])

        def counts(out):
            summary = json.loads((out / "summary.json").read_text())
            packages = summary.pop("packages")
            timings = ("baseline", "limit_s", "shards")
            return (summary,
                    [({k: v for k, v in p.items() if k not in timings}, p.get("baseline", {}).get("tests"))
                     for p in packages])

        self.assertEqual(counts(self.merged), counts(self.whole))
        self.assertEqual(without_timings((self.merged / "report.md").read_text()),
                         without_timings((self.whole / "report.md").read_text()))
        # The merge prints the report, as a run does.
        self.assertEqual(without_timings(self.result.stdout), without_timings((self.whole / "report.md").read_text()) + "\n")

    def test_the_package_without_a_mutant_runs_in_the_first_shard(self):
        packages = [[p["directory"] for p in json.loads((s / "summary.json").read_text())["packages"]]
                    for s in self.shards]
        self.assertEqual(packages, [["log", "empty"], ["log"], ["log"]])
        merged = json.loads((self.merged / "summary.json").read_text())["packages"]
        self.assertEqual([(p["directory"], p["mutants"], p["baseline"]["tests"]) for p in merged],
                         [("log", 8, 3), ("empty", 0, 0)])
        self.assertEqual([s["shard"] for s in merged[0]["shards"]], ["1/3", "2/3", "3/3"])

    def test_a_merge_needs_every_shard_of_one_run(self):
        missing = subprocess.run([sys.executable, str(MERGE), "--out", str(self.tmp / "missing"),
                                  str(self.shards[0]), str(self.shards[2])], capture_output=True, text=True)
        self.assertEqual(missing.returncode, 1)
        self.assertIn("shard 2/3 is missing", missing.stderr)
        twice = subprocess.run([sys.executable, str(MERGE), "--out", str(self.tmp / "twice"),
                                *map(str, self.shards), str(self.shards[1])], capture_output=True, text=True)
        self.assertEqual(twice.returncode, 1)
        self.assertIn("shard 2/3 is given twice", twice.stderr)
        other = subprocess.run([sys.executable, str(MERGE), "--out", str(self.tmp / "other"),
                                str(self.whole), *map(str, self.shards[1:])], capture_output=True, text=True)
        self.assertEqual(other.returncode, 1)
        self.assertIn(f"{self.whole} is not a shard", other.stderr)


class SampleTest(unittest.TestCase):
    """Seeded samples, chosen without a run (--sites-only)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-choice-samples-"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def chosen(self, name, *args, root=FIXTURE):
        out = self.tmp / name
        result = run_runner(root, out, "--sites-only", *args, *PACKAGES)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [(s["file"].split("/")[0], s["id"]) for s in read_lines(out / "chosen.jsonl")]

    def test_a_seeded_sample_is_stratified_by_package_and_the_same_for_the_same_seed_and_tree(self):
        # #305: "A seeded sample of N mutants, stratified by package, gives
        # the same mutants for the same seed and tree."
        whole = self.chosen("whole")
        sample = self.chosen("sample", "--sample", "20", "--seed", "one")
        self.assertEqual(len(sample), 20)
        # Stratified: each package's share of the sample is its share of
        # the set, rounded down or up.
        for package in PACKAGES:
            share = 20 * sum(1 for p, _ in whole if p == package) / len(whole)
            taken = sum(1 for p, _ in sample if p == package)
            self.assertIn(taken, {int(share), int(share) + 1} if share != int(share) else {int(share)}, package)
        # The sample's mutants are the set's, in the run's order.
        self.assertEqual([m for m in whole if m in sample], sample)
        self.assertEqual(self.chosen("again", "--sample", "20", "--seed", "one"), sample)
        self.assertNotEqual(self.chosen("other", "--sample", "20", "--seed", "two"), sample)
        # The same tree elsewhere.
        copy = self.tmp / "copy"
        shutil.copytree(FIXTURE, copy, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
        self.assertEqual(self.chosen("copy", "--sample", "20", "--seed", "one", root=copy), sample)

    def test_a_sample_as_large_as_the_set_is_the_set(self):
        whole = self.chosen("whole-full", "--set", "full")
        self.assertEqual(self.chosen("all", "--set", "full", "--sample", str(len(whole) + 5)), whole)


if __name__ == "__main__":
    unittest.main()
