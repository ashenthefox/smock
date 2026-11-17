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
    author = ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"]
    result = subprocess.run(["git", "-C", str(repo), *author, *args], capture_output=True, text=True)
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
            "///|\n/// A text, which is no site: STR's scope does not hold this package.\n"
            'pub let text : String = "a"\n')
        cls.packages = ("--set", "full", "log", "empty")
        cls.whole = cls.run_once(cls.tmp / "whole")
        cls.shards = [cls.run_once(cls.tmp / f"shard-{k}", "--shard", f"{k}/3") for k in (1, 2, 3)]
        cls.merged = cls.tmp / "merged"
        # The shards in any order.
        given = [cls.shards[2], cls.shards[0], cls.shards[1]]
        cls.result = subprocess.run([sys.executable, str(MERGE), "--out", str(cls.merged), *map(str, given)],
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
            for package in packages:
                # Each shard runs the package's self-test (#309), whose
                # timings are timings too.
                package.get("self_test", {}).pop("timings", None)
            return (summary,
                    [({k: v for k, v in p.items() if k not in timings}, p.get("baseline", {}).get("tests"))
                     for p in packages])

        self.assertEqual(counts(self.merged), counts(self.whole))
        self.assertEqual(without_timings((self.merged / "report.md").read_text()),
                         without_timings((self.whole / "report.md").read_text()))
        # The merge prints the report, as a run does.
        self.assertEqual(without_timings(self.result.stdout),
                         without_timings((self.whole / "report.md").read_text()) + "\n")

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


class MergedCountsTest(unittest.TestCase):
    """What merge.py takes again from the records and the shards'
    summaries for the counts that the importers' credit (#300) and kill
    confirmation (#301) add, so that the merged summary is the summary of
    the run without shards (#305). log, which MergeTest shards, has no
    importer and no flaky test, so these are built by hand."""

    def test_the_own_counts_come_from_the_records_and_the_importers_counts_add_up(self):
        import importers
        import run

        # A kill of the package's own tests, and two survivors of them that
        # its importer's tests ran again: one killed, one not.
        records = [{"outcome": "killed", "importers": []},
                   {"outcome": "killed", "importers": ["mutation/fixture/meter"]},
                   {"outcome": "survived", "importers": ["mutation/fixture/meter"]}]
        own = run.outcome_counts(importers.own_records(records))
        self.assertEqual((own["mutants"], own["killed"], own["survived"]), (3, 1, 2))
        # Three shards: one with no survivor, whose importers' tests did not
        # run, and two that each ran one survivor again.
        none = importers.credit(["mutation/fixture/meter"], [])
        first = dict(none, reran=1, killed=1, killed_by={"mutation/fixture/meter": 1}, baseline={"tests": 2},
                     limit_s=4.5)
        second = dict(none, reran=1, baseline={"tests": 2}, limit_s=4.6)
        self.assertEqual(importers.merge_credits([none, first, second]),
                         {"packages": ["mutation/fixture/meter"], "native_only": [], "reran": 2, "killed": 1,
                          "killed_by": {"mutation/fixture/meter": 1}, "baseline": {"tests": 2}, "limit_s": 4.5})

    def test_the_flaky_results_of_this_run_add_up_over_the_shards(self):
        import confirm

        def shard(flaked):
            # A shard's flake records: its package's tests ran twice without
            # a mutant, and one kill ran again with the mutant on.
            return {"version": confirm.VERSION, "threshold": 0.01, "recent_runs": 10,
                    "runs": [{"suites": {"p": 2},
                              "tests": [{"package": "p", "file": "f", "name": "t", "flaked": flaked, "reruns": 1}]}]}

        summary = {"threshold": 0.01, "recent_runs": 10, "runs_read": 0, "above": [], "flaked": []}
        merged = confirm.merged_summary([summary, summary], confirm.merge([shard(1), shard(0)]))
        # One flaky result in 4 runs without a mutant and 2 reruns with it.
        self.assertEqual(merged, dict(summary, flaked=[{"package": "p", "file": "f", "name": "t", "flaked": 1,
                                                        "observed": 6, "rate": round(1 / 6, 6)}]))


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
            # The mutant of a site of v1, written otherwise: halve_until's
            # `x = x / 2` deleted with its indentation, which v1's DEL
            # deletes without it. It does not build (calc.mbt's comment).
            {"file": "calc/calc.mbt", "offset": at(36, 1), "original": "    x = x / 2", "replacement": "",
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
            ("calc/calc.mbt,halve_until,DEL,x = x / 2,,0", 36, 5, True, True),
            # CONTRIBUTING, "Mutation runner": a mutant outside v1 is named
            # as a site is, with the operator it gives (OTHER when it gives
            # none), and an ordinal that counts the same original text
            # outside comments before it in its definition.
            ("calc/calc.mbt,is_odd,ROR,==,!=,0", 75, 11, False, False),
            ("calc/calc.mbt,halve_until,OTHER,x / 2,2 / x,0", 36, 9, False, False),
        ])
        self.assertEqual([m["listed"] for m in chosen], self.entries)
        self.assertEqual(chosen[3]["definition_lines"], [22, 39])
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
            ("calc/calc.mbt,halve_until,DEL,x = x / 2,,0", "unviable", True, "listed"),
            ("calc/calc.mbt,is_odd,ROR,==,!=,0", "killed", False, "listed"),
            ("calc/calc.mbt,halve_until,OTHER,x / 2,2 / x,0", "survived", False, "listed"),
        ])
        self.assertEqual([t["name"] for t in records[2]["killing_tests"]], ["3 is odd"])
        report = (out / "report.md").read_text()
        self.assertIn("Operator set v1, a listed set.", report)
        self.assertIn("## Listed mutants\n\n"
                      "| package | listed | run | no longer apply | outside operator set v1 |\n"
                      "|---|---:|---:|---:|---:|\n"
                      "| calc | 4 | 4 | 0 | 2 |\n\n"
                      "| mutant | operator set v1 | outcome |\n"
                      "|---|---|---|\n"
                      "| `calc/calc.mbt,in_range,ROR,<=,<,1` | in it | survived |\n"
                      "| `calc/calc.mbt,halve_until,DEL,x = x / 2,,0` | in it | unviable |\n"
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
        offset = offset_of(self.text, 17, 16)
        self.assertIn(f'{listed}:1: calc/calc.mbt does not hold "<=" at offset {offset}', result.stderr)


NEXT = "///|\n/// The number after `n`.\npub fn next(n : Int32) -> Int32 {\n  n + 1\n}\n\n"


def later_commit(root):
    """A second commit on the fixture's history: calc.mbt gains a function
    before in_range, six lines, and is_odd's body becomes `n % 2 != 0`."""
    calc = root / "calc" / "calc.mbt"
    text = calc.read_text(encoding="utf-8")
    first = text.index("///|")
    text = text[:first] + NEXT + text[first:]
    calc.write_text(text.replace("  !(n % 2 == 0)\n", "  n % 2 != 0\n"), encoding="utf-8")
    git(root, "commit", "-q", "-am", "a later commit")
    return git(root, "rev-parse", "HEAD").strip()


class ListedByKeyTest(unittest.TestCase):
    """A list of mutants by key, written for the fixture's first commit,
    on a later one."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-choice-keys-"))
        cls.root = cls.tmp / "root"
        fixture_history(cls.root)
        later_commit(cls.root)

        def key(definition, operator, original, replacement, ordinal=0, file="calc/calc.mbt"):
            return {"file": file, "definition": definition, "operator": operator, "original": original,
                    "replacement": replacement, "ordinal": ordinal}

        cls.entries = [
            # Two sites of operator set v1, by their ids: in_range's `n <=
            # high` to `n < high`, which survives, and its `&&` to `||`,
            # which 0 kills (calc.mbt's comments).
            key("in_range", "ROR", "<=", "<", 1),
            key("in_range", "LCR", "&&", "||"),
            # Outside v1, with an operator of its own: halve_until's `x /
            # 2` to `2 / x`, which still halves 100 to 0, so it survives.
            key("halve_until", "SWAP", "x / 2", "2 / x"),
            # Four keys that the later commit leaves without their text: a
            # site of v1 that is gone (is_odd has no `!` any more), a text
            # that is gone, a definition that is gone, a file that is gone.
            key("is_odd", "NOT", "!", ""),
            key("is_odd", "EQ", "n % 2 == 0", "n % 2 != 0"),
            key("is_even", "EQ", "n % 2 == 0", "n % 2 != 0"),
            key("old", "EQ", "1", "2", file="old/old.mbt"),
        ]
        cls.list = write_list(cls.tmp / "keys.jsonl", cls.entries)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_each_key_applies_to_a_later_commit_where_it_still_finds_its_text(self):
        # #305: "applies each to any later commit where that key still
        # finds its text".
        out = self.tmp / "chosen"
        result = run_runner(self.root, out, "--sites-only", "--list", str(self.list))
        self.assertEqual(result.returncode, 0, result.stderr)
        chosen = read_lines(out / "chosen.jsonl")
        # Six lines later than on the first commit.
        self.assertEqual([(m["id"], m["line"], m["column"], m["in_operator_set"]) for m in chosen], [
            ("calc/calc.mbt,in_range,ROR,<=,<,1", 23, 17, True),
            ("calc/calc.mbt,in_range,LCR,&&,||,0", 23, 12, True),
            ("calc/calc.mbt,halve_until,SWAP,x / 2,2 / x,0", 42, 9, False),
        ])
        self.assertEqual([m["listed"] for m in chosen], self.entries[:3])
        # CONTRIBUTING, "Mutation runner": why each other key no longer
        # applies.
        self.assertEqual([(u["directory"], u["listed"], u["why"]) for u in read_lines(out / "unapplied.jsonl")], [
            ("calc", self.entries[3], "no site of operator set v1 has its id"),
            ("calc", self.entries[4], "its text is gone"),
            ("calc", self.entries[5], "its definition is gone"),
            ("old", self.entries[6], "its file is gone"),
        ])

    def test_the_report_counts_the_keys_that_no_longer_apply_beside_the_outcomes_of_the_others(self):
        # #305: "The report counts the mutants that no longer apply, beside
        # the outcomes of the others."
        out = self.tmp / "run"
        result = run_runner(self.root, out, "--list", str(self.list))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([(r["id"], r["outcome"]) for r in read_lines(out / "mutants.jsonl")], [
            ("calc/calc.mbt,in_range,ROR,<=,<,1", "survived"),
            ("calc/calc.mbt,in_range,LCR,&&,||,0", "killed"),
            ("calc/calc.mbt,halve_until,SWAP,x / 2,2 / x,0", "survived"),
        ])
        report = (out / "report.md").read_text()
        self.assertIn("| package | listed | run | no longer apply | outside operator set v1 |\n"
                      "|---|---:|---:|---:|---:|\n"
                      "| calc | 6 | 3 | 3 | 1 |\n"
                      "| old | 1 | 0 | 1 | 0 |\n", report)
        self.assertIn("### No longer apply (4)\n\n"
                      "- `calc/calc.mbt,is_odd,NOT,!,,0`: no site of operator set v1 has its id\n"
                      "- `calc/calc.mbt,is_odd,EQ,n % 2 == 0,n % 2 != 0,0`: its text is gone\n"
                      "- `calc/calc.mbt,is_even,EQ,n % 2 == 0,n % 2 != 0,0`: its definition is gone\n"
                      "- `old/old.mbt,old,EQ,1,2,0`: its file is gone\n", report)

    def test_the_shards_of_a_listed_run_merge_into_its_report(self):
        whole = self.tmp / "whole"
        self.assertEqual(run_runner(self.root, whole, "--list", str(self.list)).returncode, 0)
        shards = [self.tmp / f"shard-{k}" for k in (1, 2)]
        for k, shard in enumerate(shards, 1):
            result = run_runner(self.root, shard, "--list", str(self.list), "--shard", f"{k}/2")
            self.assertEqual(result.returncode, 0, result.stderr)
        # The first shard counts the keys that no longer apply.
        self.assertEqual([len(read_lines(s / "unapplied.jsonl")) for s in shards], [4, 0])
        merged = self.tmp / "merged"
        result = subprocess.run([sys.executable, str(MERGE), "--out", str(merged), *map(str, shards)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("unapplied.jsonl", "report.md"):
            self.assertEqual(without_timings((merged / name).read_text()), without_timings((whole / name).read_text()),
                             name)

    def test_a_run_is_limited_to_the_packages_given(self):
        # #305: "A run can be limited to chosen packages": the list's
        # mutants of other packages are left out, and not counted.
        listed = write_list(self.tmp / "two.jsonl", [
            self.entries[0],
            {"file": "log/lines.mbt", "definition": "cut_mark", "operator": "STR", "original": '"~"',
             "replacement": '"_"', "ordinal": 0},
        ])
        out = self.tmp / "log-only"
        result = run_runner(self.root, out, "--list", str(listed), "log")
        self.assertEqual(result.returncode, 0, result.stderr)
        # cut_mark's mark changed survives (lines.mbt's comment beside it).
        self.assertEqual([(r["id"], r["outcome"]) for r in read_lines(out / "mutants.jsonl")],
                         [('log/lines.mbt,cut_mark,STR,"~","_",0', "survived")])
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual([p["directory"] for p in summary["packages"]], ["log"])
        self.assertIn("| log | 1 | 1 | 0 | 0 |\n\n", (out / "report.md").read_text())


class TotalsOnlyTest(unittest.TestCase):
    """A listed run that writes totals only, on the later commit of the
    fixture's history: among its mutants, one that does not build and one
    that a test fails on."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-choice-totals-"))
        cls.root = cls.tmp / "root"
        fixture_history(cls.root)
        later_commit(cls.root)

        def key(definition, operator, original, replacement, ordinal=0, file="calc/calc.mbt"):
            return {"file": file, "definition": definition, "operator": operator, "original": original,
                    "replacement": replacement, "ordinal": ordinal}

        # The outcomes are those calc.mbt's and lines.mbt's comments give.
        cls.entries = [
            key("halve_until", "DEL", "x = x / 2", ""),  # unviable
            key("in_range", "ROR", "<=", "<"),  # killed: "a number at the low end is in range" fails
            key("in_range", "ROR", "<=", "<", 1),  # survived
            key("halve_until", "SWAP", "x / 2", "2 / x"),  # outside v1, survived
            key("is_odd", "EQ", "n % 2 == 0", "n % 2 != 0"),  # no longer applies
            key("is_comment", "STR", '"#"', '"_"', file="log/lines.mbt"),  # killed
        ]
        cls.list = write_list(cls.tmp / "held-back.jsonl", cls.entries)
        cls.out = cls.tmp / "out"
        cls.out.mkdir()
        # What an earlier run left there, which names a mutant.
        (cls.out / "mutants.jsonl").write_text('{"id": "calc/calc.mbt,in_range,ROR,<=,<,0"}\n')
        cls.work = cls.tmp / "work"
        cls.result = run_runner(cls.root, cls.out, "--list", str(cls.list), "--totals-only", work=cls.work)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_a_totals_only_run_writes_per_package_and_total_counts(self):
        # #305: "a listed-set run writes only per-package and total counts
        # (killed, survived, no longer applying)".
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        summary = json.loads((self.out / "summary.json").read_text())
        fields = ("listed", "killed", "timed_out", "survived", "unviable", "no_longer_apply")
        self.assertEqual([(p["directory"], *[p[f] for f in fields]) for p in summary["packages"]],
                         [("calc", 5, 1, 0, 2, 1, 1), ("log", 1, 1, 0, 0, 0, 0)])
        self.assertEqual([summary["total"][f] for f in fields], [6, 2, 0, 2, 1, 1])
        self.assertEqual(summary["total"]["score"], 0.5)
        self.assertTrue(summary["totals_only"])
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), ["report.md", "summary.json"])
        self.assertIn("| total | 6 | 2 | 0 | 2 | 1 | 1 | 50.0% |", (self.out / "report.md").read_text())

    def test_nothing_a_totals_only_run_prints_or_keeps_names_a_mutant(self):
        # #305: "no record, log line or artifact names a mutant. Nor does the
        # output of the build or of the tests, which can quote a mutated
        # line or value: it is not printed or kept."
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        kept = [self.result.stdout, self.result.stderr]
        kept += [p.read_text(errors="replace") for p in self.out.rglob("*") if p.is_file()]
        kept += [p.read_text(errors="replace") for p in self.work.rglob("*")
                 if p.is_file() and ".mutation-files" not in p.name and p.suffix in (".json", ".jsonl", ".log", ".txt")]
        names = ["calc/calc.mbt", "log/lines.mbt", "in_range", "halve_until", "is_odd", "is_comment",
                 "x = x / 2", "2 / x", "n % 2", '"_"',
                 # The compiler's message on the mutant that does not build,
                 # and the failing test with its snapshot.
                 "never used", "a number at the low end is in range", "content=", "failed"]
        for text in kept:
            for name in names:
                self.assertNotIn(name, text)
        # The work directory keeps no build of a mutant, and its tree holds
        # the source as it is.
        self.assertEqual(sorted(p.name for p in self.work.iterdir() if p.name.startswith("target-")), [])
        self.assertEqual((self.work / "tree-0" / "calc" / "calc.mbt").read_text(),
                         (self.root / "calc" / "calc.mbt").read_text())

    def test_totals_only_needs_a_listed_set_and_a_run_of_its_own(self):
        listed = ["--list", str(self.list)]
        for args in (["calc"], [*listed, "--sites-only"], [*listed, "--shard", "1/2"]):
            result = run_runner(self.root, self.tmp / "refused", "--totals-only", *args, work=self.work)
            self.assertEqual(result.returncode, 2, args)
            self.assertIn("--totals-only", result.stderr)


if __name__ == "__main__":
    unittest.main()
