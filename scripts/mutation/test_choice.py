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


def offset_of(text, line, column):
    """The offset, in characters, of a line and a column, both from 1."""
    return sum(len(t) + 1 for t in text.split("\n")[: line - 1]) + column - 1


def write_list(path, entries):
    """A list of mutants, one JSON object per line."""
    path.write_text("".join(json.dumps(e) + "\n" for e in entries), encoding="utf-8")
    return path


class ListedByOffsetTest(unittest.TestCase):
    """A list of mutants by offset, on the commit of a copy of the fixture
    in git."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-choice-offsets-"))
        cls.root = cls.tmp / "root"
        cls.commit = fixture_history(cls.root)
        cls.text = text = (cls.root / "calc" / "calc.mbt").read_text(encoding="utf-8")

        def at(line, column):
            return offset_of(text, line, column)
        cls.entries = [
            # In operator set v1: in_range's `n <= high` to `n < high`,
            # which survives (calc.mbt's comment beside it).
            {"file": "calc/calc.mbt", "offset": at(17, 17), "original": "<=", "replacement": "<",
             "commit": cls.commit},
            # Outside it, with an operator of v1's name: `==` to `!=` in
            # is_odd, which v1's ROR never makes (ADR 0006); 3 is then
            # not odd, so "3 is odd" fails.
            {"file": "calc/calc.mbt", "offset": at(75, 11), "original": "==", "replacement": "!=",
             "commit": cls.commit, "operator": "ROR"},
            # Outside it, without an operator: halve_until's `x / 2` to
            # `2 / x`, which still halves 100 to 0, so it survives.
            {"file": "calc/calc.mbt", "offset": at(36, 9), "original": "x / 2", "replacement": "2 / x",
             "commit": cls.commit},
        ]
        cls.list = write_list(cls.tmp / "offsets.jsonl", cls.entries)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_each_listed_mutant_is_found_and_marked_in_or_outside_operator_set_v1(self):
        # #305: "A run can take a list of mutants by file, offset and
        # replacement, on a given commit, ...; a replacement outside v1 is
        # allowed and is marked as such."
        out = self.tmp / "chosen"
        result = run_runner(self.root, out, "--sites-only", "--list", str(self.list))
        self.assertEqual(result.returncode, 0, result.stderr)
        chosen = read_lines(out / "chosen.jsonl")
        self.assertEqual([(m["id"], m["line"], m["column"], m["in_operator_set"], m["pinned"]) for m in chosen], [
            # The site of v1 that makes the same mutant: its id.
            ("calc/calc.mbt,in_range,ROR,<=,<,1", 17, 17, True, True),
            # CONTRIBUTING, "Mutation runner": a mutant outside v1 is named
            # as a site is, with the operator it gives (OTHER when it gives
            # none), and an ordinal that counts the same original text
            # outside comments before it in its definition.
            ("calc/calc.mbt,is_odd,ROR,==,!=,0", 75, 11, False, False),
            ("calc/calc.mbt,halve_until,OTHER,x / 2,2 / x,0", 36, 9, False, False),
        ])
        self.assertEqual([m["listed"] for m in chosen], self.entries)
        self.assertEqual(chosen[2]["definition_lines"], [22, 39])
        # The packages run are those of the listed files.
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual([p["directory"] for p in summary["packages"]], ["calc"])
        self.assertEqual(summary["set"], "listed")

    def test_a_listed_run_reports_each_mutant_with_its_outcome(self):
        out = self.tmp / "run"
        result = run_runner(self.root, out, "--list", str(self.list))
        self.assertEqual(result.returncode, 0, result.stderr)
        records = read_lines(out / "mutants.jsonl")
        self.assertEqual([(r["id"], r["outcome"], r["in_operator_set"], r["set"]) for r in records], [
            ("calc/calc.mbt,in_range,ROR,<=,<,1", "survived", True, "listed"),
            ("calc/calc.mbt,is_odd,ROR,==,!=,0", "killed", False, "listed"),
            ("calc/calc.mbt,halve_until,OTHER,x / 2,2 / x,0", "survived", False, "listed"),
        ])
        self.assertEqual([t["name"] for t in records[1]["killing_tests"]], ["3 is odd"])
        report = (out / "report.md").read_text()
        self.assertIn("Operator set v1, a listed set.", report)
        self.assertIn("## Listed mutants\n\n"
                      "| package | listed | run | no longer apply | outside operator set v1 |\n"
                      "|---|---:|---:|---:|---:|\n"
                      "| calc | 3 | 3 | 0 | 2 |\n\n"
                      "| mutant | operator set v1 | outcome |\n"
                      "|---|---|---|\n"
                      "| `calc/calc.mbt,in_range,ROR,<=,<,1` | in it | survived |\n"
                      "| `calc/calc.mbt,is_odd,ROR,==,!=,0` | outside it | killed |\n"
                      "| `calc/calc.mbt,halve_until,OTHER,x / 2,2 / x,0` | outside it | survived |\n", report)
        # The survivor outside v1 is shown with its diff, as every survivor.
        self.assertIn("-    x = x / 2\n+    x = 2 / x\n", report)

    def test_a_listed_file_that_differs_from_its_commit_stops_the_run(self):
        # The offsets hold on the commit the list gives.
        root = self.tmp / "later"
        fixture_history(root)
        calc = root / "calc" / "calc.mbt"
        calc.write_text("// A line more.\n" + calc.read_text(encoding="utf-8"), encoding="utf-8")
        result = run_runner(root, self.tmp / "later-out", "--sites-only", "--list", str(self.list))
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"calc/calc.mbt differs from its text at {self.commit}", result.stderr)

    def test_an_offset_that_does_not_hold_the_original_text_stops_the_run(self):
        listed = write_list(self.tmp / "wrong.jsonl", [dict(self.entries[0], offset=offset_of(self.text, 17, 16))])
        result = run_runner(self.root, self.tmp / "wrong-out", "--sites-only", "--list", str(listed))
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{listed}:1: calc/calc.mbt does not hold \"<=\" at offset {offset_of(self.text, 17, 16)}", result.stderr)


if __name__ == "__main__":
    unittest.main()
